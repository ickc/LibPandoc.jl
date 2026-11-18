using Test
using LibPandoc, Panir
import LibPandoc as P
const JSON = P.JSON
import CodecZlib, SHA, Tar

# The example wasm filters of libpandoc-rs (filters/, built for
# wasm32-wasip1), if given: $LIBPANDOC_WASM_FILTERS.
const WASM = get(ENV, "LIBPANDOC_WASM_FILTERS", "")
wasm(name) = joinpath(WASM, "$name.wasm")

const EMPTY_WASM = P._EMPTY_WASM   # a WASI command doing nothing

# A wasm module from its text (wasmtime's wat2wasm).
function wat(text::String)
    v = Ref(P._Vec(0, C_NULL))
    P._check((@ccall P.libwasmtime.wasmtime_wat2wasm(text::Ptr{UInt8}, sizeof(text)::Csize_t, v::Ptr{P._Vec})::Ptr{Cvoid}), "wat")
    bytes = copy(unsafe_wrap(Vector{UInt8}, v[].data, v[].size))   # (wasmtime's vector, copied, then deleted)
    @ccall P.libwasmtime.wasm_byte_vec_delete(v::Ptr{P._Vec})::Cvoid
    bytes
end

# A WASI command writing 64 KiB at a time to descriptor `fd`, 256 MiB in all
# or until a write fails, then exiting normally.
FLOOD(fd) = """
    (module
      (import "wasi_snapshot_preview1" "fd_write" (func \$w (param i32 i32 i32 i32) (result i32)))
      (memory (export "memory") 2)
      (func (export "_start") (local \$n i32)
        (i32.store (i32.const 0) (i32.const 1024))
        (i32.store (i32.const 4) (i32.const 65536))
        (loop \$l
          (if (i32.eqz (call \$w (i32.const $fd) (i32.const 0) (i32.const 1) (i32.const 8)))
            (then
              (local.set \$n (i32.add (local.get \$n) (i32.const 1)))
              (br_if \$l (i32.lt_u (local.get \$n) (i32.const 4096))))))))
    """

const PROJECT = dirname(Base.active_project())

# pandocjl ARGS as a separate process: (status, stdout, stderr). One still
# running after 5 minutes is killed (a status of its own, and what it wrote):
# a child that hangs fails its test rather than the job's time limit (seen
# once on Windows, in the directory sandbox, cause not found).
function pandocjl(args...; input = "", env = Dict{String, String}(), dir = pwd())
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc $args`
    out, err = IOBuffer(), IOBuffer()
    p = cd(() -> Base.run(pipeline(ignorestatus(addenv(cmd, env)); stdin = IOBuffer(input), stdout = out, stderr = err);
                          wait = false), dir)
    if timedwait(() -> process_exited(p), 300) === :timed_out
        @error "pandocjl $(join(args, ' ')) still running after 300 s: killed"
        kill(p)
    end
    wait(p)
    # pandoc writes native line endings (CRLF on Windows) to files and stdout
    p.exitcode, replace(String(take!(out)), "\r\n" => "\n"), String(take!(err))
end

# An absolute path as the module, or a wasm filter, names it: on Windows
# C:\x is /c/x.
function named(p)
    s = replace(String(p), '\\' => '/')
    Sys.iswindows() && length(s) > 1 && s[2] == ':' ? "/$(lowercase(s[1]))$(s[3:end])" : s
end

# What `f()` threw (nothing if it returned).
refused_with(f) = try f(); nothing catch e; e end

# No directories for wasm filters but those a test gives (it sets the
# variable with `withenv`, or in a child's environment).
delete!(ENV, "LIBPANDOC_WASM_DIRS")

upper(s::Str) = Str(uppercase(s.text))
_filter_env_of(w) = P._filter_env(Conversion(; writer_options = w))
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

@testset "the format, however it is given" begin
    tex = "\\emph{x}"
    emph(d) = d.blocks[1].content[1] isa Emph
    # as an argument, a keyword, under pandoc's other name
    @test emph(P.read(tex, "latex")) && emph(P.read(tex; from = "latex")) && emph(P.read(tex; reader = "latex"))
    @test all(emph, P.read_many([tex], "latex")) && all(emph, P.read_many([tex]; from = "latex")) &&
          all(emph, P.read_many([tex]; reader = "latex"))
    doc = P.read("*x*")
    @test P.write(doc, "rst") == P.write(doc; to = "rst") == P.write(doc; writer = "rst") == "*x*\n"
    @test emph(P.read(tex)) == false && P.write(doc) == "<p><em>x</em></p>\n"   # the defaults
    # given twice: refused, whichever would have won
    @test_throws ArgumentError P.read(tex, "latex"; from = "html")
    @test_throws ArgumentError P.read(tex; from = "latex", reader = "html")
    @test_throws ArgumentError P.write(doc, "rst"; to = "html")
    @test_throws ArgumentError P.read_many([tex], "latex"; from = "html")
    # with a conversion, the options may name another format
    @test emph(only(P.read_many([tex], Conversion(; input_format = "html"); from = "latex")))
end

@testset "arguments a function can't apply: refused, not ignored" begin
    doc = P.read("*x*")
    @test_throws ArgumentError P.read("x"; to = "rst")
    @test_throws ArgumentError P.read("x"; output_file = "o.html")
    @test_throws ArgumentError P.write(doc; from = "latex")
    @test_throws ArgumentError P.write(doc; input_files = ["a.md"])
    @test_throws ArgumentError P.read_many(["a"]; standalone = true)
    @test_throws ArgumentError P.read_many(["a"]; filters = ["x.lua"])
    @test length(P.read_many(["a"]; tab_stop = 2, sandbox = true, timeout = 30, untrusted = true)) == 1
    @test_throws ArgumentError P.read_many("abc")             # a text, not texts
    @test_throws ArgumentError P.convert("a"; filters = "x.lua")   # a filter, not filters
    # read converts as convert does: Julia filters too
    @test Panir.stringify(P.read("a"; filters = [upper])) == "A"
    # bytes for a binary format under pandoc's other name too
    @test P.convert("# R"; writer = "docx") isa Vector{UInt8}
    # no output file: the output
    @test P.convert("x"; to = "plain", output_file = nothing) == "x\n"
    @test P.convert("x"; to = "plain", output_file = "-") == "x\n"
end

@testset "nothing is an absent option" begin
    # as Lua's nil in a table: the key is not there
    @test P.convert("*x*"; to = nothing, timeout = nothing, sandbox = nothing, untrusted = nothing,
                    standalone = nothing, filters = nothing) == "<p><em>x</em></p>\n"
    @test P.convert("*x*", Dict("to" => nothing, "timeout" => nothing, "sandbox" => nothing)) == "<p><em>x</em></p>\n"
    # a keyword nothing leaves the Dict's value
    @test P.convert("*x*", Dict("to" => "plain"); to = nothing) == "x\n"
    @test P.read("*x*"; timeout = nothing) == P.read("*x*")
    @test P.write(P.read("x"); timeout = nothing) == "<p>x</p>\n"
    @test P.read_many(["x"]; timeout = nothing, sandbox = nothing, to = nothing) == [P.read("x")]
    # a vector with nothing in it stays an error
    @test_throws Exception P.convert("x"; filters = [nothing])
    @test_throws Exception P.convert(; input_files = [nothing])
end

@testset "no input: refused, not this process's standard input" begin
    # pandoc would read it and close it: Julia's stdin then reads another file
    code = """
        import LibPandoc as P
        for f in (() -> P.convert(; to = "plain"), () -> P.read(nothing))
            try f(); print("read it") catch e; e isa ArgumentError || rethrow() end
        end
        print(read(stdin, String))"""
    out = Base.read(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -e $code`; stdin = IOBuffer("still here")), String)
    @test out == "still here"
