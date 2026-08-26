#!/usr/bin/env julia
# RepliBuildTooling.jl — Introspection & analysis toolkit for RepliBuild
#
# Structured access to binary analysis, Julia introspection, LLVM tooling, and
# benchmarking, for dataset-generation and performance-analysis workflows.
#
# Split out of the RepliBuild core (2026-07-19) so the backend stays lean: this
# is the opt-in "extra" that depends on RepliBuild, never the reverse. Everything
# here consumes the core's public API + build artifacts; it does not participate
# in a build.

module RepliBuildTooling

# Core backend primitives the submodules build on — all public RepliBuild API.
# Imported by name (not a blanket `using`) to keep the core's large export
# surface out of this namespace.
using RepliBuild: extract_symbols_from_binary, extract_dwarf_return_types,
                  execute, get_tool, with_llvm_env

# Standard library imports
using InteractiveUtils  # For @code_* macros
using Dates            # For timestamps
using Statistics       # For benchmark statistics
using JSON            # For JSON export

# Load submodules in dependency order
include("Introspect/Types.jl")
include("Introspect/DataExport.jl")
include("Introspect/Binary.jl")
include("Introspect/Julia.jl")
include("Introspect/LLVM.jl")
include("Introspect/Benchmarking.jl")
include("Introspect/Project.jl")
include("Introspect/Api.jl")
# CMakeHarvest.jl moved to RepliBuild (src/Builder/SysConfigGen.jl) 2026-08-26.
# Generating a library's configure-time headers is a BUILD capability, not
# introspection: without it the compile has nothing to include. Reach for
# RepliBuild.SysConfigGen.

# Re-export public APIs from submodules

# Project Introspection
export project_artifacts, lto_ir, aot_ir, aot_symbols

# API Surface — which of a wrapper's thousands of definitions are callable API
export api, api_surface, api_struct, byvalue_args, signature
export ApiFunction, ApiSurface

# Binary Introspection
export symbols, dwarf_info, disassemble, headers, dwarf_dump


# Julia Introspection
export code_lowered, code_typed, code_llvm, code_native, code_warntype
export analyze_type_stability, analyze_simd, analyze_allocations, analyze_inlining
export compilation_pipeline

# LLVM Tooling
export llvm_ir, optimize_ir, compare_optimization, run_passes, compile_to_asm
export analyze_ir_structure, extract_function_names, compare_ir_files

# Benchmarking
export benchmark, benchmark_suite, track_allocations
export compare_benchmarks, fastest, slowest, is_significant, speedup

# Dataset Export
export export_json, export_csv, export_dataset, to_json_dict, to_dataframe

# Types (structured result types)
export BenchmarkResult, TypeStabilityAnalysis, SIMDAnalysis, AllocationAnalysis,
       CompilationPipelineResult, OptimizationResult,
       CodeLoweredInfo, CodeTypedInfo, LLVMIRInfo, AssemblyInfo,
       DWARFInfo, HeaderInfo, FunctionInfo, StructInfo

end # module RepliBuildTooling
