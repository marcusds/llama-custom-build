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
-DCMAKE_CUDA_ARCHITECTURES=120       # RTX 5000 only (sm_120)
-DGGML_AVX=ON
-DGGML_AVX2=ON
-DGGML_FMA=ON
-DGGML_F16C=ON
-DGGML_AVX_VNNI=ON                   # AVX-VNNI (256-bit, quant dot products)
-DGGML_AVX512=ON
-DGGML_AVX512_VBMI=ON
-DGGML_AVX512_VNNI=ON
-DGGML_AVX512_BF16=ON                # Zen 5 supports AVX512-BF16
-DGGML_NATIVE=OFF
-DLLAMA_FLASH_ATTN=ON
-DBUILD_SHARED_LIBS=ON
-DCMAKE_CXX_FLAGS="/O2 /GL /arch:AVX512"
-DCMAKE_EXE_LINKER_FLAGS="/LTCG"
```

---

## Artifacts

Each successful build uploads a zip containing:
- All `llama-*.exe` binaries
- All required `.dll` files (including CUDA runtime)
- `build-info.json` — records upstream commit, date, and flags used

Scheduled builds also create a **GitHub Release** tagged `build-<sha>`.

---

## Runtime tip (Windows)

For best throughput when using `llama-server` or `llama-cli`:

```powershell
# Increase CUDA command queue (helps with long prompts)
$env:CUDA_SCALE_LAUNCH_QUEUES = "4x"

.\llama-server.exe -m your-model.gguf -ngl 999 -c 8192
```


