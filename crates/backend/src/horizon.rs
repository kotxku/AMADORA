//! Horizon instances: Minecraft: Java Edition 26.3 rewritten in Rust (Horizon, MIT licensed at the commit AMADORA
//! builds), played in place of Java Minecraft. The desktop counterpart of AMADORA iOS's HorizonGame.m and
//! HorizonSetup.m, through Horizon's Launch API (docs/api/launch.md in Horizon's source):
//!
//! - The engine is a Horizon release folder (`horizon-client`, `horizon-prepare`, `research-lock.json` and the
//!   compiled exporters) that AMADORA's packages carry beside the launcher (see [`engine_dir`]).
//! - Setup downloads the pinned 26.3 files from Mojang into AMADORA's own libraries and assets, with the pinned Java
//!   runtime, then runs `horizon-prepare`, which turns them into the resources `horizon-client --resources` reads.
//!   They are shared by every Horizon instance, under `<AMADORA>/horizon/resources`.
//! - Play starts `horizon-client` in the instance's .minecraft and hands the Microsoft account's session over on
//!   its standard input. Horizon is started only for a signed-in Microsoft account (one that owns Java Edition),
//!   as the Launch API asks.

use std::{
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use bridge::modal_action::{ModalAction, ProgressTracker, ProgressTrackerFinishType};
use command::{PandoraChild, PandoraCommand};
use schema::{
    instance::InstanceConfiguration,
    version::{GameLibraryArtifact, MinecraftVersion},
};
use serde::Deserialize;
use sha1::{Digest, Sha1};

use crate::{account::MinecraftLoginInfo, BackendState};

/// Content mods of a Horizon modpack (a Horizon port's carry folders, each with a horizon-mod.toml), loaded with
/// `--dev-mod` in name order. AMADORA iOS keeps them in the same folder.
pub const CONTENT_MODS_FOLDER: &str = "content-mods";

fn program(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX))
}

/// The Horizon release folder: `AMADORA_HORIZON_DIR` when set (a folder you built or downloaded yourself), else
/// `horizon` beside the AMADORA executable (the Windows installer and the portable archives), else
/// `../lib/amadora/horizon` from it (the Linux packages, the AppImage and the Flatpak).
pub fn engine_dir() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(dir) = std::env::var_os("AMADORA_HORIZON_DIR") {
        candidates.push(PathBuf::from(dir));
    }
    if let Some(exe_dir) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)) {
        candidates.push(exe_dir.join("horizon"));
        if let Some(prefix) = exe_dir.parent() {
            candidates.push(prefix.join("lib").join("amadora").join("horizon"));
        }
    }
    candidates.into_iter().find(|dir| {
        program(dir, "horizon-client").is_file() && program(dir, "horizon-prepare").is_file() && dir.join("research-lock.json").is_file()
    })
}

/// The pins from research-lock.json that preparing needs.
#[derive(Deserialize, Debug, Clone)]
pub struct MinecraftPins {
    pub version: String,
    pub manifest_sha1: String,
    pub client_sha1: String,
    pub server_sha1: String,
}

#[derive(Deserialize)]
struct ResearchLock {
    minecraft: MinecraftPins,
}

fn read_pins(engine: &Path) -> Result<MinecraftPins, String> {
    let bytes = std::fs::read(engine.join("research-lock.json"))
        .map_err(|err| format!("Couldn't read Horizon's research-lock.json: {err}"))?;
    let lock: ResearchLock =
        serde_json::from_slice(&bytes).map_err(|err| format!("Couldn't read Horizon's research-lock.json: {err}"))?;
    for hash in [&lock.minecraft.manifest_sha1, &lock.minecraft.client_sha1, &lock.minecraft.server_sha1] {
        if hash.len() != 40 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("Horizon's research-lock.json has an invalid SHA-1".into());
        }
    }
    if !crate::fs::is_single_component_path_str(&lock.minecraft.version) {
        return Err("Horizon's research-lock.json has an invalid version".into());
    }
    Ok(lock.minecraft)
}