end

@testset "errors and warnings" begin
    e = try P.convert("x"; from = "nonesuch") catch e; e end
    @test e isa PandocError && e.kind == "PandocUnknownReaderError"
    @test occursin("nonesuch", sprint(showerror, e))
    @test_logs (:warn, r"Could not fetch|not found|Could not find"i) match_mode = :any P.convert("![](nowhere.png)"; to = "docx")
end

@testset "untrusted" begin
    # libpandoc's "untrusted": only options that read, write, fetch and run
    # nothing, with pandoc's sandbox on
    @test P.convert("*hi*"; to = "html", untrusted = true) == "<p><em>hi</em></p>\n"
    mktempdir() do d
        # (citeproc: refused before libpandoc 1.8, which runs it inside the sandbox)
        for opts in [(filters = ["x.lua"],), (output_file = joinpath(d, "o"),),
                     (to = "pdf",), (data_dir = d,)]
            e = try
                P.convert("x"; to = "html", untrusted = true, opts...)
            catch e
                e
            end
            @test e isa PandocError && contains(e.message, "not allowed for untrusted code")
        end
        secret = joinpath(d, "secret.tex")
        Base.write(secret, "SECRET")
        tex = "\\input{$(replace(secret, '\\' => '/'))}"   # / on Windows too, for LaTeX
        @test contains(P.convert(tex; from = "latex", to = "plain"), "SECRET")
        out = @test_logs (:warn, r"Could not load include file") match_mode = :any P.convert(tex; from = "latex", to = "plain", untrusted = true)
        @test !contains(out, "SECRET")
    end
end

@testset "time limit" begin
    # the review's 100,000 nested block quotes: over 15 s without a limit
    slow = ">"^100_000
    timeout(f) = (e = try f(); nothing catch e; e end; istimeout(e))
    t = @elapsed @test timeout(() -> P.convert(slow; to = "html", timeout = 0.5))
    @test t < 5
    @test timeout(() -> P.read(slow; timeout = 0.5))
    @test P.convert("x"; to = "plain", timeout = 30) == "x\n"   # and the next call works
    # read_many: the whole call's limit; a text not read in time fails alone
    # (a longer limit where each text's result is looked at: the call's
    # setup must end within it, or the whole call fails, as documented; with
    # 0.5 s it did once in libpandoc-python's twin of this test, on a macOS
    # Intel CI runner)
    @test timeout(() -> P.read_many(["a", slow]; timeout = 0.5))
    docs = P.read_many(["a", slow, "[x"]; timeout = 3, return_exceptions = true)
    @test docs[1] isa Panir.Pandoc && istimeout(docs[2]) && !istimeout(docs[1]) && !istimeout(ErrorException("Timeout"))
    @test docs[3] isa Panir.Pandoc
    @test P.read_many(["a"]) isa Vector{Panir.Pandoc}
    # code in this process runs to its end, and the call fails then (a
    # limit the call reaches its filter within, on a slow CI runner too)
    nap(d::Panir.Pandoc) = (sleep(2); nothing)
    t = @elapsed @test timeout(() -> P.convert("x"; to = "html", timeout = 1, filters = [nap]))
    @test t >= 2
end

@testset "run" begin
    @test String(P.run(["-f", "markdown", "-t", "latex"]; input = "*hi*")) == "\\emph{hi}\n"
    @test_throws PandocError P.run(["--version"])
    # a NUL would end the argument there (writing "out" for "out\0.html")
    @test_throws ArgumentError P.run(["-o", "out\0.html"]; input = "x")
    @test_throws ArgumentError P.main(["-o", "out\0.html"])
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
    # the readers' warnings are logged, as a conversion's
    @test_logs (:warn, r"Could not load include file") match_mode = :any P.read_many(["\\input{nowhere-at-all}"], "latex")
    # as a conversion reads: its input format and reader options
    c = Conversion(; input_format = "commonmark", options = Dict{String, Any}("tab-stop" => 2))
    @test P.read_options(c) == Dict("from" => "commonmark", "tab-stop" => 2, "preserve-tabs" => true)
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
    # the writer's options (libpandoc's "writer-options", as Lua's PANDOC_WRITER_OPTIONS)
    P.convert("x"; to = "latex", number_sections = true, top_level_division = "chapter", filters = [see])
    w = got[].writer_options
    @test w["number-sections"] == true && w["top-level-division"] == "top-level-chapter"
