<#
.SYNOPSIS
  Benchmark this repo's MSVC + ClangCL builds vs the official ggml-org/llama.cpp CUDA Windows build.

.DESCRIPTION
  Resolves three llama-bench targets and runs them on the same model with
  identical parameters. By default each non-local target is downloaded from
  the latest CUDA Windows GitHub release of the corresponding repo:

    official    -- ggml-org/llama.cpp           (fat-binary, multi-arch)
    msvc        -- marcusds/llama-custom-build  (MSVC,    sm_120 + Zen 5, AVX-512)
    clang       -- marcusds/llama-custom-build  (ClangCL, sm_120 + Zen 5, ThinLTO)

  Use -CustomMsvcPath / -CustomClangPath to point at local build folders
  instead of downloading from a release (folder must contain llama-bench.exe).

  Output: side-by-side table with three throughput columns + delta % vs
  official; full JSON results written to bench-work/compare-<timestamp>.json.

  Requires:
    - gh CLI authenticated  (`gh auth login`)
    - PowerShell 7+
    - A GGUF model file (or rely on auto-download default)
    - CUDA-capable GPU (RTX 5000/5090 sm_120 for the custom builds)

.PARAMETER Model
  Path to a GGUF model file. Same model for all three targets.
  Omit to auto-download Qwen3.5-9B-UD-Q4_K_XL.gguf into bench-work/models/.

.PARAMETER OfficialTag
  Release tag from ggml-org/llama.cpp. Default "latest".

.PARAMETER CustomTag
  Release tag from marcusds/llama-custom-build. Default "latest".

.PARAMETER CustomMsvcPath
  Local folder containing llama-bench.exe for the MSVC custom build. If set,
  the script skips the GitHub release download for the msvc target.

.PARAMETER CustomClangPath
  Local folder containing llama-bench.exe for the ClangCL custom build. If
  set, the script skips the GitHub release download for the clang target.

.PARAMETER SkipOfficial
  Don't bench the official upstream build. Useful for quick msvc-vs-clang
  comparisons.

.PARAMETER SkipMsvc
  Don't bench the MSVC target.

.PARAMETER SkipClang
  Don't bench the ClangCL target.

.PARAMETER Pp
  Comma-separated prompt-processing sizes for llama-bench -p. Default "512".

.PARAMETER Tg
  Comma-separated token-generation sizes for llama-bench -n. Default "128".

.PARAMETER Reps
  Repetitions per test (llama-bench -r). Default 5.

.PARAMETER NGL
  GPU layers to offload (-ngl). Default 999.

.PARAMETER WorkDir
  Download + extract cache. Default "bench-work" in CWD.

.PARAMETER Refresh
  Re-download builds even if cached.

.EXAMPLE
  # Default: 3-way bench (official + custom msvc + custom clang from releases)
  .\scripts\bench-compare.ps1

.EXAMPLE
  # Bench against local builds (skip downloads)
  .\scripts\bench-compare.ps1 `
    -CustomMsvcPath  D:\builds\msvc\bin `
    -CustomClangPath D:\builds\clang\bin

.EXAMPLE
  # Skip official, just msvc vs clang
  .\scripts\bench-compare.ps1 -SkipOfficial -Pp "128,512,2048" -Tg "64,128"
#>
param(
  [string]$Model = "",
  [string]$OfficialTag = "latest",
  [string]$CustomTag = "latest",
  [string]$CustomMsvcPath = "",
  [string]$CustomClangPath = "",
  [switch]$SkipOfficial,
  [switch]$SkipMsvc,
  [switch]$SkipClang,
  [string]$Pp = "512",
  [string]$Tg = "128",
  [int]$Reps = 5,
  [int]$NGL = 999,
  [string]$WorkDir = "bench-work",
  [switch]$Refresh
)

$ErrorActionPreference = "Stop"

$OFFICIAL_REPO   = "ggml-org/llama.cpp"
$CUSTOM_REPO     = "marcusds/llama-custom-build"
$DEFAULT_MODEL_URL  = "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-Q4_K_XL.gguf?download=true"
$DEFAULT_MODEL_NAME = "Qwen3.5-9B-UD-Q4_K_XL.gguf"

function Assert-Tool {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required tool '$Name' not on PATH."
  }
}

# gh only needed if at least one target is from a release
$needsGh = (-not $SkipOfficial) -or (-not $SkipMsvc -and -not $CustomMsvcPath) -or (-not $SkipClang -and -not $CustomClangPath)
if ($needsGh) { Assert-Tool "gh" }
Assert-Tool "curl.exe"

# Resolve work dir early so we can place the default model into it
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$WorkDir = (Resolve-Path $WorkDir).Path

