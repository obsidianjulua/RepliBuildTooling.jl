#!/usr/bin/env julia
# Api.jl — "what can I actually call?" for a generated wrapper.
#
# A generated wrapper is the whole LIBRARY, not its API. llama.cpp wraps to
# 105k lines and 5,364 definitions, and `names(Llamacpp, all=true)` returns
# 11,762 entries in which `llama_tokenize` sits between
# `llama_vocab_impl_tokenize` and `llm_tokenizer_bpe_session_tokenize`. Nothing
# in the module marks which of those you are meant to call, so finding an entry
# point meant reading the C++ source or guessing the name.
#
# The discriminator is C LINKAGE. A C++ symbol is Itanium-mangled (`_ZN...`);
# an `extern "C"` one is not, so its mangled name IS its source name. That test
# needs no per-library knowledge and is decisive on the shape RepliBuild wraps
# best: llamacpp goes 3686 functions -> 1249, and searching "tokenize" goes
# from 37 hits to 2.
#
# Reads `compilation_metadata.json`, never the wrapper — about a second,
# against the ~17s the llamacpp module takes to load, and it works on a package
# that has been built but never loaded.

"""
    ApiFunction

One callable function from a wrapped library's metadata.

`params_from_dwarf` is false when DWARF supplied no parameter list. For a
niladic function that is correct and expected; for anything else the parameter
list was inferred from the symbol name and should not be trusted.
"""
struct ApiFunction
    name::String
    mangled::String
    return_type::String
    params::Vector{Tuple{String,String}}   # (name, c_type)
    c_linkage::Bool
    params_from_dwarf::Bool
end

function signature(f::ApiFunction)
    args = join(("$n::$t" for (n, t) in f.params), ", ")
    return "$(f.name)($args) -> $(f.return_type)"
end

function Base.show(io::IO, f::ApiFunction)
    print(io, signature(f))
    if !f.params_from_dwarf && !isempty(f.params)
        print(io, "   [!] params inferred, not from DWARF")
    end
end

"""
    ApiSurface

The callable surface of a wrapped library, split into what you are meant to
call and what merely happens to be linkable.

`strategy` records HOW the split was made, because there is no single rule:

  * `:c_linkage` — the library exposes a C API over a C++ implementation, so C
    linkage is the entry surface (llama.cpp: 1249 of 3686).
  * `:cpp` — the library's API *is* C++, so linkage says nothing and the split
    is by implementation namespace instead (pugixml is 411 functions all in
    `pugi::`; box2d is `b2World::…`, `b2DynamicTree::…`).
  * `:all` — no split requested.

Getting this wrong is worse than not filtering: a naive C-linkage rule reports
pugixml and box2d as having **zero** public functions. Always check `strategy`
before trusting a small count, and override it if the guess is wrong.
"""
struct ApiSurface
    metadata_path::String
    strategy::Symbol
    functions::Vector{ApiFunction}
    internal::Vector{ApiFunction}
    structs::Dict{String,Any}
end

const _STRATEGY_NOTE = Dict(
    :c_linkage => "C-linkage entry points; C++-mangled symbols treated as internal",
    :cpp       => "C++ API; only implementation namespaces (std::, __gnu_cxx::) treated as internal",
    :all       => "no filtering",
)

function Base.show(io::IO, s::ApiSurface)
    println(io, "ApiSurface: $(length(s.functions)) public, $(length(s.internal)) internal")
    println(io, "  strategy : :$(s.strategy) — $(get(_STRATEGY_NOTE, s.strategy, ""))")
    println(io, "  from     : $(s.metadata_path)")
    print(io,   "  api(surface, \"pattern\") to search; internals=true for the rest")
end

# Namespaces that are never the library's own API, whatever the strategy.
const _IMPL_NAMESPACES = ("std::", "__gnu_cxx::", "__cxxabiv1::", "__pstl::", "__detail::")

_is_impl_symbol(f::ApiFunction) =
    any(ns -> occursin(ns, f.name), _IMPL_NAMESPACES)

_md_ret(f) = get(get(f, "return_type", Dict()), "c_type", "void")

function _api_function(f::Dict)
    mangled = get(f, "mangled", "")
    ps = Tuple{String,String}[(get(p, "name", "_"), get(p, "c_type", "?"))
                              for p in get(f, "parameters", [])]
    return ApiFunction(get(f, "name", "?"), mangled, _md_ret(f), ps,
                       !startswith(mangled, "_Z"),
                       get(f, "parameters_source", "") == "dwarf")
end

"""
    api_surface(path; strategy=:auto) -> ApiSurface

Load the callable surface of a wrapped library.

`path` may be the `compilation_metadata.json` itself, the `julia/` directory
holding it, a project directory, or a `replibuild.toml` — whichever you have to
hand.

`strategy` is `:auto`, `:c_linkage`, `:cpp`, or `:all`; see [`ApiSurface`](@ref).
`:auto` picks `:c_linkage` only when C-linkage functions are at least
`C_API_FRACTION` of the total — a real C API is a substantial share of the
symbols (llama.cpp 34%, lua 100%), whereas an incidental `extern "C"` in a C++
library is not (tinyxml2 has exactly one, 0.35%, and it is not the API).
Override it when the guess is wrong; the guess is reported by `show`.
"""
const C_API_FRACTION = 0.10

