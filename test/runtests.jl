using RepliBuildTooling
using Test
using JSON        # synthetic metadata for the api-surface tests
const T = RepliBuildTooling

# ---------------------------------------------------------------------------
# Fixture discovery for the binary/LLVM/project tests. These need a compiled
# artifact, so they're opt-in: they run against a discoverable build and are
# skipped (not failed) otherwise, keeping `Pkg.test()` green anywhere. Point
# REPLIBUILD_TEST_SO at a built `.so` to force-enable them.
# ---------------------------------------------------------------------------
function find_fixture()
    candidates = String[]
    haskey(ENV, "REPLIBUILD_TEST_SO") && push!(candidates, ENV["REPLIBUILD_TEST_SO"])
    # Sibling checkouts in the usual Projects/ layout.
    push!(candidates, joinpath(@__DIR__, "..", "..", "RepliBuild-Hub", "packages", "cjson", "julia", "libcjson.so"))
    push!(candidates, joinpath(@__DIR__, "..", "..", "RepliBuild.jl", "test", "stress_test", "julia", "libstress_test.so"))
    for so in candidates
        isfile(so) || continue
        dir = dirname(so)
        stem = replace(basename(so), r"^lib" => "", r"\.so$" => "")
        bc  = joinpath(dir, "$(stem)_lto.bc")    # bitcode  -> llvm_ir (llvm-dis)
        ll  = joinpath(dir, "$(stem)_lto.ll")    # textual  -> opt / llc
        toml = joinpath(dirname(dir), "replibuild.toml")
        return (so = abspath(so),
                bc = isfile(bc) ? abspath(bc) : nothing,
                ll = isfile(ll) ? abspath(ll) : nothing,
                toml = isfile(toml) ? abspath(toml) : nothing)
    end
    return nothing
end

