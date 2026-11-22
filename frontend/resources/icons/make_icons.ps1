# Regenerates the app icon PNGs and quicksilver.ico from quicksilver.svg.
#
# The SVG uses filters (feTurbulence, feDisplacementMap, feDropShadow) that Qt's
# SVG renderer does not support, so it is rasterised with headless Edge (or
# Chrome) instead, once per size so small sizes stay sharp. The .ico holds
# PNG-compressed entries (supported since Windows Vista).
#
# Usage (from any directory):  powershell -NoProfile -File make_icons.ps1
$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$sizes = 16, 24, 32, 48, 64, 128, 256

$browser = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Need Microsoft Edge or Google Chrome to render the SVG.' }

$work = Join-Path ([IO.Path]::GetTempPath()) ("qs-icons-" + [Guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
try {
    Copy-Item (Join-Path $here 'quicksilver.svg') (Join-Path $work 'icon.svg')
    foreach ($n in $sizes) {
        $html = Join-Path $work "r$n.html"
        Set-Content -Encoding utf8 $html ("<!doctype html><html><head><style>" +
            "html,body{margin:0;padding:0;background:transparent;overflow:hidden}" +
            "img{display:block;width:${n}px;height:${n}px}</style></head>" +
            "<body><img src=`"icon.svg`"></body></html>")
        $png = Join-Path $here "quicksilver_$n.png"
        Remove-Item $png -ErrorAction SilentlyContinue
        $browserArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars',
                  "--user-data-dir=$work\profile", '--default-background-color=00000000',
                  "--window-size=$n,$n", "--screenshot=$png", ([Uri]$html).AbsoluteUri)
        Start-Process -FilePath $browser -ArgumentList $browserArgs -Wait -WindowStyle Hidden
        if (-not (Test-Path $png)) { throw "Rendering $n px failed." }
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

# Pack the PNGs into an .ico: ICONDIR, one ICONDIRENTRY per image, then the data.
$images = foreach ($n in $sizes) { ,[IO.File]::ReadAllBytes((Join-Path $here "quicksilver_$n.png")) }
$ms = New-Object IO.MemoryStream
$w  = New-Object IO.BinaryWriter($ms)
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }   # 0 means 256
    $w.Write([Byte]$dim); $w.Write([Byte]$dim); $w.Write([Byte]0); $w.Write([Byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32)
    $w.Write([UInt32]$images[$i].Length); $w.Write([UInt32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $here 'quicksilver.ico'), $ms.ToArray())
Write-Host "Wrote quicksilver.ico and $($sizes.Count) PNGs to $here"