/// Where Horizon's shared files live: `<AMADORA>/horizon`.
pub struct HorizonHome {
    pub root: PathBuf,
}

impl HorizonHome {
    pub fn new(state: &BackendState) -> Self {
        Self { root: state.directories.root_launcher_dir.join("horizon") }
    }

    /// The prepared 26.3 resources every Horizon instance plays with.
    pub fn resources(&self) -> PathBuf {
        self.root.join("resources")
    }

    /// A writable copy of the release folder's sources and exporters, which horizon-prepare uses as its root
    /// (it keeps its imports and scratch files in the root's .local/). The release folder itself may be read-only.
    fn prepare_root(&self) -> PathBuf {
        self.root.join("prepare")
    }

    fn downloads(&self) -> PathBuf {
        self.root.join("downloads")
    }
}

/// Why a Horizon instance can't start in this build, else None.
pub fn start_problem() -> Option<&'static str> {
    if engine_dir().is_none() {
        return Some(
            "This build of AMADORA doesn't include Horizon. Use a release that has a horizon folder beside AMADORA, \
             or set AMADORA_HORIZON_DIR to a Horizon release folder.",
        );
    }
    None
}

fn sha1_hex(bytes: &[u8]) -> String {
    hex::encode(Sha1::digest(bytes))
}

fn sha1_of_file(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut hasher = Sha1::new();
    std::io::copy(&mut file, &mut hasher).ok()?;
    Some(hex::encode(hasher.finalize()))
}

async fn download_verified(client: &reqwest::Client, url: &str, path: &Path, sha1: &str) -> Result<(), String> {
    if sha1_of_file(path).is_some_and(|actual| actual.eq_ignore_ascii_case(sha1)) {
        return Ok(());
    }
    if !url.starts_with("https://") {
        return Err(format!("Refusing a download that isn't HTTPS: {url}"));
    }
    let mut last_error = String::new();
    for _ in 0..3 {
        let response = match client.get(url).send().await.and_then(|r| r.error_for_status()) {
            Ok(response) => response,
            Err(err) => {
                last_error = format!("Couldn't download {url}: {err}");
                continue;
            },
        };
        let bytes = match response.bytes().await {
            Ok(bytes) => bytes,
            Err(err) => {
                last_error = format!("Couldn't download {url}: {err}");
                continue;
            },
        };
        let actual = sha1_hex(&bytes);
        if !actual.eq_ignore_ascii_case(sha1) {
            last_error = format!("{url} didn't match its SHA-1 (expected {sha1}, got {actual})");
            continue;
        }
        return crate::fs::write_safe(path, &bytes).map_err(|err| format!("Couldn't save {}: {err}", path.display()));
    }
    Err(last_error)
}

/// Copies the release folder's files (not its programs) into the writable prepare root, replacing what an older
/// AMADORA put there. The root's .local/ (imports and scratch files) is kept.
fn refresh_prepare_root(engine: &Path, root: &Path) -> std::io::Result<()> {
    fn copy_tree(from: &Path, to: &Path, top: bool) -> std::io::Result<()> {
        std::fs::create_dir_all(to)?;
        for entry in std::fs::read_dir(from)? {
            let entry = entry?;
            let name = entry.file_name();
            let source = entry.path();
            let target = to.join(&name);
            let file_type = entry.file_type()?;
            if top {
                let text = name.to_string_lossy();
                if text == ".local" || text.starts_with("horizon-") && !source.is_dir() {
                    continue;
                }
            }
            if file_type.is_dir() {
                copy_tree(&source, &target, false)?;
            } else if file_type.is_file() {
                std::fs::copy(&source, &target)?;
            }
        }
        Ok(())
    }
    for entry in std::fs::read_dir(root).into_iter().flatten().flatten() {
        if entry.file_name() != ".local" {
            let path = entry.path();
            if path.is_dir() {
                std::fs::remove_dir_all(&path)?;
            } else {
                std::fs::remove_file(&path)?;
            }
        }
    }
    copy_tree(engine, root, true)
}

