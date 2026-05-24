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
  Repetitions per test within a single llama-bench process (-r flag).
  Default 5. Captures intra-process variance; llama-bench reports avg + stddev.

.PARAMETER Runs
  How many times to invoke llama-bench per target. Each Run is a fresh
  process so inter-process variance (CUDA init, GPU thermal, scheduler
  drift) is captured. Default 1 (rely on llama-bench's own -r averaging,
  fastest). Bump to 3+ when you want to expose cold-start variance and
  produce stddev bars across invocations.

.PARAMETER NGL
  GPU layers to offload (-ngl). Default 999.

.PARAMETER WorkDir
  Download + extract cache. Default "bench-work" in CWD.

.PARAMETER Refresh
  Re-download builds even if cached.

.PARAMETER PublishToRelease
  After the bench finishes, append/replace a per-model markdown table inside
  the GitHub Release body for the corresponding upstream-<tag> release in
  marcusds/llama-custom-build. Sections are keyed by model filename so
  re-running against the same model overwrites the prior table; benching a
  different model appends a new section alongside.

  Requires at least one msvc/clang target to come from a release (so we know
  the upstream tag). Use -ReleaseTag to override.

.PARAMETER ReleaseTag
  Explicit upstream-<tag> name in marcusds/llama-custom-build to publish the
  bench table to. Only used when -PublishToRelease is set. Defaults to the
  tag of whichever msvc/clang target came from a release.

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
  [int]$Runs = 1,
  [int]$NGL = 999,
  [int]$BatchSize = 0,
  [int]$UBatchSize = 0,
  [string]$CtkType = "",
  [string]$CtvType = "",
  [int]$FlashAttn = 1,
  [string]$WorkDir = "bench-work",
  [switch]$Refresh,
  [switch]$PublishToRelease,
  [string]$ReleaseTag = ""
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

  $extraArgs = @()
  if ($BatchSize  -gt 0) { $extraArgs += @('-b',   "$BatchSize") }
  if ($UBatchSize -gt 0) { $extraArgs += @('-ub',  "$UBatchSize") }
  if ($CtkType)          { $extraArgs += @('-ctk', $CtkType) }
  if ($CtvType)          { $extraArgs += @('-ctv', $CtvType) }
  if ($FlashAttn -ge 0)  { $extraArgs += @('-fa',  "$FlashAttn") }

  $argDisplay = "-m <model> -p $Pp -n $Tg -r $Reps -ngl $NGL"
  if ($extraArgs.Count) { $argDisplay += ' ' + ($extraArgs -join ' ') }
  $argDisplay += ' -o json'

  Write-Host "  running: $BenchExe" -ForegroundColor DarkGray
  Write-Host "  args:    $argDisplay" -ForegroundColor DarkGray

  $output = & $BenchExe -m $ModelPath -p $Pp -n $Tg -r $Reps -ngl $NGL @extraArgs -o json 2>&1
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
  $all = @()
  for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "  run $i / $Runs" -ForegroundColor DarkGray
    $r = Invoke-Bench -Label "$($t.Label)-$($t.Tag)-run$i" -BenchExe $t.Bench -ModelPath $Model
    foreach ($rec in $r) { $rec | Add-Member -NotePropertyName outer_run -NotePropertyValue $i -Force }
    $all += $r
  }
  $t | Add-Member -NotePropertyName Results -NotePropertyValue $all
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

function Get-MeanTs {
  param($Records)
  if (-not $Records -or $Records.Count -eq 0) { return $null }
  $vals = $Records | ForEach-Object { [double]$_.avg_ts }
  return ($vals | Measure-Object -Average).Average
}

function Get-StdTs {
  param($Records)
  if (-not $Records -or $Records.Count -eq 0) { return $null }
  if ($Records.Count -eq 1) {
    # Only one outer-run record; fall back to llama-bench's intra-process stddev
    return [double]$Records[0].stddev_ts
  }
  $vals = $Records | ForEach-Object { [double]$_.avg_ts }
  $mean = ($vals | Measure-Object -Average).Average
  $sumSq = 0.0
  foreach ($v in $vals) { $sumSq += [Math]::Pow($v - $mean, 2) }
  return [Math]::Sqrt($sumSq / ($vals.Count - 1))
}

