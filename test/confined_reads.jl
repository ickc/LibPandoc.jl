# What a filter reads through pandoc with its conversion (`read(text,
# ctx.conversion)`, `read_many`) is read in pandoc's own sandbox when the
# conversion is sandboxed, however the sandbox was asked for and however the
# filter was given; and when that can't be told (one made by hand, or from
# the environment under plain pandoc). libpandoc (1.13) tells every filter
# whether pandoc's sandbox is on (a callback's context, PANDOC_SANDBOX); the
# directory sandbox, whose filters run in this process outside
# libpandoc.wasm, tells them it is.
#
# The probe: a filter reading LaTeX, RST and Org fragments that include a
# canary inside a directory (INSIDE-OK) and one outside it (CANARY), and
# saying which it got ("latex:IO": both), and what it was told (`|true`:
# its conversion's `sandbox`).

const OPEN = "latex:IO rst:IO org:IO|false"
const CONFINED = "latex:-- rst:-- org:--|true"

# what a probe does, as a script's text (`seen` below is the same)
function seen_source(root)
    d = replace(root, '\\' => '/')
    """
    import LibPandoc, Panir
    const FRAGMENTS = [
        "latex" => $(repr("\\input{$d/inside/in.tex}\n\n\\input{$d/outside/out.tex}\n")),
        "rst" => $(repr(".. include:: $d/inside/in.rst\n\n.. include:: $d/outside/out.rst\n")),
        "org" => $(repr("#+INCLUDE: \"$d/inside/in.org\"\n\n#+INCLUDE: \"$d/outside/out.org\"\n")),
    ]
    function seen(conversion)
        join([begin
            s = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do   # (an include not found)
                Panir.serialize(LibPandoc.read(text, conversion; from = fmt))
            end
            string(fmt, ":", occursin("INSIDE-OK", s) ? "I" : "-", occursin("CANARY", s) ? "O" : "-")
        end for (fmt, text) in FRAGMENTS], " ") * "|" * repr(conversion.sandbox)
    end
    """
end

struct ConfinedLab
    root::String
    inside::String
    scripts::Dict{String, String}
    seen::Function
end

function confined_lab()
    root = realpath(mktempdir())
    inside, outside = joinpath(root, "inside"), joinpath(root, "outside")
    mkpath(inside), mkpath(outside)
    for ext in ("tex", "rst", "org")
        Base.write(joinpath(inside, "in.$ext"), "INSIDE-OK\n")
        Base.write(joinpath(outside, "out.$ext"), "CANARY\n")
    end
    src = seen_source(root)
    Base.write(joinpath(root, "seen.jl"), src)
    m = Module(:ConfinedProbe)
    Core.eval(m, :(include(x) = Base.include($m, x)))
    Base.include_string(m, src)
    seen = (c) -> Base.invokelatest(getproperty(m, :seen), c)
    scripts = Dict(
        # a script handing its filter over, run in process
        "handoff" => """
            using Panir
            include(joinpath(@__DIR__, "seen.jl"))
            probe(doc::Pandoc, ctx) = (empty!(doc.blocks); push!(doc.blocks, Para([Str(seen(ctx.conversion))])); doc)
            run_filter(probe)
            """,
        # a script run as a subprocess, its conversion made from its environment
        "subprocess" => """
            # pandocjl: subprocess
            using Panir
            include(joinpath(@__DIR__, "seen.jl"))
            import JSON
            d = JSON.parse(read(stdin, String))
            d["blocks"] = [Dict("t" => "Para", "c" => [Dict("t" => "Str", "c" => seen(Panir.Conversion(ARGS, ENV)))])]
            print(JSON.json(d))
            """)
    paths = Dict(k => (p = joinpath(root, "probe_$k.jl"); Base.write(p, v); p) for (k, v) in scripts)
    ConfinedLab(root, inside, paths, seen)
end

plain(out) = strip(out)

function by_function(lab, opts)
    got = String[]
    probe(doc::Panir.Pandoc, ctx) = (push!(got, lab.seen(ctx.conversion)); nothing)
    P.convert("x"; to = "plain", filters = [probe], opts...)
    only(got)
end

function by_raw(lab, opts)
    got = String[]
    P.convert("x"; to = "plain", filters = [RawFilter((json, c) -> (push!(got, lab.seen(c)); json))], opts...)
    only(got)
end

by_script(kind) = (lab, opts) -> plain(P.convert("x"; to = "plain", filters = [lab.scripts[kind]], opts...))

# a filter's own conversion, with the options to read as its conversion
# does, whose filter reads
function nested(lab, opts)
    got = String[]
    inner(doc::Panir.Pandoc, ctx) = (push!(got, lab.seen(ctx.conversion)); nothing)
    outer(doc::Panir.Pandoc, ctx) =
        (P.convert("x", merge(P.read_options(ctx.conversion), Dict("to" => "json")); filters = [inner]); nothing)
    P.convert("x"; to = "plain", filters = [outer], opts...)
    only(got)
