//! Mod Doctor: finds Fabric mods whose required dependencies are missing and downloads them from Modrinth.
//!
//! Desktop port of AMADORA iOS's ModDoctor. Only `fabric.mod.json` is read; Forge and NeoForge `mods.toml`
//! dependencies are not checked. Native-code mods that the iOS build switches off (C2ME, PhysX, OpenCL) work on
//! desktop, so that part of the iOS doctor is not ported.

use std::{
    collections::{BTreeSet, HashMap, HashSet},
    io::{Cursor, Read, Seek},
    path::Path,
};

use schema::loader::Loader;
use serde::Deserialize;
use serde_json::Value;
use sha1::{Digest, Sha1};

/// Dependency ids that are provided by the game or the loader, never by a jar in mods/.
const BUILT_IN: &[&str] = &["minecraft", "java", "fabricloader", "fabric-loader"];

/// Newly downloaded mods can have dependencies of their own; stop after this many rounds.
const MAX_PASSES: usize = 5;

/// Deepest jar-in-jar nesting that is scanned.
const MAX_NESTING: usize = 4;

/// Nested jars bigger than this are not read into memory.
const MAX_NESTED_JAR_SIZE: u64 = 64 * 1024 * 1024;

#[derive(Default)]
struct ModScan {
    provides: HashSet<String>,
    depends_by_mod: HashMap<String, BTreeSet<String>>,
}

/// Parses JSON the way Fabric Loader tolerates it: comments, trailing commas and raw newlines inside strings.
pub fn parse_lenient_json(bytes: &[u8]) -> Option<Value> {
    if let Ok(value) = serde_json::from_slice(bytes) {
        return Some(value);
    }
    let text = String::from_utf8_lossy(bytes);
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    let mut in_string = false;
    while let Some(c) = chars.next() {
        if in_string {
            match c {
                '\\' => {
                    out.push(c);
                    if let Some(next) = chars.next() {
                        out.push(next);
                    }
                }
                '"' => {
                    in_string = false;
                    out.push(c);
                }
                '\n' | '\r' => out.push(' '),
                _ => out.push(c),
            }
            continue;
        }
        match c {
            '"' => {
                in_string = true;
                out.push(c);
            }
            '/' if chars.peek() == Some(&'/') => {
                while let Some(&next) = chars.peek() {
                    if next == '\n' {
                        break;
                    }
                    chars.next();
                }
            }
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                let mut last = '\0';
                for next in chars.by_ref() {
                    if last == '*' && next == '/' {
                        break;
                    }
                    last = next;
                }
            }
            _ => out.push(c),
        }
    }
    // Drop trailing commas before a closing bracket
    let bytes = out.as_bytes();
    let mut cleaned: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut in_string = false;
    let mut escaped = false;
    for (i, &b) in bytes.iter().enumerate() {
        if in_string {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_string = false;
            }
            cleaned.push(b);
            continue;
        }
        if b == b'"' {
            in_string = true;
        }
        if b == b',' {
            let rest = bytes[i + 1..].iter().find(|c| !c.is_ascii_whitespace());
            if matches!(rest, Some(b'}') | Some(b']')) {
                continue;
            }
        }
        cleaned.push(b);
    }
    serde_json::from_slice(&cleaned).ok()
}

/// Reads `fabric.mod.json` from a zip.
pub fn read_fabric_mod_json<R: Read + Seek>(archive: &mut zip::ZipArchive<R>) -> Option<Value> {
    let mut file = archive.by_name("fabric.mod.json").ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    parse_lenient_json(&bytes)
}