end

@testset "a filter calls pandoc" begin
    parse_blocks(b::CodeBlock, ctx) = "parse" in b.attr.classes ? P.read(b.text, ctx.conversion).blocks : nothing
    @test P.convert("```parse\n*a*\n```"; to = "html", filters = [parse_blocks]) == "<p><em>a</em></p>\n"
    many(b::CodeBlock, ctx) = reduce(vcat, (d.blocks for d in P.read_many(split(b.text, '\n'), ctx.conversion)))
    @test P.convert("```\na\n*b*\n```"; to = "plain", filters = [many]) == "a\n\nb\n"
end

@testset "a filter's read keeps tabs, as pandoc.read" begin
    # Lua's pandoc.read (pandoc 3.14: CodeBlock "x\ty"), not the pandoc
    # command, which expands them first ("x   y")
    c = Conversion(; input_format = "markdown", options = Dict{String, Any}())
    code(d) = only(d.blocks).text
    @test P.read_options(c)["preserve-tabs"] === true
    @test code(P.read("    x\ty\n", c)) == "x\ty"
    @test code(only(P.read_many(["    x\ty\n"], c))) == "x\ty"
    @test code(P.read("    x\ty\n", c; preserve_tabs = false)) == "x   y"
    # with no conversion: as the command
    @test code(P.read("    x\ty\n")) == "x   y"
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
    # one whose showerror throws too: nothing unwinds through pandoc's frames
    # (which would skip its cleanup: the call's temporary files stayed)
    mktempdir() do tmp
        code = """
            import LibPandoc as P; using Panir
            struct Bad <: Exception end
            Base.showerror(io::IO, ::Bad) = error("showerror fails too")
            e = try P.convert("x"; to = "plain", filters = [(s::Str) -> throw(Bad())]) catch e; e end
            print(e isa P.FilterError && e.exception isa Bad)"""
        out = Base.read(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -e $code`, "TMPDIR" => tmp, "TMP" => tmp, "TEMP" => tmp), String)
        @test out == "true" && isempty(readdir(tmp))
    end
end

@testset "threads" begin
    outs = fetch.([Threads.@spawn P.convert("t$i *x*"; to = "plain", filters = [upper]) for i in 1:40])
    @test outs == ["T$i X\n" for i in 1:40]
    # a filter that yields inside pandoc's call (sleep, yield), from tasks
    # free to move between threads: each returns into pandoc on the thread
    # that called it (`_pinned`, which uses what Julia's scheduler does)
    waits(s::Str) = (sleep(0.001); yield(); Str(uppercase(s.text)))
    outs = fetch.([Threads.@spawn P.convert("t$i *x*"; to = "plain", filters = [waits]) for i in 1:40])
    @test outs == ["T$i X\n" for i in 1:40]
    # the number in effect: set (before pandoc's threads have grown) or not
    @test P.set_num_threads(1) == P.num_threads() >= 1
end

@testset "versions" begin
    # the same major, a minor at least the one relied on
    v = 1000P.ABI_MAJOR + P.ABI_MINOR
    @test P.ABI_MINOR >= 14 && P._abi_ok(v) && P._abi_ok(v + 1)
    @test !P._abi_ok(v - 1) && !P._abi_ok(v + 1000)
    e = try P._abi_check(1007, "old/libpandoc.so") catch e; e end
    @test e isa ErrorException && contains(e.msg, "ABI 1.7") && contains(e.msg, "needs 1.$(P.ABI_MINOR)")
    @test P._abi_ok(ccall(P._load().abi_version, Cint, ()))
    # an old download says how to refresh it
    withenv("LIBPANDOC_DOWNLOAD_DIR" => mktempdir()) do
        e = try P._abi_check(1007, joinpath(P._download_prefix(), P._libname())) catch e; e end
        @test contains(e.msg, "remove $(P._download_prefix())")
    end
end

@testset "downloads are checked" begin
    mktempdir() do d
        # a release of one tarball, as libpandoc's, and its SHA256SUMS
        name = "libpandoc-$(P._target()).tar.gz"
        tree = mkpath(joinpath(d, "tree", dirname(P._libname())))
        Base.write(joinpath(d, "tree", P._libname()), "not really a library")
        tarball = joinpath(d, name)
        open(io -> (z = CodecZlib.GzipCompressorStream(io); Tar.create(joinpath(d, "tree"), z); close(z)), tarball, "w")
        sum = bytes2hex(open(SHA.sha256, tarball))
        sums(text) = Base.write(joinpath(d, "SHA256SUMS"), text)
        download(to) = withenv(() -> (try P._download(to); nothing catch e; e.msg end), "LIBPANDOC_DOWNLOAD_URL" => tarball)
        sums("$(repeat("0", 64))  other.tar.gz\n$sum  $name\n")
        @test (@test_logs (:info, r"Downloading") download(joinpath(d, "ok"))) === nothing
        @test isfile(joinpath(d, "ok", P._libname()))
        sums("$(repeat("0", 64))  $name\n")
        @test contains(@test_logs((:info,), download(joinpath(d, "bad"))), "but $(joinpath(d, "SHA256SUMS")) says")
        @test !ispath(joinpath(d, "bad"))
        sums("$sum  other.tar.gz\n")
        @test contains(@test_logs((:info,), download(joinpath(d, "missing"))), "$name is not in")
        rm(joinpath(d, "SHA256SUMS"))
        @test contains(@test_logs((:info,), download(joinpath(d, "none"))), "SHA256SUMS, to check $name")
        @test !ispath(joinpath(d, "missing")) && !ispath(joinpath(d, "none"))
    end
    @test P._split_url("https://h/x/releases/download/continuous/a.tar.gz") ==
          ("https://h/x/releases/download/continuous", "a.tar.gz")
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
        # told the writer's options: in process, and as a subprocess
        wo = joinpath(d, "wo.jl")
        Base.write(wo, "using Panir\nrun_filter((d::Panir.Pandoc, ctx) -> (push!(d.blocks, " *
                       "Para(string(ctx.conversion.writer_options[\"number-sections\"]))); nothing))")
        @test P.convert("x"; to = "plain", number_sections = true, filters = [wo]) == "x\n\ntrue\n"
        wsub = joinpath(d, "wsub.jl")
        Base.write(wsub, "# pandocjl: subprocess\n" * Base.read(wo, String))
        @test P.convert("x"; to = "plain", number_sections = true, filters = [wsub]) == "x\n\ntrue\n"
        @test P._SCRIPTS[abspath(wsub)].filter === nothing
        # loaded again when changed with its time kept (cp -p, tar, a coarse
        # clock): the size and inode tell too
        if !Sys.iswindows()
            same = joinpath(d, "same.jl")
            Base.write(same, "using Panir\nrun_filter(s::Str -> Str(\"one\"))")
            @test P.convert("x"; to = "plain", filters = [same]) == "one\n"
            Base.run(`touch -r $same $(same).time`)
            Base.write(same * ".new", "using Panir\nrun_filter(s::Str -> Str(\"second\"))")
            mv(same * ".new", same; force = true)
            Base.run(`touch -r $(same).time $same`)
            @test P.convert("x"; to = "plain", filters = [same]) == "second\n"
        end
        # a script run as a subprocess is stopped by the conversion's time
        # limit, as pandoc stops a JSON filter
        slow = joinpath(d, "slow.jl")
        Base.write(slow, "# pandocjl: subprocess\nread(stdin); sleep(20)")
        t = @elapsed e = try P.convert("x"; to = "plain", timeout = 1, filters = [slow]) catch e; e end
        @test e isa PandocError && e.kind == "Timeout" && t < 10
        # a script's traverse
        td = joinpath(d, "td.jl")
        Base.write(td, "using Panir\nseen = String[]\nf(x::Union{Para, Str}) = (push!(seen, string(nameof(typeof(x)))); nothing)\n" *
                       "f(d::Panir.Pandoc) = (push!(d.blocks, Para(join(seen, \",\"))); nothing)\nrun_filter(f; traverse = :bottomup)")
        @test P.convert("a"; to = "plain", filters = [td]) |> contains("Str,Para")
        # a script that fails in process is not run again (as a subprocess):
        # its side effects once, its error with the ways to opt out
        log = joinpath(d, "side.log")
        fails = joinpath(d, "fails.jl")
        Base.write(fails, "using Panir\nopen(io -> println(io, \"ran\"), $(repr(log)), \"a\")\nerror(\"my bug\")\nrun_filter(s::Str -> s)")
        e = try P.convert("x"; to = "plain", filters = [fails]) catch e; e end
        msg = sprint(showerror, e)
        @test contains(msg, "my bug") && contains(msg, "# pandocjl: subprocess") && contains(msg, "PANDOCJL_SUBPROCESS")
        @test readlines(log) == ["ran"]
        # nor one that hands no filter over in process
        none = joinpath(d, "none.jl")
        Base.write(none, "# run_filter, someday\nopen(io -> println(io, \"none\"), $(repr(log)), \"a\")")
        @test_throws Exception P.convert("x"; to = "plain", filters = [none])
        @test readlines(log) == ["ran", "none"]
        # a script's cd stays its own: pandoc writes the output where it was named
        away = mkpath(joinpath(d, "away"))
        cdf = joinpath(d, "cd.jl")
        Base.write(cdf, "using Panir\ncd($(repr(away)))\nrun_filter(s::Str -> (cd($(repr(away))); nothing))")
        cd(d) do
            P.convert("x"; to = "plain", output_file = "out.txt", filters = [cdf])
            @test samefile(pwd(), d) && isfile(joinpath(d, "out.txt")) && !isfile(joinpath(away, "out.txt"))
        end
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
        # its output is counted against its memory limit: standard output (kept
        # in this process) and standard error (passed on)
        for (fd, stream) in ((1, "standard output"), (2, "standard error"))
            flood = joinpath(d, "flood$fd.wasm")
            Base.write(flood, wat(FLOOD(fd)))
            msg = try
                redirect_stderr(devnull) do
                    WasmFilter(flood; max_memory = 4 << 20)("{}", Conversion())
                end
                nothing
            catch err
                sprint(showerror, err)
            end
            @test msg !== nothing && contains(msg, stream) && contains(msg, "memory limit: 4194304 bytes")
        end
        # limits out of range: refused, not taken for none (or for an instant)
        for bad in (-1, NaN, Inf, -Inf)
            @test_throws ArgumentError WasmFilter(e; timeout = bad)
        end
        @test_throws ArgumentError WasmFilter(e; max_memory = -1)
        @test WasmFilter(e; timeout = 1e300)("{}", Conversion()) == UInt8[]   # huge: none in practice
        @test WasmFilter(e; timeout = 0).timeout === nothing && WasmFilter(e; max_memory = 0).max_memory === nothing  # 0: none, as the variables
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
        out = JSON.parse(P.convert("x"; to = "json", number_sections = true, filters = [wasm("conversion")]))
        @test JSON.parse(out["blocks"][end]["c"][2])["number-sections"] == true   # PANDOC_WRITER_OPTIONS
        # without the variables when it would be too long for an environment variable
        big = Dict(_filter_env_of(Dict("variables" => Dict("v" => "x"^40_000), "toc-depth" => 3)))
        @test haskey(JSON.parse(big["PANDOC_WRITER_OPTIONS"]), "toc-depth") && !contains(big["PANDOC_WRITER_OPTIONS"], "variables")
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
        # a filter can't name a cancel token: "untrusted" is written over what
        # it wrote (its calls stop with the conversion they run in), and one
        # beside it is refused
        t = CancelToken()
        cancel!(t)
        a = calls([Dict("convert" => [Dict("to" => "html", "untrusted" => Dict("cancel-token" => t.id)), "*x*"]),
                   Dict("convert" => [Dict("to" => "html", "cancel-token" => t.id), "*x*"]),
                   Dict("read_many" => [["x"], Dict("untrusted" => Dict("cancel-token" => t.id))])])
        @test a[1] == Dict("ok" => "<p><em>x</em></p>\n")
        @test a[2]["error"][1] == "PandocOptionError"
        @test length(a[3]["ok"]) == 1
        # its calls may give citeproc its files as their contents (libpandoc
        # 1.14's "citeproc-files"), and read none themselves
        mktempdir() do d
            Base.write(joinpath(d, "refs.bib"), "@book{key, title={CANARY-ON-DISK}, author={B}, year={2001}}\n")
            bib = Dict("refs.bib" => "@book{key, title={BIB-OK}, author={A}, year={2000}}\n")
            doc = "---\nbibliography: refs.bib\n---\n\n[@key]\n"
            a = cd(() -> calls([Dict("convert" => [Dict("to" => "plain", "citeproc" => true, "citeproc-files" => bib), doc]),
                                Dict("convert" => [Dict("to" => "plain", "citeproc" => true), doc])]), d)
            @test contains(a[1]["ok"], "BIB-OK")
            @test haskey(a[2], "error") && !contains(JSON.json(a), "CANARY")
        end
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
        # what it may see: only what it is given (none by default)
        mktempdir() do base
            base = realpath(base)   # (the working directory's: macOS's /var is /private/var)
            dir, other = mkpath(joinpath(base, "given")), mkpath(joinpath(base, "other"))
            Base.write(joinpath(dir, "part.txt"), "included")
            Base.write(joinpath(other, "secret.txt"), "CANARY-WASM-API")
            run(f, file) = cd(() -> P.convert("```include\n$file\n```\n"; to = "plain", filters = [f]), base)
            # (its message: the filter's own exception)
            failure(f, file) = try
                run(f, file)
                nothing
            catch e
                e isa FilterError ? sprint(showerror, e.exception) : rethrow()
            end
            # the directory given, as the filter's current directory
            @test strip(run(WasmFilter(wasm("include"); preopens = [(dir, ".", false)]), "part.txt")) == "included"
            # given as the variable gives it: by its absolute path, and its real one
            for d in (dir, joinpath(base, ".", "given")), part in (named(joinpath(dir, "part.txt")), "given/part.txt")
                @test strip(run(WasmFilter(wasm("include"); dirs = [d]), part)) == "included"
            end
            # and through a link to it, by the link's name and the real one
            if !Sys.iswindows()
                link = joinpath(base, "link")
                symlink(dir, link)
                for part in (named(joinpath(link, "part.txt")), named(joinpath(dir, "part.txt")))
                    @test strip(run(WasmFilter(wasm("include"); dirs = [link]), part)) == "included"
                end
            end
            # what is outside is missing
            msg = failure(WasmFilter(wasm("include"); dirs = [dir]), named(joinpath(other, "secret.txt")))
            @test endswith(msg, "exited with status 3") && !contains(msg, "CANARY")
            # none by default: the file can't be read, the filter's failure
            # fails the conversion, and says it had none (and where they come from)
            withenv(P.DIRS_VAR => nothing) do
                @test endswith(failure(wasm("include"), "given/part.txt"),
                               "exited with status 3 (it was given no directory: LIBPANDOC_WASM_DIRS)")
            end
            @test endswith(failure(WasmFilter(wasm("include"); dirs = String[]), "given/part.txt"),
                           "exited with status 3 (it was given no directory)")
            # a directory that doesn't exist, or isn't one: it fails before it runs
            for (d, says) in ((joinpath(base, "nope"), "does not exist"), (joinpath(dir, "part.txt"), "is not a directory"))
                msg = failure(WasmFilter(wasm("include"); dirs = [d]), "given/part.txt")
                @test contains(msg, "include.wasm: $d $says") && !contains(msg, P.DIRS_VAR)
            end
            # given as a list or a pair, refused: `dirs` lists directories
            @test_throws ArgumentError WasmFilter(wasm("include"); dirs = dir)
            @test_throws ArgumentError WasmFilter(wasm("include"); dirs = ["." => "."])
            @test_throws ArgumentError WasmFilter(wasm("include"); preopens = [(dir, ".")])
            # LIBPANDOC_WASM_DIRS gives a filter made without directories its,
            # read when it runs; a program's own choice replaces it
            withenv(P.DIRS_VAR => dir) do
                f = wasm("include")
                @test strip(run(f, "given/part.txt")) == "included"
                @test strip(run(WasmFilter(f), named(joinpath(dir, "part.txt")))) == "included"
                @test endswith(failure(WasmFilter(f; dirs = String[]), "given/part.txt"),
                               "exited with status 3 (it was given no directory)")
                @test endswith(failure(WasmFilter(f; dirs = [other]), "given/part.txt"), "exited with status 3")
            end
            # read-only, unless it is told otherwise
            write(w) = cd(() -> P.convert("```write\nout.txt\n```"; to = "plain",
                                          filters = [WasmFilter(wasm("misbehave"); preopens = [(dir, ".", w)])]), base)
            @test refused_with(() -> write(false)) isa FilterError && !isfile(joinpath(dir, "out.txt"))
            write(true)
            @test isfile(joinpath(dir, "out.txt"))
        end
        # the names it sees each directory by, and those it doesn't: in the
        # working directory of `work`, with `common` beside it
        mktempdir() do base
            base = realpath(base)
            for d in ("work/img", "common", "secret")
                mkpath(joinpath(base, d))
            end
            for (f, text) in ("work/here.txt" => "HERE-OK", "work/img/in.txt" => "IMG-OK", "common/part.txt" => "COMMON-OK",
                              "secret/secret.txt" => "CANARY-WASM-DIRS", "a-file.txt" => "not a directory")
                Base.write(joinpath(base, f), text)
            end
            Sys.iswindows() || symlink("../secret/secret.txt", joinpath(base, "work", "link-out.txt"))
            sep = Sys.iswindows() ? ";" : ":"
            # (output, or the filter's failure) with the variable listing `dirs`
            include(dirs, file) = withenv(P.DIRS_VAR => join(dirs, sep)) do
                try
                    strip(cd(() -> P.convert("```include\n$file\n```\n"; to = "plain", filters = [wasm("include")]),
                             joinpath(base, "work")))
                catch e
                    e isa FilterError || rethrow()
                    msg = sprint(showerror, e.exception)
                    @test !contains(msg, "CANARY")
                    msg
                end
            end
            missing_ = r"exited with status 3$"
            # empty: none
            @test endswith(include([""], "here.txt"), "(it was given no directory: LIBPANDOC_WASM_DIRS)")
            # the working directory, as `.`, and by its absolute path
            @test include(["."], "here.txt") == "HERE-OK"
            @test include(["."], "img/in.txt") == "IMG-OK"
            @test include(["."], named(joinpath(base, "work", "here.txt"))) == "HERE-OK"
            @test contains(include(["."], "../common/part.txt"), missing_)
            @test include([joinpath(base, "work")], "here.txt") == "HERE-OK"
            # its parent, as `..` (an include through `..`), and the working
            # directory as `.` inside it
            @test include([".."], "../common/part.txt") == "COMMON-OK"
            @test include([".."], "here.txt") == "HERE-OK"
            @test include([".."], named(joinpath(base, "common", "part.txt"))) == "COMMON-OK"
            # a sibling, and a list
            @test include(["../common"], "../common/part.txt") == "COMMON-OK"
            @test contains(include(["../common"], "here.txt"), missing_)
            @test include([".", "../common"], "here.txt") == "HERE-OK"
            @test include([".", "../common"], "../common/part.txt") == "COMMON-OK"
            # a subdirectory: only below it
            @test include(["img"], "img/in.txt") == "IMG-OK"
            @test contains(include(["img"], "here.txt"), missing_)
            # not normalised (wasi-libc matches the names; a leading `./` is
            # kept by this filter, built with lto = true, and dropped by one
            # built without, where the two names with it work)
            @test contains(include(["img"], "./img/in.txt"), missing_)
            for file in ("./../common/part.txt", "img/../../common/part.txt")
                @test contains(include([".", "../common"], file), missing_)
            end
            # outside what was given: missing
            @test contains(include([".", "../common"], named(joinpath(base, "secret", "secret.txt"))), missing_)
            @test contains(include([".", "../common"], "../secret/secret.txt"), missing_)
            Sys.iswindows() || @test contains(include(["."], "link-out.txt"), missing_)
            # (even with its target's directory given: the link leaves the
            # directory its name is opened through, the working directory)
            Sys.iswindows() || @test contains(include([".", ".."], "link-out.txt"), missing_)
            # a directory that doesn't exist, a file: the filter fails, naming it
            @test contains(include([".", "nope"], "here.txt"), "include.wasm: LIBPANDOC_WASM_DIRS: nope does not exist")
            file = joinpath("..", "a-file.txt")
            @test contains(include([file], "here.txt"), "include.wasm: LIBPANDOC_WASM_DIRS: $file is not a directory")
            # pandocjl: the variable, and what the filter says (its standard error)
            status, out, err = pandocjl("-t", "plain", "-F", wasm("include"); input = "```include\nhere.txt\n```\n",
                                        env = Dict(P.DIRS_VAR => "."), dir = joinpath(base, "work"))
            @test (status, strip(out)) == (0, "HERE-OK")
            status, out, err = pandocjl("-t", "plain", "-F", wasm("include"); input = "```include\nhere.txt\n```\n",
                                        env = Dict(P.DIRS_VAR => ""), dir = joinpath(base, "work"))
            @test status == 83 && contains(err, "exited with status 3 (it was given no directory: LIBPANDOC_WASM_DIRS)")
            for file in ("./../common/part.txt", "img/../../common/part.txt")
                status, out, err = pandocjl("-t", "plain", "-F", wasm("include"); input = "```include\n$file\n```\n",
                                            env = Dict(P.DIRS_VAR => join([".", "../common"], sep)), dir = joinpath(base, "work"))
                @test status == 83 && contains(err, "Operation not permitted") && !contains(out * err, "CANARY")
            end
        end
        # limits: time and memory
        failure(f, input) = try
            P.convert(input; to = "plain", filters = [f])
            nothing
        catch e
            e isa FilterError ? sprint(showerror, e.exception) : rethrow()
        end
        t = @elapsed msg = failure(WasmFilter(wasm("misbehave"); timeout = 0.3), "```spin\n```")
        @test contains(msg, "its time limit") && t < 10
        @test contains(failure(WasmFilter(wasm("misbehave"); max_memory = 64 << 20), "```hog\n```"),
                       "memory limit: 67108864 bytes")
        withenv("LIBPANDOC_WASM_TIMEOUT" => "0.3", "LIBPANDOC_WASM_MAX_MEMORY" => "64m") do
            @test contains(failure(wasm("misbehave"), "```spin\n```"), "its time limit")
            @test contains(failure(wasm("misbehave"), "```hog\n```"), "memory limit: 67108864 bytes")
            @test failure(wasm("upper"), "hi") === nothing
        end
        @test failure(WasmFilter(wasm("upper"); timeout = 60, max_memory = 1 << 30), "hi") === nothing
        # the time limit covers its calls to pandoc: each runs with the time
        # it has left (the review's 100,000 nested block quotes: minutes)
        slow = ">"^100_000
        for request in (Dict("convert" => [Dict("from" => "markdown", "to" => "html"), slow]),
                        Dict("read_many" => [[slow], Dict("from" => "markdown")]))
            t = @elapsed msg = failure(WasmFilter(wasm("calls"); timeout = 1), "```call\n$(JSON.json(request))\n```")
            @test msg !== nothing && contains(msg, "its time limit")
            @test t < 4
        end
        # the filter's own shorter "timeout" is kept: its call fails, it goes on
        request = Dict("convert" => [Dict("from" => "markdown", "to" => "html", "timeout" => 0.2), slow])
        out = JSON.parse(P.convert("```call\n$(JSON.json(request))\n```"; to = "json",
                                   filters = [WasmFilter(wasm("calls"); timeout = 30)]))
        @test JSON.parse(out["blocks"][1]["c"][2])["error"][1] == "Timeout"
        # citeproc in a wasm filter (libpandoc-rs's example `citeproc`): it
        # reads the files the metadata names in the directories it is given and
        # hands pandoc their contents. Without them they are missing, and a
        # canary outside them never shows, however the conversion is
        # sandboxed (not, pandoc's `--sandbox`, the directory sandbox listing
        # the canary's directory). With pandocjl, whose standard error has
        # pandoc's message.
        mktempdir() do base
            base = realpath(base)
            work, secret = mkpath(joinpath(base, "work")), mkpath(joinpath(base, "secret"))
            Base.write(joinpath(work, "refs.bib"), "@article{key, title={BIB-OK}, journal={Journal of Long Names}, " *
                                                   "author={Author, A.}, year={2000}}\n")
            Base.write(joinpath(work, "style.csl"), """
                <?xml version="1.0" encoding="utf-8"?>
                <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
                  <info><title>Test</title><id>test</id><updated>2026-01-01T00:00:00+00:00</updated></info>
                  <citation><layout><text value="STYLE-OK "/><text variable="title"/><text value=" in "/><text variable="container-title" form="short"/></layout></citation>
                </style>
                """)
            Base.write(joinpath(work, "abbr.json"), """{"default": {"container-title": {"Journal of Long Names": "ABBR-OK"}}}""")
            marker = "CANARY-WASM-CITEPROC-$(string(rand(UInt64); base = 16))"
            Base.write(joinpath(secret, "canary.bib"), "@book{key, title={$marker}, author={B}, year={2001}}\n")
            doc = "---\nbibliography: refs.bib\ncsl: style\ncitation-abbreviations: abbr\n---\n\n[@key]\n"
            canary = "---\nbibliography: ../secret/canary.bib\nnocite: '@*'\n---\n\n[@key]\n"
            cite(args, sandbox, dirs, input) =
                withenv("LIBPANDOC_SANDBOX" => sandbox, "LIBPANDOC_SANDBOX_WRITE" => nothing, P.DIRS_VAR => dirs) do
                    pandocjl("-t", "plain", "-F", wasm("citeproc"), args...; input, dir = work)
                end
            # native, pandoc's sandbox, the directory sandbox (`..`: the canary's
            # directory too)
            for (args, sandbox) in ((String[], nothing), (["--sandbox"], nothing), (String[], ".."))
                status, out, err = cite(args, sandbox, ".", doc)
                @test status == 0 && all(ok -> contains(out, ok), ("STYLE-OK", "BIB-OK", "ABBR-OK"))
                status, out, err = cite(args, sandbox, nothing, doc)
                @test status == 83 && contains(err, "not found") &&
                      contains(err, "(it was given no directory: LIBPANDOC_WASM_DIRS)")
                status, out, err = cite(args, sandbox, ".", canary)
                @test status == 83 && !contains(out * err, marker) && contains(err, "canary.bib' not found")
            end
        end
    end
    # what a process's image holds of an earlier process (precompiling's, a
    # system image's) is reset: the clock thread, which runs time limits,
    # too; and loading the package (with the variable set) starts none
    code = "import LibPandoc as P; c = P._CLOCK; print(c.users, c.alive, c.thread, \" \"); " *
           "c.users, c.alive, c.thread = 3, true, 1; P.__init__(); print(c.users, c.alive, c.thread)"
    @test Base.read(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -e $code`,
                           "LIBPANDOC_WASM_TIMEOUT" => "1"), String) == "0false0 0false0"
    @test LibPandoc._parse_timeout("2") == 2.0 && LibPandoc._parse_timeout("0.5") == 0.5
    @test LibPandoc._parse_timeout("") === nothing && LibPandoc._parse_timeout("0") === nothing
    @test_throws ErrorException LibPandoc._parse_timeout("2s")
    @test LibPandoc._parse_memory("512M") == 512 << 20 && LibPandoc._parse_memory("64k") == 64 << 10
    @test LibPandoc._parse_memory("4096") == 4096 && LibPandoc._parse_memory("") === nothing
    # too large to hold: no limit in practice, not a wrapped number (17179869184g was 0: none)
    @test LibPandoc._parse_memory("17179869184g") == LibPandoc._parse_memory("99999999999999g") >= 1 << 62
    @test LibPandoc._parse_timeout("1e300") == 1e300
    @test_throws ErrorException LibPandoc._parse_memory("12x")
