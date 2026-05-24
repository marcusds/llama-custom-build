# llama-custom-build

Automated build pipeline for [llama.cpp](https://github.com/ggml-org/llama.cpp), optimised for:

| Hardware | Spec                                        |
|----------|---------------------------------------------|
| GPU | RTX 5000 / 5090 (Blackwell, sm_120) |
| CPU | Zen 5 (Ryzen 9800X3D) — AVX2 / FMA / AVX-VNNI (256-bit) |
| OS | Windows 11 x64                              |
| CUDA | 13.2.1                                      |

This repo contains **no llama.cpp source code**. It only holds the CI pipeline that clones upstream at build time.

---

## Build differences vs upstream

The official `ggml-org/llama.cpp` Windows CUDA release is a portable fat-binary
targeting a wide range of GPUs and CPUs. This pipeline strips that down and
re-tunes for one rig:

| Aspect | Official upstream | This build |
|---|---|---|
| CUDA arch | Multi-arch fat binary | `sm_120` only (smaller, no JIT) |
| CPU dispatch | `GGML_CPU_ALL_VARIANTS=ON` runtime ISA dispatch | Pinned `-march=znver4` + `-mavxvnni` |
| CPU backend | `GGML_CPU=OFF`, shipped as separate DL backend (`GGML_BACKEND_DL=ON`) | Inline with CUDA build (`BUILD_SHARED_LIBS=ON`) |
| Host compiler | MSVC `cl.exe` (Ninja Multi-Config) | ClangCL (Ninja) |
| Optimization | CMake `Release` defaults (`/O2`) | `-O3 -mprefer-vector-width=256 -flto=thin` (ThinLTO) |
| Exception handling | MSVC default (on) | Explicit `/EHsc` (clang-cl needs it) |
| AVX-512 | Implicit via runtime variants | **OFF** (`-mno-avx512f`) — workaround for clang-cl `__AVX512BF16__` include bug in `ggml.c` |
| `GGML_CUDA_NCCL` | Default `ON` | **OFF** (single-GPU rig, kills NCCL link dep) |
| `GGML_CUDA_FA` | `ON` | `ON` (Flash Attention kernels) |
| `GGML_CUDA_FA_ALL_QUANTS` | `OFF` | `OFF` (smaller binary; flip ON for max prompt-proc on uncommon quants) |
| `GGML_CUDA_COMPRESSION_MODE` | unset | `size` (smaller CUDA fatbin) |
| `LLAMA_BUILD_UI` | `ON` (downloads UI assets from HF Bucket at build time) | **OFF** (no network dep, no UI shipped) |
| `LLAMA_BUILD_APP` | `ON` (unified `llama` binary) | **OFF** (only legacy `llama-*` binaries) |
| `LLAMA_BUILD_BORINGSSL` | `ON` | unset (default) |
| PGO | None | None |
| Release cadence | Per upstream release | Per upstream release (automated via `upstream-watcher.yml`) |
| Runner | `windows-2022` (GH-hosted) | `windows-2022` (GH-hosted) |

**Net effect on this rig:** smaller binary, no useless multi-arch CUDA fatbin,
no NCCL/UI dependencies, tuned-but-portable Zen 5 codegen. AVX-512 win is left
on the table until the upstream clang-cl fix lands ([marcusds/llama.cpp@fix/clang-cl-avx512bf16-include](https://github.com/marcusds/llama.cpp/tree/fix/clang-cl-avx512bf16-include)).

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

`scripts/bench-compare.ps1` downloads the latest CUDA Windows release from both
**ggml-org/llama.cpp** (official fat-binary) and **this repo** (sm_120 + Zen 5
pinned), then runs `llama-bench` on the same model with identical parameters
and prints a side-by-side comparison.

Requires `gh` CLI authenticated. If `-Model` is omitted, the script downloads
`Qwen3.5-9B-UD-Q4_K_XL.gguf` from Hugging Face into `bench-work/models/` on
first run and reuses it afterward.

```powershell
# Easiest: no args, auto-downloads default Qwen3.5-9B model
.\scripts\bench-compare.ps1

# Bring your own model
.\scripts\bench-compare.ps1 -Model C:\models\qwen2.5-7b-q4km.gguf

# Custom prompt/gen sweep
.\scripts\bench-compare.ps1 -Pp "128,512,2048" -Tg "64,128"

# Pin a specific custom release tag
.\scripts\bench-compare.ps1 -CustomTag build-abc1234567
```

Builds are cached under `bench-work/`; pass `-Refresh` to re-download. Each
run also writes a timestamped `compare-*.json` with full llama-bench output
from both binaries plus the comparison rows.

---

## Runtime tip (Windows)

For best throughput when using `llama-server` or `llama-cli`:

```powershell
# Increase CUDA command queue (helps with long prompts)
$env:CUDA_SCALE_LAUNCH_QUEUES = "4x"

.\llama-server.exe -m your-model.gguf -ngl 999 -c 8192
```


