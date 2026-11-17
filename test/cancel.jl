# Cancelling calls (CancelToken, `cancel = token`; libpandoc 1.13's cancel
# tokens) and Ctrl-C: before, during and after a call, from another task,
# with a filter running, in the directory sandbox, and SIGINT sent to a
# process converting a slow document.
#
# The slow input is libpandoc's test/cancel.c's: 100,000 '>' read as
# markdown, minutes of pandoc's time (a `timeout` bounds each use here, so
# that a cancel that doesn't work fails the test rather than hanging it).

const SLOW = ">"^100_000
const LIMIT = 60

# what `f()` threw, and how long it took
function timed(f)
    t = time()
    e = try
        f()
        nothing
    catch e
        e
    end
    e, time() - t
end

cancel_after(t, s) = Threads.@spawn (sleep(s); cancel!(t))

@testset "cancel" begin
    t = CancelToken()
    @test !iscancelled(t) && repr(t) == "CancelToken(cancelled = false)"
    cancel!(t)
    cancel!(t)   # (again: nothing more)
    @test iscancelled(t)
    @test_throws ArgumentError P.convert("x"; cancel = 1)

    # before: at once, and every call after
    for f in (() -> P.convert(SLOW; timeout = LIMIT, cancel = t), () -> P.read("x"; cancel = t),
              () -> P.write(P.read("x"), "html"; cancel = t), () -> P.read_many(["a", "b"]; cancel = t))
        e, took = timed(f)
        @test iscancelled(e) && took < 1
    end

    # during, from another task: within about a second (the runtime
    # switches threads every 20 ms), and the library goes on
    long = Panir.Pandoc(Panir.Meta(), [Para([Str("x"), Space(), Emph([Str("y")])]) for _ in 1:200_000])
    for f in ((t) -> P.convert(SLOW; timeout = LIMIT, cancel = t),
              (t) -> P.read(SLOW; timeout = LIMIT, cancel = t),
              (t) -> P.write(long, "docx"; timeout = LIMIT, cancel = t),
              (t) -> P.read_many([SLOW, "x"]; timeout = LIMIT, cancel = t),
              (t) -> P.convert(SLOW; timeout = LIMIT, cancel = t, filters = [(d::Panir.Pandoc) -> nothing]))
        t = CancelToken()
        c = cancel_after(t, 1)
        e, took = timed(() -> f(t))
        wait(c)
        @test iscancelled(e)
        @test took < 4
    end
    @test P.convert("*x*"; to = "html") == "<p><em>x</em></p>\n"

    # after: a finished call keeps its result; the next one fails
    t = CancelToken()
    @test P.convert("*x*"; to = "html", cancel = t) == "<p><em>x</em></p>\n"
    cancel!(t)
    @test iscancelled(timed(() -> P.convert("*x*"; cancel = t))[1])

    # one token for calls at once: cancelled, it stops them all
    t = CancelToken()
    calls = [Threads.@spawn timed(() -> P.convert(SLOW; timeout = LIMIT, cancel = t))[1] for _ in 1:3]
    sleep(1)
    cancel!(t)
    @test all(iscancelled ∘ fetch, calls)

    # a Julia filter running when the token is cancelled runs to its end; the
    # call then fails. A filter may cancel its own call's token.
    t = CancelToken()
    ran = Threads.Atomic{Bool}(false)
    slow_filter(d::Panir.Pandoc) = (sleep(1); ran[] = true; nothing)
    c = cancel_after(t, 0.2)
    e, took = timed(() -> P.convert("x"; to = "html", filters = [slow_filter], cancel = t))
    wait(c)
    @test iscancelled(e) && ran[] && took >= 1
    t = CancelToken()
    @test iscancelled(timed(() -> P.convert("x"; filters = [(d::Panir.Pandoc) -> (cancel!(t); nothing)], cancel = t))[1])

    # libpandoc takes no token in options from code it doesn't trust: one
    # given is its error; Ctrl-C's own token isn't given them
    @test P.convert("*x*"; to = "html", untrusted = true) == "<p><em>x</em></p>\n"
    e, _ = timed(() -> P.convert("*x*"; untrusted = true, cancel = CancelToken()))
    @test e isa PandocError && contains(e.message, "cancel-token")
end

@testset "cancel: the directory sandbox" begin
    # the token stops libpandoc.wasm from outside (wasmtime's epoch): pandoc,
    # and Lua, which nothing stops natively
    d = realpath(mktempdir())
    lua = joinpath(d, "forever.lua")
    Base.write(lua, "function Pandoc(doc) while true do end end\n")
    sandbox = (read = [d], timeout = LIMIT)
    @test P.convert("x"; to = "html", sandbox) == "<p>x</p>\n"   # (the module compiled)
    for f in ((t) -> P.convert(SLOW; to = "html", sandbox, cancel = t),
              (t) -> P.convert("x"; to = "html", filters = [lua], sandbox, cancel = t))
        t = CancelToken()
        c = cancel_after(t, 1)
        e, took = timed(() -> f(t))
        wait(c)
        @test iscancelled(e)
        @test took < 4
    end
    t = CancelToken()
    cancel!(t)
    @test iscancelled(timed(() -> P.convert("x"; sandbox, cancel = t))[1])
end

# Ctrl-C: SIGINT to a Julia process converting the slow document. (POSIX)
const CTRL_C = """
    import LibPandoc
    Base.exit_on_sigint(EXIT)
    println("started"); flush(stdout)
    t0 = time()
    try
        LibPandoc.convert($(repr(SLOW)); to = "html", timeout = 20, sandbox = SANDBOX)
    catch e
        println("caught ", typeof(e), " ", round(time() - t0; digits = 2)); flush(stdout)
    end
    println(LibPandoc.convert("*x*"; to = "html"))
    """

function interrupted(threads, exit_on_sigint, sandbox = nothing)
    code = replace(CTRL_C, "EXIT" => repr(exit_on_sigint), "SANDBOX" => repr(sandbox))
    cmd = `$(Base.julia_cmd()) --startup-file=no --threads=$threads --project=$PROJECT -e $code`
    out = Pipe()
    p = Base.run(pipeline(cmd; stdout = out, stderr = devnull); wait = false)
    close(out.in)
    @test readline(out) == "started"
    sleep(sandbox === nothing ? 2 : 4)
    sent = time()
    kill(p, Base.SIGINT)
    rest = Base.read(out, String)
    wait(p)
    p, rest, time() - sent
end

if !Sys.iswindows()
    @testset "Ctrl-C" begin
        # with another thread: the call stops at once, InterruptException,
        # and the library goes on
        for sandbox in (nothing, (read = String[], timeout = LIMIT))
            p, out, took = interrupted(2, false, sandbox)
            @test success(p) && startswith(out, "caught InterruptException") && contains(out, "<p><em>x</em></p>")
            @test took < 4
        end
        # with one thread: nowhere else to run it, it takes Ctrl-C when it
        # returns (its 20 s), as before; no crash
        p, out, took = interrupted(1, false)
        @test success(p) && startswith(out, "caught InterruptException") && took > 10
        # a script, which exits on SIGINT (Julia's default): at once
        p, out, took = interrupted(2, true)
        @test p.termsignal == Base.SIGINT && took < 4
    end
end
