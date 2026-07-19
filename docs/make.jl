using Documenter, RepliBuildTooling

makedocs(
    sitename = "RepliBuildTooling.jl",
    modules  = [RepliBuildTooling],
    format   = Documenter.HTML(),
    pages    = [
        "Introspection Tools" => "introspect.md",
    ],
    warnonly = true,   # ported @docs blocks: don't hard-fail on a missing docstring
)
