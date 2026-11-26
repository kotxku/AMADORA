//! Imports an instance from a zip archive: a Pandora instance export (a folder holding `info_v1.json` and
//! `.minecraft/`) or a plain zip of a game folder (whichever folder holds `mods/`, `saves/` or `config/`).
//!
//! Desktop port of AMADORA iOS's PandoraImport. Modrinth `.mrpack` and CurseForge modpack zips go through the
//! regular modpack installer instead. Pandora's nested `.mrpack` files in `mods/` are kept as they are: unlike the
//! iOS app, the desktop launcher unpacks them itself at launch.

use std::{
    io::{BufReader, Read, Seek},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use bridge::modal_action::{ModalAction, ProgressTracker};
use schema::{instance::InstanceConfiguration, loader::Loader};
use serde_json::Value;
use ustr::Ustr;

use crate::directories::LauncherDirectories;

pub struct ArchiveImport {
    pub instance_dir: PathBuf,
    pub name: String,
    pub loader: Loader,
    pub minecraft_version: Ustr,
    pub notes: Vec<String>,
}

/// Turns a zip entry name into safe relative path components. Zip entries are untrusted: absolute paths, `..`,
/// drive letters and empty names are refused. Windows tools write backslashes and `./` prefixes.
pub fn safe_components(name: &str) -> Option<Vec<&str>> {
    let mut components = Vec::new();
    for part in name.split(['/', '\\']) {
        match part {
            "" | "." => continue,
            ".." => return None,
            part if part.contains(':') => return None,
            part => components.push(part),
        }
    }
    if name.starts_with('/') || name.starts_with('\\') || components.is_empty() {
        return None;
    }
    Some(components)
}

struct Entry {
    index: usize,
    components: Vec<String>,
    is_dir: bool,
}

enum Layout {
    /// Folder (as components) holding info_v1.json
    Pandora { base: Vec<String>, configuration: InstanceConfiguration },
    /// Folder (as components) holding mods/, saves/ or config/
    GameFolder { root: Vec<String> },
}

fn detect_layout<R: Read + Seek>(archive: &mut zip::ZipArchive<R>, entries: &[Entry]) -> Result<Layout, String> {
    // The metadata file closest to the archive root decides the format
    if let Some(info) = entries
        .iter()
        .filter(|e| !e.is_dir && e.components.last().map(String::as_str) == Some("info_v1.json"))
        .min_by_key(|e| e.components.len())
    {
        let mut bytes = Vec::new();
        archive
            .by_index(info.index)
            .map_err(|e| e.to_string())?
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        let configuration: InstanceConfiguration =
            serde_json::from_slice(&bytes).map_err(|e| format!("info_v1.json in this archive couldn't be read: {e}"))?;
        return Ok(Layout::Pandora { base: info.components[..info.components.len() - 1].to_vec(), configuration });
    }

    let mut best: Option<Vec<String>> = None;
    for entry in entries {
        let folders = if entry.is_dir { entry.components.len() } else { entry.components.len() - 1 };
        for i in 0..folders {
            if best.as_ref().is_some_and(|b| b.len() <= i) {
                break;
            }
            if matches!(entry.components[i].as_str(), "mods" | "saves" | "config") {
                best = Some(entry.components[..i].to_vec());
                break;
            }
        }
    }
    best.map(|root| Layout::GameFolder { root })
        .ok_or_else(|| "This archive has no mods, saves or config folder, so it doesn't look like a Minecraft instance.".to_string())
}

/// "1.20.1", "~1.20.1", "=1.20.1" or ">=1.20.1 <1.21" give "1.20.1"; wildcards and ranges with an `x` don't count.
fn exact_minecraft_version(predicate: &str) -> Option<String> {
    let first = predicate.split_whitespace().next()?;
    let version = first.trim_start_matches(['~', '^', '=', '>']);
    if version.is_empty() || first.starts_with('<') || !version.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return None;
    }
    if version.split('.').count() < 2 {
        return None;
    }
    Some(version.to_string())
}

/// Guesses loader and Minecraft version from the mods in a plain game folder.
fn detect_loader_and_version(mods_dir: &Path) -> (Loader, Option<String>) {
    let mut fabric = 0usize;
    let mut forge = 0usize;
    let mut neoforge = 0usize;
    let mut versions: std::collections::HashMap<String, usize> = Default::default();
    let Ok(read_dir) = std::fs::read_dir(mods_dir) else {
        return (Loader::Vanilla, None);
    };
    for entry in read_dir.flatten() {
        if !entry.file_name().to_string_lossy().to_lowercase().ends_with(".jar") {
            continue;
        }
        let Ok(file) = std::fs::File::open(entry.path()) else {
            continue;
        };
        let Ok(mut archive) = zip::ZipArchive::new(BufReader::new(file)) else {
            continue;
        };
        if let Some(json) = crate::mod_doctor::read_fabric_mod_json(&mut archive) {
            fabric += 1;
            if let Some(version) = json.pointer("/depends/minecraft").and_then(Value::as_str).and_then(exact_minecraft_version) {
                *versions.entry(version).or_default() += 1;
            }
        } else if archive.by_name("META-INF/neoforge.mods.toml").is_ok() {
            neoforge += 1;
        } else if archive.by_name("META-INF/mods.toml").is_ok() {
            forge += 1;
        }
    }
    let loader = if fabric > 0 && fabric >= forge && fabric >= neoforge {
        Loader::Fabric
    } else if neoforge > 0 && neoforge >= forge {
        Loader::NeoForge
    } else if forge > 0 {
        Loader::Forge
    } else {
        Loader::Vanilla
    };
    let version = versions.into_iter().max_by_key(|(_, count)| *count).map(|(version, _)| version);
    (loader, version)
}

