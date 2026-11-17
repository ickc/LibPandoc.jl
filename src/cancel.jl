# Cancelling calls: CancelToken (libpandoc 1.13's cancel tokens), and
# Ctrl-C.
#
# Thread 1 runs the main task (a script's, the REPL's) and libuv's loop,
# which wakes every task's timers, sleeps and IO; Julia throws Ctrl-C as an
# InterruptException into the task on thread 1, at its next safepoint. A
# call into pandoc made there holds thread 1 until it returns: no timer
# fires meanwhile, in any task (a `Timer` meant to cancel it included), and
# Ctrl-C takes effect when it returns. So when thread 1 is Julia's
# interactive thread (Julia's default since 1.12: `julia`, and
# `--threads=N`, start one interactive thread, thread 1, beside the default
# pool; NEWS for 1.12), a call made there runs in the default pool
# (`Threads.@spawn`, which runs a task on that pool's threads only) while
# the caller waits: Ctrl-C reaches the caller, which cancels the call's
# token (one of its own if not given one), waits for the call to stop, and
# throws the InterruptException on. Julia filters of such a call run in that
# task, which inherits the caller's scoped values and logger. Without an
# interactive thread (`--threads=1`, `--threads=N,0`: thread 1 in the
# default pool, where the spawned call could run on thread 1 itself) the
# call runs where it is made, and Ctrl-C takes effect when it returns.
# Public API only (the threadpools, `Threads.@spawn`, `wait`, `Timer`,
# `atexit`).

"""
    CancelToken()

A way to stop calls while they run: give it as `cancel = token` to
[`convert`](@ref), [`read`](@ref), [`write`](@ref) or [`read_many`](@ref)
(any number of calls, one after another or at once), and [`cancel!`](@ref)
it from another task or thread, or from a filter of the call. Each call
using it then throws a `PandocError` of kind `"Cancelled"`
([`iscancelled`](@ref)), as one past its `timeout` throws one of kind
`"Timeout"`, and the process goes on. A token stays cancelled: a call given
it later fails at once.

It stops what `timeout` stops: pandoc's own code and the JSON filters
pandoc runs, and in the directory sandbox the whole of pandoc, Lua included
(the module is stopped from outside, by wasmtime's epoch); not a Julia
filter running (it runs to its end, and the call then fails), nor Lua
outside the sandbox. A call that finished before the cancel keeps its
result. `untrusted` options take none (libpandoc's rule).

```julia
token = CancelToken()
Timer(_ -> cancel!(token), 5)          # a cancel button, a deadline
LibPandoc.convert(text; to = "html", cancel = token)
```

A call holding thread 1 holds up every timer in the process: where a call
is made on thread 1 with no interactive thread (`julia --threads=1`), cancel
it from another thread, not with a `Timer`.

Ctrl-C stops a call made on thread 1 (the REPL's, a script's) when thread 1
is Julia's interactive thread (`julia`'s default, and `--threads=N`): an
`InterruptException`. See the README's "Ctrl-C".
"""
mutable struct CancelToken
    id::Int64
    @atomic cancelled::Bool
    function CancelToken()
        id = ccall(_load().cancel_token_new, Int64, ())
        id > 0 || error("no cancel token: pandoc's runtime isn't running")
        finalizer(_free!, new(id, false))
    end
end

Base.show(io::IO, t::CancelToken) = print(io, "CancelToken(cancelled = ", iscancelled(t), ")")

"""
    cancel!(token::CancelToken)

Stop every call using `token`, running or to come. From any task or thread
(not a raw signal handler's C code).
"""
function cancel!(t::CancelToken)
    @atomic t.cancelled = true
    t.id > 0 && ccall(_load().cancel, Cint, (Int64,), t.id)
    _interrupt()
    nothing
end

