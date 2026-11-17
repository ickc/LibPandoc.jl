# Cancelling calls: CancelToken (libpandoc 1.13's cancel tokens), and
# Ctrl-C.
#
# Ctrl-C: Julia delivers SIGINT as an InterruptException to the task on
# thread 1 (the REPL's, a script's main task), at its next safepoint; a task
# inside a foreign call reaches none until the call returns, so a long
# conversion took Ctrl-C only when it ended (in a script, which exits on
# SIGINT, the process ended at once). So a call made on thread 1, when the
# process has another thread, runs on that one (a task pinned there) while
# the caller waits, where the InterruptException arrives: it cancels the
# call's token, waits for the call to stop, and throws it on. The caller
# wakes every 0.1 s meanwhile (a timer): a task asleep in `wait` on a quiet
# thread 1 took the InterruptException only when the call ended (seen in a
# script; the REPL's thread wakes by itself). Julia filters
# then run on that thread, in a task that inherits the caller's scope and
# logger. With one thread there is nowhere else to run: Ctrl-C takes effect
# when the call returns, as before.

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

Ctrl-C stops a call made on thread 1 (the REPL's, a script's) when Julia
has another thread to run it on (`julia --threads=2`, or the REPL's default
of one default and one interactive thread): an `InterruptException`. In a
script Julia exits on Ctrl-C anyway.
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

# Another thread to run thread 1's call on, preferring the default pool;
# nothing when the caller isn't on thread 1, or there is none, or while
# precompiling.
function _other_thread()
    Threads.threadid() == 1 || return nothing
    # (not on Windows: the test run hung there in CI with this arrangement,
    # cause not found; Ctrl-C then takes effect when the call returns)
    Sys.iswindows() && return nothing
    ccall(:jl_generating_output, Cint, ()) == 0 || return nothing
    others = 2:Threads.maxthreadid()
    i = findfirst(t -> Threads.threadpool(t) === :default, others)
    i === nothing ? (isempty(others) ? nothing : first(others)) : others[i]
end

"""
`f(token, own)`, a call into pandoc, stopped by `cancel` (a CancelToken or
nothing) and, on thread 1, by Ctrl-C: there it runs on another thread, with
a token of its own if not given one (`own`), while this task waits.
"""
function _interruptible(f, cancel)
    cancel === nothing || cancel isa CancelToken ||
        throw(ArgumentError("cancel: a CancelToken, not $(repr(cancel))"))
    cancel !== nothing && iscancelled(cancel) && throw(PandocError("Cancelled", _CANCELLED))
    other = _other_thread()
    other === nothing && return f(cancel, false)
    own = cancel === nothing
    t = own ? CancelToken() : cancel
    result, failed = Ref{Any}(nothing), Ref{Any}(nothing)
    ended = Base.Event(true)
    task = Task() do
        try
            result[] = f(t, own)
        catch e
            failed[] = e
        finally
            notify(ended)
        end
    end
    task.sticky = true
    ccall(:jl_set_task_tid, Cint, (Any, Cint), task, other - 1)
    awake = nothing
    try
        schedule(task)
        try
            # (a short call ends before the timer is set, the caller
            # spinning for its first millisecond: thread 1 waiting with a
            # timer set wakes more slowly, 40 µs more a call)
            ready = time_ns() + 1_000_000
            while !istaskdone(task) && time_ns() < ready
                GC.safepoint()
                ccall(:jl_cpu_pause, Cvoid, ())
            end
            istaskdone(task) || (awake = Timer(_ -> notify(ended), 0.1; interval = 0.1))
            while !istaskdone(task)
                wait(ended)
            end
        catch
            # Ctrl-C (or anything thrown at this task): the call stopped,
            # then thrown on
            cancel!(t)
            while !istaskdone(task)
                try
                    wait(task)
                catch
                end
            end
            rethrow()
        end
    finally
        awake === nothing || close(awake)
        own && _free!(t)
    end
    failed[] === nothing || throw(failed[])
    result[]
end