fn unique_temp_dir(directories: &LauncherDirectories) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default();
    directories.temp_dir.join(format!("archive-import-{}-{nanos}", std::process::id()))
}

/// Blocking: call from `spawn_blocking`. `fallback_version` is used when a plain zip doesn't say which Minecraft
/// version it's for (normally the latest release).
pub fn import_archive(
    directories: &LauncherDirectories,
    archive_path: &Path,
    fallback_version: Option<Ustr>,
    modal_action: &ModalAction,
    tracker: &ProgressTracker,
) -> Result<ArchiveImport, String> {
    let file = std::fs::File::open(archive_path).map_err(|e| format!("Couldn't open {}: {e}", archive_path.display()))?;
    let mut archive =
        zip::ZipArchive::new(BufReader::new(file)).map_err(|e| format!("Couldn't open {} as a zip: {e}", archive_path.display()))?;

    let mut entries = Vec::with_capacity(archive.len());
    for index in 0..archive.len() {
        let Ok(file) = archive.by_index_raw(index) else {
            continue;
        };
        let name = file.name().to_string();
        let Some(components) = safe_components(&name) else {
            log::warn!("Skipping unsafe zip entry {name:?}");
            continue;
        };
        entries.push(Entry {
            index,
            components: components.into_iter().map(str::to_string).collect(),
            is_dir: file.is_dir() || name.ends_with('/') || name.ends_with('\\'),
        });
    }

    let layout = detect_layout(&mut archive, &entries)?;
    let file_stem = archive_path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Imported".into());
    let mut notes = Vec::new();

    let (prefix, target_subdir, mut name) = match &layout {
        Layout::Pandora { base, .. } => (base.clone(), None, base.last().cloned().unwrap_or(file_stem)),
        Layout::GameFolder { root } => {
            let name = match root.last().map(String::as_str) {
                Some(".minecraft" | "minecraft") if root.len() >= 2 => root[root.len() - 2].clone(),
                Some(".minecraft" | "minecraft") | None => file_stem,
                Some(other) => other.to_string(),
            };
            (root.clone(), Some(".minecraft"), name)
        }
    };

    name = sanitize_filename::sanitize_with_options(&name, sanitize_filename::Options { windows: true, ..Default::default() });
    if name.is_empty() || name.starts_with('.') {
        name = format!("Imported{name}");
    }
    let name = crate::fs::unique_name(&directories.instances_dir, &name, true).into_owned();

    let temp_dir = unique_temp_dir(directories);
    let extract_root = match target_subdir {
        Some(sub) => temp_dir.join(sub),
        None => temp_dir.clone(),
    };
    std::fs::create_dir_all(&extract_root).map_err(|e| format!("Couldn't create {}: {e}", extract_root.display()))?;
    let cleanup = scopeguard::guard(temp_dir.clone(), |dir| {
        _ = std::fs::remove_dir_all(dir);
    });

    let to_extract: Vec<&Entry> = entries.iter().filter(|e| e.components.len() > prefix.len() && e.components.starts_with(&prefix)).collect();
    tracker.set_total(to_extract.len());
    for entry in to_extract {
        if modal_action.has_requested_cancel() {
            return Err("Import cancelled".into());
        }
        let mut dest = extract_root.clone();
        for component in &entry.components[prefix.len()..] {
            dest.push(component);
        }
        if entry.is_dir {
            std::fs::create_dir_all(&dest).map_err(|e| format!("Couldn't create {}: {e}", dest.display()))?;
        } else {
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent).map_err(|e| format!("Couldn't create {}: {e}", parent.display()))?;
            }
            // Streamed: whole-file extraction would run out of memory on multi-GB worlds
            let mut zip_file = archive.by_index(entry.index).map_err(|e| e.to_string())?;
            let mut out = std::fs::File::create(&dest).map_err(|e| format!("Couldn't write {}: {e}", dest.display()))?;
            std::io::copy(&mut zip_file, &mut out).map_err(|e| format!("Couldn't extract {}: {e}", entry.components.join("/")))?;
        }
        tracker.add_count(1);
    }

    let (loader, minecraft_version) = match layout {
        Layout::Pandora { configuration, .. } => {
            let mrpacks = std::fs::read_dir(temp_dir.join(".minecraft").join("mods"))
                .map(|dir| dir.flatten().filter(|e| e.file_name().to_string_lossy().to_lowercase().contains(".mrpack")).count())
                .unwrap_or(0);
            if mrpacks > 0 {
                notes.push(format!("Kept {mrpacks} installed modpack(s) in mods/. AMADORA unpacks them when the instance launches."));
            }
            (configuration.loader, configuration.minecraft_version)
        }
        Layout::GameFolder { .. } => {
            let (loader, detected) = detect_loader_and_version(&extract_root.join("mods"));
            let version = match (detected, fallback_version) {
                (Some(version), _) => Ustr::from(version.as_str()),
                (None, Some(fallback)) => {
                    notes.push(format!(
                        "This zip doesn't say which Minecraft version it's for, so the instance uses {fallback}. Change it in the instance's settings if that's wrong."
                    ));
                    fallback
                }
                (None, None) => return Err("This zip doesn't say which Minecraft version it's for, and the version list couldn't be downloaded. Check your connection and try again.".into()),
            };
            if loader == Loader::Vanilla && extract_root.join("mods").is_dir() {
                notes.push("Couldn't tell which mod loader the mods are for, so the instance is vanilla. Pick a loader in the instance's settings.".into());
            }
            let configuration = InstanceConfiguration::new(version, loader);
            let json = serde_json::to_string(&configuration).map_err(|e| e.to_string())?;
            crate::fs::write_safe(&temp_dir.join("info_v1.json"), json.as_bytes()).map_err(|e| e.to_string())?;
            (loader, version)
        }
    };

    let instance_dir = directories.instances_dir.join(&name);
    crate::fs::rename_with_fallback_across_devices(&temp_dir, &instance_dir)
        .map_err(|e| format!("Couldn't move the imported instance into place: {e}"))?;
    scopeguard::ScopeGuard::into_inner(cleanup);

    Ok(ArchiveImport { instance_dir, name, loader, minecraft_version, notes })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsafe_entries_are_refused() {
        assert_eq!(safe_components("a/b.txt"), Some(vec!["a", "b.txt"]));
        assert_eq!(safe_components("./a\\b.txt"), Some(vec!["a", "b.txt"]));
        assert_eq!(safe_components("../evil"), None);
        assert_eq!(safe_components("a/../../evil"), None);
        assert_eq!(safe_components("/etc/passwd"), None);
        assert_eq!(safe_components("C:/Windows/evil.dll"), None);
        assert_eq!(safe_components(""), None);
    }

    #[test]
    fn minecraft_version_predicates() {
        assert_eq!(exact_minecraft_version("1.20.1").as_deref(), Some("1.20.1"));
        assert_eq!(exact_minecraft_version("~1.20.1").as_deref(), Some("1.20.1"));
        assert_eq!(exact_minecraft_version(">=1.20.1 <1.21").as_deref(), Some("1.20.1"));
        assert_eq!(exact_minecraft_version("1.20.x"), None);
        assert_eq!(exact_minecraft_version("*"), None);
        assert_eq!(exact_minecraft_version("<1.21"), None);
    }
}

