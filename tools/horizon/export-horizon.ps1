# Zips Horizon's prepared Minecraft 26.3 game files for AMADORA (Library > Horizon > Import from a zip).
# Run it on the computer where the Horizon launcher (playhorizon.dev) has prepared 26.3: install the
# launcher, sign in with the Microsoft account that owns Java Edition, and press Play once.
#   powershell -ExecutionPolicy Bypass -File export-horizon.ps1
$ErrorActionPreference = 'Stop'

$launcherHome = if ($env:HORIZON_LAUNCHER_HOME) { $env:HORIZON_LAUNCHER_HOME } else { Join-Path $env:APPDATA 'horizon-launcher' }
$versions = Join-Path $launcherHome 'versions'
if (-not (Test-Path $versions)) {
    Write-Host "No Horizon launcher data at $launcherHome. Install it from https://playhorizon.dev and press Play once." -ForegroundColor Red
    exit 1
}

# Each installed game version keeps its resources in .local\horizon-client\<Minecraft version>
$manifest = Get-ChildItem -Path $versions -Recurse -Force -Filter 'horizon-resources.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match '\\\.local\\horizon-client\\' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $manifest) {
    Write-Host "Horizon hasn't prepared its game files yet. Open the Horizon launcher and press Play once." -ForegroundColor Red
    exit 1
}

$resources = $manifest.DirectoryName
$mcVersion = Split-Path $resources -Leaf
$sounds = Test-Path (Join-Path $resources 'sounds')
$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "horizon-$mcVersion.zip"
if (Test-Path $zip) { Remove-Item $zip }

Write-Host "Zipping $resources"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($resources, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$size = '{0:N0} MB' -f ((Get-Item $zip).Length / 1MB)
Write-Host "Made $zip ($size)." -ForegroundColor Green
if (-not $sounds) {
    Write-Host 'These files have no sounds, so Horizon will be silent. The Horizon launcher copies them from your Minecraft install when it prepares.' -ForegroundColor Yellow
}
Write-Host 'Put the zip on your iPhone (iCloud Drive, AirDrop or a share), then in AMADORA: Library > Horizon > Import from a zip.'
