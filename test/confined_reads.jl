# What a filter reads through pandoc with its conversion (`read(text,
# ctx.conversion)`, `read_many`) is read in pandoc's own sandbox when the
# conversion is sandboxed, however the sandbox was asked for and however the
# filter was given; and when that can't be told (pandocjl's conversion, one a
# script run as a subprocess makes from its environment, one made by hand).
#
# The probe: a filter reading LaTeX, RST and Org fragments that include a
# canary inside a directory (INSIDE-OK) and one outside it (CANARY), and
# saying which it got ("latex:IO": both).

const OPEN = "latex:IO rst:IO org:IO"
const CONFINED = "latex:-- rst:-- org:--"

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
        end for (fmt, text) in FRAGMENTS], " ")
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
        # pandoc.read; a script making its conversion from its environment
        # can't tell, and is confined
        @test f(lab, (;)) == (way == "script as a subprocess" ? CONFINED : OPEN)
        @test f(lab, (sandbox = true,)) == CONFINED
        # in process, outside the module: pandoc's own sandbox, no files,
        # not even inside the directory listed
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
    # a conversion made by hand, without options: can't tell; with options
    # without "sandbox": not sandboxed
    @test P.read_options(Conversion())["sandbox"] === true
    @test !haskey(P.read_options(Conversion(; options = Dict{String, Any}())), "sandbox")
    @test P.read_options(Conversion(; options = Dict{String, Any}("sandbox" => Dict("read" => String[]))))["sandbox"] === true
    @test lab.seen(Conversion(; options = Dict{String, Any}())) == OPEN
    @test_throws PandocError P.read_many(["x"]; sandbox = (read = String[],))
    # pandocjl: pandoc doesn't tell its filters about --sandbox (in the
    # arguments or a defaults file), so they are always confined; in the
    # directory sandbox too
    for kind in ("handoff", "subprocess")
        for (args, env) in (((), Dict{String, String}()), (("--sandbox",), Dict{String, String}()),
                            ((), Dict("LIBPANDOC_SANDBOX" => lab.inside)))
            status, out, err = pandocjl("-t", "plain", args..., "-F", lab.scripts[kind]; input = "x", env)
            @test status == 0 && plain(out) == CONFINED
            status == 0 || println(err)
        end
    end
end
