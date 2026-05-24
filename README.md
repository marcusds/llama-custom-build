# llama-custom-build

Automated build pipeline for [llama.cpp](https://github.com/ggml-org/llama.cpp), optimised for:

| Hardware | Spec                                        |
|----------|---------------------------------------------|
| GPU | RTX 5000 (Blackwell, sm_120) |
| CPU | Zen 5, AVX-512                              |
| OS | Windows 11 x64                              |
| CUDA | 13.x                                        |

This repo contains **no llama.cpp source code**. It only holds the CI pipeline that clones upstream at build time.

---

## How it works

```
[Upstream: ggml-org/llama.cpp master]
              │  cloned fresh each run
              ▼
  GitHub Actions (windows-latest)
    └── CMake configure (custom flags)
    └── Build Release
    └── Package EXEs + DLLs
    └── Upload artifact / create Release
```

Builds run automatically every **Sunday at 03:00 UTC**, or trigger manually.

---

## Triggering a manual build

1. Go to **Actions → Build llama.cpp**
2. Click **Run workflow**
3. Optionally specify a branch, tag, or commit SHA (defaults to `master`)

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

Scheduled builds also create a **GitHub Release** tagged `build-<sha>`.

---

## Benchmarking vs upstream

`scripts/bench-compare.ps1` downloads the latest CUDA Windows release from both
**ggml-org/llama.cpp** (official fat-binary) and **this repo** (sm_120 + Zen 5
pinned), then runs `llama-bench` on the same model with identical parameters
and prints a side-by-side comparison.

Requires `gh` CLI authenticated and a GGUF model on disk.

```powershell
# Default: pp512 + tg128, 5 reps, -ngl 999, latest releases of both repos
.\scripts\bench-compare.ps1 -Model C:\models\qwen2.5-7b-q4km.gguf

# Custom prompt/gen sweep
.\scripts\bench-compare.ps1 -Model model.gguf -Pp "128,512,2048" -Tg "64,128"

# Pin a specific custom release tag
.\scripts\bench-compare.ps1 -Model model.gguf -CustomTag build-abc1234567
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


