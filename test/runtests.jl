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

# pandocjl ARGS as a separate process: (status, stdout, stderr)
function pandocjl(args...; input = "", env = Dict{String, String}(), dir = pwd())
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc $args`
    out, err = IOBuffer(), IOBuffer()
    p = cd(() -> Base.run(pipeline(ignorestatus(addenv(cmd, env)); stdin = IOBuffer(input), stdout = out, stderr = err)), dir)
    # pandoc writes native line endings (CRLF on Windows) to files and stdout
    p.exitcode, replace(String(take!(out)), "\r\n" => "\n"), String(take!(err))
end

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
    timeout(f) = (e = try f(); nothing catch e; e end; e isa PandocError && e.kind == "Timeout")
    t = @elapsed @test timeout(() -> P.convert(slow; to = "html", timeout = 0.5))
    @test t < 5
    @test timeout(() -> P.read(slow; timeout = 0.5))
    @test P.convert("x"; to = "plain", timeout = 30) == "x\n"   # and the next call works
    # read_many: the whole call's limit; a text not read in time fails alone
    @test timeout(() -> P.read_many(["a", slow]; timeout = 0.5))
    docs = P.read_many(["a", slow, "[x"]; timeout = 0.5, return_exceptions = true)
    @test docs[1] isa Panir.Pandoc && docs[2] isa PandocError && docs[2].kind == "Timeout"
    @test docs[3] isa Panir.Pandoc
    @test P.read_many(["a"]) isa Vector{Panir.Pandoc}
    # code in this process runs to its end, and the call fails then
    nap(d::Panir.Pandoc) = (sleep(1); nothing)
    t = @elapsed @test timeout(() -> P.convert("x"; to = "html", timeout = 0.2, filters = [nap]))
    @test t >= 1
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
    # the number in effect: set (before pandoc's threads have grown) or not
    @test P.set_num_threads(1) == P.num_threads() >= 1
end

@testset "versions" begin
    # the same major, a minor at least the one relied on
    v = 1000P.ABI_MAJOR + P.ABI_MINOR
    @test P.ABI_MINOR >= 11 && P._abi_ok(v) && P._abi_ok(v + 1)
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
            # read-only, unless it is told otherwise
            e = try
                cd(() -> P.convert("```write\nout.txt\n```"; to = "plain", filters = [wasm("misbehave")]), d)
            catch e
                e
            end
            @test e isa FilterError && !isfile(joinpath(d, "out.txt"))
            cd(() -> P.convert("```write\nout.txt\n```"; to = "plain",
                               filters = [WasmFilter(wasm("misbehave"); writable = true)]), d)
            @test isfile(joinpath(d, "out.txt"))
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
    end
    # what a process's image holds of an earlier process (precompiling's, a
    # system image's) is reset: the clock thread, which runs time limits, too
    code = "import LibPandoc as P; P._CLOCK[] = UInt64(1); P.__init__(); print(P._CLOCK[] === nothing)"
    @test Base.read(`$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -e $code`, String) == "true"
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
        end
    end
end

include("sandbox.jl")
include("confined_reads.jl")

end
