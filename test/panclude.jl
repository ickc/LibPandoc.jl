# The include step built into libpandoc (1.15, panclude): "panclude" among
# the filters and its roots, natively, under pandoc's sandbox, for untrusted
# options and in the directory sandbox; wasm filters given no directory after
# it, which see the files' content, while their own calls to pandoc read
# nothing; and pandocjl's -F panclude, never a filter of that name (included
# in runtests.jl's testset).

# a file inside the document's directory, one outside it, and (but on
# Windows) a link inside it that leads out
const PANCLUDE_DOC = """
    ```{include="part.txt"}
    OWN-PART
    ```

    ```{include="../secret.txt"}
    OWN-OUT
    ```

    ```{include="link.txt"}
    OWN-LINK
    ```
    """
const NO_ROOTS = "there are no roots, so no file is included"

# `doc/` (doc.md, part.txt, a link to the canary), `other/`, and the canary
# `secret.txt` beside them, at its real path (macOS's /var); `f(base)`.
function panclude_tree(f)
    base = realpath(mktempdir())
    try
        mkpath(joinpath(base, "doc"))
        mkpath(joinpath(base, "other"))
        Base.write(joinpath(base, "doc", "doc.md"), PANCLUDE_DOC)
        Base.write(joinpath(base, "doc", "part.txt"), "hello *from the part*\n")
        Base.write(joinpath(base, "other", "other.txt"), "OTHER-OK\n")
        Base.write(joinpath(base, "secret.txt"), "CANARY-PANCLUDE\n")
        Sys.iswindows() || symlink("../secret.txt", joinpath(base, "doc", "link.txt"))
        f(base)
    finally
        rm(base; recursive = true, force = true)
    end
end

# A conversion: its output and pandoc's warnings (the messages of LibPandoc's
# @warn); never the canary.
function warned(f)
    logs, out = Test.collect_test_logs(f)
    said = String[string(l.message) for l in logs if l.level == Base.CoreLogging.Warn]
    @test !contains(out, "CANARY") && !any(contains("CANARY"), said)
    out, said
end
doc_plain(base, filters; options...) =
    warned(() -> P.convert(; input_files = [joinpath(base, "doc", "doc.md")], to = "plain", filters, options...))

# A path as a document names it natively: with /.
native(p) = replace(String(p), '\\' => '/')

# The warning for an include that failed, as pandoc's log gives it.
cannot(path, file, reason) = "[ScriptingWarning] Scripting warning: panclude: cannot include \"$path\" in $file: $reason"

@testset "panclude: the include step" begin
    panclude_tree() do base
        doc = joinpath(base, "doc", "doc.md")
        # by default the document's directory
        out, said = doc_plain(base, ["panclude"])
        @test contains(out, "hello *from the part*") && contains(out, "OWN-OUT")
        @test cannot("../secret.txt", doc, "outside the roots") in said
        if !Sys.iswindows()
            @test contains(out, "OWN-LINK")
            @test cannot("link.txt", doc, "a symbolic link leads outside the roots") in said
        end
        # off unless named
        out, said = doc_plain(base, [])
        @test contains(out, "OWN-PART") && !contains(out, "hello") && isempty(said)
        # roots given
        other = joinpath(base, "other")
        out, said = doc_plain(base, [Dict("type" => "panclude", "roots" => [other])])
        @test contains(out, "OWN-PART") && !contains(out, "hello") && cannot("part.txt", doc, "outside the roots") in said
        out, _ = doc_plain(base, [Dict("type" => "panclude", "roots" => [joinpath(base, "doc"), other])])
        @test contains(out, "hello *from the part*")
        out, said = doc_plain(base, [Dict("type" => "panclude", "roots" => String[])])
        @test contains(out, "OWN-PART") && !contains(out, "hello") && cannot("part.txt", doc, NO_ROOTS) in said
        for bad in (Dict("type" => "panclude", "roots" => [joinpath(base, "secret.txt")]),
                    Dict("type" => "panclude", "root" => [other]))
            e = refused_with(() -> doc_plain(base, [bad]))
            @test e isa PandocError && e.kind == "PandocOptionError"
        end
        # pandoc's sandbox: only roots named
        out, said = doc_plain(base, ["panclude"]; sandbox = true)
        @test contains(out, "OWN-PART") && !contains(out, "hello") && cannot("part.txt", doc, NO_ROOTS) in said
        out, said = doc_plain(base, [Dict("type" => "panclude", "roots" => [joinpath(base, "doc")])]; sandbox = true)
        @test contains(out, "hello *from the part*") && cannot("../secret.txt", doc, "outside the roots") in said
        # one of pandoc's own: it ends a run of Julia filters
        seen = Bool[]
        look = (d::Panir.Pandoc) -> (push!(seen, contains(Panir.serialize(d), "from the part")); nothing)
        doc_plain(base, Any[look, "panclude", look, look])
        @test seen == [false, true, true]
    end