impl crate::BackendState {
    /// Imports a Pandora instance export or a plain game-folder zip as a new instance, then runs Mod Doctor on it.
    pub async fn import_instance_archive(self: &std::sync::Arc<Self>, file: PathBuf, modal_action: ModalAction) {
        let fallback_version = self
            .meta
            .fetch(crate::metadata::items::MinecraftVersionManifestMetadataItem)
            .await
            .ok()
            .map(|manifest| manifest.latest.release);

        self.file_watching.write().watch_filesystem(self.directories.instances_dir.clone(), crate::WatchTarget::InstancesDir);

        let directories = self.directories.clone();
        let tracker = modal_action.push_tracker("Extracting files".into());
        let result = {
            let modal_action = modal_action.clone();
            let tracker = tracker.clone();
            tokio::task::spawn_blocking(move || import_archive(&directories, &file, fallback_version, &modal_action, &tracker))
                .await
                .unwrap_or_else(|e| Err(format!("Import failed: {e}")))
        };

        let import = match result {
            Ok(import) => {
                tracker.set_finished(bridge::modal_action::ProgressTrackerFinishType::Normal);
                import
            },
            Err(error) => {
                tracker.set_finished(bridge::modal_action::ProgressTrackerFinishType::Error);
                modal_action.set_finished_with_error(error.into());
                return;
            },
        };

        let mut report = format!("Imported \"{}\" ({} {}).", import.name, import.loader.pretty_name(), import.minecraft_version);
        for note in &import.notes {
            report.push_str("\n\n");
            report.push_str(note);
        }
        if import.loader == Loader::Fabric {
            let doctor = modal_action.push_tracker("Mod Doctor: checking for missing mods".into());
            let client = self.http_client_provider.client();
            let doctor_report =
                crate::mod_doctor::fix_missing_mods(&client, &import.instance_dir.join(".minecraft"), import.minecraft_version.as_str(), import.loader).await;
            doctor.set_finished(bridge::modal_action::ProgressTrackerFinishType::Normal);
            report.push_str("\n\n");
            report.push_str(&doctor_report);
        }

        log::info!("{report}");
        self.send.send_success(report);
        modal_action.set_finished();
    }
}