end

const WAYS = ["function" => by_function, "RawFilter" => by_raw, "script handing over" => by_script("handoff"),
              "script as a subprocess" => by_script("subprocess"), "a filter's convert" => nested]

@testset "a filter's read is confined when its conversion is" begin
    lab = confined_lab()
    for (way, f) in WAYS
        # unsandboxed, what a filter reads may include files, as Lua's
        # pandoc.read, and it is told so (a script making its conversion from
        # its environment too: PANDOC_SANDBOX=false)
        @test f(lab, (;)) == OPEN
        @test f(lab, (sandbox = false,)) == OPEN
        @test f(lab, (sandbox = true,)) == CONFINED
        # in process, outside the module: told that the conversion is
        # sandboxed (the module tells of pandoc's own sandbox only, which is
        # off here), and so in pandoc's own sandbox, no files, not even
        # inside the directory listed
        @test f(lab, (sandbox = (read = [lab.inside],),)) == CONFINED
    end
    # a filter that wants files read gives its own options: its code
    got = String[]
    outside = "\\input{$(replace(lab.root, '\\' => '/'))/outside/out.tex}"
    function unconfined(doc::Panir.Pandoc, ctx)
        d = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            P.read(outside, ctx.conversion; from = "latex", sandbox = false)
        end
        push!(got, Panir.serialize(d))
        nothing
    end
    P.convert("x"; to = "plain", filters = [unconfined], sandbox = true)
    @test contains(only(got), "CANARY")
    # the rule: sandboxed when told so, or the options ask for it, or nothing
    # tells (no `sandbox`, no options: one made by hand, or from the
    # environment under plain pandoc)
    O(pairs...) = Dict{String, Any}(pairs...)
    for (c, confined) in ((Conversion(), true), (Conversion(; sandbox = true), true),
                          (Conversion(; sandbox = false), false), (Conversion(; options = O()), false),
                          (Conversion(; options = O("sandbox" => true)), true),
                          (Conversion(; options = O("sandbox" => Dict("read" => String[]))), true),
                          (Conversion(; sandbox = false, options = O("sandbox" => true)), true),
                          (Conversion(; sandbox = true, options = O()), true),
                          (Conversion(; options = O("sandbox" => false)), false))
        @test get(P.read_options(c), "sandbox", false) === confined
    end
    @test lab.seen(Conversion(; sandbox = false)) == OPEN
    @test lab.seen(Conversion()) == replace(CONFINED, "true" => "nothing")
    @test_throws PandocError P.read_many(["x"]; sandbox = (read = String[],))
    # pandocjl: its filters are told whether pandoc's sandbox is on, however
    # it was set (--sandbox, a defaults file): confined then only; in the
    # directory sandbox told it is, and confined (the security-critical
    # case: pandoc in the module, whose own sandbox is off, the filter here)
    Base.write(joinpath(lab.root, "d.yaml"), "sandbox: true\n")
    for kind in ("handoff", "subprocess")
        for (args, env, expected) in (((), Dict{String, String}(), OPEN), (("--sandbox",), Dict{String, String}(), CONFINED),
                                      (("-d", joinpath(lab.root, "d.yaml")), Dict{String, String}(), CONFINED),
                                      ((), Dict("LIBPANDOC_SANDBOX" => lab.inside), CONFINED),
                                      (("--sandbox",), Dict("LIBPANDOC_SANDBOX" => lab.inside), CONFINED))
            status, out, err = pandocjl("-t", "plain", args..., "-F", lab.scripts[kind]; input = "x", env)
            @test status == 0 && plain(out) == expected
            status == 0 || println(err)
        end
    end
    # a subprocess script gets libpandoc's variables from its conversion
    # only, none of this process's
    withenv("PANDOC_SANDBOX" => "true", "PANDOC_INPUT_FORMAT" => "stale") do
        script = joinpath(lab.root, "env.jl")
        Base.write(script, "read(stdin); print(join(sort([k for k in keys(ENV) if startswith(k, \"PANDOC_\")]), ' '))")
        out = String(P._subprocess(script, "{}", Dict{String, Any}("format" => "html")))
        @test out == "PANDOC_READER_OPTIONS PANDOC_VERSION"
        out = String(P._subprocess(script, "{}", Dict{String, Any}("format" => "html", "sandbox" => false)))
        @test out == "PANDOC_READER_OPTIONS PANDOC_SANDBOX PANDOC_VERSION"
    end
    # a wasm filter's PANDOC_SANDBOX
    if !isempty(WASM)
        told(; opts...) = JSON.parse(JSON.parse(P.convert("x"; to = "json", filters = [wasm("conversion")], opts...))["blocks"][end]["c"][2])["sandbox"]
        @test told() == "false"
        @test told(sandbox = true) == "true"
        @test told(sandbox = (read = [lab.inside], timeout = 120)) == "true"
    end
end
