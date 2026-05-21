$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$root  = "G:\내 드라이브\01. Work\[2026] AX tft\01. GEO\00. 이트라이브_GEO_도구·자산 통합 정리\site_mirror"
$cdn   = Join-Path $root 'cdn'
$wsDir = Join-Path $cdn 'wanted-sans'
$gfDir = Join-Path $cdn 'google-fonts'
foreach ($d in @($cdn,$wsDir,$gfDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

# Modern Chrome UA so Google Fonts serves woff2
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Fetch-Text {
    param([string]$url)
    return (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'User-Agent' = $ua } -TimeoutSec 30).Content
}
function Fetch-Binary {
    param([string]$url, [string]$out)
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ 'User-Agent' = $ua } -TimeoutSec 60 | Out-Null
}
function Save-Text {
    param([string]$path, [string]$content)
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Process-Css {
    param([string]$cssUrl, [string]$cssLocalPath, [string]$fontsDir, [string]$fontsRelFromCss)
    Write-Host "Fetch CSS: $cssUrl"
    $css = Fetch-Text $cssUrl
    $cssBase = [Uri]$cssUrl
    $matches = [regex]::Matches($css, 'url\(([^)]+)\)')
    $i = 0
    foreach ($m in $matches) {
        $raw = $m.Groups[1].Value.Trim().Trim("'`"")
        if ($raw.StartsWith('data:')) { continue }
        $abs = [Uri]::new($cssBase, $raw)
        $name = [System.IO.Path]::GetFileName($abs.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "font_$i" }
        if ($abs.Query) {
            $qh = [System.BitConverter]::ToString(([System.Security.Cryptography.MD5]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($abs.Query))).Replace('-','').Substring(0,6)
            $ext = [System.IO.Path]::GetExtension($name)
            $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $name = "$base`_$qh$ext"
        }
        $outFile = Join-Path $fontsDir $name
        if (-not (Test-Path -LiteralPath $outFile)) {
            Write-Host "  font: $($abs.AbsoluteUri) -> $name"
            Fetch-Binary -url $abs.AbsoluteUri -out $outFile
        }
        $relUrl = "$fontsRelFromCss/$name"
        $css = $css.Replace($m.Value, "url($relUrl)")
        $i++
    }
    Save-Text -path $cssLocalPath -content $css
    Write-Host "Saved CSS: $cssLocalPath"
}

# 1) Wanted Sans  (NOTE: HTML referenced a 404 path; correcting to the real path at same tag)
$wsCssBroken = "https://cdn.jsdelivr.net/gh/wanteddev/wanted-sans@v1.0.3/packages/wanted-sans/fonts/webfontstatic/wanted-sans.css"
$wsCss       = "https://cdn.jsdelivr.net/gh/wanteddev/wanted-sans@v1.0.3/packages/wanted-sans/fonts/webfonts/static/complete/WantedSans.css"
$wsCssOut    = Join-Path $cdn 'wanted-sans.css'
# fonts referenced from CSS as ./woff2/*.woff2  -> save under cdn/woff2/
$wsFontsDir  = Join-Path $cdn 'woff2'
if (-not (Test-Path -LiteralPath $wsFontsDir)) { New-Item -ItemType Directory -Force -Path $wsFontsDir | Out-Null }
Process-Css -cssUrl $wsCss -cssLocalPath $wsCssOut -fontsDir $wsFontsDir -fontsRelFromCss 'woff2'

# 2) Google Fonts: Red Hat Display
$gfCss     = "https://fonts.googleapis.com/css2?family=Red+Hat+Display:wght@400;500;700&display=swap"
$gfCssOut  = Join-Path $cdn 'google-fonts.css'
Process-Css -cssUrl $gfCss -cssLocalPath $gfCssOut -fontsDir $gfDir -fontsRelFromCss 'google-fonts'

# 3) Rewrite index.html
$idx = Join-Path $root 'index.html'
$html = Get-Content -LiteralPath $idx -Raw -Encoding UTF8

$html = $html.Replace($wsCssBroken, 'cdn/wanted-sans.css')
$html = $html.Replace($wsCss, 'cdn/wanted-sans.css')
$html = $html.Replace($gfCss, 'cdn/google-fonts.css')
# strip preconnect to external font hosts (harmless but unnecessary offline)
$html = [regex]::Replace($html, '<link[^>]+preconnect[^>]+(cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com)[^>]*>\s*', '')

Save-Text -path $idx -content $html
Write-Host ""
Write-Host "=== HTML rewritten to use local CDN copies ==="
Write-Host "index.html: $idx"