end

@testset "the clock runs while a call with a time limit runs" begin
    mktempdir() do d
        empty, loop = joinpath(d, "empty.wasm"), joinpath(d, "loop.wasm")
        Base.write(empty, EMPTY_WASM)
        Base.write(loop, wat("""(module (memory (export "memory") 1)
                                  (func (export "_start") (loop \$l (br \$l))))"""))
        c = P._CLOCK
        state() = (lock(c.lock); s = (c.users, c.alive); unlock(c.lock); s)
        # ended: it found no call running (within a tick), and it is joined
        function ended()
            timedwait(() -> state() == (0, false), 5.0) === :ok || return false
            lock(P._CLOCK_START) do
                c.thread == 0 || @ccall gc_safe = true uv_thread_join(Ref(c.thread)::Ptr{UInt64})::Cint
                c.thread = 0
            end
            true
        end
        @test ended()   # (an earlier test's)
        @test WasmFilter(empty; timeout = 30)("{}", Conversion()) == UInt8[]
        @test ended()
        # started and ended many times, by tasks on every thread at once
        for _ in 1:20
            @sync for _ in 1:8
                Threads.@spawn WasmFilter(empty; timeout = 30)("{}", Conversion())
            end
        end
        @test ended()
        # a time limit still fires on the first call after it ended
        t = @elapsed e = try WasmFilter(loop; timeout = 0.5)("{}", Conversion()); nothing catch e; e end
        @test e isa ErrorException && contains(e.msg, "its time limit") && t < 5
        @test ended()
        # and so does the directory sandbox's (timed with the module compiled)
        P.convert("x"; sandbox = (read = String[], timeout = 0))
        @test ended()
        t = @elapsed e = try P.convert(">"^100_000; sandbox = (read = String[], timeout = 0.5)) catch e; e end
        @test istimeout(e) && t < 10
        @test ended()
        # with no time limit, none starts
        WasmFilter(empty; timeout = nothing)("{}", Conversion())
        @test state() == (0, false) && c.thread == 0
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
        # a file name that isn't UTF-8 (Linux: macOS and Windows take only Unicode names)
        if Sys.islinux()
            name = String(UInt8[codeunits("caf")..., 0xe9, codeunits(".md")...])
            Base.write(joinpath(d, name), "*caf*")
            status, out, err = pandocjl("-t", "plain", "-F", "upper.jl", name; dir = d)
            @test status == 0 && out == "CAF\n"
            status, _, _ = pandocjl("-t", "plain", name, "-o", name * ".txt"; dir = d)
            @test status == 0 && Base.read(joinpath(d, name * ".txt"), String) == "caf\n"
            # where it would cross as JSON or as UTF-8 arguments: refused, saying why
            @test_throws ArgumentError P.convert(; input_files = [joinpath(d, name)], to = "plain")
            @test_throws ArgumentError P.run([joinpath(d, name)])
        end
        if !isempty(WASM)
            status, out, _ = pandocjl("-t", "plain", "-F", wasm("upper"); input = "a *b*")
            @test status == 0 && out == "A B\n"
            # a filter that fails: as pandoc fails for a JSON filter, the
            # message saying it was given no directory
            status, _, err = pandocjl("-t", "plain", "-F", wasm("include"); input = "```include\nupper.jl\n```\n",
                                      env = Dict(P.DIRS_VAR => ""), dir = d)
            @test status == 83 && contains(err, "(it was given no directory: LIBPANDOC_WASM_DIRS)")
        end
    end