if ([string]::IsNullOrWhiteSpace($Model)) {
  $modelsDir = Join-Path $WorkDir "models"
  New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
  $Model = Join-Path $modelsDir $DEFAULT_MODEL_NAME
  if (-not (Test-Path $Model)) {
    Write-Host "No -Model specified. Downloading default ($DEFAULT_MODEL_NAME)..." -ForegroundColor Cyan
    Write-Host "  $DEFAULT_MODEL_URL" -ForegroundColor DarkGray
    $tmp = "$Model.partial"
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
    curl.exe -fL --retry 3 --retry-delay 5 -o $tmp $DEFAULT_MODEL_URL
    if ($LASTEXITCODE -ne 0) {
      if (Test-Path $tmp) { Remove-Item -Force $tmp }
      throw "Model download failed (curl exit $LASTEXITCODE)"
    }
    Move-Item -Path $tmp -Destination $Model -Force
    Write-Host "  saved: $Model" -ForegroundColor Gray
  } else {
    Write-Host "Using cached default model: $Model" -ForegroundColor DarkGray
  }
}

if (-not (Test-Path $Model)) { throw "Model file not found: $Model" }
$Model = (Resolve-Path $Model).Path

function Find-ReleaseAsset {
  param([string]$Repo, [string]$Tag, [string]$AssetGlob)

  if ($Tag -eq "latest") {
    $releases = gh release list --repo $Repo --limit 25 --json tagName,isDraft,isPrerelease,publishedAt | ConvertFrom-Json
    foreach ($r in $releases) {
      if ($r.isDraft) { continue }
      $view = gh release view $r.tagName --repo $Repo --json assets,tagName,publishedAt | ConvertFrom-Json
      $asset = $view.assets | Where-Object { $_.name -like $AssetGlob } | Select-Object -First 1
      if ($asset) {
        return [PSCustomObject]@{
          Tag = $view.tagName; Published = $view.publishedAt
          AssetName = $asset.name; AssetSize = $asset.size
        }
      }
    }
    throw "No asset matching '$AssetGlob' in last 25 releases of $Repo"
  } else {
    $view = gh release view $Tag --repo $Repo --json assets,tagName,publishedAt | ConvertFrom-Json
    $asset = $view.assets | Where-Object { $_.name -like $AssetGlob } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$AssetGlob' in $Repo $Tag" }
    return [PSCustomObject]@{
      Tag = $view.tagName; Published = $view.publishedAt
      AssetName = $asset.name; AssetSize = $asset.size
    }
  }
}

function Resolve-BenchFromPath {
  param([string]$Label, [string]$Path)
  if (-not (Test-Path $Path)) { throw "$Label path does not exist: $Path" }
  $bench = Get-ChildItem -Path $Path -Recurse -Filter "llama-bench.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $bench) { throw "llama-bench.exe not found under $Label path: $Path" }
  return $bench.FullName
}

function Ensure-Build {
  param([string]$Repo, [string]$Tag, [string]$AssetName, [string]$Dest)

  if ((Test-Path $Dest) -and -not $Refresh) {
    $bench = Get-ChildItem -Path $Dest -Recurse -Filter "llama-bench.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bench) {
      Write-Host "  cached: $Dest" -ForegroundColor DarkGray
      return $bench.FullName
    }
  }

  if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
  New-Item -ItemType Directory -Path $Dest -Force | Out-Null

  Write-Host "  downloading $AssetName from $Repo @ $Tag ..." -ForegroundColor DarkGray
  gh release download $Tag --repo $Repo --pattern $AssetName --dir $Dest
  if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $Repo $Tag" }

  $zip = Join-Path $Dest $AssetName
  Write-Host "  extracting ..." -ForegroundColor DarkGray
  Expand-Archive -Path $zip -DestinationPath $Dest -Force
  Remove-Item $zip

  $bench = Get-ChildItem -Path $Dest -Recurse -Filter "llama-bench.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $bench) { throw "llama-bench.exe not found after extracting $AssetName" }
  return $bench.FullName
}

function Invoke-Bench {
  param([string]$Label, [string]$BenchExe, [string]$ModelPath)

  $benchDir = Split-Path -Parent $BenchExe
  $oldPath = $env:PATH
  $env:PATH = "$benchDir;$env:PATH"
  if ($env:CUDA_PATH) { $env:PATH = "$($env:CUDA_PATH)\bin;$env:PATH" }

  $jsonFile = Join-Path $WorkDir ("bench-$Label.json")
  $logFile  = Join-Path $WorkDir ("bench-$Label.log")

  Write-Host "  running: $BenchExe" -ForegroundColor DarkGray
  Write-Host "  args:    -m <model> -p $Pp -n $Tg -r $Reps -ngl $NGL -o json" -ForegroundColor DarkGray

  $output = & $BenchExe -m $ModelPath -p $Pp -n $Tg -r $Reps -ngl $NGL -o json 2>&1
  $env:PATH = $oldPath

  if ($LASTEXITCODE -ne 0) {
    $output | Out-File -FilePath $logFile -Encoding utf8
    throw "llama-bench '$Label' failed (exit $LASTEXITCODE). See $logFile"
  }

  $text = ($output | Out-String)
  $start = $text.IndexOf('[')
  $end   = $text.LastIndexOf(']')
  if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
    $text | Out-File -FilePath $logFile -Encoding utf8
    throw "Could not locate JSON array in llama-bench output. See $logFile"
  }
  $jsonText = $text.Substring($start, $end - $start + 1)
  $jsonText | Out-File -FilePath $jsonFile -Encoding utf8
  return ($jsonText | ConvertFrom-Json)
}

