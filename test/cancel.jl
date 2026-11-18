# Cancelling calls (CancelToken, `cancel = token`; libpandoc 1.13's cancel
# tokens, inside "untrusted" for untrusted options from 1.14) and Ctrl-C: before, during and after a call, from another thread,
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
    # (The token is cancelled once the filter is running, which waits to
    # see it cancelled and goes on to its end; not after a fixed time: on a
    # busy CI runner a call had not reached its filter by then and was
    # cancelled before it, seen in libpandoc-rs's twin of this test.)
    t = CancelToken()
    started, ran = Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false)
    until(f) = (stop = time() + LIMIT; while !f() && time() < stop; nap(0.01); end)
    slow_filter(d::Panir.Pandoc) = (started[] = true; until(() -> iscancelled(t)); nap(0.1); ran[] = true; nothing)
    c = Threads.@spawn (until(() -> started[]); cancel!(t))
    e, _ = timed(() -> P.convert("x"; to = "html", filters = [slow_filter], cancel = t))
    wait(c)
    @test iscancelled(e) && ran[]
    t = CancelToken()
    @test iscancelled(timed(() -> P.convert("x"; filters = [(d::Panir.Pandoc) -> (cancel!(t); nothing)], cancel = t))[1])

    # untrusted options take the host's token inside "untrusted" (libpandoc
    # 1.14): before, during, and a call that ends before it
    @test P.convert("*x*"; to = "html", untrusted = true) == "<p><em>x</em></p>\n"
    @test P.convert("*x*"; to = "html", untrusted = true, cancel = CancelToken()) == "<p><em>x</em></p>\n"
    t = CancelToken()
    cancel!(t)
    for f in (() -> P.convert(SLOW; timeout = LIMIT, untrusted = true, cancel = t),
              () -> P.read_many(["a", "b"]; untrusted = true, cancel = t))
        e, took = timed(f)
        @test iscancelled(e) && took < 1
    end
    for f in ((t) -> P.convert(SLOW; timeout = LIMIT, untrusted = true, cancel = t),
              (t) -> P.read_many([SLOW, "x"]; timeout = LIMIT, untrusted = true, cancel = t))
        t = CancelToken()
        c = cancel_after(t, 1)
        e, took = timed(() -> f(t))
        wait(c)
        @test iscancelled(e)
        @test took < 4
    end
    # what the host writes: inside "untrusted" (true, or an object), over a
    # token of the code's own; any other value left for libpandoc to refuse
    t = CancelToken()
    @test P._with_token(Dict{String, Any}("untrusted" => true), t)["untrusted"] == Dict("cancel-token" => t.id)
    o = P._with_token(Dict{String, Any}("untrusted" => Dict("cancel-token" => 0)), t)
    @test o["untrusted"] == Dict("cancel-token" => t.id) && !haskey(o, "cancel-token")
    @test P._with_token(Dict{String, Any}("untrusted" => false), t)["cancel-token"] == t.id
    @test P._with_token(Dict{String, Any}(), t)["cancel-token"] == t.id
    e, _ = timed(() -> P.convert("*x*"; untrusted = 1, cancel = t))
    @test e isa PandocError && e.kind == "PandocOptionError"
    # a token beside "untrusted" is still refused (the code could have written it)
    for u in (true, Dict(), Dict("cancel-token" => t.id))
        e, _ = timed(() -> P.convert("*x*", Dict("untrusted" => u, "cancel-token" => t.id)))
        @test e isa PandocError && e.kind == "PandocOptionError" && contains(e.message, "cancel-token")
    end
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
    # untrusted options: the token stops the module as well (it is never in
    # the options the module gets); one beside "untrusted" is refused, as
    # natively
    t = CancelToken()
    c = cancel_after(t, 1)
    e, took = timed(() -> P.convert(SLOW; to = "html", sandbox, untrusted = true, cancel = t))
    wait(c)
    @test iscancelled(e) && took < 4
    @test P.convert("*x*"; to = "html", sandbox, untrusted = true, cancel = CancelToken()) == "<p><em>x</em></p>\n"
    e, _ = timed(() -> P.convert("x", Dict("sandbox" => sandbox, "untrusted" => true, "cancel-token" => CancelToken().id)))
    @test e isa PandocError && e.kind == "PandocOptionError" && contains(e.message, "cancel-token")
    # a Julia filter running when the token is cancelled runs to its end, and
    # the call then fails: once `iscancelled` is true the module is stopped
    # when the filter returns, not at the epoch's next tick (no time limit:
    # only the cancel advances the epoch). The filter may cancel the token.
    unlimited = (read = String[], timeout = 0)
    t = CancelToken()
    started, ran = Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false)
    until(f) = (stop = time() + LIMIT; while !f() && time() < stop; nap(0.01); end)
    slow_filter(d::Panir.Pandoc) = (started[] = true; until(() -> iscancelled(t)); nap(0.1); ran[] = true; nothing)
    c = Threads.@spawn (until(() -> started[]); cancel!(t))
    e, _ = timed(() -> P.convert("x"; to = "html", filters = [slow_filter], sandbox = unlimited, cancel = t))
    wait(c)
    @test iscancelled(e) && ran[]
    t = CancelToken()
    @test iscancelled(timed(() -> P.convert("x"; filters = [(d::Panir.Pandoc) -> (cancel!(t); nothing)],
                                            sandbox = unlimited, cancel = t))[1])
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
# loaded and its call compiled before. The arrangement is an interactive
# session's (`-i`) with an interactive thread (`julia`'s default since
# 1.12, `--threads=2`). POSIX only (on Windows, `kill(p, SIGINT)` is no
# Ctrl-C).
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

