# Cancelling calls (CancelToken, `cancel = token`; libpandoc 1.13's cancel
# tokens) and Ctrl-C: before, during and after a call, from another thread,
# with a filter running, in the directory sandbox, and SIGINT sent to a
# process converting a slow document.
#
# The slow input is libpandoc's test/cancel.c's: 100,000 '>' read as
# markdown, minutes of pandoc's time (a `timeout` bounds each use here, so
# that a cancel that doesn't work fails the test rather than hanging it).
#
# The token's tests don't depend on Ctrl-C's arrangement (a call made on
# thread 1 run in the default pool): the cancelling task naps on its own
# thread (`nap`), not on libuv's timers, which a call holding thread 1
# would hold up; it needs a thread other than the call's (the tests run
# with --threads=2).

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

# `s` seconds on this thread, without libuv's timers; a GC waits for it
# 10 ms at most (Libc.systemsleep doesn't let one run meanwhile)
nap(s) = (t = time() + s; while time() < t; Libc.systemsleep(0.01); GC.safepoint(); end)
cancel_after(t, s) = Threads.@spawn (nap(s); cancel!(t))

@testset "cancel" begin
    t = CancelToken()
    @test !iscancelled(t) && repr(t) == "CancelToken(cancelled = false)"
    cancel!(t)
    cancel!(t)   # (again: nothing more)
    @test iscancelled(t)
    @test_throws ArgumentError P.convert("x"; cancel = 1)

    # before: at once, and every call after (each function run once first:
    # a first call's compiling took over a second on a slow runner)
    doc = P.read("x")
    P.convert("x"); P.write(doc, "html"); P.read_many(["a", "b"])
    for f in (() -> P.convert(SLOW; timeout = LIMIT, cancel = t), () -> P.read("x"; cancel = t),
              () -> P.write(doc, "html"; cancel = t), () -> P.read_many(["a", "b"]; cancel = t))
        e, took = timed(f)
        @test iscancelled(e)
        @test took < 1
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
    # (cancelled from this task: the calls may fill the default pool)
    calls = [Threads.@spawn timed(() -> P.convert(SLOW; timeout = LIMIT, cancel = t))[1] for _ in 1:3]
    nap(1)
    cancel!(t)
    @test all(iscancelled ∘ fetch, calls)

    # a Julia filter running when the token is cancelled runs to its end; the
    # call then fails. A filter may cancel its own call's token.
    t = CancelToken()
    ran = Threads.Atomic{Bool}(false)
    slow_filter(d::Panir.Pandoc) = (nap(1); ran[] = true; nothing)
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
    # (the filter as the module names it: on Windows C:\x is /c/x)
    inside = replace(lua, '\\' => '/')
    Sys.iswindows() && (inside = "/$(lowercase(inside[1]))$(inside[3:end])")
    @test P.convert("x"; to = "html", sandbox) == "<p>x</p>\n"   # (the module compiled)
    for f in ((t) -> P.convert(SLOW; to = "html", sandbox, cancel = t),
              (t) -> P.convert("x"; to = "html", filters = [inside], sandbox, cancel = t))
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
    # cancelled once the call has begun but before the store is watched
    # (while the module loads): stopped when it is, with no time limit (no
    # clock moving the epoch after the cancel's own move)
    e, took = timed(() -> P._sandboxed_convert(Dict{String, Any}("to" => "html"), SLOW,
                                                P._sandbox_of(Dict("sandbox" => (read = String[], timeout = 0))), t))
    iscancelled(e) || @info "not cancelled" e
    @test iscancelled(e)
    @test took < 4
end

# Ctrl-C: SIGINT to a Julia process converting the slow document, timed
# from the signal to the line saying what the process caught, the package
# loaded and its call compiled before (a first load on a slow runner took
# seconds). Only where the arrangement is: Julia with an interactive thread
# (`julia`'s default since 1.12, `--threads=2`), POSIX (on Windows,
# `kill(p, SIGINT)` is no Ctrl-C).
const CTRL_C = """
    import LibPandoc
    Base.exit_on_sigint(EXIT)
    LibPandoc.convert("*x*"; to = "html", sandbox = SANDBOX)
    println("started"); flush(stdout)
    t0 = time()
    try
        LibPandoc.convert($(repr(SLOW)); to = "html", timeout = 8, sandbox = SANDBOX)
    catch e
        println("caught ", typeof(e), " ", round(time() - t0; digits = 2)); flush(stdout)
    end
    println(LibPandoc.convert("*x*"; to = "html"))
    """

# (process, the line after "started", the rest, seconds from the signal to that line)
function interrupted(threads, exit_on_sigint, sandbox = nothing; slow = false)
    code = replace(CTRL_C, "EXIT" => repr(exit_on_sigint), "SANDBOX" => repr(sandbox))
    flag = threads === nothing ? `` : `--threads=$threads`
    cmd = `$(Base.julia_cmd()) --startup-file=no $flag --project=$PROJECT -e $code`
    out = Pipe()
    p = withenv("JULIA_NUM_THREADS" => nothing) do
        Base.run(pipeline(cmd; stdout = out, stderr = devnull); wait = false)
    end
    close(out.in)
    @test readline(out) == "started"
    sleep(1)
    sent = time()
    kill(p, Base.SIGINT)
    line = readline(out)
    took = time() - sent
    rest = Base.read(out, String)
    wait(p)
    took < 4 || slow || @info "Ctrl-C took $(round(took; digits = 2)) s" threads exit_on_sigint sandbox line rest
    p, line, rest, took
end

if Sys.iswindows()
    @info "Ctrl-C: not tested on Windows (no way to send a child process Ctrl-C here)"
else
    @testset "Ctrl-C" begin
        # Julia's default threads, and --threads=2: the call stops at once,
        # InterruptException, and the library goes on
        for threads in (nothing, 2), sandbox in (nothing, (read = String[], timeout = LIMIT))
            p, line, rest, took = interrupted(threads, false, sandbox)
            @test success(p) && startswith(line, "caught InterruptException") && contains(rest, "<p><em>x</em></p>")
            @test took < 4
        end
        # with no interactive thread (--threads=1, or 2,0): the call takes
        # Ctrl-C when it returns (its time limit, 8 s); no crash
        p, line, rest, took = interrupted(1, false; slow = true)
        @test success(p) && startswith(line, "caught InterruptException") && took > 5
        # a script, which exits on SIGINT (Julia's default), with one thread
        # in the default pool (the call's): at once, the call cancelled
        # (Julia's exit waits for a task of its own in that pool)
        p, line, rest, took = interrupted(nothing, true)
        @test p.termsignal == Base.SIGINT && took < 4
        # pandocjl, a command (`julia -m`, which Julia leaves throwing
        # InterruptException): at once too
        mktempdir() do d
            Base.write(joinpath(d, "slow.md"), SLOW)
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc -t html slow.md -o slow.html`
            p = cd(() -> Base.run(pipeline(cmd; stderr = devnull); wait = false), d)
            sleep(10)
            sent = time()
            kill(p, Base.SIGINT)
            timedwait(() -> process_exited(p), 60) === :ok || kill(p, Base.SIGKILL)
            wait(p)
            @test p.termsignal == Base.SIGINT && time() - sent < 4
        end
    end
end
