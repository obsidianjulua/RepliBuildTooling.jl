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