function Get-TestLabel {
  param($Record)
  if ($Record.n_prompt -gt 0 -and $Record.n_gen -eq 0)      { return "pp$($Record.n_prompt)" }
  elseif ($Record.n_gen -gt 0 -and $Record.n_prompt -eq 0)  { return "tg$($Record.n_gen)" }
  else                                                       { return "pp$($Record.n_prompt)+tg$($Record.n_gen)" }
}

# ---------- Build target list ----------

$targets = @()

if (-not $SkipOfficial) {
  Write-Host ""
  Write-Host "Resolving official ($OFFICIAL_REPO) ..." -ForegroundColor Cyan
  $asset = Find-ReleaseAsset -Repo $OFFICIAL_REPO -Tag $OfficialTag -AssetGlob "llama-*-bin-win-cuda-13*-x64.zip"
  Write-Host "  -> $($asset.Tag) :: $($asset.AssetName) ($([math]::Round($asset.AssetSize / 1MB, 1)) MB)" -ForegroundColor Gray
  $dest = Join-Path $WorkDir "official-$($asset.Tag)"
  $bench = Ensure-Build -Repo $OFFICIAL_REPO -Tag $asset.Tag -AssetName $asset.AssetName -Dest $dest
  $targets += [PSCustomObject]@{
    Label = "official"; Tag = $asset.Tag; Published = $asset.Published
    Asset = $asset.AssetName; Bench = $bench; Source = "release"; Repo = $OFFICIAL_REPO
  }
}

if (-not $SkipMsvc) {
  if ($CustomMsvcPath) {
    Write-Host ""
    Write-Host "Resolving msvc (local path) ..." -ForegroundColor Cyan
    Write-Host "  -> $CustomMsvcPath" -ForegroundColor Gray
    $bench = Resolve-BenchFromPath -Label "msvc" -Path $CustomMsvcPath
    $targets += [PSCustomObject]@{
      Label = "msvc"; Tag = "local"; Published = ""
      Asset = ""; Bench = $bench; Source = "local"; Repo = $CustomMsvcPath
    }
  } else {
    Write-Host ""
    Write-Host "Resolving msvc ($CUSTOM_REPO) ..." -ForegroundColor Cyan
    $asset = Find-ReleaseAsset -Repo $CUSTOM_REPO -Tag $CustomTag -AssetGlob "*win-x64-msvc-*.zip"
    Write-Host "  -> $($asset.Tag) :: $($asset.AssetName) ($([math]::Round($asset.AssetSize / 1MB, 1)) MB)" -ForegroundColor Gray
    $dest = Join-Path $WorkDir "custom-msvc-$($asset.Tag)"
    $bench = Ensure-Build -Repo $CUSTOM_REPO -Tag $asset.Tag -AssetName $asset.AssetName -Dest $dest
    $targets += [PSCustomObject]@{
      Label = "msvc"; Tag = $asset.Tag; Published = $asset.Published
      Asset = $asset.AssetName; Bench = $bench; Source = "release"; Repo = $CUSTOM_REPO
    }
  }
}

if (-not $SkipClang) {
  if ($CustomClangPath) {
    Write-Host ""
    Write-Host "Resolving clang (local path) ..." -ForegroundColor Cyan
    Write-Host "  -> $CustomClangPath" -ForegroundColor Gray
    $bench = Resolve-BenchFromPath -Label "clang" -Path $CustomClangPath
    $targets += [PSCustomObject]@{
      Label = "clang"; Tag = "local"; Published = ""
      Asset = ""; Bench = $bench; Source = "local"; Repo = $CustomClangPath
    }
  } else {
    Write-Host ""
    Write-Host "Resolving clang ($CUSTOM_REPO) ..." -ForegroundColor Cyan
    $asset = Find-ReleaseAsset -Repo $CUSTOM_REPO -Tag $CustomTag -AssetGlob "*win-x64-clang-*.zip"
    Write-Host "  -> $($asset.Tag) :: $($asset.AssetName) ($([math]::Round($asset.AssetSize / 1MB, 1)) MB)" -ForegroundColor Gray
    $dest = Join-Path $WorkDir "custom-clang-$($asset.Tag)"
    $bench = Ensure-Build -Repo $CUSTOM_REPO -Tag $asset.Tag -AssetName $asset.AssetName -Dest $dest
    $targets += [PSCustomObject]@{
      Label = "clang"; Tag = $asset.Tag; Published = $asset.Published
      Asset = $asset.AssetName; Bench = $bench; Source = "release"; Repo = $CUSTOM_REPO
    }
  }
}

