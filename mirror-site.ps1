param(
    [string]$BaseUrl = "https://etribe-g9ez2ebwd-junghwan-s-projects.vercel.app/",
    [string]$OutDir  = "G:\내 드라이브\01. Work\[2026] AX tft\01. GEO\00. 이트라이브_GEO_도구·자산 통합 정리\site_mirror",
    [int]$MaxPages   = 200
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$baseUri  = [Uri]$BaseUrl
$baseHost = $baseUri.Host

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$visited       = New-Object 'System.Collections.Generic.HashSet[string]'
$pageQueue     = New-Object System.Collections.Queue
$assetQueue    = New-Object System.Collections.Queue
$savedCount    = 0
$failCount     = 0
$pageCount     = 0

function Resolve-Url {
    param([string]$href, [Uri]$pageUri)
    if ([string]::IsNullOrWhiteSpace($href)) { return $null }
    $h = $href.Trim()
    if ($h.StartsWith('#') -or $h.StartsWith('javascript:') -or $h.StartsWith('mailto:') -or $h.StartsWith('tel:') -or $h.StartsWith('data:')) { return $null }
    try {
        $u = [Uri]::new($pageUri, $h)
        $b = New-Object UriBuilder $u
        $b.Fragment = ''
        return $b.Uri
    } catch { return $null }
}

function Get-LocalPath {
    param([Uri]$u)
    $path = $u.AbsolutePath
    if ($u.Query) {
        $q = $u.Query.TrimStart('?')
        $qhash = [System.BitConverter]::ToString(([System.Security.Cryptography.MD5]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($q))).Replace('-','').Substring(0,8)
        if ($path.EndsWith('/')) { $path = $path + "index_$qhash.html" }
        else {
            $ext = [System.IO.Path]::GetExtension($path)
            if ($ext) { $path = $path.Substring(0,$path.Length-$ext.Length) + "_$qhash" + $ext }
            else      { $path = $path + "_$qhash" }
        }
    } elseif ($path.EndsWith('/') -or $path -eq '') {
        $path = $path + 'index.html'
    } elseif (-not [System.IO.Path]::GetExtension($path)) {
        $path = $path + '/index.html'
    }
    $rel = $path.TrimStart('/') -replace '/', '\'
    # sanitize illegal Windows chars
    $rel = ($rel -split '\\' | ForEach-Object {
        ($_ -replace '[<>:"|?*]', '_')
    }) -join '\'
    return Join-Path $OutDir $rel
}

function Save-Url {
    param([Uri]$u, [bool]$IsPage)
    $key = $u.AbsoluteUri
    if ($visited.Contains($key)) { return $null }
    [void]$visited.Add($key)

    $local = Get-LocalPath -u $u
    $dir = Split-Path $local -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    try {
        $resp = Invoke-WebRequest -Uri $u.AbsoluteUri -OutFile $local -UseBasicParsing -PassThru -TimeoutSec 30
        $script:savedCount++
        $ct = ''
        try { $ct = (Invoke-WebRequest -Uri $u.AbsoluteUri -Method Head -UseBasicParsing -TimeoutSec 15).Headers['Content-Type'] } catch {}
        Write-Host ("[{0,4}] {1}  -> {2}" -f $script:savedCount, $u.AbsoluteUri, $local)
        return @{ Path = $local; ContentType = $ct }
    } catch {
        $script:failCount++
        Write-Host ("[FAIL] {0}  ({1})" -f $u.AbsoluteUri, $_.Exception.Message)
        return $null
    }
}

function Parse-Html {
    param([string]$file, [Uri]$pageUri)
    $html = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $patterns = @(
        'href\s*=\s*"([^"]+)"',
        "href\s*=\s*'([^']+)'",
        'src\s*=\s*"([^"]+)"',
        "src\s*=\s*'([^']+)'",
        'srcset\s*=\s*"([^"]+)"',
        "srcset\s*=\s*'([^']+)'",
        'data-src\s*=\s*"([^"]+)"',
        "data-src\s*=\s*'([^']+)'",
        'url\(([^)]+)\)'
    )
    $found = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($pat in $patterns) {
        $matches = [regex]::Matches($html, $pat, 'IgnoreCase')
        foreach ($m in $matches) {
            $val = $m.Groups[1].Value.Trim().Trim("'`"")
            # srcset may contain multiple urls
            if ($pat -like '*srcset*') {
                foreach ($part in $val -split ',') {
                    $url = ($part.Trim() -split '\s+')[0]
                    if ($url) { [void]$found.Add($url) }
                }
            } else {
                [void]$found.Add($val)
            }
        }
    }

    foreach ($href in $found) {
        $u = Resolve-Url -href $href -pageUri $pageUri
        if ($null -eq $u) { continue }
        if ($u.Host -ne $baseHost) { continue }
        if ($visited.Contains($u.AbsoluteUri)) { continue }

        $ext = [System.IO.Path]::GetExtension($u.AbsolutePath).ToLower()
        $isPagey = ($ext -eq '' -or $ext -eq '.html' -or $ext -eq '.htm' -or $u.AbsolutePath.EndsWith('/'))
        if ($isPagey) {
            $pageQueue.Enqueue($u)
        } else {
            $assetQueue.Enqueue($u)
        }
    }
}

function Parse-Css {
    param([string]$file, [Uri]$cssUri)
    try { $css = Get-Content -LiteralPath $file -Raw -Encoding UTF8 } catch { return }
    $matches = [regex]::Matches($css, 'url\(([^)]+)\)', 'IgnoreCase')
    foreach ($m in $matches) {
        $val = $m.Groups[1].Value.Trim().Trim("'`"")
        $u = Resolve-Url -href $val -pageUri $cssUri
        if ($null -eq $u) { continue }
        if ($u.Host -ne $baseHost) { continue }
        if ($visited.Contains($u.AbsoluteUri)) { continue }
        $assetQueue.Enqueue($u)
    }
}

$pageQueue.Enqueue($baseUri)

while (($pageQueue.Count -gt 0 -or $assetQueue.Count -gt 0) -and $pageCount -lt $MaxPages) {
    if ($pageQueue.Count -gt 0) {
        $u = [Uri]$pageQueue.Dequeue()
        if ($visited.Contains($u.AbsoluteUri)) { continue }
        $r = Save-Url -u $u -IsPage $true
        $pageCount++
        if ($null -ne $r) {
            $ct = $r.ContentType
            if ($ct -match 'html|text/plain' -or $r.Path -like '*.html') {
                Parse-Html -file $r.Path -pageUri $u
            } elseif ($ct -match 'css' -or $r.Path -like '*.css') {
                Parse-Css -file $r.Path -cssUri $u
            }
        }
    } else {
        $u = [Uri]$assetQueue.Dequeue()
        if ($visited.Contains($u.AbsoluteUri)) { continue }
        $r = Save-Url -u $u -IsPage $false
        if ($null -ne $r -and ($r.ContentType -match 'css' -or $r.Path -like '*.css')) {
            Parse-Css -file $r.Path -cssUri $u
        }
    }
}

Write-Host ""
Write-Host "=== Mirror complete ==="
Write-Host "Saved : $savedCount"
Write-Host "Failed: $failCount"
Write-Host "Pages : $pageCount"
Write-Host "Output: $OutDir"
