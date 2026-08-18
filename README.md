# RepliBuildTooling.jl

Introspection & analysis toolkit for [RepliBuild](https://github.com/obsidianjulua/RepliBuild.jl) — the opt-in **extra** to the backend.

RepliBuild's core is the ABI-aware C/C++ → Julia compiler bridge. This package is everything *around* it: binary/DWARF inspection, Julia code introspection, LLVM IR tooling, benchmarking, dataset export, and **cmake build-system introspection**. It depends on RepliBuild (never the reverse) and consumes the core's public API + build artifacts — it does not participate in a build. Splitting it out keeps the core's dependency surface lean (no DataFrames/CSV/BenchmarkTools in the backend's precompile path).

The cmake tools read an upstream build system rather than running one: a configure-only
pass yields the generated headers a library cannot be compiled without, the exact `-D`/`-I`
set upstream uses, and a mechanical check of whether every translation unit shares one
flag set. That unblocks the whole class of libraries whose `config.h` does not exist in
git — see the CMake section of `docs/src/introspect.md`, and `packages/pcre2/` in the Hub
for a worked example.

```julia
using RepliBuild, RepliBuildTooling

lib = RepliBuild.build("replibuild.toml")     # core produces the .so + metadata

syms  = symbols(lib)                          # binary introspection
info  = dwarf_info(lib)                        # DWARF layout
ir    = llvm_ir(lib)                           # LLVM IR tooling
res   = benchmark(() -> mylib.hot_path())      # benchmarking
export_dataset([res], "training_data/")        # dataset export
```

## What's inside

| Area | Entry points |
|------|--------------|
| Project artifacts | `project_artifacts`, `lto_ir`, `aot_ir`, `aot_symbols` |
| Binary / DWARF | `symbols`, `dwarf_info`, `disassemble`, `headers`, `dwarf_dump` |
| CMake build systems | `cmake_probe`, `harvest_config`, `propose_toml`, `main_target`, `uniform` |
| Julia code | `code_typed`, `code_llvm`, `code_native`, `analyze_type_stability`, `analyze_simd`, `analyze_allocations`, `compilation_pipeline` |
| LLVM IR | `llvm_ir`, `optimize_ir`, `compare_optimization`, `run_passes`, `compile_to_asm` |
| Benchmarking | `benchmark`, `benchmark_suite`, `track_allocations`, `compare_benchmarks` |
| Dataset export | `export_json`, `export_csv`, `export_dataset`, `to_dataframe` |

## Install

```julia
using Pkg
Pkg.add("RepliBuildTooling")   # pulls RepliBuild as a dependency
```

Docs: `docs/src/introspect.md` (tooling reference).