# Ctrl-C to `p`; when it was sent. For a process that exits on it (`exits`),
# on macOS, a second one 3 s later if the process is still running, as a
# user would: Julia's exit on Ctrl-C takes thread 1 over wherever it is and
# "can get stuck" (its signals-unix.c; it ends the process itself at a
# second request). Seen once on macOS in CI: a script went on to its call's
# end. Not elsewhere: on Linux a miss would be this package's (a call run
# off thread 1 hung that exit).
function ctrl_c(p; exits = false)
    sent = time()
    kill(p, Base.SIGINT)
    if exits && Sys.isapple() && timedwait(() -> process_exited(p), 3) !== :ok
        @info "Ctrl-C: sent again, the first did not end the process"
        sent = time()
        kill(p, Base.SIGINT)
    end
    sent
end

# (process, the line after "started", the rest, seconds from the signal to that line)
function interrupted(threads, exit_on_sigint, sandbox = nothing; interactive = true, slow = false)
    code = replace(CTRL_C, "EXIT" => repr(exit_on_sigint), "SANDBOX" => repr(sandbox))
    flag = threads === nothing ? `` : `--threads=$threads`
    i = interactive ? `-i --banner=no` : ``
    cmd = `$(Base.julia_cmd()) --startup-file=no $flag $i --project=$PROJECT -e $code`
    out = Pipe()
    p = withenv("JULIA_NUM_THREADS" => nothing) do
        Base.run(pipeline(cmd; stdin = devnull, stdout = out, stderr = devnull); wait = false)
    end
    close(out.in)
    @test readline(out) == "started"
    sleep(1)
    # (one still running a minute later is killed: the test fails, not hangs)
    Timer(_ -> process_running(p) && kill(p, Base.SIGKILL), 60)
    sent = ctrl_c(p; exits = exit_on_sigint && !interactive)
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
        # Ctrl-C when it returns (its time limit, 8 s; which of the two the
        # process then catches, or whether one comes after its catch, is
        # Julia's timing); no crash
        p, line, rest, took = interrupted(1, false; slow = true)
        @test p.termsignal == 0 && took > 5
        # a script, which exits on SIGINT (Julia's default), its call on
        # thread 1: at once
        p, line, rest, took = interrupted(nothing, true; interactive = false)
        @test p.termsignal == Base.SIGINT && took < 4
        # not interactive (`-e`, a script) with exit_on_sigint(false): the
        # call takes Ctrl-C when it returns
        p, line, rest, took = interrupted(nothing, false; interactive = false, slow = true)
        @test p.termsignal == 0 && took > 5
        # pandocjl, a command (`julia -m`, which Julia leaves throwing
        # InterruptException): at once too
        mktempdir() do d
            Base.write(joinpath(d, "slow.md"), SLOW)
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc -t html slow.md -o slow.html`
            p = cd(() -> Base.run(pipeline(cmd; stderr = devnull); wait = false), d)
            sleep(10)
            sent = ctrl_c(p; exits = true)
            timedwait(() -> process_exited(p), 60) === :ok || kill(p, Base.SIGKILL)
            wait(p)
            @test p.termsignal == Base.SIGINT && time() - sent < 4
        end
    end
end
