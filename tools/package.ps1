# Builds the CurseForge upload folder:
#   curseforge\LunarJournal-<version>.zip   the file to upload (contains LunarJournal\...)
#   curseforge\description.md               paste into the project description (Markdown editor)
#   curseforge\changelog.md                 this version's notes from CHANGELOG.md, for the upload's Changelog box
#   curseforge\avatar.png                   400x400 project avatar (from Media\icon.png)
#   curseforge\screenshots\                 pictures for the Images tab (the PNGs in Media other than icon*)
# Usage (from the repo root): .\tools\package.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root "curseforge"
$name = "LunarJournal"

# version from the .toc
$toc = Get-Content (Join-Path $root "$name.toc")
$version = ($toc | Where-Object { $_ -match '^## Version:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
if (-not $version) { throw "No '## Version:' line in $name.toc" }

# files that go into the addon folder in the zip (only what the game needs, plus licence and readme)
$files = @(
    "$name.toc",
    "LunarLink.lua",
    "$name.lua",
    "LICENSE",
    "README.md"
)
foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $root $f))) { throw "Missing $f" }
}

New-Item -ItemType Directory -Force $out | Out-Null
Get-ChildItem $out -Filter "$name-*.zip" | Remove-Item -Force

# Build the zip by hand so entry names use forward slashes (Compress-Archive on
# Windows PowerShell writes backslashes, which other unzip tools mis-read).
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $out "$name-$version.zip"
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $entry = "$name/" + ($f -replace '\\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root $f), $entry, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $zip.Dispose()
}

Copy-Item (Join-Path $root "CURSEFORGE.md") (Join-Path $out "description.md") -Force

# changelog: this version's section of CHANGELOG.md, for the upload's Changelog box
$log = @(Get-Content (Join-Path $root "CHANGELOG.md"))
$start = -1
for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i] -match "^## $([regex]::Escape($version))(\s|$)") { $start = $i; break } }
if ($start -lt 0) { throw "No '## $version' section in CHANGELOG.md" }
$end = $start + 1
while ($end -lt $log.Count -and $log[$end] -notmatch '^## ') { $end++ }
$notes = ($log[$start..($end - 1)] -join "`r`n").Trim()
[System.IO.File]::WriteAllText((Join-Path $out "changelog.md"), $notes + "`r`n", (New-Object System.Text.UTF8Encoding $false))

# avatar: Media\icon.png scaled to 400x400
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile((Join-Path $root "Media\icon.png"))
try {
    $bmp = New-Object System.Drawing.Bitmap 400, 400
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, 0, 0, 400, 400)
    $g.Dispose()
    $bmp.Save((Join-Path $out "avatar.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
} finally {
    $src.Dispose()
}

# screenshots: every PNG in Media except the icon, for the project's Images tab
$shots = Get-ChildItem (Join-Path $root "Media") -Filter *.png | Where-Object { $_.Name -notlike "icon*" }
if ($shots) {
    $shotDir = Join-Path $out "screenshots"
    New-Item -ItemType Directory -Force $shotDir | Out-Null
    $shots | Copy-Item -Destination $shotDir -Force
}

"Built $zipPath"
Get-ChildItem $out -Recurse -File | ForEach-Object { "  " + $_.FullName.Substring($out.Length + 1) + "  (" + $_.Length + " bytes)" }