function api_surface(path::AbstractString="."; strategy::Symbol=:auto)
    md = _resolve_metadata_path(path)
    data = JSON.parsefile(md)
    all_fns = [_api_function(f) for f in get(data, "functions", [])]
    byname(v) = sort!(v, by = f -> f.name)

    n_c = count(f -> f.c_linkage, all_fns)
    if strategy === :auto
        strategy = (!isempty(all_fns) && n_c / length(all_fns) >= C_API_FRACTION) ?
                   :c_linkage : :cpp
    end

    if strategy === :all
        return ApiSurface(md, :all, byname(all_fns), ApiFunction[],
                          get(data, "struct_definitions", Dict{String,Any}()))
    elseif strategy === :c_linkage
        pub, int = filter(f -> f.c_linkage, all_fns), filter(f -> !f.c_linkage, all_fns)
    elseif strategy === :cpp
        # Linkage carries no signal here, so split on implementation namespace.
        pub, int = filter(!_is_impl_symbol, all_fns), filter(_is_impl_symbol, all_fns)
    else
        error("unknown strategy :$strategy — use :auto, :c_linkage, :cpp or :all")
    end
    return ApiSurface(md, strategy, byname(pub), byname(int),
                      get(data, "struct_definitions", Dict{String,Any}()))
end

function _resolve_metadata_path(path::AbstractString)
    p = abspath(path)
    isfile(p) && endswith(p, ".json") && return p
    # A replibuild.toml, or a directory containing one / a julia/ output dir.
    dir = isfile(p) ? dirname(p) : p
    for cand in (joinpath(dir, "compilation_metadata.json"),
                 joinpath(dir, "julia", "compilation_metadata.json"))
        isfile(cand) && return cand
    end
    error("""
          No compilation_metadata.json found for: $path
          Looked in $dir and $(joinpath(dir, "julia")).
          Build the project first — the metadata is written by RepliBuild.build.""")
end

"""
    api(surface_or_path, pattern=""; internals=false) -> Vector{ApiFunction}

Search a library's public API by name, case-insensitively. Empty pattern lists
everything. `internals=true` searches the C++-mangled symbols instead — the
implementation, not the API.

```julia
julia> api("packages/llamacpp", "tokenize")
llama_detokenize(vocab::const llama_vocab*, …) -> int32_t
llama_tokenize(vocab::const llama_vocab*, text::const char*, …) -> int32_t
```
"""
function api(s::ApiSurface, pattern::AbstractString=""; internals::Bool=false)
    pool = internals ? s.internal : s.functions
    isempty(pattern) && return pool
    pat = lowercase(pattern)
    return filter(f -> occursin(pat, lowercase(f.name)), pool)
end

api(path::AbstractString, pattern::AbstractString=""; internals::Bool=false) =
    api(api_surface(path), pattern; internals=internals)

"""
    api_struct(surface, name) -> Vector{NamedTuple}

Field name, byte offset and C type for a struct in the wrapped library — what
you need to build a `setproperties` call against a by-value parameter struct.
"""
function api_struct(s::ApiSurface, name::AbstractString)
    info = get(s.structs, name, nothing)
    info === nothing && error("no struct named $name in $(s.metadata_path)")
    return [(name = get(m, "name", "?"),
             offset = _parse_c_int(get(m, "offset", "0x0")),
             c_type = get(m, "c_type", "?"))
            for m in get(info, "members", [])]
end

api_struct(path::AbstractString, name::AbstractString) = api_struct(api_surface(path), name)

function _parse_c_int(x)
    s = string(x)
    return startswith(s, "0x") ? parse(Int, s[3:end], base=16) : parse(Int, s)
end

"""
    byvalue_args(f, surface) -> Vector{NamedTuple}

The parameters `f` takes as by-value structs, with their sizes and SysV class.

Worth checking before calling: a >16-byte by-value struct is MEMORY class and
crosses through the Tier-2 thunk path, which is where the ABI is hardest. A
`*` in the C type means pointer, not by value — that distinction is the whole
point of this function.
"""
function byvalue_args(f::ApiFunction, s::ApiSurface)
    out = NamedTuple[]
    for (pname, ct) in f.params
        occursin("*", ct) && continue
        key = strip(replace(ct, "const " => "", "struct " => ""))
        info = get(s.structs, key, nothing)
        info === nothing && continue
        n = _parse_c_int(get(info, "byte_size", "0x0"))
        push!(out, (name = pname, type = key, bytes = n,
                    class = n > 16 ? :memory : :register))
    end
    return out
end
