<#
.SYNOPSIS
  Benchmark this repo's llama.cpp build vs the official ggml-org/llama.cpp CUDA Windows build.

.DESCRIPTION
  Downloads the latest CUDA Windows release artifact from:
    1. ggml-org/llama.cpp  (official upstream, fat-binary)
    2. marcusds/llama-custom-build  (this repo, pinned to sm_120 + Zen 5)

  Runs `llama-bench` on the same model with identical parameters and emits
  a side-by-side comparison plus a JSON results file.

  Requires:
    - gh CLI authenticated  (`gh auth login`)
    - PowerShell 7+
    - A local GGUF model file
    - CUDA-capable GPU (RTX 5000/5090 / sm_120 for the custom build)

.PARAMETER Model
  Path to a GGUF model file. Must be the same model for both builds.
  If omitted, a default Qwen3.5-9B-UD-Q4_K_XL.gguf is downloaded from
  Hugging Face into the work directory and reused on subsequent runs.

.PARAMETER OfficialTag
  Release tag from ggml-org/llama.cpp. Default "latest" picks the newest
  release that has a CUDA 13.x Windows asset.

.PARAMETER CustomTag
  Release tag from marcusds/llama-custom-build. Default "latest".

.PARAMETER Pp
  Comma-separated prompt-processing sizes for llama-bench -p. Default "512".

.PARAMETER Tg
  Comma-separated token-generation sizes for llama-bench -n. Default "128".

.PARAMETER Reps
  Repetitions per test (llama-bench -r). Default 5 (matches llama-bench default).

.PARAMETER NGL
  GPU layers to offload (-ngl). Default 999 (offload everything).

.PARAMETER WorkDir
  Where build zips are downloaded + extracted. Default "bench-work" in CWD.

.PARAMETER Refresh
  Re-download builds even if already cached locally.

.EXAMPLE
  .\scripts\bench-compare.ps1 -Model C:\models\qwen2.5-7b-q4km.gguf

.EXAMPLE
  .\scripts\bench-compare.ps1 -Model model.gguf -Pp "128,512,2048" -Tg "64,128"