fn scan_archive<R: Read + Seek>(archive: &mut zip::ZipArchive<R>, owner_fallback: &str, record_depends: bool, depth: usize, scan: &mut ModScan) {
    let Some(json) = read_fabric_mod_json(archive) else {
        return;
    };
    let mod_id = json.get("id").and_then(Value::as_str).map(str::to_string);
    if let Some(id) = &mod_id {
        scan.provides.insert(id.clone());
    }
    if let Some(provides) = json.get("provides").and_then(Value::as_array) {
        for alias in provides.iter().filter_map(Value::as_str) {
            scan.provides.insert(alias.to_string());
        }
    }
    if record_depends {
        let owner = mod_id.clone().unwrap_or_else(|| owner_fallback.to_string());
        let entry = scan.depends_by_mod.entry(owner).or_default();
        if let Some(depends) = json.get("depends").and_then(Value::as_object) {
            entry.extend(depends.keys().cloned());
        }
    }

    if depth >= MAX_NESTING {
        return;
    }
    let nested: Vec<String> = json
        .get("jars")
        .and_then(Value::as_array)
        .map(|jars| jars.iter().filter_map(|jar| jar.get("file").and_then(Value::as_str)).map(str::to_string).collect())
        .unwrap_or_default();
    for inner in nested {
        let Ok(mut file) = archive.by_name(&inner) else {
            continue;
        };
        if file.size() > MAX_NESTED_JAR_SIZE {
            continue;
        }
        let mut bytes = Vec::with_capacity(file.size() as usize);
        if file.read_to_end(&mut bytes).is_err() {
            continue;
        }
        drop(file);
        if let Ok(mut inner_archive) = zip::ZipArchive::new(Cursor::new(bytes)) {
            scan_archive(&mut inner_archive, &inner, record_depends, depth + 1, scan);
        }
    }
}

fn scan_mods_dir(mods_dir: &Path) -> ModScan {
    let mut scan = ModScan::default();
    let Ok(read_dir) = std::fs::read_dir(mods_dir) else {
        return scan;
    };
    for entry in read_dir.flatten() {
        let file_name = entry.file_name().to_string_lossy().to_lowercase();
        // Mods the player switched off count as present, so they aren't reinstalled behind the player's back
        let record_depends = if file_name.ends_with(".jar") {
            true
        } else if file_name.ends_with(".jar.disabled") {
            false
        } else {
            continue;
        };
        let Ok(file) = std::fs::File::open(entry.path()) else {
            continue;
        };
        let Ok(mut archive) = zip::ZipArchive::new(std::io::BufReader::new(file)) else {
            continue;
        };
        scan_archive(&mut archive, &file_name, record_depends, 0, &mut scan);
    }
    scan
}

/// Applies `config/fabric_loader_dependencies.json` the way Fabric Loader does; packs use it to drop dependencies.
fn apply_dependency_overrides(dot_minecraft: &Path, depends_by_mod: &mut HashMap<String, BTreeSet<String>>) {
    let Ok(bytes) = std::fs::read(dot_minecraft.join("config").join("fabric_loader_dependencies.json")) else {
        return;
    };
    let Some(json) = parse_lenient_json(&bytes) else {
        return;
    };
    let Some(overrides) = json.get("overrides").and_then(Value::as_object) else {
        return;
    };
    for (mod_id, rules) in overrides {
        let Some(depends) = depends_by_mod.get_mut(mod_id) else {
            continue;
        };
        let keys = |name: &str| -> Vec<String> {
            rules.get(name).and_then(Value::as_object).map(|o| o.keys().cloned().collect()).unwrap_or_default()
        };
        if rules.get("depends").and_then(Value::as_object).is_some() {
            *depends = keys("depends").into_iter().collect();
        }
        depends.extend(keys("+depends"));
        for removed in keys("-depends") {
            depends.remove(&removed);
        }
    }
}

#[derive(Deserialize)]
struct ModrinthVersion {
    files: Vec<ModrinthVersionFile>,
}

#[derive(Deserialize)]
struct ModrinthVersionFile {
    url: String,
    filename: String,
    primary: bool,
    hashes: HashMap<String, String>,
}

#[derive(Deserialize)]
struct ModrinthSearch {
    hits: Vec<ModrinthSearchHit>,
}

#[derive(Deserialize)]
struct ModrinthSearchHit {
    project_id: String,
    slug: Option<String>,
    title: Option<String>,
}

fn normalized(name: &str) -> String {
    name.to_lowercase().chars().filter(|c| !matches!(c, '-' | '_' | ' ')).collect()
}