@testset "RepliBuildTooling" begin

    @testset "load & API surface" begin
        for name in (:symbols, :dwarf_info, :disassemble, :headers,
                     :code_typed, :code_llvm, :analyze_type_stability,
                     :llvm_ir, :optimize_ir, :run_passes,
                     :benchmark, :benchmark_suite, :track_allocations,
                     :export_json, :export_csv, :export_dataset, :to_dataframe,
                     :cmake_probe, :harvest_config, :propose_toml, :main_target,
                     :BenchmarkResult, :DWARFInfo, :LLVMIRInfo, :CMakeProbe)
            @test isdefined(RepliBuildTooling, name)
        end
        # The core-backend seam is wired (imported by name from RepliBuild)
        @test isdefined(RepliBuildTooling, :extract_symbols_from_binary)
        @test isdefined(RepliBuildTooling, :extract_dwarf_return_types)
    end

    # -- Julia introspection: pure, needs no external binary, always runs --------
    f_stable(x::Vector{Float64}) = (s = 0.0; @inbounds for v in x; s += v * v; end; s)
    f_union(n::Int) = n > 0 ? 1 : "neg"                # Union{Int,String}
    f_any(x::Vector{Any}) = x[1] + 1                   # Any

    @testset "code_* wrappers" begin
        @test T.code_lowered(f_stable, (Vector{Float64},)).code isa Vector
        @test T.code_typed(f_stable, (Vector{Float64},)).return_type === Float64
        llvm = T.code_llvm(f_stable, (Vector{Float64},))
        @test occursin("define", llvm.ir) && llvm.instruction_count > 0
        @test T.code_native(f_stable, (Vector{Float64},), syntax = :intel).syntax === :intel
        p = T.compilation_pipeline(f_stable, (Vector{Float64},))
        @test p.llvm_ir.instruction_count > 0 && p.native.instruction_count > 0
        @test T.analyze_inlining(f_stable, (Vector{Float64},))[:optimized] isa T.CodeTypedInfo
    end

    @testset "type stability" begin
        # Regression: @code_warntype prints non-concrete types UPPERCASED in a
        # no-color IO (`Body::UNION{…}`); the old substring check for "Union"/"Any"
        # never matched, so every function read as stable. Verdict is now taken from
        # the inferred return type (what `@inferred` enforces).
        @test T.analyze_type_stability(f_stable, (Vector{Float64},)).is_stable
        @test !T.analyze_type_stability(f_union, (Int,)).is_stable        # was WRONGLY stable
        a = T.analyze_type_stability(f_any, (Vector{Any},))
        @test !a.is_stable
        @test !isempty(a.unstable_variables)                             # pinpoints the Any exprs
        # A stable function must not list phantom "unstable" vars: benign union-split
        # intermediates (e.g. the iteration protocol's Union{Nothing,Tuple}) and
        # control-flow statements are excluded.
        @test isempty(T.analyze_type_stability(f_stable, (Vector{Float64},)).unstable_variables)
    end

    @testset "simd / allocation analysis" begin
        f_bcast(x::Vector{Int32}) = x .* Int32(2)      # integer broadcast — vectorizes
        simd = T.analyze_simd(f_bcast, (Vector{Int32},))
        @test simd isa T.SIMDAnalysis
        @test simd.vector_instructions >= 0 && simd.scalar_instructions >= 0
        # Forced bounds-checking (Pkg.test's `--check-bounds=yes` default) inserts
        # branches that inhibit auto-vectorization, so the strong "vectors detected"
        # claim is only asserted when bounds-checks aren't forced on.
        if Base.JLOptions().check_bounds != 1
            @test simd.vector_instructions > 0
        end
        @test T.analyze_allocations(f_stable, (Vector{Float64},)) isa T.AllocationAnalysis
    end

    # -- Benchmarking: per-call accounting regression ---------------------------
    @testset "benchmarking" begin
        r = T.benchmark(() -> sum(rand(1000)), samples = 200, warmup = 10)
        @test r.samples == 200 && r.median_time > 0
        # Per-call semantics: a single ~8KB array allocation must NOT scale with the
        # sample count. The old code reported allocations == samples (200) and
        # memory == samples × bytes (≈1.6 MB).
        @test 0 < r.allocations < 100
        @test 0 < r.memory < 1_000_000
        r0 = T.benchmark(() -> 1 + 1, samples = 100, warmup = 5)
        @test r0.allocations == 0 && r0.memory == 0

        suite = T.benchmark_suite(Dict("a" => () -> sum(rand(50)),
                                       "b" => () -> sum(rand(50))), samples = 50)
        @test length(suite) == 2
        @test T.track_allocations(() -> sum(rand(1000)))[:total_bytes] > 0

        r1 = T.benchmark(() -> sum(rand(50)),   samples = 50)
        r2 = T.benchmark(() -> sum(rand(5000)), samples = 50)
        @test T.fastest(r1, r2).median_time == min(r1.median_time, r2.median_time)
        @test T.slowest(r1, r2).median_time == max(r1.median_time, r2.median_time)
        @test T.speedup(r2, r1) > 0
        @test T.is_significant(r1, r2) isa Bool
        @test size(T.compare_benchmarks([r1, r2]), 1) == 2
    end

    # -- Data export: fallback CSV path (generator gotcha + nothing→missing) -----
    @testset "data export" begin
        mktempdir() do dir
            # FunctionInfo has no special-case in to_dataframe, so this drives the
            # generic fallback that used to (a) throw on the `all(pred for …)`
            # generator gotcha and (b) choke on a raw `nothing` (the `class` field).
            fns = [T.FunctionInfo("f$i", "f$i", "f$i", "int",
                                  Tuple{String,String}[], false,
                                  i == 1 ? nothing : "C") for i in 1:3]
            df = T.to_dataframe(fns)
            @test size(df, 1) == 3
            csv = joinpath(dir, "fns.csv")
            @test T.export_csv(fns, csv) == csv && filesize(csv) > 0

            r = T.benchmark(() -> sum(rand(10)), samples = 20)
            @test T.to_json_dict(r) isa AbstractDict
            T.export_json(r, joinpath(dir, "b.json"))
            @test isfile(joinpath(dir, "b.json"))
            T.export_dataset([r], dir, formats = [:json, :csv])
            @test isfile(joinpath(dir, "benchmarks.json"))
            @test isfile(joinpath(dir, "benchmarks.csv"))
        end
    end

    @testset "IR utilities (no binary)" begin
        ir = join(["define i64 @foo(i64 %x) {",
                   "  %1 = add i64 %x, 1",
                   "  ret i64 %1",
                   "}"], "\n")
        @test T.count_ir_instructions(ir) == 2
        @test T.extract_function_names(ir) == ["foo"]
        @test T.analyze_ir_structure(ir)[:function_count] == 1
        @test occursin("μs", T.format_time(1500.0)) && occursin("1.5", T.format_time(1500.0))
        @test occursin("KiB", T.format_bytes(2048)) && occursin("2.0", T.format_bytes(2048))
    end

    # -- Binary / LLVM / project introspection: gated on a discoverable fixture --
    fx = find_fixture()
    if fx === nothing
        @info "No RepliBuild binary fixture found — skipping binary-introspection tests. " *
              "Set REPLIBUILD_TEST_SO to a built .so to enable them."
    else
        @testset "binary introspection [$(basename(fx.so))]" begin
            syms = T.symbols(fx.so, filter = :functions)
            @test !isempty(syms) && all(s -> s.type === :function, syms)
            @test length(T.symbols(fx.so)) >= length(syms)

            dw = T.dwarf_info(fx.so)
            @test dw isa T.DWARFInfo
            @test !isempty(dw.functions)

            h = T.headers(fx.so)
            # Regression: section names must be real (".text", …), never the "N]"
            # fragments the old positional split produced from "[ 1]".
            @test !isempty(h.sections)
            @test any(s -> startswith(s[1], "."), h.sections)
            @test !any(s -> occursin(']', s[1]), h.sections)

            # Regression: symbol disassembly must not truncate at the first `call <…>`.
            # Assert we captured the whole block — the right header plus a terminating
            # `ret` — rather than the two-or-three lines the old '<'-terminated filter
            # produced (which cut off before the function's body, and its return).
            target = syms[1].name
            asm = T.disassemble(fx.so, target, syntax = :intel)
            @test occursin("<$target>:", asm)         # captured the correct block
            @test occursin("ret", asm)                # ...through to its return, not truncated

            T.export_json(dw, tempname() * ".json")   # smoke: full DWARF serialization
        end

        if fx.bc !== nothing
            @testset "LLVM bitcode [$(basename(fx.bc))]" begin
                info = T.llvm_ir(fx.bc)              # llvm_ir disassembles bitcode
                @test info.instruction_count > 0
                @test !isempty(T.extract_function_names(info.ir))
                @test T.analyze_ir_structure(info.ir)[:function_count] >= 1
            end
        end

        if fx.ll !== nothing
            @testset "LLVM opt/llc [$(basename(fx.ll))]" begin
                opt = T.optimize_ir(fx.ll, "2")     # opt / llc consume textual IR
                @test opt.metrics.instructions_before > 0
                @test !isempty(T.compile_to_asm(fx.ll))
                @test haskey(T.compare_optimization(fx.ll, ["0", "2"]), "2")
            end
        end

        if fx.toml !== nothing
            @testset "project artifacts" begin
                arts = T.project_artifacts(fx.toml)
                @test haskey(arts, :library)
                if haskey(arts, :lto_ir)
                    @test T.lto_ir(fx.toml).instruction_count > 0
                end
                if haskey(arts, :aot_lib)
                    @test !isempty(T.aot_symbols(fx.toml))
                end
            end
        end
    end

    # -----------------------------------------------------------------------
    # API surface. Synthetic metadata only — the classification is a pure
    # function of the symbol table, so it needs no toolchain, no built package
    # and no fixture, and therefore always runs.
    #
    # The shapes below are the three real ones, and the third is why the
    # strategy exists at all: a naive "C linkage == public" rule reports
    # pugixml and box2d as having ZERO public functions, which is worse than
    # no filter. Each shape is asserted against what a user would ask for.
    # -----------------------------------------------------------------------
    @testset "api surface" begin
        fn(name, mangled, ret, params; src="dwarf") = Dict(
            "name" => name, "mangled" => mangled,
            "return_type" => Dict("c_type" => ret),
            "parameters" => [Dict("name" => n, "c_type" => t) for (n, t) in params],
            "parameters_source" => src)

        function write_md(fns; structs = Dict())
            p = joinpath(mktempdir(), "compilation_metadata.json")
            open(p, "w") do io
                JSON.print(io, Dict("functions" => fns, "struct_definitions" => structs))
            end
            return p
        end

        # (a) C API over a C++ implementation — llama.cpp's shape (34% C).
        mixed = write_md(vcat(
            [fn("lib_open", "lib_open", "lib_ctx*", [("path", "const char*")]),
             fn("lib_close", "lib_close", "void", [("ctx", "lib_ctx*")]),
             fn("lib_read", "lib_read", "int", [("ctx", "lib_ctx*")]),
             fn("lib_write", "lib_write", "int", [("ctx", "lib_ctx*")])],
            [fn("impl_step$i", "_ZN4impl4stepEv", "void", []) for i in 1:20]))
        s = T.api_surface(mixed)
        @test s.strategy === :c_linkage
        @test length(s.functions) == 4
        @test length(s.internal) == 20
        @test only(T.api(s, "open")).name == "lib_open"
        @test isempty(T.api(s, "impl_step"))                  # internals hidden…
        @test length(T.api(s, "impl_step"; internals=true)) == 20  # …but reachable

        # (b) Pure C — everything is the API.
        purec = write_md([fn("z_deflate", "z_deflate", "int", []),
                          fn("z_inflate", "z_inflate", "int", [])])
        s = T.api_surface(purec)
        @test s.strategy === :c_linkage
        @test length(s.functions) == 2

        # (c) C++ API — linkage carries no signal. Includes ONE incidental
        # extern "C" symbol, which is tinyxml2's real shape (1 of 284) and the
        # case a bare "any C linkage wins" rule gets wrong.
        cpp = write_md(vcat(
            [fn("xml_document::load_string", "_ZN12xml_document11load_stringEPKc",
                "xml_parse_result", [("s", "const char*")])],
            [fn("xml_node::child$i", "_ZN8xml_node5childEi", "xml_node", []) for i in 1:30],
            [fn("std::vector<int>::push_back", "_ZNSt6vectorIiE9push_backEi", "void", [])],
            [fn("_incidental_c", "_incidental_c", "void", [])]))
        s = T.api_surface(cpp)
        @test s.strategy === :cpp
        @test only(T.api(s, "load_string")).name == "xml_document::load_string"
        @test any(f -> occursin("std::", f.name), s.internal)   # STL is internal
        @test !any(f -> occursin("std::", f.name), s.functions)
        # The defect this guards: :c_linkage here yields one function, and it
        # is the incidental symbol rather than any part of the API.
        naive = T.api_surface(cpp; strategy = :c_linkage)
        @test length(naive.functions) == 1
        @test only(naive.functions).name == "_incidental_c"

        @test T.api_surface(cpp; strategy = :all).strategy === :all
        @test_throws ErrorException T.api_surface(cpp; strategy = :nonsense)

        # The :auto threshold is a heuristic, so pin it deliberately rather
        # than letting some fixture's incidental ratio pin it by accident.
        # Real spread it has to separate: tinyxml2 0.35% C vs llama.cpp 34%.
        ratio(n_c, n_cpp) = T.api_surface(write_md(vcat(
            [fn("c$i", "c$i", "void", []) for i in 1:n_c],
            [fn("m$i", "_ZN1x1yEv", "void", []) for i in 1:n_cpp]))).strategy
        @test ratio(20, 79) === :c_linkage    # 20.2% — comfortably a C API
        @test ratio(1, 999) === :cpp          # 0.1%  — an incidental extern "C"
        @test T.C_API_FRACTION == 0.10

        # Struct fields, and by-value vs pointer — '*' must not be stripped, or
        # a pointer parameter is reported as a by-value crossing.
        md = write_md([fn("take", "take", "int",
                          [("ctx", "big_t*"), ("v", "small_t"), ("b", "big_t")])],
                      structs = Dict(
                          "small_t" => Dict("byte_size" => "0x8",
                                            "members" => [Dict("name" => "a", "offset" => "0x0",
                                                               "c_type" => "int64_t")]),
                          "big_t"   => Dict("byte_size" => "0x28",
                                            "members" => [Dict("name" => "x", "offset" => "0x0",
                                                               "c_type" => "int32_t"),
                                                          Dict("name" => "y", "offset" => "0x8",
                                                               "c_type" => "double")])))
        s = T.api_surface(md)
        bv = T.byvalue_args(only(T.api(s, "take")), s)
        @test length(bv) == 2                          # ctx is a POINTER
        @test all(a -> a.name != "ctx", bv)
        @test (name = "v", type = "small_t", bytes = 8,  class = :register) in bv
        @test (name = "b", type = "big_t",   bytes = 40, class = :memory)   in bv

        flds = T.api_struct(s, "big_t")
        @test [f.name for f in flds] == ["x", "y"]
        @test [f.offset for f in flds] == [0, 8]       # hex parsed, not string
        @test_throws ErrorException T.api_struct(s, "no_such_struct")

        # Inferred parameters are flagged, since they did not come from DWARF.
        inf = write_md([fn("guessed", "guessed", "void", [("arg1", "int")]; src="inferred")])
        @test occursin("inferred", sprint(show, only(T.api(T.api_surface(inf)))))

        @test_throws ErrorException T.api_surface(mktempdir())   # no metadata
    end

    # -- CMake harvest: parsing internals, pure, always run ---------------------
    @testset "cmake harvest internals" begin
        # A flag signature must drop everything file-specific, or two TUs that
        # share a flag set would look divergent purely because their names differ.
        sig = T._flag_signature(["/usr/bin/cc", "-DFOO=1", "-I/inc", "-O2",
                                 "-o", "CMakeFiles/x.dir/a.c.o", "-c", "src/a.c"])
        @test sig == ["-DFOO=1", "-I/inc", "-O2"]
        @test T._flag_signature(["cc", "-DA", "-o", "b.o", "-c", "b.cpp"]) == ["-DA"]

        # Target extraction, from the `output` field and from -o as a fallback.
        @test T._target_of(Dict("output" => "CMakeFiles/mylib.dir/src/a.c.o"), String[]) == "mylib"
        @test T._target_of(Dict{String,Any}(), ["cc", "-o", "CMakeFiles/z.dir/a.c.o"]) == "z"
        @test T._target_of(Dict("output" => "weird/path.o"), String[]) == ""

        @test T._is_cmake_internal("CMakeFiles/3.31/CompilerIdC/CMakeCCompilerId.c")
        @test T._is_cmake_internal("_deps/foo-src/x.h")
        @test !T._is_cmake_internal("config.h")

        # Include translation: build-tree -> the package's config dir, source
        # tree -> clone-relative, anything else (system/external) dropped.
        inc = T._translate_includes(["-I/src/lib", "-I/bld", "-I/usr/include", "-I/src"],
                                    "/src", "/bld", "config", "deps/x")
        @test inc == ["deps/x/lib", "config"]

        # Exclusion collapsing prefers the shallowest wholly-dead directory. A
        # directory that still holds compiled sources must stay per-file, since a
        # coarse pattern there would silently drop live code.
        ex = T._collapse_excludes(["src/a.c", "src/b.c"],
                                  ["src/skip.c", "tools/x.c", "tools/deep/y.c"])
        @test "tools/" in ex
        @test "src/skip.c" in ex
        @test !("src/" in ex)
        @test !("tools/deep/" in ex)      # already covered by tools/

        # Directory names the resolver prunes on its own are not proposed.
        @test isempty(T._collapse_excludes(["src/a.c"], ["tests/t.c"]))
    end

    # -- CMake harvest end-to-end, gated on cmake being installed ---------------
    if Sys.which("cmake") === nothing
        @info "cmake not found — skipping cmake_probe end-to-end test."
    else
        @testset "cmake harvest end-to-end" begin
            src = mktempdir()
            write(joinpath(src, "CMakeLists.txt"), """
                cmake_minimum_required(VERSION 3.10)
                project(fixt C)
                set(FIXT_GREETING "hello")
                configure_file(fixt_config.h.in fixt_config.h)
                add_library(fixt \${LIBKIND} a.c b.c)
                target_include_directories(fixt PRIVATE \${CMAKE_CURRENT_BINARY_DIR})
                target_compile_definitions(fixt PRIVATE HAVE_CONFIG_H)
                """)
            write(joinpath(src, "fixt_config.h.in"),
                  "#define FIXT_GREETING \"@FIXT_GREETING@\"\n")
            write(joinpath(src, "a.c"), "int a(void) { return 1; }\n")
            write(joinpath(src, "b.c"), "int b(void) { return 2; }\n")
            # Never referenced by any target — must show up as an exclusion.
            write(joinpath(src, "orphan.c"), "int orphan(void) { return 3; }\n")
            mkpath(joinpath(src, "tools"))
            write(joinpath(src, "tools", "cli.c"), "int main(void) { return 0; }\n")

            gen = Sys.which("ninja") === nothing ? "Unix Makefiles" : "Ninja"
            probe = T.cmake_probe(src; name="fixt", generator=gen,
                                  clone_rel="deps/fixt", use_llvm_env=false)

            # The generated header is the whole point: it does not exist in the
            # source tree, only in the build tree, and only after configure.
            @test "fixt_config.h" in probe.generated_headers
            @test !isfile(joinpath(src, "fixt_config.h"))

            t = T.main_target(probe)
            @test t !== nothing
            @test t.name == "fixt"
            @test T.uniform(t)
            @test sort(t.files) == ["a.c", "b.c"]
            @test "-DHAVE_CONFIG_H" in t.defines
            @test "config" in t.include_dirs      # the build dir, remapped

            # Sources no target compiles become exclusions.
            frag = T.propose_toml(probe; language="c")
            @test occursin("orphan.c", frag)
            @test occursin("tools/", frag)
            @test occursin("-DHAVE_CONFIG_H", frag)
            @test !occursin("\"a.c\"", frag)      # live source must not be excluded

            # Harvest copies the header out and leaves a provenance note.
            out = mktempdir()
            written = T.harvest_config(probe, out)
            @test length(written) == 1
            @test isfile(joinpath(out, "fixt_config.h"))
            @test occursin("hello", read(joinpath(out, "fixt_config.h"), String))
            @test isfile(joinpath(out, "HARVEST.md"))
            @test occursin("cmake_probe", read(joinpath(out, "HARVEST.md"), String))

            rm(src; recursive=true, force=true)
            rm(out; recursive=true, force=true)
            rm(probe.build_dir; recursive=true, force=true)
        end
    end
end
