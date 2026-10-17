# llama-custom-build

Automated build pipeline for [llama.cpp](https://github.com/ggml-org/llama.cpp), optimised for:

| Hardware | Spec                                        |
|----------|---------------------------------------------|
| GPU | RTX 5000 / 5090 (Blackwell, sm_120) |
| CPU | Zen 5 (Ryzen 9800X3D) — AVX2 / FMA / AVX-VNNI (256-bit) |
| OS | Windows 11 x64                              |
| CUDA | 13.2.1                                      |
| Mac | Apple M4 MacBook Pro (4P+6E cores, 10-core GPU, 24 GB) — macOS, Metal |

This repo contains **no llama.cpp source code**. It only holds the CI pipeline that clones upstream at build time.

---

## Build differences vs upstream

The official `ggml-org/llama.cpp` Windows CUDA release is a portable fat-binary
targeting a wide range of GPUs and CPUs. This pipeline strips that down and
re-tunes for one rig, producing **two artifacts per upstream release** -- one
from MSVC and one from ClangCL -- so the two compilers can be benchmarked
head-to-head:

| Aspect | Official upstream | This build (MSVC) | This build (ClangCL) |
|---|---|---|---|
| Host compiler | MSVC `cl.exe` (Ninja Multi-Config) | MSVC `cl.exe` (Ninja) | ClangCL (Ninja) |
| CUDA arch | Multi-arch fat binary | `sm_120` only | `sm_120` only |
| CPU dispatch | `GGML_CPU_ALL_VARIANTS=ON` runtime ISA dispatch | Pinned via `/arch:AVX512` + GGML_AVX_VNNI ON | Pinned `-march=znver4` + `-mavxvnni` |
| AVX-512 | Implicit via runtime variants | **ON** (F/BW/CD/DQ/VL + VBMI/VNNI; BF16 still OFF, upstream `sgemm.cpp` `(__m512bh)` C-cast rejected by MSVC) | **OFF** -- clang-cl `__AVX512BF16__` include bug ([fork patch](https://github.com/marcusds/llama.cpp/tree/fix/clang-cl-avx512bf16-include)) |
| Optimization | CMake `Release` defaults (`/O2`) | `/O2 /Ob3 /Oi /Ot /Gy /Gw /Zc:inline` (Release overridden to `/Ob3`) | `-O3 -mprefer-vector-width=256 -ffunction-sections -fdata-sections` |
| LTO + dead-code elim | None explicit | **None** (`/GL` + `/LTCG` crashed link.exe on `llama-common.dll` with `BUILD_SHARED_LIBS=ON` + auto-export) | ThinLTO (`-flto=thin`) |
| Exception handling | MSVC default (on) | MSVC default (on) | Explicit `/EHsc` (clang-cl needs it) |
| CPU backend | `GGML_CPU=OFF`, shipped as separate DL backend (`GGML_BACKEND_DL=ON`) | Inline (`BUILD_SHARED_LIBS=ON`) | Inline (`BUILD_SHARED_LIBS=ON`) |
| `GGML_CUDA_NCCL` | Default `ON` | **OFF** (single-GPU rig) | **OFF** (single-GPU rig) |
| `GGML_CUDA_FA` | `ON` | `ON` | `ON` |
| `GGML_CUDA_FORCE_MMQ` | `OFF` | **`ON`** (forces MMQ over cuBLAS for Q-quants) | **`ON`** |
| `GGML_CUDA_FA_ALL_QUANTS` | `OFF` | **`ON`** (fused FA for all KV-quant combos) | **`ON`** |
| `GGML_CUDA_GRAPHS` | `OFF` (default) | **`ON`** (cuts decode launch overhead) | **`ON`** |
| `CMAKE_CUDA_FLAGS` (ptxas) | default | `-Xptxas=-O3 -Xptxas=-dlcm=ca` | `-Xptxas=-O3 -Xptxas=-dlcm=ca` |
| `GGML_CUDA_COMPRESSION_MODE` | unset | `size` | `size` |
| `LLAMA_BUILD_UI` | `ON` (downloads HF UI assets) | **OFF** | **OFF** |
| `LLAMA_BUILD_APP` | `ON` (unified `llama` binary) | **OFF** | **OFF** |
| `LLAMA_BUILD_BORINGSSL` | `ON` | unset | unset |
| PGO | None | None | None |
| Release tag | `b<NNNN>` | `upstream-<tag>-msvc` | `upstream-<tag>-clang` |
| Runner | `windows-2022` (GH-hosted) | `windows-2022` (GH-hosted) | `windows-2022` (GH-hosted) |

**Per-compiler trade-offs:**
- **MSVC** -- gets full AVX-512 incl. VBMI/VNNI/BF16. Lacks Zen-specific microarch tuning (only `/arch:AVX512`, no `-march=znver4` equivalent).
- **ClangCL** -- gets precise `-march=znver4` instruction selection and ThinLTO. AVX-512 is currently disabled at the compiler level to work around an upstream `_MSC_VER`-branch include bug in `ggml/src/ggml.c` (fix pending on the fork branch above).

The watcher in `upstream-watcher.yml` triggers a new run when **either** marker is missing.

---

## How it works

```
[Upstream release on ggml-org/llama.cpp]
              │  upstream-watcher.yml polls every 30 min
              ▼
[workflow_dispatch build.yml with llama_ref=<upstream-tag>]
              │
              ▼
  GitHub Actions (windows-2022)
    └── Restore cached CUDA Toolkit 13.2.1 (redist archives)
    └── Clone llama.cpp @ <upstream-tag>
    └── CMake configure (ClangCL, sm_120, tuned znver4)
    └── Build Release
    └── Package EXEs + DLLs + CUDA runtime
    └── Upload artifact + create GitHub Release tagged upstream-<tag>
```

Builds run automatically whenever a new release is published on
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp/releases), via the
`upstream-watcher.yml` workflow (polls every 30 minutes). Manual builds via
the **Actions → Build llama.cpp → Run workflow** UI.

---

## Triggering a manual build

1. Go to **Actions → Build llama.cpp**
2. Click **Run workflow**
3. Optionally specify a branch, tag, or commit SHA (defaults to `master`).
   Passing an upstream release tag (e.g. `b6789`) also creates a GitHub
   Release tagged `upstream-b6789` on success.

---

## CMake flags used

```cmake
-DGGML_CUDA=ON
-DCMAKE_CUDA_ARCHITECTURES=120       # RTX 5000/5090 (sm_120)
-DGGML_AVX=ON
-DGGML_AVX2=ON
-DGGML_FMA=ON
-DGGML_F16C=ON
-DGGML_AVX_VNNI=ON                   # AVX-VNNI (256-bit, quant dot products)
-DGGML_AVX512=OFF                    # disabled: clang-cl C-mode BF16 intrinsic gap
-DGGML_NATIVE=OFF
-DBUILD_SHARED_LIBS=ON
-DCMAKE_C_FLAGS="-O3 -march=znver4 -mprefer-vector-width=256 -flto=thin"
-DCMAKE_CXX_FLAGS="-O3 -march=znver4 -mprefer-vector-width=256 -flto=thin"
-DCMAKE_EXE_LINKER_FLAGS="-flto=thin"
-DCMAKE_SHARED_LINKER_FLAGS="-flto=thin"
```

Compiler: ClangCL (from VS 2022 LLVM toolset). ThinLTO at link time.

---

## Artifacts

Each successful build uploads a zip containing:
- All `llama-*.exe` binaries
- All required `.dll` files (including CUDA runtime)
- `build-info.json` — records upstream commit, date, and flags used

Builds dispatched from `upstream-watcher.yml` (or manually with an upstream
tag) also create a **GitHub Release** tagged `upstream-<tag>` (e.g.
`upstream-b6789`).

---

## Benchmarking vs upstream

`scripts/bench-compare.ps1` resolves three `llama-bench` targets and runs each
on the same model with identical parameters, then prints a side-by-side
throughput table with delta % vs the **official** baseline:

  | Target | Default source |
  |---|---|
  | `official` | latest CUDA-13 Windows asset from `ggml-org/llama.cpp` |
  | `msvc`     | latest `*win-x64-msvc-*.zip` from `marcusds/llama-custom-build` |
  | `clang`    | latest `*win-x64-clang-*.zip` from `marcusds/llama-custom-build` |

Requires `gh` CLI authenticated. If `-Model` is omitted, the script downloads
`Qwen3.5-9B-UD-Q4_K_XL.gguf` from Hugging Face into `bench-work/models/` on
first run and reuses it afterward.

```powershell
# Default: 3-way bench (official + msvc + clang from releases)
.\scripts\bench-compare.ps1

# Bring your own model
.\scripts\bench-compare.ps1 -Model C:\models\qwen2.5-7b-q4km.gguf

# Bench local build folders instead of downloading from releases
.\scripts\bench-compare.ps1 `
  -CustomMsvcPath  D:\local\msvc\bin `
  -CustomClangPath D:\local\clang\bin

# Skip official, just compare msvc vs clang
.\scripts\bench-compare.ps1 -SkipOfficial

# Custom prompt/gen sweep
.\scripts\bench-compare.ps1 -Pp "128,512,2048" -Tg "64,128"

# Pin specific release tags
.\scripts\bench-compare.ps1 -CustomTag upstream-b9297

# Append the result table to the GitHub Release body (per-model section,
# replaced on re-run for the same model)
.\scripts\bench-compare.ps1 -PublishToRelease

# Publish to a specific release tag (useful when both customs are local)
.\scripts\bench-compare.ps1 `
  -CustomMsvcPath  D:\local\msvc\bin `
  -CustomClangPath D:\local\clang\bin `
  -PublishToRelease -ReleaseTag upstream-b9297
```

`-CustomMsvcPath` / `-CustomClangPath` point to folders containing
`llama-bench.exe` (searched recursively); when set, the script skips the
GitHub download for that target. `-SkipOfficial` / `-SkipMsvc` / `-SkipClang`
drop a target from the run. At least two targets are required.

Builds are cached under `bench-work/`; pass `-Refresh` to re-download. Each
run writes `bench-work/compare-<timestamp>.json` with the full llama-bench
output from every target plus the comparison rows.

---

## macOS (Apple M4)

A third job, `build-macos-metal`, builds `*-macos-arm64-*.zip` on a GitHub
`macos-15` runner, tuned for the M4 MacBook Pro rather than the runner:

| Aspect | Official upstream macOS | This build |
|---|---|---|
| CPU target | `-mcpu=native` of the release runner | `-mcpu=apple-m4` pinned (dotprod, i8mm, fp16, bf16, SME2; no SVE), `GGML_NATIVE=OFF` |
| GPU | Metal | Metal, shaders embedded in the binary |
| `GGML_CPU_KLEIDIAI` | `OFF` | **`ON`** (SME2 microkernels for ops left on the CPU) |
| Linking | shared `libggml*.dylib` + `libllama.dylib` | shared, `@loader_path` rpath (unzip anywhere) |
| TLS | system/Homebrew OpenSSL | **BoringSSL, linked in** (no `/opt/homebrew` dependency) |
| `LLAMA_BUILD_NUMBER` | from full clone | recovered from the `bNNNN` tag (shallow clone would say build 1) |

The runner is an older M-series chip, so the binaries are not executed in CI
(SME instructions would fault there); the job instead fails if any binary needs
a dylib that is neither part of macOS nor shipped in the zip. Requires Apple
clang 17+, so
the job selects the newest Xcode on the image.

Running it on the M4:

```sh
gh release download upstream-bNNNN -R marcusds/llama-custom-build -p '*-macos-arm64-*.zip'
unzip llama-cpp-m4-macos-arm64-*.zip -d llama-m4
xattr -dr com.apple.quarantine llama-m4   # only needed if downloaded via a browser

# Metal lets the GPU wire ~75% of RAM by default (18186 MiB on 24 GB).
# Raise it until next reboot if weights + KV cache don't fit:
sudo sysctl iogpu.wired_limit_mb=20480

# -t 4: P-cores only; E-cores just make each token wait on the slowest thread.
./llama-m4/llama-server -m model.gguf -ngl 999 -fa on -t 4 -c 32768
```

`scripts/bench-compare.ps1` is Windows-only and does not cover this artifact.

---

## Runtime tip (Windows)

For best throughput when using `llama-server` or `llama-cli`:

```powershell
# Increase CUDA command queue (helps with long prompts)
$env:CUDA_SCALE_LAUNCH_QUEUES = "4x"

.\llama-server.exe -m your-model.gguf -ngl 999 -c 8192
```