#>
param(
  [string]$Model = "",
  [string]$OfficialTag = "latest",
  [string]$CustomTag = "latest",
  [ValidateSet("msvc","clang")][string]$Compiler = "msvc",
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

Assert-Tool "gh"
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

if (-not (Test-Path $Model)) {
  throw "Model file not found: $Model"
}
$Model = (Resolve-Path $Model).Path

function Find-ReleaseAsset {
  param(
    [string]$Repo,
    [string]$Tag,
    [string]$AssetGlob   # PowerShell -like wildcard pattern
  )

  if ($Tag -eq "latest") {
    $releases = gh release list --repo $Repo --limit 25 --json tagName,isDraft,isPrerelease,publishedAt | ConvertFrom-Json
    foreach ($r in $releases) {
      if ($r.isDraft) { continue }
      $view = gh release view $r.tagName --repo $Repo --json assets,tagName,publishedAt | ConvertFrom-Json
      $asset = $view.assets | Where-Object { $_.name -like $AssetGlob } | Select-Object -First 1
      if ($asset) {
        return [PSCustomObject]@{
          Tag       = $view.tagName
          Published = $view.publishedAt
          AssetName = $asset.name
          AssetSize = $asset.size
        }
      }
    }
    throw "No asset matching '$AssetGlob' in last 25 releases of $Repo"
  } else {
    $view = gh release view $Tag --repo $Repo --json assets,tagName,publishedAt | ConvertFrom-Json
    $asset = $view.assets | Where-Object { $_.name -like $AssetGlob } | Select-Object -First 1
    if (-not $asset) {
      throw "No asset matching '$AssetGlob' in $Repo $Tag"
    }
    return [PSCustomObject]@{
      Tag       = $view.tagName
      Published = $view.publishedAt
      AssetName = $asset.name
      AssetSize = $asset.size
    }
  }
}

function Ensure-Build {
  param(
    [string]$Repo,
    [string]$Tag,
    [string]$AssetName,
    [string]$Dest
  )

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
  if (-not $bench) {
    throw "llama-bench.exe not found after extracting $AssetName"
  }
  return $bench.FullName
}

function Invoke-Bench {
  param(
    [string]$Label,
    [string]$BenchExe,
    [string]$ModelPath
  )

  $benchDir = Split-Path -Parent $BenchExe

  # Ensure CUDA + bench-local DLLs are findable
  $oldPath = $env:PATH
  $env:PATH = "$benchDir;$env:PATH"
  if ($env:CUDA_PATH) {
    $env:PATH = "$($env:CUDA_PATH)\bin;$env:PATH"
  }

  $jsonFile = Join-Path $WorkDir ("bench-$Label.json")
  $logFile  = Join-Path $WorkDir ("bench-$Label.log")

  Write-Host "  running: $BenchExe" -ForegroundColor DarkGray
  Write-Host "  args:    -m <model> -p $Pp -n $Tg -r $Reps -ngl $NGL -o json" -ForegroundColor DarkGray

  # llama-bench emits JSON to stdout; capture
  $output = & $BenchExe `
    -m $ModelPath `
    -p $Pp `
    -n $Tg `
    -r $Reps `
    -ngl $NGL `
    -o json 2>&1

  $env:PATH = $oldPath

  if ($LASTEXITCODE -ne 0) {
    $output | Out-File -FilePath $logFile -Encoding utf8
    throw "llama-bench '$Label' failed (exit $LASTEXITCODE). See $logFile"
  }

  # Stdout may contain non-JSON warnings before the JSON array. Trim to '['..']'.
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

# ---------- Run ----------

Write-Host ""
Write-Host "Resolving releases ..." -ForegroundColor Cyan
Write-Host "  official ($OFFICIAL_REPO) ..." -ForegroundColor Cyan
$official = Find-ReleaseAsset -Repo $OFFICIAL_REPO -Tag $OfficialTag -AssetGlob "*cuda-13*-x64.zip"
Write-Host "    -> $($official.Tag) :: $($official.AssetName) ($([math]::Round($official.AssetSize / 1MB, 1)) MB)" -ForegroundColor Gray

Write-Host "  custom   ($CUSTOM_REPO, $Compiler) ..." -ForegroundColor Cyan
$custom = Find-ReleaseAsset -Repo $CUSTOM_REPO -Tag $CustomTag -AssetGlob "*win-x64-$Compiler-*.zip"
Write-Host "    -> $($custom.Tag) :: $($custom.AssetName) ($([math]::Round($custom.AssetSize / 1MB, 1)) MB)" -ForegroundColor Gray

$officialDir = Join-Path $WorkDir "official-$($official.Tag)"
$customDir   = Join-Path $WorkDir "custom-$($custom.Tag)"

Write-Host ""
Write-Host "Preparing builds ..." -ForegroundColor Cyan
Write-Host "  official ..." -ForegroundColor Cyan
$officialBench = Ensure-Build -Repo $OFFICIAL_REPO -Tag $official.Tag -AssetName $official.AssetName -Dest $officialDir
Write-Host "  custom ..." -ForegroundColor Cyan
$customBench   = Ensure-Build -Repo $CUSTOM_REPO   -Tag $custom.Tag   -AssetName $custom.AssetName   -Dest $customDir

Write-Host ""
Write-Host "Running benchmarks ..." -ForegroundColor Cyan
Write-Host "  Model: $Model"
Write-Host ""

Write-Host "[official $($official.Tag)]" -ForegroundColor Yellow
$officialResults = Invoke-Bench -Label "official-$($official.Tag)" -BenchExe $officialBench -ModelPath $Model

Write-Host ""
Write-Host "[custom $($custom.Tag)]" -ForegroundColor Yellow
$customResults = Invoke-Bench -Label "custom-$($custom.Tag)" -BenchExe $customBench -ModelPath $Model

# ---------- Compare ----------

$rows = @()
foreach ($o in $officialResults) {
  $label = Get-TestLabel -Record $o
  $c = $customResults | Where-Object {
    $_.n_prompt -eq $o.n_prompt -and $_.n_gen -eq $o.n_gen
  } | Select-Object -First 1
  if (-not $c) { continue }
  $oTs = [double]$o.avg_ts
  $cTs = [double]$c.avg_ts
  $delta = if ($oTs -gt 0) { (($cTs - $oTs) / $oTs) * 100.0 } else { 0.0 }
  $rows += [PSCustomObject]@{
    Test            = $label
    "Official t/s"  = [math]::Round($oTs, 2)
    "Custom t/s"    = [math]::Round($cTs, 2)
    "Delta %"       = ("{0:+0.00;-0.00; 0.00}" -f $delta)
    "Official sd"   = [math]::Round([double]$o.stddev_ts, 2)
    "Custom sd"     = [math]::Round([double]$c.stddev_ts, 2)
  }
}

Write-Host ""
Write-Host "================ BENCHMARK COMPARISON ================" -ForegroundColor Cyan
Write-Host "Model:    $Model"
Write-Host "Official: $($official.Tag)  (published $($official.Published))"
Write-Host "Custom:   $($custom.Tag)  (published $($custom.Published))"
Write-Host "Reps:     $Reps   |  NGL: $NGL"
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
  official = @{
    repo      = $OFFICIAL_REPO
    tag       = $official.Tag
    published = $official.Published
    asset     = $official.AssetName
    results   = $officialResults
  }
  custom   = @{
    repo      = $CUSTOM_REPO
    tag       = $custom.Tag
    published = $custom.Published
    asset     = $custom.AssetName
    results   = $customResults
  }
  comparison = $rows
} | ConvertTo-Json -Depth 12 | Set-Content -Path $outFile -Encoding utf8

Write-Host ""
Write-Host "Saved: $outFile" -ForegroundColor Gray
Write-Host "Builds cached under: $WorkDir" -ForegroundColor Gray
Write-Host "(re-run with -Refresh to re-download)" -ForegroundColor DarkGray