async fn fetch_json<T: for<'de> Deserialize<'de>>(client: &reqwest::Client, url: url::Url) -> Option<T> {
    let response = client.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.json().await.ok()
}

async fn modrinth_file_for_project(client: &reqwest::Client, project: &str, minecraft_version: &str) -> Option<ModrinthVersionFile> {
    let mut url = url::Url::parse("https://api.modrinth.com/v2/project/").ok()?;
    url.path_segments_mut().ok()?.pop_if_empty().push(project).push("version");
    url.query_pairs_mut()
        .append_pair("loaders", "[\"fabric\"]")
        .append_pair("game_versions", &serde_json::to_string(&[minecraft_version]).ok()?);
    let versions: Vec<ModrinthVersion> = fetch_json(client, url).await?;
    let mut files = versions.into_iter().next()?.files;
    let index = files.iter().position(|f| f.primary).unwrap_or(0);
    if index < files.len() { Some(files.swap_remove(index)) } else { None }
}

/// Finds a Modrinth file for a mod id. Searches only accept a project whose slug or title matches the id exactly
/// (ignoring case, dashes and underscores), so a lookalike is never installed.
async fn modrinth_file_for_mod_id(client: &reqwest::Client, mod_id: &str, minecraft_version: &str) -> Option<ModrinthVersionFile> {
    // "fabric" is the old id of Fabric API
    let slug = if mod_id == "fabric" { "fabric-api" } else { mod_id };
    let mut candidates = vec![slug.to_string()];
    let dashed = slug.replace('_', "-");
    if dashed != slug {
        candidates.push(dashed);
    }
    for candidate in &candidates {
        if let Some(file) = modrinth_file_for_project(client, candidate, minecraft_version).await {
            return Some(file);
        }
    }

    let mut url = url::Url::parse("https://api.modrinth.com/v2/search").ok()?;
    url.query_pairs_mut()
        .append_pair("query", mod_id)
        .append_pair("limit", "10")
        .append_pair("facets", &format!("[[\"project_type:mod\"],[\"versions:{minecraft_version}\"],[\"categories:fabric\"]]"));
    let search: ModrinthSearch = fetch_json(client, url).await?;
    let wanted = normalized(slug);
    for hit in search.hits {
        let matches = hit.slug.as_deref().map(normalized).as_deref() == Some(&*wanted)
            || hit.title.as_deref().map(normalized).as_deref() == Some(&*wanted);
        if !matches {
            continue;
        }
        if let Some(file) = modrinth_file_for_project(client, &hit.project_id, minecraft_version).await {
            return Some(file);
        }
    }
    None
}

/// Downloads a Modrinth file into mods/, checking its SHA-1. Returns the saved file name.
async fn download_into(client: &reqwest::Client, file: &ModrinthVersionFile, mods_dir: &Path) -> Result<String, String> {
    // The file name comes from the server: keep it to one plain path component ending in .jar
    let name = sanitize_filename::sanitize_with_options(&file.filename, sanitize_filename::Options { windows: true, ..Default::default() });
    if name.is_empty() || name.starts_with('.') || !name.to_lowercase().ends_with(".jar") || !crate::fs::is_single_component_path_str(&name) {
        return Err(format!("refused file name {:?}", file.filename));
    }
    let url = url::Url::parse(&file.url).map_err(|e| e.to_string())?;
    if url.scheme() != "https" {
        return Err("download URL is not HTTPS".into());
    }
    let response = client.get(url).send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if let Some(expected) = file.hashes.get("sha1") {
        let actual = hex::encode(Sha1::digest(&bytes));
        if !actual.eq_ignore_ascii_case(expected) {
            return Err("SHA-1 mismatch".into());
        }
    }
    std::fs::create_dir_all(mods_dir).map_err(|e| e.to_string())?;
    let dest = mods_dir.join(&name);
    crate::fs::write_safe(&dest, &bytes).map_err(|e| e.to_string())?;
    Ok(name)
}

