#!/usr/bin/env julia
# Julia.jl - Julia introspection tools (@code_* wrappers and performance analysis)
# Provides structured access to Julia's code introspection macros

using InteractiveUtils

# ============================================================================
# CODE LOWERING
# ============================================================================

"""
    code_lowered(func, types::Tuple)

Get lowered Julia IR before type inference.

Wraps `@code_lowered` macro and returns structured `CodeLoweredInfo`.

# Arguments
- `func` - Function to inspect
- `types::Tuple` - Argument types tuple

# Returns
CodeLoweredInfo

# Examples
```julia
# Inspect lowered code
info = code_lowered(sort, (Vector{Int},))
println("Slots: \$(info.slot_names)")
println("Instructions: \$(length(info.code))")
```
"""
function code_lowered(func, types::Tuple)
    # Get lowered code using InteractiveUtils
    results = InteractiveUtils.code_lowered(func, types)

    if isempty(results)
        error("Could not get lowered code for $func$types")
    end

    ci = results[1]

    # Extract function name
    func_name = string(func)

    # Extract slot names and code
    slot_names = ci.slotnames
    code = ci.code

    return CodeLoweredInfo(
        func_name,
        types,
        code,
        slot_names
    )
end

# ============================================================================
# TYPE INFERENCE
# ============================================================================

"""
    code_typed(func, types::Tuple; optimized=true)

Get type-inferred Julia IR.

Wraps `@code_typed` macro and returns structured `CodeTypedInfo`.

# Arguments
- `func` - Function to inspect
- `types::Tuple` - Argument types tuple
- `optimized::Bool` - Apply optimizations (default: true)

# Returns
CodeTypedInfo

# Examples
```julia
# Get typed IR
info = code_typed(sum, (Vector{Float64},), optimized=true)
println("Return type: \$(info.return_type)")
```
"""
function code_typed(func, types::Tuple; optimized::Bool=true)
    # Get typed code
    result = InteractiveUtils.code_typed(func, types; optimize=optimized)

    if isempty(result)
        error("Could not get typed code for $func$types")
    end

    ci, return_type = result[1]

    # Extract function name
    func_name = string(func)

    return CodeTypedInfo(
        func_name,
        types,
        ci,
        return_type,
        optimized
    )
end

"""
    code_warntype(func, types::Tuple)

Get type inference warnings (wrapper for @code_warntype).

# Arguments
- `func` - Function to inspect
- `types::Tuple` - Argument types tuple

# Returns
String - Warning output

# Examples
```julia
# Check for type instabilities
warnings = code_warntype(my_func, (Int, Vector))
```
"""
function code_warntype(func, types::Tuple)
    io = IOBuffer()
    InteractiveUtils.code_warntype(io, func, types)
    return String(take!(io))
end

# ============================================================================
# LLVM IR
# ============================================================================

"""
    code_llvm(func, types::Tuple; optimized=true, raw=false, debuginfo=:none)

Get LLVM IR for Julia function.

Wraps `@code_llvm` macro and returns structured `LLVMIRInfo`.

# Arguments
- `func` - Function to inspect
- `types::Tuple` - Argument types tuple
- `optimized::Bool` - Apply LLVM optimizations (default: true)
- `raw::Bool` - Show raw unoptimized IR (default: false)
- `debuginfo::Symbol` - Debug info level (:none, :source, :default)

# Returns
LLVMIRInfo

# Examples
```julia
# Get optimized LLVM IR
info = code_llvm(sort, (Vector{Int},), optimized=true)
println(info.ir)

# Get unoptimized IR
info = code_llvm(sort, (Vector{Int},), optimized=false)
```
"""
function code_llvm(func, types::Tuple; optimized::Bool=true, raw::Bool=false, debuginfo::Symbol=:none)
    # Capture LLVM IR output
    io = IOBuffer()
    InteractiveUtils.code_llvm(io, func, types; optimize=optimized, raw=raw, debuginfo=debuginfo)
    ir = String(take!(io))

    # Extract function name
    func_name = string(func)

    # Count instructions (lines starting with % or indented)
    instruction_count = count_ir_instructions(ir)

    return LLVMIRInfo(
        func_name,
        types,
        ir,
        optimized,
        instruction_count
    )
end

# ============================================================================
# NATIVE ASSEMBLY
# ============================================================================

"""
    code_native(func, types::Tuple; syntax=:att, debuginfo=:none)

Get native assembly for Julia function.

Wraps `@code_native` macro and returns structured `AssemblyInfo`.

# Arguments
- `func` - Function to inspect
- `types::Tuple` - Argument types tuple
- `syntax::Symbol` - Assembly syntax (:att or :intel, default: :att)
- `debuginfo::Symbol` - Debug info level (:none, :source, :default)

# Returns
AssemblyInfo

# Examples
```julia
# Get AT&T syntax assembly
info = code_native(sum, (Vector{Float64},))
println(info.assembly)

# Get Intel syntax assembly
info = code_native(sum, (Vector{Float64},), syntax=:intel)
```
"""
function code_native(func, types::Tuple; syntax::Symbol=:att, debuginfo::Symbol=:none)
    # Capture assembly output
    io = IOBuffer()
    InteractiveUtils.code_native(io, func, types; syntax=syntax, debuginfo=debuginfo)
    assembly = String(take!(io))

    # Extract function name
    func_name = string(func)

    # Count instructions (lines with assembly mnemonics)
    instruction_count = count(l -> occursin(r"^\s+[a-z]", l), split(assembly, '\n'))

    return AssemblyInfo(
        func_name,
        types,
        assembly,
        syntax,
        instruction_count
    )
