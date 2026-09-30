using Test
using LibPandoc, Panir
import LibPandoc as P
const JSON = P.JSON

# The example wasm filters of libpandoc-rs (filters/, built for
# wasm32-wasip1), if given: $LIBPANDOC_WASM_FILTERS.
const WASM = get(ENV, "LIBPANDOC_WASM_FILTERS", "")
wasm(name) = joinpath(WASM, "$name.wasm")

const EMPTY_WASM = P._EMPTY_WASM   # a WASI command doing nothing

const PROJECT = dirname(Base.active_project())

# pandocjl ARGS as a separate process: (status, stdout, stderr)
function pandocjl(args...; input = "", env = Dict{String, String}(), dir = pwd())
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc $args`
    out, err = IOBuffer(), IOBuffer()
    p = cd(() -> Base.run(pipeline(ignorestatus(addenv(cmd, env)); stdin = IOBuffer(input), stdout = out, stderr = err)), dir)
    # pandoc writes native line endings (CRLF on Windows) to files and stdout
    p.exitcode, replace(String(take!(out)), "\r\n" => "\n"), String(take!(err))
end

upper(s::Str) = Str(uppercase(s.text))
demote(h::Header) = (h.level += 1; nothing)

@testset "LibPandoc" begin

@testset "convert" begin
    @test P.convert("*hi*"; from = "markdown", to = "html") == "<p><em>hi</em></p>\n"
    @test P.convert("*hi*", Dict("from" => "markdown", "to" => "latex")) == "\\emph{hi}\n"
    @test P.convert("# A"; to = "html", section_divs = true) |> contains("<section")
    docx = P.convert("# Report"; to = "docx")
    @test docx isa Vector{UInt8} && docx[1:2] == b"PK"
    mktempdir() do d
        f = joinpath(d, "a.md")
        Base.write(f, "*a*")
        @test P.convert(; input_files = [f], to = "html") == "<p><em>a</em></p>\n"
        @test P.convert("x"; to = "html", output_file = joinpath(d, "o.html")) == ""
        @test replace(Base.read(joinpath(d, "o.html"), String), "\r\n" => "\n") == "<p>x</p>\n"   # native line endings
    end
    @test P.convert(codeunits("*b*"); to = "plain") == "b\n"
end

@testset "errors and warnings" begin
    e = try P.convert("x"; from = "nonesuch") catch e; e end
    @test e isa PandocError && e.kind == "PandocUnknownReaderError"
    @test occursin("nonesuch", sprint(showerror, e))
    @test_logs (:warn, r"Could not fetch|not found|Could not find"i) match_mode = :any P.convert("![](nowhere.png)"; to = "docx")
end

@testset "run" begin
    @test String(P.run(["-f", "markdown", "-t", "latex"]; input = "*hi*")) == "\\emph{hi}\n"
    @test_throws PandocError P.run(["--version"])
end

@testset "queries" begin
    @test P.pandoc_version() isa VersionNumber
    @test P.api_version()[1:2] == Panir.PANDOC_API_VERSION[1:2]
    @test "markdown" in P.input_formats() && "html" in P.output_formats()
    @test P.extensions("gfm")["pipe_tables"] == true
    @test contains(P.default_template("html"), "\$body\$")
    @test P.num_threads() >= 1
end

@testset "read, read_many, write" begin
    doc = P.read("Hello *world*")
    @test doc isa Panir.Pandoc
    @test doc.blocks[1].content[3] isa Emph
    @test P.write(doc, "rst") == "Hello *world*\n"
    @test P.read("<em>x</em>", "html").blocks[1].content[1] isa Emph
    docs = P.read_many(["a", "*b*", "# c"])
    @test length(docs) == 3 && docs[3].blocks[1] isa Header
    e = try P.read_many(["a"], "nonesuch") catch e; e end
    @test e isa PandocError
    # as a conversion reads: its input format and reader options
    c = Conversion(; input_format = "commonmark", options = Dict{String, Any}("tab-stop" => 2))
    @test P.read_options(c) == Dict("from" => "commonmark", "tab-stop" => 2)
    @test P.read("~~x~~", c).blocks[1].content[1] isa Str   # no strikeout in commonmark
end

@testset "Julia filters" begin
    @test P.convert("hello *world*"; to = "plain", filters = [upper]) == "HELLO WORLD\n"
    # several, in order, with pandoc's own between them
    mktempdir() do d
        lua = joinpath(d, "emph.lua")
        Base.write(lua, "function Str(s) return pandoc.Emph(s) end")
        out = P.convert("# a"; to = "markdown", filters = [upper, demote, lua])
        @test out == "## *A*\n"
    end
    # other orders, and whole-document methods
    seen = String[]
    visit(x::Union{Para, Str}) = (push!(seen, string(nameof(typeof(x)))); nothing)
    P.convert("a"; to = "html", filters = [visit => :topdown])
    @test seen == ["Para", "Str"]
    empty!(seen)
    P.convert("a"; to = "html", filters = [visit => :bottomup])
    @test seen == ["Str", "Para"]
    add(d::Panir.Pandoc) = (push!(d.blocks, Para("end")); nothing)
    @test P.convert("a"; to = "plain", filters = [add]) == "a\n\nend\n"
    # raw JSON
    raw = RawFilter((json, c) -> replace(json, "\"a\"" => "\"b\""))
    @test P.convert("a"; to = "plain", filters = [raw]) == "b\n"
end

@testset "a filter is told the conversion" begin
    got = Ref{Any}()
    see(d::Panir.Pandoc, ctx) = (got[] = ctx.conversion; nothing)
    P.convert("x"; from = "commonmark_x", to = "html5", tab_stop = 2, filters = [see])
    c = got[]
    @test c.format == "html5"
    @test startswith(c.input_format, "commonmark_x")
    @test startswith(c.output_format, "html5")
    @test c.reader_options["tab-stop"] == 2
    @test c.options["tab-stop"] == 2 && !haskey(c.options, "filters")
end

@testset "a filter calls pandoc" begin
    parse_blocks(b::CodeBlock, ctx) = "parse" in b.attr.classes ? P.read(b.text, ctx.conversion).blocks : nothing
    @test P.convert("```parse\n*a*\n```"; to = "html", filters = [parse_blocks]) == "<p><em>a</em></p>\n"
    many(b::CodeBlock, ctx) = reduce(vcat, (d.blocks for d in P.read_many(split(b.text, '\n'), ctx.conversion)))
    @test P.convert("```\na\n*b*\n```"; to = "plain", filters = [many]) == "a\n\nb\n"
end

@testset "a filter's exception" begin
    boom(s::Str) = error("boom")
    e = try P.convert("x"; to = "html", filters = [boom]) catch e; e end
    @test e isa FilterError
    @test e.exception isa ErrorException && e.exception.msg == "boom"
    @test occursin("boom", sprint(showerror, e))
    # and after it, conversions work
    @test P.convert("y"; to = "plain", filters = [upper]) == "Y\n"
    bad(d::Panir.Pandoc) = Para("x")
    @test_throws FilterError P.convert("x"; to = "html", filters = [bad])
end

@testset "threads" begin
    outs = fetch.([Threads.@spawn P.convert("t$i *x*"; to = "plain", filters = [upper]) for i in 1:40])
    @test outs == ["T$i X\n" for i in 1:40]
end

@testset "scripts" begin
    mktempdir() do d
        s = joinpath(d, "upper.jl")
        Base.write(s, """
            #!/usr/bin/env julia
            using Panir
            upper(s::Str) = Str(uppercase(s.text))
            run_filter(upper)
            """)
        @test P.convert("hi *x*"; to = "plain", filters = [s]) == "HI X\n"
        @test P._SCRIPTS[abspath(s)].filter !== nothing   # in process
        # a script that reads stdin itself: a subprocess
        raw = joinpath(d, "raw.jl")
        Base.write(raw, "print(replace(read(stdin, String), \"\\\"a\\\"\" => \"\\\"b\\\"\"))")
        @test P.convert("a"; to = "plain", filters = [raw]) == "b\n"
        @test P._SCRIPTS[abspath(raw)].filter === nothing
        # opting out
        out = joinpath(d, "out.jl")
        Base.write(out, "# pandocjl: subprocess\nusing Panir\nrun_filter(s::Str -> Str(s.text * \"!\"))")
        @test P.convert("a"; to = "plain", filters = [out]) == "a!\n"
        @test P._SCRIPTS[abspath(out)].filter === nothing
        withenv("PANDOCJL_SUBPROCESS" => "upper2") do
            u2 = joinpath(d, "upper2.jl")
            cp(s, u2)
            @test P.convert("a"; to = "plain", filters = [u2]) == "A\n"
            @test P._SCRIPTS[abspath(u2)].filter === nothing
        end
        # loaded again when changed
        sleep(1.1)  # mtime's resolution
        Base.write(s, "using Panir\nrun_filter(s::Str -> Str(lowercase(s.text)))")
        @test P.convert("HI"; to = "plain", filters = [s]) == "hi\n"
        # a script's traverse
        td = joinpath(d, "td.jl")
        Base.write(td, "using Panir\nseen = String[]\nf(x::Union{Para, Str}) = (push!(seen, string(nameof(typeof(x)))); nothing)\n" *
                       "f(d::Panir.Pandoc) = (push!(d.blocks, Para(join(seen, \",\"))); nothing)\nrun_filter(f; traverse = :bottomup)")
        @test P.convert("a"; to = "plain", filters = [td]) |> contains("Str,Para")
    end
end

@testset "wasm filters" begin
    mktempdir() do d
        e = joinpath(d, "empty.wasm")
        Base.write(e, EMPTY_WASM)
        f = WasmFilter(e)
        @test f("{}", Conversion()) == UInt8[]      # runs, writes nothing
        @test_throws PandocError P.convert("x"; to = "html", filters = [f])   # which isn't a document
        Base.write(joinpath(d, "bad.wasm"), "not wasm")
        @test_throws ErrorException WasmFilter(joinpath(d, "bad.wasm"))
    end
    if isempty(WASM)
        @info "wasm filters: set LIBPANDOC_WASM_FILTERS to libpandoc-rs's filters built for wasm32-wasip1 to test them"
    else
        @test P.convert("hello *world*"; from = "markdown", to = "plain", filters = [wasm("upper")]) == "HELLO WORLD\n"
        @test P.convert("hello *world*"; to = "plain", filters = [WasmFilter(wasm("upper"))]) == "HELLO WORLD\n"
        # told the conversion (the conversion filter adds it as a code block)
        out = JSON.parse(P.convert("x"; from = "commonmark", to = "json", filters = [wasm("conversion")]))
        told = JSON.parse(out["blocks"][end]["c"][2])
        @test startswith(told["input-format"], "commonmark") && told["format"] == "json"
        @test told["reader-options"] == true && told["pandoc-version"] == P._version_string()
        # calling pandoc
        @test P.convert("```parse\n*a*\n```\n\n```parse\n# b\n```\n"; from = "markdown", to = "html",
                        filters = [wasm("parse")]) == "<p><em>a</em></p>\n<h1 id=\"b\">b</h1>\n"
        function calls(requests)
            input = join("```call\n$(JSON.json(r))\n```\n\n" for r in requests)
            doc = JSON.parse(P.convert(input; from = "markdown", to = "json", filters = [wasm("calls")]))
            [JSON.parse(b["c"][2]) for b in doc["blocks"]]
        end
        a = calls([Dict("convert" => [Dict("from" => "markdown", "to" => "html"), "*x*"]),
                   Dict("read_many" => [["a", "*b*"], Dict("from" => "markdown")]),
                   Dict("query" => ["version", nothing])])
        @test a[1]["ok"] == "<p><em>x</em></p>\n"
        @test length(a[2]["ok"]) == 2 && a[2]["ok"][2]["blocks"][1]["c"][1]["t"] == "Emph"
        @test a[3]["ok"] == P._version_string()
        # refused: files, programs, Lua
        refused = calls([
            Dict("convert" => [Dict("from" => "markdown", "to" => "html", "filters" => ["/bin/sh"]), "x"]),
            Dict("convert" => [Dict("from" => "markdown", "to" => "html", "output-file" => "out.html"), "x"]),
            Dict("convert" => [Dict("from" => "markdown", "to" => "writer.lua"), "x"]),
            Dict("convert" => [Dict("from" => "markdown", "to" => "pdf"), "x"]),
            Dict("convert" => [Dict("from" => "markdown", "to" => "html"), nothing]),
            Dict("read_many" => [["x"], Dict("from" => "markdown", "data-dir" => "/")]),
            Dict("query" => ["parse-args", Dict("args" => ["-d", "x.yaml"])])])
        @test all(r -> r["error"][1] == "PandocOptionError", refused)
        @test contains(refused[1]["error"][2], "not allowed for untrusted code: filters")
        # sandboxed: LaTeX's \input reads no file
        mktempdir() do d
            secret = joinpath(d, "secret.tex")
            Base.write(secret, "SECRET")
            tex = "\\input{$secret}"
            a = calls([Dict("read_many" => [[tex], Dict("from" => "latex")]),
                       Dict("convert" => [Dict("from" => "latex", "to" => "plain"), tex])])
            @test !contains(JSON.json(a), "SECRET")
            @test contains(Panir.stringify(P.read(tex, "latex")), "SECRET")   # natively it is read
        end
        # what it may see: the current directory, read-only
        mktempdir() do d
            Base.write(joinpath(d, "in.txt"), "included")
            cd(d) do
                @test P.convert("```include\nin.txt\n```"; to = "plain", filters = [wasm("include")]) |> contains("included")
            end
            e = try
                cd(() -> P.convert("```include\n/etc/passwd\n```"; to = "plain", filters = [wasm("include")]), d)
            catch e
                e
            end
            @test e isa FilterError && contains(sprint(showerror, e.exception), "exited with status 3")
        end
    end