"""
    iscancelled(token::CancelToken) -> Bool
    iscancelled(e) -> Bool

Whether `cancel!(token)` was called; whether `e` is a `PandocError` of a
call stopped by its token (kind `"Cancelled"`), as libpandoc-rs's
`is_cancelled`.
"""
iscancelled(t::CancelToken) = @atomic t.cancelled
iscancelled(e) = e isa PandocError && e.kind == "Cancelled"

# Forget the token now (freed once: the finalizer, or the end of the call
# whose own token it was).
function _free!(t::CancelToken)
    id, t.id = t.id, 0
    id > 0 && @ccall gc_safe = true $(_load().cancel_token_free)(id::Int64)::Cvoid
    nothing
end

const _CANCELLED = "the call was cancelled"

# The options with libpandoc's "cancel-token" for `t`. Not "untrusted" ones
# with Ctrl-C's own token: libpandoc takes no token in options from code it
# doesn't trust (a token given with them is its error).
function _with_token(opts, t, own::Bool)
    t === nothing && return opts
    own && get(opts, "untrusted", false) == true && return opts
    merge(opts, Dict{String, Any}("cancel-token" => t.id))
end

# Whether a call made here runs in the default pool while this task waits
# (above): on thread 1, when it is Julia's interactive thread.
_elsewhere() = Threads.threadid() == 1 && Threads.threadpool() === :interactive && Threads.nthreads(:default) > 0

# The tokens of the calls running in the default pool for thread 1, once
# each: cancelled when the process exits (`_on_exit`).
const _AWAY = CancelToken[]
const _AWAY_LOCK = ReentrantLock()

# An exit hook, run before Base's (hooks run last in, first out): Julia's
# exit waits for a task of Base's in the default pool (its profile
# listener's), which with one thread there (`julia`'s default) runs only
# when a call in it returns. So a script's Ctrl-C, or `exit()` from another
# task, would wait for the call; the calls are cancelled instead.
function _on_exit()
    @lock _AWAY_LOCK foreach(cancel!, _AWAY)
    nothing
end

"""
`f(token, own)`, a call into pandoc, stopped by `cancel` (a CancelToken or
nothing) and, on thread 1 when Julia has an interactive thread, by Ctrl-C:
there it runs in the default pool, with a token of its own if not given one
(`own`), while this task waits.
"""
function _interruptible(f, cancel)
    cancel === nothing || cancel isa CancelToken ||
        throw(ArgumentError("cancel: a CancelToken, not $(repr(cancel))"))
    cancel !== nothing && iscancelled(cancel) && throw(PandocError("Cancelled", _CANCELLED))
    _elsewhere() || return f(cancel, false)
    own = cancel === nothing
    t = own ? CancelToken() : cancel
    result, failed = Ref{Any}(nothing), Ref{Any}(nothing)
    # The caller wakes every 50 ms meanwhile and runs: Julia throws Ctrl-C
    # into the task on thread 1 at its next safepoint, which a task asleep
    # in `wait` may not reach until something wakes it (seen: with nothing
    # to wake it, Ctrl-C came when the call ended, 18 s later; with a timer
    # it didn't wait on, at once but once, on macOS, at the end). The call
    # closes the timer when it ends, which wakes the caller at once.
    awake = Timer(0.05; interval = 0.05)
    @lock _AWAY_LOCK push!(_AWAY, t)
    task = Threads.@spawn try
        result[] = f(t, own)
    catch e
        failed[] = e
    finally
        close(awake)
    end
    try
        while !istaskdone(task)
            isopen(awake) || (wait(task); break)
            try
                wait(awake)
            catch
                isopen(awake) && rethrow()   # (not the call's end: Ctrl-C)
            end
        end
    catch
        # Ctrl-C (or anything thrown at this task): the call stopped, then
        # thrown on
        cancel!(t)
        while !istaskdone(task)
            try
                wait(task)
            catch
            end
        end
        rethrow()
    finally
        close(awake)
        @lock _AWAY_LOCK deleteat!(_AWAY, findfirst(x -> x === t, _AWAY))
        own && _free!(t)
    end
    failed[] === nothing || throw(failed[])
    result[]
end