/// Checks an instance's mods and downloads missing required Fabric dependencies. Returns a report for the player.
pub async fn fix_missing_mods(client: &reqwest::Client, dot_minecraft: &Path, minecraft_version: &str, loader: Loader) -> String {
    if loader != Loader::Fabric {
        return format!("Mod Doctor can only check Fabric mods. This instance uses {}.", loader.pretty_name());
    }
    if minecraft_version.is_empty() {
        return "Mod Doctor needs to know the Minecraft version. Set one for this instance first.".into();
    }

    let mods_dir = dot_minecraft.join("mods");
    let mut installed = Vec::new();
    let mut not_found = Vec::new();
    let mut tried: HashSet<String> = HashSet::new();

    for _ in 0..MAX_PASSES {
        let scan_dir = mods_dir.clone();
        let dot_minecraft_owned = dot_minecraft.to_path_buf();
        let missing = tokio::task::spawn_blocking(move || {
            let mut scan = scan_mods_dir(&scan_dir);
            apply_dependency_overrides(&dot_minecraft_owned, &mut scan.depends_by_mod);
            let mut missing: BTreeSet<String> = scan.depends_by_mod.into_values().flatten().collect();
            missing.retain(|id| !scan.provides.contains(id) && !BUILT_IN.contains(&id.as_str()));
            missing
        })
        .await
        .unwrap_or_default();

        let missing: Vec<String> = missing.into_iter().filter(|id| !tried.contains(id)).collect();
        if missing.is_empty() {
            break;
        }

        for mod_id in missing {
            tried.insert(mod_id.clone());
            let Some(file) = modrinth_file_for_mod_id(client, &mod_id, minecraft_version).await else {
                not_found.push(mod_id);
                continue;
            };
            match download_into(client, &file, &mods_dir).await {
                Ok(saved) => {
                    log::info!("[ModDoctor] Installed {mod_id} as {saved}");
                    installed.push(format!("{mod_id} ({saved})"));
                }
                Err(err) => {
                    log::warn!("[ModDoctor] Couldn't download {mod_id}: {err}");
                    not_found.push(format!("{mod_id} (download failed: {err})"));
                }
            }
        }
    }

    if installed.is_empty() && not_found.is_empty() {
        return "No missing mods. Every dependency is installed.".into();
    }
    let mut report = String::new();
    if !installed.is_empty() {
        report.push_str(&format!("Downloaded {} missing mod(s):\n{}", installed.len(), installed.join("\n")));
    }
    if !not_found.is_empty() {
        if !report.is_empty() {
            report.push_str("\n\n");
        }
        report.push_str(&format!(
            "Couldn't find these on Modrinth for Minecraft {minecraft_version}, so add them yourself:\n{}",
            not_found.join("\n")
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lenient_json_accepts_comments_and_trailing_commas() {
        let text = br#"{
            // comment
            "id": "example", /* block */
            "depends": { "fabric-api": "*", },
            "description": "line one
line two",
        }"#;
        let value = parse_lenient_json(text).unwrap();
        assert_eq!(value["id"], "example");
        assert!(value["depends"].get("fabric-api").is_some());
    }

    #[test]
    fn lenient_json_keeps_utf8() {
        let value = parse_lenient_json("{\"name\": \"Café\", }".as_bytes()).unwrap();
        assert_eq!(value["name"], "Café");
    }

    #[test]
    fn overrides_replace_add_and_remove() {
        let dir = std::env::temp_dir().join(format!("amadora-doctor-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("config")).unwrap();
        std::fs::write(
            dir.join("config/fabric_loader_dependencies.json"),
            r#"{"version":1,"overrides":{"a":{"-depends":{"x":"*"},"+depends":{"z":"*"}}}}"#,
        )
        .unwrap();
        let mut depends = HashMap::new();
        depends.insert("a".to_string(), BTreeSet::from(["x".to_string(), "y".to_string()]));
        apply_dependency_overrides(&dir, &mut depends);
        assert_eq!(depends["a"], BTreeSet::from(["y".to_string(), "z".to_string()]));
        _ = std::fs::remove_dir_all(dir);
    }
}