fn hidden_command(program: &Path) -> std::process::Command {
    #[allow(unused_mut)]
    let mut command = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window over the launcher
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

/// `horizon-prepare --check`: whether the resources are complete and current for this build's preparer.
fn resources_current(engine: &Path, root: &Path, resources: &Path) -> bool {
    if !resources.join("horizon-resources.json").is_file() {
        return false;
    }
    // A root copied from another Horizon build (before an AMADORA update) prepares again
    let same_build = ["research-lock.json", ".amadora-horizon-commit"].iter().all(|file| {
        std::fs::read(root.join(file)).ok() == std::fs::read(engine.join(file)).ok()
    }) && root.join("research-lock.json").is_file();
    if !same_build {
        return false;
    }
    hidden_command(&program(engine, "horizon-prepare"))
        .arg("--check")
        .arg("--root")
        .arg(root)
        .arg("--output")
        .arg(resources)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[derive(Deserialize)]
struct PrepareProgress {
    message: Option<String>,
    fraction: Option<f64>,
    error: Option<String>,
}

impl BackendState {
    /// Prepares Horizon's 26.3 resources unless they are already current: downloads the pinned files from Mojang
    /// (for the signed-in owner only) and runs horizon-prepare. Returns the engine folder and the resources folder.
    pub async fn ensure_horizon_prepared(self: &Arc<Self>, modal_action: &ModalAction) -> Result<(PathBuf, PathBuf), String> {
        let engine = engine_dir().ok_or_else(|| start_problem().unwrap_or_default().to_string())?;
        let home = HorizonHome::new(self);
        let resources = home.resources();
        let root = home.prepare_root();

        let check = {
            let (engine, root, resources) = (engine.clone(), root.clone(), resources.clone());
            tokio::task::spawn_blocking(move || resources_current(&engine, &root, &resources)).await.unwrap_or(false)
        };
        if check {
            return Ok((engine, resources));
        }

        let pins = read_pins(&engine)?;
        let client = self.http_client_provider.client();
        let downloads = home.downloads();

        // The version JSON Horizon pins (Mojang republished others for 26.3)
        let tracker = modal_action.push_tracker(format!("Horizon: downloading Minecraft {} for preparing", pins.version).into());
        let version_json = downloads.join(format!("{}.json", pins.version));
        let url = format!("https://piston-meta.mojang.com/v1/packages/{}/{}.json", pins.manifest_sha1, pins.version);
        let result = download_verified(&client, &url, &version_json, &pins.manifest_sha1).await;
        tracker.set_finished(ProgressTrackerFinishType::from_err(result.is_err()));
        result?;
        let bytes = std::fs::read(&version_json).map_err(|err| format!("Couldn't read the version JSON: {err}"))?;
        let version_info: MinecraftVersion =
            serde_json::from_slice(&bytes).map_err(|err| format!("Couldn't read Mojang's version JSON: {err}"))?;

        // Client and server jars, checked against the pins
        let client_jar = downloads.join(format!("{}-client.jar", pins.version));
        let server_jar = downloads.join(format!("{}-server.jar", pins.version));
        let Some(server) = version_info.downloads.server.as_ref() else {
            return Err("Mojang's 26.3 version JSON has no server jar".into());
        };
        let jars_tracker = modal_action.push_tracker("Horizon: downloading the 26.3 client and server".into());
        jars_tracker.set_total(2);
        let result = async {
            download_verified(&client, &version_info.downloads.client.url, &client_jar, &pins.client_sha1).await?;
            jars_tracker.add_count(1);
            download_verified(&client, &server.url, &server_jar, &pins.server_sha1).await?;
            jars_tracker.add_count(1);
            Ok::<(), String>(())
        }
        .await;
        jars_tracker.set_finished(ProgressTrackerFinishType::from_err(result.is_err()));
        result?;
        if modal_action.has_requested_cancel() {
            return Err("Cancelled".into());
        }

        // Every library jar, each OS's natives too (the preparer picks), the assets and the pinned Java, with the
        // launcher's own downloaders and stores
        let artifacts: Vec<GameLibraryArtifact> = version_info
            .libraries
            .iter()
            .filter_map(|library| library.downloads.artifact.clone())
            .filter(|artifact| !artifact.path.contains(".."))
            .collect();
        let launch_tracker = modal_action.push_tracker("Horizon: game files".into());
        launch_tracker.set_total(3);
        let java_configuration = InstanceConfiguration::new_horizon();
        let dot_minecraft: Arc<Path> = home.root.join("game").into();
        let (java, _, _) = futures::future::try_join3(
            async {
                self.launcher
                    .load_mojang_java_binary(&self.meta, &client, &java_configuration, &version_info, modal_action, &launch_tracker)
                    .await
                    .map_err(|err| format!("Couldn't install Java for Horizon: {err}"))
            },
            async {
                self.launcher
                    .load_assets(&self.meta, &client, &dot_minecraft, &version_info, modal_action, &launch_tracker)
                    .await
                    .map_err(|err| format!("Couldn't download the 26.3 assets: {err}"))
            },
            async {
                self.launcher
                    .load_libraries(&client, &artifacts, modal_action, &launch_tracker)
                    .await
                    .map_err(|err| format!("Couldn't download the 26.3 libraries: {err}"))
            },
        )
        .await
        .inspect_err(|_| launch_tracker.set_finished(ProgressTrackerFinishType::Error))?;
        launch_tracker.set_finished(ProgressTrackerFinishType::Normal);
        let java_home = java
            .parent()
            .and_then(Path::parent)
            .map(Path::to_path_buf)
            .ok_or_else(|| "Couldn't find the Java runtime's folder".to_string())?;
        if modal_action.has_requested_cancel() {
            return Err("Cancelled".into());
        }

        // Horizon's own preparer
        let prepare_tracker = modal_action.push_tracker("Horizon: preparing the 26.3 game files".into());
        prepare_tracker.set_total(1000);
        let args = PrepareArgs {
            engine: engine.clone(),
            root,
            version_json,
            client_jar,
            server_jar,
            libraries: self.directories.libraries_dir.to_path_buf(),
            assets: self.directories.assets_root_dir.to_path_buf(),
            java_home,
            output: resources.clone(),
        };
        let result = {
            let prepare_tracker = prepare_tracker.clone();
            let modal_action = modal_action.clone();
            tokio::task::spawn_blocking(move || run_prepare(&args, &prepare_tracker, &modal_action))
                .await
                .unwrap_or_else(|err| Err(format!("Horizon's preparer stopped: {err}")))
        };
        prepare_tracker.set_finished(ProgressTrackerFinishType::from_err(result.is_err()));
        result?;
        Ok((engine, resources))
    }

    /// Creates a Horizon instance (Vanilla 26.3, played by Horizon) with its packs folders. Returns its folder.
    pub fn create_horizon_instance(&self, name: &str, icon: Option<bridge::message::EmbeddedOrRaw>) -> Option<PathBuf> {
        let mut configuration = InstanceConfiguration::new_horizon();
        configuration.show_shader_tab = true;
        let path = self.create_instance_sanitized_with(name, configuration, icon)?;
        for folder in ["resourcepacks", "shaderpacks", CONTENT_MODS_FOLDER] {
            _ = std::fs::create_dir_all(path.join(".minecraft").join(folder));
        }
        Some(path)
    }

    /// Prepares Horizon if needed, then starts it in the instance's .minecraft with the account's session.
    pub async fn launch_horizon(
        self: &Arc<Self>,
        dot_minecraft: &Path,
        login_info: MinecraftLoginInfo,
        read_game_output: bool,
        launch_tracker: &ProgressTracker,
        modal_action: &ModalAction,
    ) -> Result<PandoraChild, String> {
        // The Launch API's owner gate: a Microsoft account that owns Java Edition, never an offline name
        let Some(access_token) = login_info.access_token.as_ref() else {
            return Err(
                "Horizon plays only with a Microsoft account that owns Minecraft: Java Edition. Select one in Accounts, then press Play.".into(),
            );
        };
        launch_tracker.set_total(2);
        let (engine, resources) = self.ensure_horizon_prepared(modal_action).await?;
        launch_tracker.add_count(1);
        if modal_action.has_requested_cancel() {
            return Err("Cancelled".into());
        }

        std::fs::create_dir_all(dot_minecraft).map_err(|err| format!("Couldn't make the instance's folder: {err}"))?;
        let mut command = PandoraCommand::new(program(&engine, "horizon-client"));
        command.current_dir(dot_minecraft);
        for arg in [
            "--resources".as_ref(),
            resources.as_os_str(),
            "--game-dir".as_ref(),
            dot_minecraft.as_os_str(),
            "--home".as_ref(),
            dot_minecraft.as_os_str(),
            "--width".as_ref(),
            "1280".as_ref(),
            "--height".as_ref(),
            "720".as_ref(),
            "--session-stdin".as_ref(),
        ] {
            command.arg(arg.to_os_string());
        }
        for content_mod in content_mods(dot_minecraft) {
            command.arg("--dev-mod");
            command.arg(content_mod.into_os_string());
        }
        command.env("HORIZON_HOME", dot_minecraft.as_os_str().to_os_string());
        command.stdin(command::PandoraStdioWriteMode::Pipe);
        if read_game_output {
            command.stdout(command::PandoraStdioReadMode::Pipe);
            command.stderr(command::PandoraStdioReadMode::Pipe);
        } else {
            command.stdout(command::PandoraStdioReadMode::Null);
            command.stderr(command::PandoraStdioReadMode::Null);
        }
        log::info!("Starting Horizon in {}", dot_minecraft.display());
        let mut child = command.spawn().await.map_err(|err| format!("Couldn't start Horizon: {err}"))?;

        // The session JSON on standard input, then closed (--session-stdin)
        let session = serde_json::json!({
            "name": &*login_info.username,
            "uuid": login_info.uuid.as_simple().to_string(),
            "access_token": access_token.secret(),
            "user_type": "msa",
        });
        if let Some(mut stdin) = child.stdin.take() {
            if let Err(err) = stdin.write_all(session.to_string().as_bytes()) {
                log::warn!("Couldn't hand Horizon the session: {err}");
            }
        }
        launch_tracker.add_count(1);
        Ok(child)
    }
}

/// The instance's content mods (content-mods/*/horizon-mod.toml), in name order.
fn content_mods(dot_minecraft: &Path) -> Vec<PathBuf> {
    let mut mods: Vec<PathBuf> = std::fs::read_dir(dot_minecraft.join(CONTENT_MODS_FOLDER))
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.join("horizon-mod.toml").is_file())
        .collect();
    mods.sort();
    mods
}

struct PrepareArgs {
    engine: PathBuf,
    root: PathBuf,
    version_json: PathBuf,
    client_jar: PathBuf,
    server_jar: PathBuf,
    libraries: PathBuf,
    assets: PathBuf,
    java_home: PathBuf,
    output: PathBuf,
}

fn run_prepare(args: &PrepareArgs, tracker: &ProgressTracker, modal_action: &ModalAction) -> Result<(), String> {
    refresh_prepare_root(&args.engine, &args.root).map_err(|err| format!("Couldn't copy Horizon's preparer files: {err}"))?;
    std::fs::create_dir_all(&args.output).map_err(|err| format!("Couldn't make Horizon's resources folder: {err}"))?;
    let mut command = hidden_command(&program(&args.engine, "horizon-prepare"));
    command
        .arg("--prepare")
        .arg("--root")
        .arg(&args.root)
        .arg("--output")
        .arg(&args.output)
        .arg("--version-json")
        .arg(&args.version_json)
        .arg("--client-jar")
        .arg(&args.client_jar)
        .arg("--libraries-dir")
        .arg(&args.libraries)
        .arg("--assets-dir")
        .arg(&args.assets)
        .arg("--server-jar")
        .arg(&args.server_jar)
        .arg("--java-home")
        .arg(&args.java_home)
        .arg("--complete")
        .arg("--progress")
        .arg("json")
        .current_dir(&args.root)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    log::info!("Preparing Horizon's resources in {}", args.output.display());
    let mut child = command.spawn().map_err(|err| format!("Couldn't start Horizon's preparer: {err}"))?;

    // stderr is human text: keep its tail for the error message
    let stderr = child.stderr.take();
    let stderr_tail = std::thread::spawn(move || {
        let mut tail = std::collections::VecDeque::new();
        if let Some(stderr) = stderr {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                log::info!("[horizon-prepare] {line}");
                if tail.len() == 8 {
                    tail.pop_front();
                }
                tail.push_back(line);
            }
        }
        tail.into_iter().collect::<Vec<_>>().join("\n")
    });

    let mut error = None;
    let mut done = 0;
    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if modal_action.has_requested_cancel() {
                _ = child.kill();
                break;
            }
            let Ok(progress) = serde_json::from_str::<PrepareProgress>(&line) else {
                continue;
            };
            if let Some(message) = progress.message {
                log::info!("[horizon-prepare] {message}");
                tracker.set_title(format!("Horizon: {message}").into());
            }
            if let Some(fraction) = progress.fraction {
                let count = (fraction.clamp(0.0, 1.0) * 1000.0) as usize;
                if count > done {
                    tracker.add_count(count - done);
                    done = count;
                }
            }
            if let Some(message) = progress.error {
                error = Some(message);
            }
        }
    }
    let status = child.wait().map_err(|err| format!("Horizon's preparer stopped: {err}"))?;
    let tail = stderr_tail.join().unwrap_or_default();
    if modal_action.has_requested_cancel() {
        return Err("Cancelled".into());
    }
    if status.success() {
        return Ok(());
    }
    Err(match error {
        Some(error) => format!("Horizon couldn't prepare the 26.3 game files: {error}"),
        None if !tail.is_empty() => format!("Horizon couldn't prepare the 26.3 game files:\n{tail}"),
        None => format!("Horizon couldn't prepare the 26.3 game files ({status})"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_are_read_and_checked() {
        let dir = std::env::temp_dir().join(format!("amadora-horizon-pins-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("research-lock.json"),
            r#"{"minecraft": {"version": "26.3", "manifest_sha1": "11f1aefe473eefba0af62e3286c33b692807b2eb",
                "client_sha1": "e877b6a07acd633fb3bb475002175cec036e7b87", "server_sha1": "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
                "java_major": 25}, "other": {}}"#,
        )
        .unwrap();
        let pins = read_pins(&dir).unwrap();
        assert_eq!(pins.version, "26.3");
        assert_eq!(pins.client_sha1, "e877b6a07acd633fb3bb475002175cec036e7b87");

        std::fs::write(
            dir.join("research-lock.json"),
            r#"{"minecraft": {"version": "../26.3", "manifest_sha1": "11f1aefe473eefba0af62e3286c33b692807b2eb",
                "client_sha1": "e877b6a07acd633fb3bb475002175cec036e7b87", "server_sha1": "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"}}"#,
        )
        .unwrap();
        assert!(read_pins(&dir).is_err());
        _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn content_mods_need_a_manifest_and_sort_by_name() {
        let dir = std::env::temp_dir().join(format!("amadora-horizon-mods-{}", std::process::id()));
        for (name, manifest) in [("b-mod", true), ("a-mod", true), ("not-a-mod", false)] {
            let folder = dir.join(CONTENT_MODS_FOLDER).join(name);
            std::fs::create_dir_all(&folder).unwrap();
            if manifest {
                std::fs::write(folder.join("horizon-mod.toml"), "").unwrap();
            }
        }
        let names: Vec<_> = content_mods(&dir).iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names, ["a-mod", "b-mod"]);
        _ = std::fs::remove_dir_all(&dir);
    }
}
