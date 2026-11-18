# Consecutive filters of this process: one exchange with pandoc (a run), by
# default; "separate-filters" (`separate_filters = true`) or
# LIBPANDOC_SEPARATE_FILTERS=1 makes each its own.

const SEPARATE = P.SEPARATE_VAR
const CHAIN_SEEN = Any[]   # what the scripts below were given
hint(j) = " (its input is what filters[$j] wrote, unchecked: LIBPANDOC_SEPARATE_FILTERS=1 has pandoc check it)"

# a filter appending a paragraph
adding(text) = (d::Panir.Pandoc) -> (push!(d.blocks, Para(text)); nothing)
# filters recording the documents they were given (kept: so no two share an address)
recorder() = (seen = Panir.Pandoc[]; (seen, (d::Panir.Pandoc) -> (push!(seen, d); nothing)))
paras(out) = split(out)
const GARBLE = RawFilter((json, c) -> "{\"not\": \"a document\"}")
const LUA_ADD = "function Pandoc(doc) doc.blocks:insert(pandoc.Para('lua')); return doc end"

# the paragraphs of a conversion of "hi" to plain text, with `filters`
plain(filters; kw...) = paras(P.convert("hi"; to = "plain", filters, kw...))

# whether two Julia filters had one exchange
function one_exchange(; kw...)
    seen, rec = recorder()
    P.convert("hi"; to = "plain", filters = [rec, rec], kw...)
    seen[1] === seen[2]
end

# what a call threw
thrown(f) = try f(); nothing catch e; e end

