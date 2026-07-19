using RepliBuildTooling
using Test

@testset "RepliBuildTooling — load & API surface" begin
    # Package loads and the submodule re-exports resolve
    for name in (:symbols, :dwarf_info, :disassemble, :headers,
                 :code_typed, :code_llvm, :analyze_type_stability,
                 :llvm_ir, :optimize_ir, :run_passes,
                 :benchmark, :benchmark_suite, :track_allocations,
                 :export_json, :export_csv, :export_dataset, :to_dataframe,
                 :BenchmarkResult, :DWARFInfo, :LLVMIRInfo)
        @test isdefined(RepliBuildTooling, name)
    end

    # The core-backend seam is wired (imported by name from RepliBuild)
    @test isdefined(RepliBuildTooling, :extract_symbols_from_binary)
    @test isdefined(RepliBuildTooling, :extract_dwarf_return_types)
end

# Integration demos exercise the full path against a built library + wrapper.
# They need a compiled `.so` (and its stress_test fixture), so they are NOT run
# by Pkg.test() — run them manually against a build:
#   julia --project test/test_introspect.jl
#   julia --project test/introspect_demo.jl