end

@testset "panclude: untrusted options read only the host's roots" begin
    panclude_tree() do base
        text = "```{include=\"$(native(joinpath(base, "doc", "part.txt")))\"}\nOWN-PART\n```\n"
        roots = [joinpath(base, "doc")]
        untrusted(host; kw...) = warned(() -> P.convert(text; to = "plain", filters = ["panclude"], untrusted = host, kw...))
        out, said = untrusted(true)
        @test contains(out, "OWN-PART") && !contains(out, "hello") && endswith(said[1], NO_ROOTS)
        # the host's roots, also beside a cancel token, and from another thread
        host = Dict("panclude-roots" => roots)
        @test contains(first(untrusted(host)), "hello *from the part*")
        @test contains(first(untrusted(host; cancel = CancelToken())), "hello *from the part*")
        @test contains(fetch(Threads.@spawn first(untrusted(host))), "hello *from the part*")
        # the code's own roots: refused
        for theirs in ((panclude_roots = roots,), (filters = [Dict("type" => "panclude", "roots" => roots)],),
                       (filters = ["panclude", "x.lua"],))
            e = refused_with(() -> P.convert(text; to = "plain", untrusted = true, filters = ["panclude"], theirs...))
            @test e isa PandocError && e.kind == "PandocOptionError"
        end
        # citeproc may be named too (libpandoc 1.15)
        @test P.convert("x"; to = "plain", filters = ["citeproc"], untrusted = true) == "x\n"
    end
end

@testset "panclude: a file or package of that name is not run" begin
    panclude_tree() do base
        work = joinpath(base, "doc")
        # a Julia script, and a program (a script's #! line)
        Base.write(joinpath(work, "panclude"), "#!/usr/bin/env julia\nwrite(\"ran.txt\", \"RAN\")\nwrite(stdout, read(stdin))\n")
        Sys.iswindows() || chmod(joinpath(work, "panclude"), 0o755)
        for filters in (["panclude"], [Dict("type" => "json", "path" => "panclude")])
            out, _ = cd(() -> warned(() -> P.convert(; input_files = ["doc.md"], to = "plain", filters)), work)
            @test contains(out, "hello *from the part*")
            @test !isfile(joinpath(work, "ran.txt"))
        end
        @test P._json_path("panclude") === nothing
        # pandocjl: -F panclude, under --sandbox no roots
        status, out, err = pandocjl("doc.md", "-t", "plain", "-F", "panclude"; dir = work)
        @test status == 0 && contains(out, "hello *from the part*")
        @test contains(err, "panclude: cannot include \"../secret.txt\" in doc.md: outside the roots")
        status, out, err = pandocjl("doc.md", "-t", "plain", "--sandbox", "-F", "panclude"; dir = work)
        @test status == 0 && contains(out, "OWN-PART") && !contains(out, "hello") && contains(err, NO_ROOTS)
        @test !isfile(joinpath(work, "ran.txt")) && !contains(out * err, "CANARY")
    end
end

@testset "panclude: a wasm filter given no directory sees the content" begin
    if isempty(WASM)
        @info "panclude with wasm filters: set LIBPANDOC_WASM_FILTERS to test it"
    else
        panclude_tree() do base
            # the step first, then parse (the block's text read as the
            # document was) and upper (upper-cased): they see the file's
            # text, after the block's own; without the step, never
            Base.write(joinpath(base, "doc", "doc.md"), "```{.parse include=\"part.txt\"}\nbefore the part:\n```\n")
            after = [wasm("parse"), wasm("upper")]
            @test first(doc_plain(base, ["panclude"; after])) == "BEFORE THE PART: HELLO FROM THE PART\n"
            @test first(doc_plain(base, after)) == "BEFORE THE PART:\n"
            roots = Dict("type" => "panclude", "roots" => [joinpath(base, "doc")])
            @test first(doc_plain(base, Any[roots, after...]; sandbox = true)) == "BEFORE THE PART: HELLO FROM THE PART\n"
            status, out, err = pandocjl("doc.md", "-t", "plain", "-F", "panclude", "-F", wasm("parse"),
                                        "-F", wasm("upper"); dir = joinpath(base, "doc"))
            @test (status, out) == (0, "BEFORE THE PART: HELLO FROM THE PART\n")
        end
    end
