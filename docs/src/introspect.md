# Introspection Tools

`RepliBuildTooling` is the introspection & analysis toolkit for RepliBuild — an opt-in package that depends on the core (`using RepliBuild, RepliBuildTooling`). It provides a unified interface for analyzing every stage of the compilation pipeline—from binary artifacts and DWARF debug info to Julia's lowered code and LLVM IR.

## Binary Analysis

These tools allow you to inspect the compiled C++ artifacts directly.

```@docs
RepliBuildTooling.symbols
RepliBuildTooling.dwarf_info
RepliBuildTooling.dwarf_dump
RepliBuildTooling.disassemble
RepliBuildTooling.headers
```

## Julia Introspection

Analyze how Julia compiles your wrapper code. These functions wrap standard Julia introspection tools but provide more structured output suitable for analysis.

```@docs
RepliBuildTooling.code_lowered
RepliBuildTooling.code_typed
RepliBuildTooling.code_llvm
RepliBuildTooling.code_native
RepliBuildTooling.code_warntype
RepliBuildTooling.analyze_type_stability
RepliBuildTooling.analyze_simd
RepliBuildTooling.analyze_allocations
RepliBuildTooling.analyze_inlining
RepliBuildTooling.compilation_pipeline
```

## LLVM Tooling

Work directly with LLVM IR to understand optimization passes and code generation.

```@docs
RepliBuildTooling.llvm_ir
RepliBuildTooling.optimize_ir
RepliBuildTooling.compare_optimization
RepliBuildTooling.run_passes
RepliBuildTooling.compile_to_asm
```

## Benchmarking

Performance analysis tools designed to compare C++ native performance against Julia wrappers.

```@docs
RepliBuildTooling.benchmark
RepliBuildTooling.benchmark_suite
RepliBuildTooling.track_allocations
```

## Data Export

Export your findings for external analysis or reporting.

```@docs
RepliBuildTooling.export_json
RepliBuildTooling.export_csv
RepliBuildTooling.export_dataset
```

## CMake Build-System Introspection

Some libraries cannot be compiled from a bare checkout: their headers are produced by
feature detection (`configure_file` over a `config.h.in`), so the files the build needs
do not exist in git. RepliBuild compiles all-sources-minus-excludes under one uniform
flag set and never runs a configure step, which would rule those libraries out
entirely.

cmake's **configure** step is not its build step, though — it is a self-contained
feature-detection pass that emits the generated headers and, with
`CMAKE_EXPORT_COMPILE_COMMANDS`, a full record of how upstream intends to compile every
translation unit. Both are readable in seconds without a compiler touching a real
source file. These tools read that build system rather than running one.

```julia
using RepliBuildTooling

# Configure only — no build. `args` turns off tests/tools/optional deps.
probe = cmake_probe("/path/to/checkout";
                    name      = "pcre2",
                    clone_rel = ".replibuild_cache/deps/pcre2",
                    args      = ["-DPCRE2_BUILD_TESTS=OFF", "-DPCRE2_SUPPORT_JIT=OFF"])

display(probe)          # generated files, targets, per-target uniformity verdict
uniform(probe)          # can RepliBuild's single flag set reproduce this?

harvest_config(probe, "config")   # copy generated headers/sources + write HARVEST.md
println(propose_toml(probe; language="c", shim_headers=["pcre2.h"]))
```

`propose_toml` renders the **structural** half of a `replibuild.toml`: the real `-D`/`-I`
set, and the exclude list derived as the set difference between every source in the tree
and the TUs the chosen target compiles. It is a proposal to read, not a manifest to
paste blind — and it can never produce the residue half (`[wrap.varargs]`,
`[wrap.macros]`), which is precisely what the preprocessor erased before the build
system saw it.

A project routinely configures the same sources into several targets (shared, static,
and a compat shim is the common trio). That is not per-file flag divergence, so
uniformity is judged per target and [`main_target`](@ref) picks which one to build from.

Libraries that defer generation to a *build rule* rather than to configure (libpng's
`pnglibconf.h` comes out of an awk pipeline wired as a custom command) yield no
generated headers here. That empty result is the signal to look for a shipped fallback
or to use `RepliBuild.ingest()` instead.

```@docs
RepliBuildTooling.cmake_probe
RepliBuildTooling.harvest_config
RepliBuildTooling.propose_toml
RepliBuildTooling.main_target
RepliBuildTooling.uniform
RepliBuildTooling.CMakeProbe
RepliBuildTooling.CMakeTarget
```

## Real-World Workflow: Analyzing a Slow Function

Suppose you have a wrapped C++ function `compute_physics` that isn't performing as expected. Here is how you can use the introspection toolkit to diagnose the issue.

### 1. Benchmark
First, establish a baseline.

```julia
using RepliBuildTooling
using MyWrappedLib

# Run a reliable benchmark
result = benchmark(MyWrappedLib.compute_physics, (data_ptr, 1000))
println("Average time: \$(result.avg_time_ns) ns")
```

### 2. Check Type Stability
If the wrapper is type-unstable, Julia has to box values, killing performance.

```julia
# This will print a warning if return types or variables are not concrete
analyze_type_stability(MyWrappedLib.compute_physics, (data_ptr, 1000))
```

### 3. Inspect Native Code
Did the compiler vectorize the loop? Use `code_native` or `analyze_simd`.

```julia
# Look for vector instructions (e.g., vmovups, vmulpd) in the assembly
analyze_simd(MyWrappedLib.compute_physics, (data_ptr, 1000))
```

### 4. Optimize and Compare
Recompile your library with higher optimization levels using `replibuild.toml` (set `optimization_level = "3"`), then rebuild and compare.

```julia
# Compare the IR of two build variants
compare_optimization("build/O2/lib.so", "build/O3/lib.so")
```
