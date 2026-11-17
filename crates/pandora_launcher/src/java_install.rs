use std::{fs, io::Write, path::{Path, PathBuf}};

use anyhow::{Context, Result, bail};
use futures::StreamExt;
use serde::Deserialize;
use sha2::{Digest, Sha256};

#[derive(Deserialize)]
struct Release {
    binary: Binary,
}

#[derive(Deserialize)]
struct Binary {
    package: Package,
}

#[derive(Deserialize)]
struct Package {
    link: String,
    checksum: String,
}

/// Installs a platform-matched Temurin JDK in AMADORA's data directory.
/// The caller can select the returned Java binary in an instance's Java settings.
pub async fn install(launcher_dir: &Path, major: u32) -> Result<PathBuf> {
    if major < 8 || major > 99 {
        bail!("Java major version must be between 8 and 99");
    }

    let os = match std::env::consts::OS {
        "windows" => "windows",
        "linux" => "linux",
        other => bail!("Java installation is not implemented for {other}"),
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "x64",
        "aarch64" => "aarch64",
        other => bail!("No Temurin architecture mapping for {other}"),
    };

    let root = launcher_dir.join("java");
    fs::create_dir_all(&root)?;
    let installed = root.join(format!("temurin-{major}-{os}-{arch}"));
    if let Some(binary) = find_java_binary(&installed) {
        return Ok(binary);
    }
    if installed.exists() {
        bail!("{} is incomplete; remove or rename it before reinstalling", installed.display());
    }

    let client = reqwest::Client::builder()
        .user_agent("AMADORA desktop Java installer")
        .build()?;
    let url = format!("https://api.adoptium.net/v3/assets/latest/{major}/hotspot?architecture={arch}&image_type=jdk&os={os}&vendor=eclipse");
    let releases: Vec<Release> = client.get(url).send().await?.error_for_status()?.json().await?;
    let package = &releases.first().context("No Temurin JDK release exists for this Java version and platform")?.binary.package;
    let expected = hex::decode(&package.checksum).context("Invalid release checksum")?;
    if expected.len() != 32 {
        bail!("Invalid SHA-256 checksum length in release metadata");
    }
    let download_url = reqwest::Url::parse(&package.link)?;
    if download_url.scheme() != "https" {
        bail!("Java download URL is not HTTPS");
    }

    let staging = root.join(format!(".temurin-{major}-{:016x}", rand::random::<u64>()));
    fs::create_dir(&staging)?;
    let result = install_into(&client, download_url, &expected, &staging, os).await;
    if let Err(err) = result {
        let _ = fs::remove_dir_all(&staging);
        return Err(err);
    }

    let Some(staged_binary) = find_java_binary(&staging) else {
        let _ = fs::remove_dir_all(&staging);
        bail!("The Java archive did not contain {}", java_relative_path().display());
    };
    let relative_binary = staged_binary.strip_prefix(&staging)?;
    fs::rename(&staging, &installed).with_context(|| format!("Unable to finish Java installation at {}", installed.display()))?;
    Ok(installed.join(relative_binary))
}

async fn install_into(client: &reqwest::Client, url: reqwest::Url, expected: &[u8], staging: &Path, os: &str) -> Result<()> {
    let archive_path = staging.with_extension(if os == "windows" { "zip" } else { "tar.gz" });
    let result = async {
        let response = client.get(url).send().await?.error_for_status()?;
        let mut output = fs::File::create(&archive_path)?;
        let mut hash = Sha256::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            hash.update(&chunk);
            output.write_all(&chunk)?;
        }
        output.sync_all()?;
        if hash.finalize().as_slice() != expected {
            bail!("Downloaded Java archive failed SHA-256 verification");
        }
        if os == "windows" {
            unpack_zip(&archive_path, staging)?;
        } else {
            unpack_tar_gz(&archive_path, staging)?;
        }
        Ok(())
    }.await;
    let _ = fs::remove_file(&archive_path);
    result
}

fn java_relative_path() -> &'static Path {
    if cfg!(windows) { Path::new("bin/javaw.exe") } else { Path::new("bin/java") }
}

fn find_java_binary(root: &Path) -> Option<PathBuf> {
    let direct = root.join(java_relative_path());
    if direct.is_file() { return Some(direct); }
    for entry in fs::read_dir(root).ok()?.flatten() {
        let path = entry.path().join(java_relative_path());
        if path.is_file() { return Some(path); }
    }
    None
}

fn unpack_zip(path: &Path, staging: &Path) -> Result<()> {
    let mut archive = zip::ZipArchive::new(fs::File::open(path)?)?;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let enclosed = entry.enclosed_name().context("Unsafe Java archive path")?;
        let target = staging.join(enclosed);
        if entry.is_dir() {
            fs::create_dir_all(&target)?;
        } else {
            fs::create_dir_all(target.parent().context("Invalid Java archive path")?)?;
            let mut output = fs::File::create(target)?;
            std::io::copy(&mut entry, &mut output)?;
        }
    }
    Ok(())
}

fn unpack_tar_gz(path: &Path, staging: &Path) -> Result<()> {
    let input = flate2::read::GzDecoder::new(fs::File::open(path)?);
    let mut archive = tar::Archive::new(input);
    for entry in archive.entries()? {
        let mut entry = entry?;
        if !entry.unpack_in(staging)? {
            bail!("Java archive contains a path outside its installation directory");
        }
    }
    Ok(())
}