end

# ============================================================================
# TYPE STABILITY ANALYSIS
# ============================================================================

"""
    analyze_type_stability(func, types::Tuple)

Analyze type stability using @code_warntype.

Parses @code_warntype output to identify type instabilities.

# Arguments
- `func` - Function to analyze
- `types::Tuple` - Argument types tuple

# Returns
TypeStabilityAnalysis

# Examples
```julia
# Check type stability
analysis = analyze_type_stability(my_func, (Int, Vector{Float64}))
if !analysis.is_stable
    println("Type unstable!")
    for var in analysis.unstable_variables
        println("  \$(var.variable): \$(var.inferred_type)")
    end
end
```
"""
function analyze_type_stability(func, types::Tuple)
    # Work directly from the inferred (typed, unoptimized) IR rather than parsing
    # `@code_warntype` text. Text parsing is fragile: in a non-color IO Julia signals
    # instability by UPPERCASING types (e.g. `Body::UNION{…}`), which a `"Union"`/`"Any"`
    # substring check silently misses — reporting unstable functions as stable.
    result = InteractiveUtils.code_typed(func, types; optimize=false)
    if isempty(result)
        error("Could not get typed code for $func$types")
    end
    ci, return_type = result[1]

    unstable_vars = TypeInstability[]
    warnings = String[]

    # Flatten a Union into its component types (avoids depending on the non-public
    # Base.uniontypes; a Union's `.a`/`.b` fields are stable structure).
    union_components(t) = t isa Union ? vcat(union_components(t.a), union_components(t.b)) : Any[t]
    # A small Union of *concrete* leaves (e.g. the ubiquitous `Union{Nothing,Tuple}`
    # from the iteration protocol) is benign: it's union-split, not a real instability.
    benign_union(t) = t isa Union && all(isconcretetype, union_components(t))
    # A genuine instability: a real `Type` that is neither concrete, bottom, nor a
    # benign concrete-leaf Union. Lattice elements that aren't plain `Type`s
    # (Core.Const, PartialStruct, …) are refinements, so they're never flagged. This
    # mirrors what `@code_warntype` prints in red (vs. the yellow benign unions).
    is_problematic(t) = (t isa Type) && t !== Union{} && !isconcretetype(t) && !benign_union(t)

    # Scan inferred SSA value types for the origins of instability (informational).
    # Only value-producing statements are meaningful: in unoptimized typed IR every
    # statement gets a type slot, but control-flow nodes (goto/return/gotoifnot) are
    # placeholder-typed `Any` — inspecting those would flag every branch as unstable.
    ssatypes = ci.ssavaluetypes
    code = ci.code
    if ssatypes isa AbstractVector && code isa AbstractVector
        for i in eachindex(ssatypes)
            (i <= length(code) && (code[i] isa Expr || code[i] isa Core.PhiNode)) || continue
            t = ssatypes[i]
            if is_problematic(t)
                push!(unstable_vars, TypeInstability("%$i", t, nothing, nothing))
            end
        end
    end

    # Verdict follows the canonical definition (what `Test.@inferred` enforces): the
    # function is type-stable iff its inferred return type is concrete. Benign
    # union-split intermediates therefore never flip the verdict.
    return_concrete = (return_type isa Type) && return_type !== Union{} && isconcretetype(return_type)
    is_stable = return_concrete

    if !return_concrete
        push!(warnings, "non-concrete return type: $(return_type)")
    end
    if !isempty(unstable_vars)
        push!(warnings, "$(length(unstable_vars)) intermediate value(s) with non-concrete inferred type")
    end

    func_name = string(func)

    return TypeStabilityAnalysis(
        func_name,
        types,
        is_stable,
        unstable_vars,
        warnings
    )
end

# ============================================================================
# SIMD ANALYSIS
# ============================================================================