if ($targets.Count -lt 2) {
  throw "Need at least two targets to compare. Got $($targets.Count)."
}

# ---------- Run all benches ----------

Write-Host ""
Write-Host "Running benchmarks on $($targets.Count) targets ..." -ForegroundColor Cyan
Write-Host "  Model: $Model"
Write-Host ""

foreach ($t in $targets) {
  Write-Host "[$($t.Label) :: $($t.Tag)]" -ForegroundColor Yellow
  $t | Add-Member -NotePropertyName Results -NotePropertyValue (Invoke-Bench -Label "$($t.Label)-$($t.Tag)" -BenchExe $t.Bench -ModelPath $Model)
  Write-Host ""
}

# ---------- Compare ----------

# Use the first target as the baseline for delta %. Prefer official; otherwise first listed.
$baseline = $targets | Where-Object { $_.Label -eq 'official' } | Select-Object -First 1
if (-not $baseline) { $baseline = $targets[0] }

# Collect every (n_prompt, n_gen) pair across all targets
$allTests = @{}
foreach ($t in $targets) {
  foreach ($r in $t.Results) {
    $key = "$($r.n_prompt)|$($r.n_gen)"
    if (-not $allTests.ContainsKey($key)) {
      $allTests[$key] = [PSCustomObject]@{
        Label = Get-TestLabel -Record $r
        n_prompt = $r.n_prompt
        n_gen = $r.n_gen
      }
    }
  }
}

$rows = @()
foreach ($k in ($allTests.Keys | Sort-Object)) {
  $meta = $allTests[$k]
  $row = [ordered]@{ Test = $meta.Label }
  $baselineTs = $null
  foreach ($t in $targets) {
    $rec = $t.Results | Where-Object { $_.n_prompt -eq $meta.n_prompt -and $_.n_gen -eq $meta.n_gen } | Select-Object -First 1
    $ts = if ($rec) { [math]::Round([double]$rec.avg_ts, 2) } else { $null }
    $row["$($t.Label) t/s"] = $ts
    if ($t.Label -eq $baseline.Label) { $baselineTs = if ($rec) { [double]$rec.avg_ts } else { $null } }
  }
  if ($baselineTs -gt 0) {
    foreach ($t in $targets) {
      if ($t.Label -eq $baseline.Label) { continue }
      $rec = $t.Results | Where-Object { $_.n_prompt -eq $meta.n_prompt -and $_.n_gen -eq $meta.n_gen } | Select-Object -First 1
      if ($rec) {
        $delta = (([double]$rec.avg_ts - $baselineTs) / $baselineTs) * 100.0
        $row["$($t.Label) vs $($baseline.Label)"] = ("{0:+0.00;-0.00; 0.00}%" -f $delta)
      } else {
        $row["$($t.Label) vs $($baseline.Label)"] = "-"
      }
    }
  }
  $rows += [PSCustomObject]$row
}

Write-Host ""
Write-Host "================ BENCHMARK COMPARISON ================" -ForegroundColor Cyan
Write-Host "Model:    $Model"
foreach ($t in $targets) {
  $src = if ($t.Source -eq 'local') { "local: $($t.Repo)" } else { "$($t.Repo) @ $($t.Tag)" }
  Write-Host ("{0,-10}{1}" -f $t.Label, $src)
}
Write-Host "Reps:     $Reps   |  NGL: $NGL"
Write-Host "Baseline for delta %: $($baseline.Label)"
Write-Host ""
$rows | Format-Table -AutoSize

$outFile = Join-Path $WorkDir ("compare-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
@{
  date     = (Get-Date -Format "o")
  model    = $Model
  reps     = $Reps
  ngl      = $NGL
  pp       = $Pp
  tg       = $Tg
  baseline = $baseline.Label
  targets  = $targets | ForEach-Object {
    @{ label = $_.Label; tag = $_.Tag; published = $_.Published
       source = $_.Source; repo = $_.Repo; asset = $_.Asset
       bench_exe = $_.Bench; results = $_.Results }
  }
  comparison = $rows
} | ConvertTo-Json -Depth 12 | Set-Content -Path $outFile -Encoding utf8

Write-Host ""
Write-Host "Saved: $outFile" -ForegroundColor Gray
Write-Host "Builds cached under: $WorkDir" -ForegroundColor Gray
Write-Host "(re-run with -Refresh to re-download)" -ForegroundColor DarkGray