$rows = @()
foreach ($k in ($allTests.Keys | Sort-Object)) {
  $meta = $allTests[$k]
  $row = [ordered]@{ Test = $meta.Label }
  $baselineMean = $null
  foreach ($t in $targets) {
    $recs = @($t.Results | Where-Object { $_.n_prompt -eq $meta.n_prompt -and $_.n_gen -eq $meta.n_gen })
    $mean = Get-MeanTs -Records $recs
    $sd   = Get-StdTs  -Records $recs
    if ($mean -ne $null) {
      $row["$($t.Label) t/s"] = ("{0:N2} +-{1:N2}" -f $mean, ([double]($sd | ForEach-Object { if ($_) { $_ } else { 0 } })))
    } else {
      $row["$($t.Label) t/s"] = "-"
    }
    if ($t.Label -eq $baseline.Label) { $baselineMean = $mean }
  }
  if ($baselineMean -gt 0) {
    foreach ($t in $targets) {
      if ($t.Label -eq $baseline.Label) { continue }
      $recs = @($t.Results | Where-Object { $_.n_prompt -eq $meta.n_prompt -and $_.n_gen -eq $meta.n_gen })
      $mean = Get-MeanTs -Records $recs
      if ($mean -ne $null) {
        $delta = (($mean - $baselineMean) / $baselineMean) * 100.0
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
Write-Host "Reps:     $Reps (intra-process)  |  Runs: $Runs (fresh processes)  |  NGL: $NGL"
Write-Host "Total samples per test: $($Reps * $Runs)"
Write-Host "Baseline for delta %: $($baseline.Label)"
Write-Host ""
$rows | Format-Table -AutoSize

$outFile = Join-Path $WorkDir ("compare-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
@{
  date     = (Get-Date -Format "o")
  model    = $Model
  reps     = $Reps
  runs     = $Runs
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

# ---------- Optional: publish to GitHub release ----------

if ($PublishToRelease) {
  # Resolve target release tag
  $tag = $ReleaseTag
  if (-not $tag) {
    $custom = $targets | Where-Object { $_.Source -eq 'release' -and ($_.Label -eq 'msvc' -or $_.Label -eq 'clang') } | Select-Object -First 1
    if ($custom) {
      $tag = $custom.Tag
    } else {
      # both customs are local paths; fall back to latest release of CUSTOM_REPO
      Write-Host "  no release-sourced custom target; looking up latest $CUSTOM_REPO release..." -ForegroundColor DarkGray
      $latest = gh release list --repo $CUSTOM_REPO --limit 1 --json tagName | ConvertFrom-Json
      if (-not $latest -or $latest.Count -eq 0) {
        Write-Warning "-PublishToRelease: no releases found in $CUSTOM_REPO. Pass -ReleaseTag explicitly."
        return
      }
      $tag = $latest[0].tagName
    }
  }

  Write-Host ""
  Write-Host "Publishing bench table to $CUSTOM_REPO release $tag ..." -ForegroundColor Cyan

  $modelName = Split-Path -Leaf $Model
  $startMarker = "<!-- bench:$modelName -->"
  $endMarker   = "<!-- /bench:$modelName -->"

  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
  $lines = @()
  $lines += $startMarker
  $lines += "### Benchmark: ``$modelName``"
  $lines += ""
  $lines += "Date: $now | Reps: $Reps (intra-process) | Runs: $Runs (fresh processes) | Total samples per test: $($Reps * $Runs) | NGL: $NGL | Baseline: ``$($baseline.Label)``"
  $lines += ""
  $cols = @($rows[0].PSObject.Properties.Name)
  $lines += "| " + ($cols -join " | ") + " |"
  $lines += "|" + ((1..$cols.Count | ForEach-Object { "---" }) -join "|") + "|"
  foreach ($r in $rows) {
    $vals = $cols | ForEach-Object { $r.$_ }
    $lines += "| " + ($vals -join " | ") + " |"
  }
  $lines += ""
  $lines += "Targets:"
  foreach ($t in $targets) {
    $src = if ($t.Source -eq 'local') { "local" } else { "$($t.Repo)@$($t.Tag)" }
    $lines += "- ``$($t.Label)`` -- $src"
  }
  $lines += $endMarker
  # Use explicit LF (Unix) line endings -- GitHub Releases preserves these
  # cleanly. CRLF mixed with existing body content was getting collapsed
  # somewhere in the gh -> GH API round-trip.
  $section = ($lines -join "`n")

  # PowerShell captures stdout as a string ARRAY (split on newlines), so we
  # have to join it back into a single string before doing any regex /
  # concatenation -- otherwise '+ "`n" +' will array-stringify with spaces
  # and silently drop every newline from the existing body.
  $existingArr = gh release view $tag --repo $CUSTOM_REPO --json body --jq '.body'
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "gh release view failed for $tag in $CUSTOM_REPO. Skipping publish."
    return
  }
  if ($null -eq $existingArr) {
    $existing = ""
  } elseif ($existingArr -is [array]) {
    $existing = $existingArr -join "`n"
  } else {
    $existing = [string]$existingArr
  }
  # Normalize to LF
  $existing = $existing -replace "`r`n", "`n" -replace "`r", "`n"

  $startEsc = [regex]::Escape($startMarker)
  $endEsc   = [regex]::Escape($endMarker)
  $pattern  = "$startEsc[\s\S]*?$endEsc\n?"
  if ([regex]::IsMatch($existing, $pattern)) {
    $new = [regex]::Replace($existing, $pattern, $section, 1)
    Write-Host "  replacing existing section for $modelName" -ForegroundColor DarkGray
  } else {
    $new = $existing.TrimEnd() + "`n`n" + $section
    Write-Host "  appending new section for $modelName" -ForegroundColor DarkGray
  }

  $notesFile = Join-Path $WorkDir ("release-notes-$tag.md")
  # Use [IO.File]::WriteAllText to guarantee no BOM and exact bytes
  [System.IO.File]::WriteAllText($notesFile, $new, [System.Text.UTF8Encoding]::new($false))

  # Debug: confirm what we're about to send has actual newlines
  $bytes = [System.IO.File]::ReadAllBytes($notesFile)
  $lfCount = ($bytes | Where-Object { $_ -eq 10 }).Count
  $crCount = ($bytes | Where-Object { $_ -eq 13 }).Count
  Write-Host "  notes-file: $($bytes.Length) bytes, $lfCount LF, $crCount CR" -ForegroundColor DarkGray

  gh release edit $tag --repo $CUSTOM_REPO --notes-file $notesFile
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "gh release edit failed for $tag. Notes saved to $notesFile for manual update."
  } else {
    Write-Host "  updated $CUSTOM_REPO release $tag" -ForegroundColor Green
  }
}