@testset "consecutive filters" begin
withenv(SEPARATE => nothing) do
    @testset "one exchange" begin
        seen, rec = recorder()
        @test plain([rec, adding("a"), rec]) == ["hi", "a"] && seen[1] === seen[2]
        empty!(seen)
        @test plain([rec, adding("a"), rec]; separate_filters = true) == ["hi", "a"] && seen[1] !== seen[2]
        mktempdir() do d
            lua = joinpath(d, "add.lua")
            Base.write(lua, LUA_ADD)
            empty!(seen)
            @test plain([rec, lua, rec]) == ["hi", "lua"] && seen[1] !== seen[2]
            # typed, Lua, typed, typed: in order; the last two one exchange
            n = Ref(0)
            numbered(d::Panir.Pandoc) = (push!(seen, d); push!(d.blocks, Para("t$(n[] += 1)")); nothing)
            for separate in (false, true)
                empty!(seen); n[] = 0
                @test plain([numbered, lua, numbered, numbered]; separate_filters = separate) == ["hi", "t1", "lua", "t2", "t3"]
                @test (seen[2] === seen[3]) == !separate
            end
        end
        # a RawFilter between: its JSON parsed for the next
        empty!(seen)
        @test plain([rec, RawFilter((json, c) -> json), rec]) == ["hi"] && seen[1] !== seen[2]
    end

    @testset "scripts" begin
        mktempdir() do d
            # two scripts handing their filters over share the parsed document
            for name in ("a", "b")
                Base.write(joinpath(d, "$name.jl"), """
                    using Panir
                    f(d::Panir.Pandoc) = (push!(Main.CHAIN_SEEN, d); push!(d.blocks, Para("$name")); nothing)
                    run_filter(f)
                    """)
            end
            a, b = joinpath(d, "a.jl"), joinpath(d, "b.jl")
            seen, rec = recorder()
            @test plain([rec, a, b, rec]) == ["hi", "a", "b"]
            @test CHAIN_SEEN[1] === CHAIN_SEEN[2] === seen[1] === seen[2]
            empty!(CHAIN_SEEN); empty!(seen)
            @test plain([rec, a, b, rec]; separate_filters = true) == ["hi", "a", "b"]
            @test CHAIN_SEEN[1] !== CHAIN_SEEN[2] && seen[1] !== CHAIN_SEEN[1]
            # a script run as a subprocess is one on JSON
            sub = joinpath(d, "sub.jl")
            Base.write(sub, "# pandocjl: subprocess\nusing Panir\nrun_filter((d::Panir.Pandoc) -> (push!(d.blocks, Para(\"sub\")); nothing))")
            empty!(seen)
            @test plain([rec, sub, rec]) == ["hi", "sub"] && seen[1] !== seen[2]
        end
    end

    if !isempty(WASM)
        @testset "a mixed run" begin
            mktempdir() do d
                s = joinpath(d, "s.jl")
                Base.write(s, "using Panir\nrun_filter((d::Panir.Pandoc) -> (push!(d.blocks, Para(\"s\")); nothing))")
                # typed, wasm, typed, script, wasm, RawFilter, typed: upper
                # uppercases what came before it only
                fs = [adding("a"), wasm("upper"), adding("b"), s, WasmFilter(wasm("identity")),
                      RawFilter((json, c) -> json), adding("c")]
                want = ["HI", "A", "b", "s", "c"]
                @test plain(fs) == want
                @test plain(fs; separate_filters = true) == want
            end
        end
    end

    @testset "a failure names the filter" begin
        ran = Ref(false)
        late(d::Panir.Pandoc) = (ran[] = true; nothing)
        bad(d::Panir.Pandoc) = throw(KeyError("boom"))
        e = thrown(() -> plain([adding("a"), bad, late]))
        @test e isa FilterError && e.filter == 2 && e.input_from === nothing && e.exception == KeyError("boom")
        @test startswith(sprint(showerror, e), "filters[2]: a filter failed: KeyError")
        @test !ran[]
        mktempdir() do d
            lua = joinpath(d, "add.lua")
            Base.write(lua, LUA_ADD)
            for separate in (false, true)
                e = thrown(() -> plain([adding("a"), lua, adding("b"), bad]; separate_filters = separate))
                @test e isa FilterError && e.filter == 4
            end
        end
        e = thrown(() -> plain([adding("a"), RawFilter((json, c) -> error("raw boom"))]))
        @test e isa FilterError && e.filter == 2 && e.exception isa ErrorException
        # a time limit's error as it is (a script stopped as pandoc stops a JSON filter)
        mktempdir() do d
            slow = joinpath(d, "slow.jl")
            Base.write(slow, "# pandocjl: subprocess\nread(stdin); sleep(20)")
            e = thrown(() -> P.convert("x"; to = "plain", timeout = 1, filters = [adding("a"), slow]))
            @test e isa PandocError && istimeout(e)
        end
    end

    @testset "unchecked JSON: the hint, and the switch" begin
        ran = Ref(false)
        late(d::Panir.Pandoc) = (ran[] = true; nothing)
        e = thrown(() -> plain([GARBLE, late]))
        @test e isa FilterError && e.filter == 2 && e.input && e.input_from == 1 && !ran[]
        @test startswith(sprint(showerror, e), "filters[2]: what it was given could not be read" * hint(1) * ": ")
        # a RawFilter given it, failing on it
        reads = RawFilter((json, c) -> (JSON.parse(json)["blocks"]; json))
        e = thrown(() -> plain([GARBLE, reads]))
        @test e isa FilterError && e.filter == 2 && !e.input && e.input_from == 1
        @test startswith(sprint(showerror, e), "filters[2]: a filter failed" * hint(1) * ": ")
        # with the switch, pandoc refuses it after the first
        e = thrown(() -> plain([GARBLE, late]; separate_filters = true))
        @test e isa PandocError && contains(e.message, "invalid document") && !ran[]
        # pandoc checks the last answer of a run
        e = thrown(() -> plain([adding("a"), GARBLE]))
        @test e isa PandocError && contains(e.message, "invalid document")
        if !isempty(WASM)
            e = thrown(() -> plain([GARBLE, wasm("upper")]))
            @test e isa FilterError && e.filter == 2 && e.input_from == 1
            @test contains(sprint(showerror, e), hint(1) * ": ") &&
                  contains(sprint(showerror, e), "(it was given no directory: LIBPANDOC_WASM_DIRS)")
        end
    end

    @testset "the switch: the option, the variable" begin
        @test one_exchange()
        for (v, one) in ("" => true, "0" => true, "1" => false)
            withenv(SEPARATE => v) do
                @test one_exchange() == one
            end
        end
        # the option wins
        withenv(SEPARATE => "1") do
            @test one_exchange(; separate_filters = false)
        end
        withenv(SEPARATE => "0") do
            @test !one_exchange(; separate_filters = true)
        end
        @test P.convert("hi", Dict("to" => "plain", "separate-filters" => true, "filters" => [adding("a")])) == "hi\n\na\n"
        for v in ("yes", "true", "2", " 1")
            withenv(SEPARATE => v) do
                e = thrown(one_exchange)
                @test e isa ErrorException &&
                      e.msg == "LIBPANDOC_SEPARATE_FILTERS: 1 (each filter its own exchange with pandoc), or 0 or empty, not $(repr(v))"
                # read only for a call with filters; the option's value wins
                @test P.convert("hi"; to = "plain") == "hi\n"
                @test one_exchange(; separate_filters = false)
            end
        end
        withenv(SEPARATE => "yes") do
            @test thrown(one_exchange) isa ErrorException
        end
        e = thrown(() -> one_exchange(; separate_filters = "yes"))
        @test e isa PandocError && e.kind == "PandocOptionError" && e.message == "\"separate-filters\": true or false, not \"yes\""
        # not pandoc's (which refuses one it doesn't know); read_many takes it, and ignores it
        @test P.convert("hi"; to = "plain", separate_filters = true) == "hi\n"
        @test P.read("hi"; separate_filters = true) == P.read("hi")
        @test P.write(P.read("hi"), "plain"; separate_filters = false) == "hi\n"
        @test only(P.read_many(["hi"]; separate_filters = true)) == P.read("hi")
        # a filter is told the options without it
        told = Ref{Any}(nothing)
        f(d::Panir.Pandoc, ctx) = (told[] = ctx.conversion.options; nothing)
        P.convert("hi"; to = "plain", tab_stop = 3, separate_filters = false, filters = [f])
        @test told[]["tab-stop"] == 3 && !haskey(told[], "separate-filters")
    end

    @testset "cancelling between two" begin
        t = CancelToken()
        ran = Ref(false)
        stop(d::Panir.Pandoc) = (cancel!(t); nothing)
        late(d::Panir.Pandoc) = (ran[] = true; nothing)
        e = thrown(() -> P.convert("hi"; to = "plain", cancel = t, filters = [stop, late]))
        @test e isa PandocError && iscancelled(e) && !ran[]
    end