end

@testset "panclude: a wasm filter's own calls read nothing" begin
    if isempty(WASM)
        @info "panclude with wasm filters: set LIBPANDOC_WASM_FILTERS to test it"
    else
        panclude_tree() do base
            # untrusted, with no roots from the host: a call naming the step
            # reads nothing, whatever it writes; roots of its own refused;
            # natively and in the directory sandbox, the conversion's own
            # step given a root holding the canary
            doc = joinpath(base, "doc", "doc.md")
            for sandboxed in (false, true)
                # (paths natively, and as the module sees them)
                path = sandboxed ? named : native
                secret, root = path(joinpath(base, "secret.txt")), path(base)
                part = "```{include=\"$secret\"}\nOWN\n```\n"
                requests = [
                    Dict("convert" => [Dict("to" => "plain", "filters" => ["panclude"]), part]),
                    Dict("convert" => [Dict("to" => "plain", "filters" => ["panclude"],
                                            "untrusted" => Dict("panclude-roots" => [root])), part]),
                    Dict("convert" => [Dict("to" => "plain", "filters" => ["panclude"], "untrusted" => false), part]),
                    Dict("convert" => [Dict("to" => "plain", "filters" => ["panclude"], "panclude-roots" => [root]), part]),
                    Dict("convert" => [Dict("to" => "plain",
                                            "filters" => [Dict("type" => "panclude", "roots" => [root])]), part]),
                ]
                Base.write(doc, join(("```call\n$(JSON.json(r))\n```" for r in requests), "\n\n"))
                options = sandboxed ? (input_files = [path(doc)], sandbox = (read = [base],)) : (input_files = [path(doc)],)
                # the conversion's own step has a root holding the canary
                step = Dict("type" => "panclude", "roots" => [root])
                out = P.convert(; to = "json", filters = [step, wasm("calls")], options...)
                @test !contains(out, "CANARY")
                answers = [JSON.parse(b["c"][2]) for b in JSON.parse(out)["blocks"]]
                @test all(a -> strip(get(a, "ok", "")) == "OWN", answers[1:3])
                @test all(a -> get(a, "error", [""])[1] == "PandocOptionError", answers[4:end])
            end
        end
    end
end

@testset "panclude: in the directory sandbox, nothing outside the mounts" begin
    panclude_tree() do base
        # roots as the module sees them (the same paths but on Windows,
        # /c/...); a root wider than the mounts is no directory there
        work = joinpath(base, "doc")
        secret = named(joinpath(base, "secret.txt"))
        Base.write(joinpath(work, "doc.md"), "```{include=\"$secret\"}\nOWN-ABS\n```\n\n$PANCLUDE_DOC")
        file = named(joinpath(work, "doc.md"))
        mounts = (read = [work],)
        for filters in (["panclude"], [Dict("type" => "panclude", "roots" => [named(work)])])
            out, said = warned(() -> P.convert(; input_files = [file], to = "plain", filters, sandbox = mounts))
            @test contains(out, "hello *from the part*") && contains(out, "OWN-ABS") && contains(out, "OWN-OUT")
            @test cannot("../secret.txt", file, "outside the roots") in said
            Sys.iswindows() || @test contains(out, "OWN-LINK")
        end
        e = refused_with(() -> P.convert(; input_files = [file], to = "plain", sandbox = mounts,
                                         filters = [Dict("type" => "panclude", "roots" => [named(base)])]))
        @test e isa PandocError && e.kind == "PandocOptionError" && contains(e.message, "is not a directory")
        # untrusted, with the host's roots as the module names them
        text = "```{include=\"$(named(joinpath(work, "part.txt")))\"}\nOWN-PART\n```\n"
        out = P.convert(text; to = "plain", filters = ["panclude"], sandbox = mounts,
                        untrusted = Dict("panclude-roots" => [named(work)]))
        @test contains(out, "hello *from the part*")
        out, _ = warned(() -> P.convert(text; to = "plain", filters = ["panclude"], sandbox = mounts, untrusted = true))
        @test contains(out, "OWN-PART") && !contains(out, "hello")
        # pandocjl, the working directory mounted
        status, out, err = pandocjl("doc.md", "-t", "plain", "-F", "panclude"; dir = work,
                                    env = Dict("LIBPANDOC_SANDBOX" => ".", "LIBPANDOC_WASM_TIMEOUT" => "120"))
        @test status == 0 && contains(out, "hello *from the part*") && !contains(out * err, "CANARY")
    end
end
