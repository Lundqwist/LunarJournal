# Makes the in-game icon (minimap button, options page) from Media\icon.png:
#   Media\Icon.tga   64x64, 32-bit with alpha, uncompressed (WoW reads TGA, not PNG)
# The book is cropped tight (the soft shadow under it is left out) so it fills the small
# round minimap button. Run again after changing icon.png: .\tools\make-icon.ps1
# -Preview <folder> also writes PNGs at 64 and 22 pixels (the minimap size) to look at.
param([string]$Preview)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$size = 64

$src = New-Object System.Drawing.Bitmap (Join-Path $root "Media\icon.png")
try {
    # bounding box of the solid pixels (alpha > 200 leaves out the shadow)
    $minX, $minY, $maxX, $maxY = $src.Width, $src.Height, -1, -1
    for ($y = 0; $y -lt $src.Height; $y++) {
        for ($x = 0; $x -lt $src.Width; $x++) {
            if ($src.GetPixel($x, $y).A -gt 200) {
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    $w, $h = ($maxX - $minX + 1), ($maxY - $minY + 1)
    $side = [Math]::Max($w, $h)
    $pad = [int]($side * 0.04)
    $side += 2 * $pad
    $crop = New-Object System.Drawing.Rectangle ($minX - $pad - [int](($side - 2 * $pad - $w) / 2)), ($minY - $pad - [int](($side - 2 * $pad - $h) / 2)), $side, $side

    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $size, $size), $crop, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
} finally {
    $src.Dispose()
}

# drop the faint shadow pixels the crop may still hold
for ($y = 0; $y -lt $size; $y++) {
    for ($x = 0; $x -lt $size; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.A -lt 40) { $bmp.SetPixel($x, $y, [System.Drawing.Color]::Transparent) }
    }
}

# TGA: type 2 (uncompressed true colour), 32 bits, 8 alpha bits, top-left origin
$data = New-Object byte[] (18 + $size * $size * 4)
$data[2] = 2
$data[12] = $size % 256; $data[13] = [int]($size / 256)
$data[14] = $size % 256; $data[15] = [int]($size / 256)
$data[16] = 32
$data[17] = 0x28
$i = 18
for ($y = 0; $y -lt $size; $y++) {
    for ($x = 0; $x -lt $size; $x++) {
        $c = $bmp.GetPixel($x, $y)
        $data[$i] = $c.B; $data[$i + 1] = $c.G; $data[$i + 2] = $c.R; $data[$i + 3] = $c.A
        $i += 4
    }
}
$out = Join-Path $root "Media\Icon.tga"
[System.IO.File]::WriteAllBytes($out, $data)
"Wrote $out"

if ($Preview) {
    New-Item -ItemType Directory -Force $Preview | Out-Null
    $bmp.Save((Join-Path $Preview "icon-64.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    # the minimap button: dark round background, icon at 22 px, shown 6x bigger
    $mm = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($mm)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::FromArgb(255, 60, 70, 60))
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 20, 20, 20))), 2, 2, 28, 28)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($bmp, 5, 5, 22, 22)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 200, 170, 80)), 2), 2, 2, 28, 28)
    $g.Dispose()
    $big = New-Object System.Drawing.Bitmap 192, 192
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.DrawImage($mm, 0, 0, 192, 192)
    $g.Dispose()
    $big.Save((Join-Path $Preview "minimap-preview.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $mm.Dispose(); $big.Dispose()
}
$bmp.Dispose()
