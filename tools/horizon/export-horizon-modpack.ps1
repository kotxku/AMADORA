# Zips a Horizon modpack port for AMADORA (sidebar > Horizon > Import a Horizon modpack).
# A port's content mods are folders with horizon-mod.toml (the Horizon launcher's
# `modpack port` writes them as mods\<id>\carry); Horizon on PC loads them with --dev-mod, and so
# does AMADORA. Shader and resource pack zips and horizon-graphics.txt come from the port's game folder.
#
#   powershell -ExecutionPolicy Bypass -File export-horizon-modpack.ps1 -Name "Better Than Christmas" `
#     -Mods "<port>\game-data\ports\better-than-christmas-updated\mods", "<port>\extra-content-built-v4" `
#     -GameDir "<port>\game-data\ports\better-than-christmas-updated\home"
#
# Each -Mods folder's subfolders are mods (their carry\ folder, or the subfolder itself), loaded in
# the order given. The zip is for your own device: ported mods keep their own licences.
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string[]]$Mods,
    [string]$GameDir,
    [string]$Out = (Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.zip")
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# powershell -File hands a comma list over as one string
$Mods = @($Mods | ForEach-Object { if (Test-Path -LiteralPath $_) { $_ } else { $_ -split ',' } })
$modDirs = @()
foreach ($folder in $Mods) {
    foreach ($dir in Get-ChildItem -LiteralPath $folder -Directory | Sort-Object Name) {
        $carry = Join-Path $dir.FullName 'carry'
        $root = if (Test-Path -LiteralPath (Join-Path $carry 'horizon-mod.toml')) { $carry } else { $dir.FullName }
        if (-not (Test-Path -LiteralPath (Join-Path $root 'horizon-mod.toml'))) { throw "No horizon-mod.toml in $($dir.FullName)" }
        $modDirs += [pscustomobject]@{ Id = $dir.Name; Path = (Resolve-Path -LiteralPath $root).Path }
    }
}
if (-not $modDirs) { throw 'No content mods found.' }

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out }
$zip = [System.IO.Compression.ZipFile]::Open($Out, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    # Forward slashes: iOS reads backslashes as part of a file name
    function Add-File($path, $entry, $level = [System.IO.Compression.CompressionLevel]::Optimal) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $path, $entry, $level)
    }
    $i = 0
    foreach ($mod in $modDirs) {
        $i++
        # The number keeps the load order: AMADORA loads content-mods\ in name order
        $prefix = 'content-mods/{0:D2}-{1}/' -f $i, $mod.Id
        Write-Host "Adding mod $($mod.Id)"
        foreach ($file in Get-ChildItem -LiteralPath $mod.Path -Recurse -File) {
            Add-File $file.FullName ($prefix + $file.FullName.Substring($mod.Path.Length + 1).Replace('\', '/'))
        }
    }
    if ($GameDir) {
        foreach ($kind in 'shaderpacks', 'resourcepacks') {
            $dir = Join-Path $GameDir $kind
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($pack in Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File) {
                Write-Host "Adding $kind\$($pack.Name)"
                Add-File $pack.FullName "$kind/$($pack.Name)" ([System.IO.Compression.CompressionLevel]::NoCompression)
            }
        }
        $graphics = Join-Path $GameDir 'horizon-graphics.txt'
        if (Test-Path -LiteralPath $graphics) { Add-File $graphics 'horizon-graphics.txt' }
    }
    $manifest = $zip.CreateEntry('horizon-modpack.json')
    $writer = New-Object System.IO.StreamWriter($manifest.Open())
    $writer.Write((@{ name = $Name; mods = @($modDirs | ForEach-Object { $_.Id }) } | ConvertTo-Json))
    $writer.Dispose()
} finally {
    $zip.Dispose()
}

Write-Host ("Made {0} ({1:N0} MB) with {2} content mods." -f $Out, ((Get-Item -LiteralPath $Out).Length / 1MB), $modDirs.Count) -ForegroundColor Green
Write-Host 'Put the zip on your iPhone (iCloud Drive, AirDrop or a share), then in AMADORA: tap the sidebar button (top left) > Horizon > Import a Horizon modpack.'