end

@testset "pandocjl" begin
    status, out, _ = pandocjl("-t", "html"; input = "*hi*")
    @test status == 0 && out == "<p><em>hi</em></p>\n"
    status, out, _ = pandocjl("--version")
    @test status == 0 && contains(out, "pandocjl: pandoc in process")
    status, _, err = pandocjl("-f", "nonesuch"; input = "x")
    @test status != 0 && contains(err, "nonesuch")
    mktempdir() do d
        Base.write(joinpath(d, "upper.jl"), "using Panir\nrun_filter(s::Str -> Str(uppercase(s.text)))")
        Base.write(joinpath(d, "demote.lua"), "function Header(h) h.level = h.level + 1; return h end")
        Base.write(joinpath(d, "boom.jl"), "using Panir\nrun_filter(s::Str -> error(\"boom\"))")
        # a package's filter: -F Name
        Base.write(joinpath(d, "Shout.jl"), "module Shout\nusing Panir\npandoc_filter(s::Str) = Str(s.text * \"!\")\nend")
        env = Dict("JULIA_LOAD_PATH" => join([d, "@", "@stdlib"], Sys.iswindows() ? ';' : ':'))
        status, out, _ = pandocjl("-t", "markdown", "-F", "upper.jl", "-L", "demote.lua", "-F", "Shout";
                                  input = "# a\n\nb", env, dir = d)
        @test status == 0 && out == "## A!\n\nB!\n"
        status, _, err = pandocjl("-F", "boom.jl"; input = "x", dir = d)
        @test status == 83 && contains(err, "boom")
        if !isempty(WASM)
            status, out, _ = pandocjl("-t", "plain", "-F", wasm("upper"); input = "a *b*")
            @test status == 0 && out == "A B\n"
        end
    end
end

end