"""
    analyze_simd(func, types::Tuple)

Analyze SIMD vectorization by parsing LLVM IR.

Searches for vector instructions and identifies vectorized loops.

# Arguments
- `func` - Function to analyze
- `types::Tuple` - Argument types tuple

# Returns
SIMDAnalysis

# Examples
```julia
# Check SIMD vectorization
analysis = analyze_simd(my_loop_func, (Vector{Float64},))
println("Vectorized loops: \$(length(analysis.vectorized_loops))")
println("Vector instructions: \$(analysis.vector_instructions)")
```
"""
function analyze_simd(func, types::Tuple)
    # Get optimized LLVM IR
    ir_info = code_llvm(func, types, optimized=true)
    ir = ir_info.ir

    # Count vector instructions
    vector_instructions = count(l -> occursin(r"<\d+ x ", l), split(ir, '\n'))

    # Count scalar instructions (total - vector)
    total_instructions = ir_info.instruction_count
    scalar_instructions = max(0, total_instructions - vector_instructions)

    # Identify vectorized loops (very basic heuristic)
    vectorized_loops = VectorizedLoop[]

    loop_id = 0
    for line in split(ir, '\n')
        if occursin(r"vector\.body", line) || occursin(r"<\d+ x ", line)
            # Found potential vectorized loop
            width_match = match(r"<(\d+) x ", line)
            if width_match !== nothing
                width = parse(Int, width_match.captures[1])
                loop_id += 1
                push!(vectorized_loops, VectorizedLoop(loop_id, width, vector_instructions))
            end
        end
    end

    func_name = string(func)

    return SIMDAnalysis(
        func_name,
        types,
        vectorized_loops,
        vector_instructions,
        scalar_instructions
    )
end

# ============================================================================
# ALLOCATION ANALYSIS
# ============================================================================

"""
    analyze_allocations(func, types::Tuple)

Analyze memory allocations by parsing LLVM IR.

Searches for Julia allocation function calls in LLVM IR.

# Arguments
- `func` - Function to analyze
- `types::Tuple` - Argument types tuple

# Returns
AllocationAnalysis

# Examples
```julia
# Check allocations
analysis = analyze_allocations(my_func, (Vector{Float64},))
println("Total allocations: \$(length(analysis.allocations))")
println("Total bytes: \$(analysis.total_bytes)")
```
"""
function analyze_allocations(func, types::Tuple)
    # Get optimized LLVM IR
    ir_info = code_llvm(func, types, optimized=true)
    ir = ir_info.ir

    # Look for Julia allocation calls
    allocation_patterns = [
        "julia.gc_alloc_obj",
        "jl_alloc_",
        "jl_gc_pool_alloc",
        "jl_gc_big_alloc",
        "jl_array_copy"
    ]

    allocations = AllocationInfo[]
    total_bytes = 0

    for line in split(ir, '\n')
        for pattern in allocation_patterns
            if occursin(pattern, line)
                # Try to extract allocation size
                size_match = match(r"i64 (\d+)", line)
                size = if size_match !== nothing
                    parse(Int, size_match.captures[1])
                else
                    0
                end

                total_bytes += size

                # Try to extract type
                type_match = match(r"%([A-Za-z0-9_\.]+)", line)
                alloc_type = if type_match !== nothing
                    type_match.captures[1]
                else
                    "unknown"
                end

                push!(allocations, AllocationInfo(
                    alloc_type,
                    size,
                    nothing
                ))

                break  # Only count once per line
            end
        end
    end

    # Determine if allocations escape (heuristic: any allocation likely escapes)
    escapes = !isempty(allocations)

    func_name = string(func)

    return AllocationAnalysis(
        func_name,
        types,
        allocations,
        total_bytes,
        escapes
    )
end

# ============================================================================
# INLINING ANALYSIS
# ============================================================================

"""
    analyze_inlining(func, types::Tuple)

Analyze inlining by comparing unoptimized vs optimized typed IR.

# Arguments
- `func` - Function to analyze
- `types::Tuple` - Argument types tuple

# Returns
Dict with :unoptimized and :optimized CodeTypedInfo

# Examples
```julia
# Check inlining
analysis = analyze_inlining(my_func, (Int, Float64))
unopt = analysis[:unoptimized]
opt = analysis[:optimized]
println("Inlining reduced code by \$(unopt.code.code.codelocs - opt.code.code.codelocs) locations")
```
"""
function analyze_inlining(func, types::Tuple)
    unoptimized = code_typed(func, types, optimized=false)
    optimized = code_typed(func, types, optimized=true)

    return Dict(
        :unoptimized => unoptimized,
        :optimized => optimized
    )
end

# ============================================================================
# FULL COMPILATION PIPELINE
# ============================================================================

"""
    compilation_pipeline(func, types::Tuple)

Run complete compilation pipeline: lowered → typed → llvm → native.

Returns all intermediate representations in a single result.

# Arguments
- `func` - Function to analyze
- `types::Tuple` - Argument types tuple

# Returns
CompilationPipelineResult

# Examples
```julia
# Get full pipeline
pipeline = compilation_pipeline(sort, (Vector{Int},))
println(pipeline.lowered)
println(pipeline.typed)
println(pipeline.llvm_ir)
println(pipeline.native)

# Export to JSON
export_json(pipeline, "pipeline.json")
```
"""
function compilation_pipeline(func, types::Tuple)
    func_name = string(func)

    # Run all stages
    lowered = code_lowered(func, types)
    typed = code_typed(func, types, optimized=true)
    llvm_ir = code_llvm(func, types, optimized=true)
    native = code_native(func, types)

    return CompilationPipelineResult(
        func_name,
        types,
        lowered,
        typed,
        llvm_ir,
        native
    )
end
