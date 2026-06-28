---
paths:
  - "**/*.cpp"
  - "**/*.cc"
  - "**/*.cxx"
  - "**/*.c"
  - "**/*.h"
  - "**/*.hpp"
  - "**/*.hxx"
  - "**/*.cu"
  - "**/*.cuh"
  - "**/CMakeLists.txt"
  - "**/*.cmake"
  - "**/Makefile"
  - "**/meson.build"
  - "**/*.py"
  - "**/pyproject.toml"
  - "**/setup.py"
  - "**/setup.cfg"
---

# Compute Overlay — C++ / CUDA / Parallel Python (Nexus)

> Loads on native/CUDA/Python compute files. Target box: **Nexus** — Threadripper 5995WX (64c/128t, multi-NUMA), 512 GB RAM, **2× RTX 3090** (Ampere, sm_86, no NVLink → PCIe peer-to-peer), Ubuntu. Default toolchain: GCC/Clang + CUDA Toolkit + nvcc, CMake + Ninja, Python via `uv`. Sections mirror the spine's numbering: §5 architecture, §6 release, §7 quality gate, §8 testing, §12 concurrency, §13 compliance.

## 5. Architecture Patterns (compute)

- **Host/device split is explicit.** Host orchestrates; device computes. Keep kernels free of host-only assumptions; keep transfer boundaries visible (every `cudaMemcpy`/H2D/D2H is a cost you can name).
- **Data layout is a first-class decision.** Prefer **SoA over AoS** for vectorized/coalesced access. Align to cache lines (CPU) and 128-byte segments (GPU global memory). State the layout in the plan, not after profiling shows the stall.
- **Separate the numeric kernel from the I/O and orchestration.** The hot kernel is pure, testable against a reference, and free of logging/allocation. Allocation and I/O live at the edges.
- **One parallelism model per layer; don't mix.** Pick CUDA *or* OpenMP *or* `multiprocessing` for a given stage; nesting them without intent causes oversubscription and false sharing.
- **Bindings are a boundary.** C++↔Python via pybind11/nanobind/ctypes is an API surface: own the ownership/lifetime contract, never leak a raw pointer whose free-time is ambiguous, release the GIL around long native calls (`py::gil_scoped_release`).
- **Determinism is designed in, not hoped for.** If results must be reproducible (research/benchmarks), fix reduction order, RNG seeds, thread counts, and fp mode up front — see §12 and the `numerics-engineer`.

## 6. Release Engineering (native artifacts)

- **Version source of truth:** one file (`VERSION`, `pyproject.toml`, or a CMake `project(... VERSION x.y.z)`); tag `vX.Y.Z` must match. SemVer; ABI-breaking change = MAJOR.
- **Build matrix:** record the toolchain that produced an artifact — compiler + version, CUDA toolkit version, target GPU archs (`-gencode arch=compute_86,code=sm_86` for the 3090s; add others only if you ship beyond Nexus), `-O` level, and whether sanitizers were on (they must be OFF in the release artifact).
- **Wheels / binaries:** pin the `manylinux`/glibc target if distributing Python wheels with native extensions; otherwise document "built for this box."
- **CHANGELOG** per Keep-a-Changelog; ABI/behavioral breaks are loud with a migration note.

## 7. Quality Gate (local + CI)

Fail fast, cheap first. Representative ordering — adapt commands to the project:
```bash
# format + static
clang-format --dry-run --Werror $(git diff --name-only --diff-filter=ACM | grep -E '\.(cpp|cc|cu|h|hpp|cuh)$')
ruff check . && ruff format --check .        # python
# build (warnings are errors)
cmake --build build -j --                     # -Wall -Wextra -Werror; nvcc -Xcompiler -Wall
# sanitizers (debug build) — at least one of:
ctest --test-dir build-asan                   # ASan+UBSan build
compute-sanitizer --tool memcheck ./build/tests/gpu_tests   # CUDA
# tests
ctest --test-dir build -j                     # C++ unit + numerical
pytest -q                                      # python unit + binding tests
```
A clean build under `-Wall -Wextra -Werror` (and `nvcc -Xcompiler -Wall`) is non-negotiable. Warnings in compute code are usually correctness bugs (narrowing, sign-compare, unused result of a `cuda*` call).

## 8. Test Coverage Policy (compute surfaces)

- **Unit** — pure kernel/function logic, host-side, fast. Every numeric kernel has a CPU reference it's checked against.
- **Numerical regression** — golden outputs with an explicit tolerance (`abs`/`rel`/ULP). Never exact-equality on floats unless the op is provably exact. Record the tolerance and why.
- **GPU-vs-CPU equivalence** — the CUDA path matches the CPU reference within tolerance on the same inputs.
- **Property / fuzz** — round-trip, invariants, bounds; seed everything and capture the seed on failure.
- **Sanitizer runs** — ASan/UBSan/TSan (CPU) and `compute-sanitizer` (memcheck/racecheck/synccheck) on the GPU path, in CI, on representative inputs.
- **Performance regression** — a benchmark gate on the hot path (e.g. Google Benchmark / `pytest-benchmark`); flag a regression beyond a set % so a "small refactor" can't silently halve throughput.

## 12. Concurrency & Parallelism

**CPU (Threadripper, multi-NUMA):**
- Know your NUMA topology (`numactl --hardware`). Pin threads/processes (`numactl`, `taskset`, `OMP_PROC_BIND=close`, `OMP_PLACES=cores`) — unpinned threads migrate across NUMA nodes and tank bandwidth.
- Avoid **false sharing** — pad/align per-thread data to a cache line (64 B).
- **OpenMP:** scope `private`/`shared` explicitly; no data races on reductions (use `reduction(...)`); mind the implicit barrier.
- **Python `multiprocessing`:** the GIL means threads don't parallelize CPU work — use processes. Beware pickling cost across the process boundary; prefer `shared_memory`/mmap for large arrays; size pools to physical cores, not threads, for CPU-bound work. Always guard with `if __name__ == "__main__":`.
- Bounded queues only; never unbounded. Propagate cancellation/timeouts.

**GPU (2× RTX 3090):**
- **Memory hierarchy is the game:** coalesce global access; use shared memory for reuse; watch bank conflicts; keep occupancy high but not at the cost of register spills.
- **Streams** for overlap (copy/compute); events for timing/sync. Default stream serializes — use non-default streams for concurrency.
- **Multi-GPU:** no NVLink on 3090s → peer access is over PCIe; partition work to minimize cross-device traffic. Set device explicitly (`cudaSetDevice`); one context discipline per device.
- **Always check CUDA return codes** (`CUDA_CHECK(...)` macro) — a swallowed `cudaError_t` is a silent corruption. Sync before timing.
- Prefer `__restrict__`, avoid divergent warps on the hot path, use `--use_fast_math` only when the `numerics-engineer` signs off.

## 13. Compliance & Reproducibility

- **Licenses** of native deps (vcpkg/conan/FetchContent pulls): confirm compatibility before vendoring; GPL/LGPL linkage has obligations.
- **Reproducibility** is the compliance surface here: pin toolchain + CUDA version + dep versions + RNG seeds + thread counts; record them with each result set. An unreproducible benchmark is not a result.
- No secrets in code (§11 spine). For research data, document provenance.