end

@testset "pandocjl: one callback per run" begin
    mktempdir() do d
        Base.write(joinpath(d, "a.jl"), "using Panir\nrun_filter((d::Panir.Pandoc) -> (push!(d.blocks, Para(\"a\")); nothing))")
        Base.write(joinpath(d, "add.lua"), LUA_ADD)
        Base.write(joinpath(d, "garble.jl"), "using LibPandoc, Panir\nrun_filter(RawFilter((json, c) -> \"{}\"))")
        ran(err) = [l[length("[INFO] Running filter ") + 1:end] for l in readlines(IOBuffer(err)) if startswith(l, "[INFO] Running filter ")]
        args = ("--verbose", "-t", "plain", "-F", "a.jl", "-F", "a.jl", "-L", "add.lua", "-F", "a.jl")
        status, out, err = pandocjl(args...; input = "hi", dir = d, env = Dict(SEPARATE => ""))
        @test status == 0 && paras(out) == ["hi", "a", "a", "lua", "a"]
        @test ran(err) == ["libpandoc:callback/0", "add.lua", "libpandoc:callback/1"]
        status, out, err = pandocjl(args...; input = "hi", dir = d, env = Dict(SEPARATE => "1"))
        @test status == 0 && paras(out) == ["hi", "a", "a", "lua", "a"]
        @test ran(err) == ["libpandoc:callback/0", "libpandoc:callback/1", "add.lua", "libpandoc:callback/2"]
        status, _, err = pandocjl("-t", "plain", "-F", "a.jl"; input = "hi", dir = d, env = Dict(SEPARATE => "yes"))
        @test status == 1 &&
              contains(err, "pandocjl: LIBPANDOC_SEPARATE_FILTERS: 1 (each filter its own exchange with pandoc), or 0 or empty, not \"yes\"")
        # without filters, not read
        status, out, _ = pandocjl("-t", "plain"; input = "hi", dir = d, env = Dict(SEPARATE => "yes"))
        @test status == 0 && out == "hi\n"
        # a failure names the filter, and the hint
        status, _, err = pandocjl("-t", "plain", "-F", "garble.jl", "-F", "a.jl"; input = "hi", dir = d,
                                  env = Dict(SEPARATE => ""))
        @test status == 83 && contains(err, "filters[2]: what it was given could not be read" * hint(1))
    end
end

@testset "the directory sandbox" begin
    withenv(SEPARATE => nothing) do
        mktempdir() do d
            box = (read = [d],)
            seen, rec = recorder()
            @test plain([rec, adding("a"), rec]; sandbox = box) == ["hi", "a"] && seen[1] === seen[2]
            empty!(seen)
            @test plain([rec, adding("a"), rec]; sandbox = box, separate_filters = true) == ["hi", "a"] &&
                  seen[1] !== seen[2]
            e = thrown(() -> plain([GARBLE, rec]; sandbox = box))
            @test e isa FilterError && e.filter == 2 && e.input_from == 1
            # pandocjl in it
            Base.write(joinpath(d, "a.jl"), "using Panir\nrun_filter((d::Panir.Pandoc) -> (push!(d.blocks, Para(\"a\")); nothing))")
            for (v, n) in ("" => 1, "1" => 2)
                status, out, err = pandocjl("--verbose", "-t", "plain", "-F", "a.jl", "-F", "a.jl"; input = "hi", dir = d,
                                            env = Dict(SEPARATE => v, "LIBPANDOC_SANDBOX" => d))
                @test status == 0 && paras(out) == ["hi", "a", "a"]
                @test count("[INFO] Running filter libpandoc:callback/", err) == n
            end
        end
    end
end
end