end

@testset "pandocjl: a Lua filter's output through a pipe" begin
    # Julia's libuv puts a pipe on standard output or error in non-blocking
    # mode; a Lua filter's io.stdout:write stopped at a full pipe (64 KiB,
    # EAGAIN), the rest lost. The reader here waits until the filter is about
    # to write, then a second, so that the pipe is full when it does.
    mktempdir() do d
        mark = joinpath(d, "writing")
        lua = joinpath(d, "big.lua")
        Base.write(lua, """
            function Pandoc(doc)
              io.open($(repr(mark)), "w"):close()
              io.stdout:write(string.rep("x", 100000))
              io.stderr:write(string.rep("y", 100000))
              return doc
            end
            """)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc -t plain -o $(joinpath(d, "out.txt")) -L $lua`
        out, err = Pipe(), Pipe()
        p = Base.run(pipeline(cmd; stdin = IOBuffer("hi"), stdout = out, stderr = err); wait = false)
        close(out.in)
        close(err.in)
        @test timedwait(() -> isfile(mark) || process_exited(p), 120) === :ok
        sleep(1)
        o, e = (@async Base.read(out, String)), (@async Base.read(err, String))
        timedwait(() -> process_exited(p), 120) === :ok || kill(p, Base.SIGKILL)
        wait(p)
        @test fetch(o) == "x"^100000
        @test count(==('y'), fetch(e)) == 100000
    end
end

@testset "a program reading its own standard output" begin
    # A library call leaves the standard streams as Julia has them: with
    # them blocking, this program (its reader a task of the thread the call
    # holds) waited forever on a write the pipe can't hold.
    code = """
        import LibPandoc, Panir
        big(d::Panir.Pandoc, ctx) = (print(stdout, "x"^200000); nothing)
        orig = stdout
        rd, wr = redirect_stdout()
        reader = @async read(rd, String)
        LibPandoc.convert("hi"; to = "plain", filters = [big])
        redirect_stdout(orig)
        close(wr)
        print(length(fetch(reader)))
        """
    out = Pipe()
    p = Base.run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -e $code`; stdin = devnull, stdout = out); wait = false)
    close(out.in)
    o = @async Base.read(out, String)
    timedwait(() -> process_exited(p), 120) === :ok || kill(p, Base.SIGKILL)
    wait(p)
    @test fetch(o) == "200000"
end

include("cancel.jl")
include("sandbox.jl")
include("confined_reads.jl")
include("chain.jl")

end
