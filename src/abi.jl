# libpandoc's C ABI: results, errors, and filters as callbacks.

"""
    PandocError(kind, message)

A pandoc failure. `kind` is pandoc's error constructor, e.g.
`"PandocParseError"` or `"PandocUnknownReaderError"`, `"Timeout"` for a
call stopped by its time limit ([`istimeout`](@ref)), `"Cancelled"` for one
stopped by its [`CancelToken`](@ref) ([`iscancelled`](@ref)), or `"Exception"`;
`message` is what the pandoc command would print.

```julia
try
    Pandoc.convert(text; timeout = 5)
catch e
    istimeout(e) || rethrow()
    ...
end
```
"""
struct PandocError <: Exception
    kind::String
    message::String
end

"""
    istimeout(e) -> Bool

Whether `e` is a `PandocError` of a call stopped by its time limit (kind
`"Timeout"`): the option `timeout`, or the directory sandbox's (`timeout`
in it, or `\$LIBPANDOC_WASM_TIMEOUT`). As libpandoc-rs's
`Error::is_timeout`.
"""
istimeout(e) = e isa PandocError && e.kind == "Timeout"

Base.showerror(io::IO, e::PandocError) = print(io, e.kind, ": ", e.message)

struct _Result
    status::Cint
    output::Ptr{UInt8}
    output_len::Csize_t
    error_kind::Ptr{UInt8}
    error_message::Ptr{UInt8}
    log::Ptr{UInt8}
end

# (a pandoc_result's strings: NUL-terminated, valid until it is freed)
_str(p::Ptr{UInt8}) = p == C_NULL ? "" : unsafe_string(p)

# A pandoc_result's parts (it is freed): status, output, error kind and
# message, log.
function _parts(p::Ptr{_Result})
    p == C_NULL && throw(OutOfMemoryError())
    # (p: libpandoc's, not NULL, laid out as _Result; its output is
    # output_len bytes, copied before it is freed below)
    r = unsafe_load(p)
    out = r.status == 0 ? copy(unsafe_wrap(Vector{UInt8}, r.output, r.output_len)) : UInt8[]
    kind, msg, log = _str(r.error_kind), _str(r.error_message), _str(r.log)
    ccall(_load().result_free, Cvoid, (Ptr{_Result},), p)
    r.status, out, isempty(kind) ? "Exception" : kind, msg, log
end

# The output of a pandoc_result, after reporting its log; a PandocError if
# it failed.
function _take(p::Ptr{_Result})
    status, out, kind, msg, log = _parts(p)
    _report(log)
    status == 0 || throw(PandocError(kind, msg))
    out
end

# (output, log) of a call, the log not reported (a wasm filter gets it);
# a PandocError if it failed.
function _take_raw(p::Ptr{_Result})
    status, out, kind, msg, log = _parts(p)
    status == 0 || throw(PandocError(kind, msg))
    out, isempty(log) ? "[]" : log
end

# pandoc's log messages as Julia's: warnings as `@warn`, the rest (every
# message is logged, whatever the verbosity) at debug level.
function _report(log::AbstractString)
    (isempty(log) || log == "[]") && return
    for m in JSON.parse(log)
        text = _render(m)
        level = get(m, "verbosity", "WARNING")
        if level == "WARNING"
            @warn text _group = :pandoc _file = nothing _line = nothing _module = LibPandoc
        elseif level == "ERROR"
            @error text _group = :pandoc _file = nothing _line = nothing _module = LibPandoc
        else
            @debug text _group = :pandoc _file = nothing _line = nothing _module = LibPandoc
        end
    end
end

function _render(m)
    haskey(m, "pretty") && return "[$(m["type"])] $(m["pretty"])"
    rest = ("$k: $v" for (k, v) in m if k ∉ ("type", "verbosity"))
    "[$(get(m, "type", ""))] " * join(rest, ", ")
end

_bytes(x::Nothing) = nothing
_bytes(x::AbstractString) = codeunits(String(x))
_bytes(x::AbstractVector{UInt8}) = x

# A foreign call that may call back into Julia. Its task stays on this OS
# thread meanwhile: pandoc returns to the thread that called it, so a filter
# that yields (to print, say) must not wake up on another. And while it
# yields, no other task on this thread may start such a call: that one's
# callbacks could yield too, and the two calls would then return to pandoc
# out of order. Calls without callbacks never yield, so need neither.
#
# The task is made sticky meanwhile (`Task.sticky`, what `@async` sets):
# Julia's scheduler puts a sticky task that yielded back on the thread it
# ran on. Julia has no documented call for this; the "threads" test (tasks
# of `Threads.@spawn` whose filter yields) crashes without it.
function _pinned(f)
    t = current_task()
    sticky = t.sticky
    t.sticky = true
    tid = Threads.threadid()
    l = tid <= length(_THREAD_LOCKS) ? _THREAD_LOCKS[tid] : nothing
    try
        l === nothing ? f() : @lock(l, f())
    finally
        t.sticky = sticky
    end
end

const _THREAD_LOCKS = ReentrantLock[]

# -- callbacks ---------------------------------------------------------------------

"""
A filter run by libpandoc's callback: `run(doc::String, context::Dict)`
returns the new document as JSON (a string or bytes). What it throws fails
the conversion, and is thrown again by the call into pandoc.
"""
mutable struct _Callback
    run::Any
    error::Any   # (exception, backtrace) if `run` threw
end
_Callback(run) = _Callback(run, nothing)

function _callback_entry(ud::Ptr{Cvoid}, doc::Ptr{UInt8}, doc_len::Csize_t,
                         ctx::Ptr{UInt8}, ctx_len::Csize_t, out::Ptr{Cvoid})::Cint
    # (ud: a _Callback _with_callbacks keeps alive for the call; doc and
    # ctx: libpandoc's, valid during this callback, copied here)
    cb = unsafe_pointer_to_objref(ud)::_Callback
    try
        d = unsafe_string(doc, doc_len)
        context = JSON.parse(unsafe_string(ctx, ctx_len))
        result = Base.invokelatest(cb.run, d, context)
        result isa AbstractString && (result = codeunits(String(result)))
        result = result::AbstractVector{UInt8}
        GC.@preserve result ccall(_load().buffer_set, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                                  out, result, length(result))
        return Cint(0)
    catch e
        cb.error = (e, catch_backtrace())
        msg = _message(e)
        ccall(_load().buffer_set, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), out, msg, sizeof(msg))
        return Cint(1)
    end
end

# An exception's message, for C: whatever its `showerror` does (it may
# throw itself), nothing unwinds into the caller's frames.
_message(e) = try
    sprint(showerror, e)
catch
    try "$(typeof(e)) (its showerror failed)" catch; "an exception" end
end

struct _Filter
    fn::Ptr{Cvoid}
    userdata::Ptr{Cvoid}
end

const _ENTRY = Ref{Ptr{Cvoid}}(C_NULL)

"""
    FilterError(exception, backtrace, filter, input_from, input)

Thrown when a filter of this process (a Julia function, a `RawFilter`, a
script, a wasm filter) threw in a conversion that failed because of it:
the filter's exception, and where it was thrown. `filter` is its place in
the `filters` given (from 1); `input` is true when it failed before it ran,
on what it was given, which Panir could not parse; `input_from`, when what it
failed on went unchecked from a filter on pandoc's JSON before it in the
same exchange with pandoc, that filter's place. `showerror` shows them all:
`filters[3]: a filter failed: ...`, and `(its input is what filters[2]
wrote, unchecked: LIBPANDOC_SEPARATE_FILTERS=1 has pandoc check it)`.
"""
struct FilterError <: Exception
    exception::Any
    backtrace::Any
    filter::Union{Nothing, Int}
    input_from::Union{Nothing, Int}
    input::Bool
end

FilterError(exception, backtrace) = FilterError(exception, backtrace, nothing, nothing, false)

function Base.showerror(io::IO, e::FilterError)
    e.filter === nothing || print(io, "filters[", e.filter, "]: ")
    print(io, e.input ? "what it was given could not be read" : "a filter failed")
    e.input_from === nothing ||
        print(io, " (its input is what filters[", e.input_from, "] wrote, unchecked: ",
              SEPARATE_VAR, "=1 has pandoc check it)")
    print(io, ": ")
    e.backtrace === nothing ? showerror(io, e.exception) : showerror(io, e.exception, e.backtrace)
end

# (pandoc's message for it: without the backtrace, which the call's
# FilterError has)
_message(e::FilterError) = invoke(_message, Tuple{Any}, FilterError(e.exception, nothing, e.filter, e.input_from, e.input))

# Call `f(filters::Vector{_Filter})` with the callbacks as libpandoc filters,
# alive meanwhile; a callback's exception is thrown after pandoc returns.
function _with_callbacks(f, cbs::Vector{_Callback})
    entry = _ENTRY[]
    fs = [_Filter(entry, pointer_from_objref(cb)) for cb in cbs]
    r = try
        GC.@preserve cbs fs _pinned(() -> f(fs))
    catch e
        for cb in cbs
            cb.error === nothing || throw(_filter_error(cb.error...))
        end
        rethrow()
    end
    for cb in cbs
        cb.error === nothing || throw(_filter_error(cb.error...))
    end
    r
end

# What a filter threw, as the call throws it: a FilterError (a run's,
# naming the filter, as it is), but a time limit's PandocError as it is (a
# script stopped as pandoc stops a JSON filter), and a cancel's (a call the
# filter made, stopped with its conversion, or a run stopped between two).
_filter_error(e, bt) = e isa FilterError || istimeout(e) || iscancelled(e) ? e : FilterError(e, bt)

# -- the calls -------------------------------------------------------------------------

# Julia's libuv puts the standard streams that are pipes in non-blocking
# mode (it duplicates fd 1 and 2 and sets FIONBIO on the copies, which share
# the flag with the originals). Code that writes to them as C does gives up
# at the first EAGAIN, when the pipe is full (64 KiB on Linux): a Lua
# filter's `io.stdout:write` returned nil and "Resource temporarily
# unavailable", the rest lost; a JSON filter inheriting standard error
# failed likewise (Python: BlockingIOError); WASI's inherited streams in the
# directory sandbox failed with "hardware fault". (GHC's runtime, pandoc's
# own output, waits.) So they are blocking while pandocjl's pandoc runs (the
# process is pandoc's command then) and while the sandbox's module does
# (which fails otherwise), as for any other program, and as they were once
# none runs. Julia's own writes to them meanwhile block too (the copies
# share the flag) rather than being queued.
#
# Not around a library call outside the sandbox: the streams are the
# program's, and one that reads its own standard output (`redirect_stdout()`,
# as test and documentation tools do) in a task of the thread the call holds
# would wait forever on a write the pipe can't hold (seen: 200,000 bytes
# from a Lua filter, and from one `print` of a Julia filter, which Julia
# writes whole when left alone; Lua's is cut either way). (Windows: no such
# mode.)
const _O_NONBLOCK = Sys.isapple() || Sys.isbsd() ? Cint(0x0004) : Cint(0x0800)
const _STD_LOCK = ReentrantLock()
const _STD_FLAGS = Cint[]   # the streams' flags before, while calls go on

function _blocking(f)
    Sys.iswindows() && return f()
    lock(_STD_LOCK) do
        isempty(_STD_FLAGS) || return push!(_STD_FLAGS, -1)   # (one more call)
        for fd in 0:2
            flags = @ccall fcntl(fd::Cint, 3::Cint)::Cint   # F_GETFL
            flags >= 0 && flags & _O_NONBLOCK != 0 && @ccall fcntl(fd::Cint, 4::Cint; (flags & ~_O_NONBLOCK)::Cint)::Cint   # F_SETFL
            push!(_STD_FLAGS, flags)
        end
    end
    try
        f()
    finally
        lock(_STD_LOCK) do
            length(_STD_FLAGS) > 3 && return pop!(_STD_FLAGS)
            for (fd, flags) in zip(0:2, _STD_FLAGS)
                flags >= 0 && flags & _O_NONBLOCK != 0 && @ccall fcntl(fd::Cint, 4::Cint; flags::Cint)::Cint
            end
            empty!(_STD_FLAGS)
        end
    end
end

function _convert(options::AbstractString, input, cbs::Vector{_Callback} = _Callback[]; take = _take)
    s = _load()
    inp = _bytes(input)
    inptr, inlen = inp === nothing ? (C_NULL, 0) : (pointer(inp), length(inp))
    isempty(cbs) && return GC.@preserve options inp take(
        @ccall gc_safe = true $(s.convert)(options::Cstring, sizeof(options)::Csize_t,
                                           inptr::Ptr{UInt8}, inlen::Csize_t)::Ptr{_Result})
    _with_callbacks(cbs) do fs
        GC.@preserve options inp _take(
            @ccall gc_safe = true $(s.convert_filters)(options::Cstring, sizeof(options)::Csize_t,
                inptr::Ptr{UInt8}, inlen::Csize_t, fs::Ptr{_Filter}, length(fs)::Csize_t)::Ptr{_Result})
    end
end

# Arguments for C, NUL-terminated (as Julia's strings are underneath): one
# with a NUL in it would end there, so it is refused.
function _argv(args)
    argv = String[a for a in args]
    any(a -> occursin('\0', a), argv) && throw(ArgumentError("an argument with a NUL in it: $(repr(first(filter(a -> occursin('\0', a), argv))))"))
    argv
end

function _convert_args(args::AbstractVector{<:AbstractString}, input)
    s = _load()
    inp = _bytes(input)
    inptr, inlen = inp === nothing ? (C_NULL, 0) : (pointer(inp), length(inp))
    argv = _argv(args)
    ptrs = map(pointer, argv)
    GC.@preserve argv ptrs inp _take(
        @ccall gc_safe = true $(s.convert_args)(length(argv)::Cint, ptrs::Ptr{Ptr{UInt8}},
                                                inptr::Ptr{UInt8}, inlen::Csize_t)::Ptr{_Result})
end

function _read_many(request::AbstractString; take = _take)
    s = _load()
    take(@ccall gc_safe = true $(s.read_many)(request::Cstring, sizeof(request)::Csize_t)::Ptr{_Result})
end

function _query(q::AbstractString; take = _take)
    s = _load()
    take(@ccall gc_safe = true $(s.query)(q::Cstring, sizeof(q)::Csize_t)::Ptr{_Result})
end

# pandoc_main: the exit status.
function _pandoc_main(argv::Vector{String}, filters_json::Union{Nothing, String}, cbs::Vector{_Callback})
    argv = _argv(argv)
    s = _load()
    fj = filters_json === nothing ? C_NULL : pointer(filters_json)
    fjlen = filters_json === nothing ? 0 : sizeof(filters_json)
    ptrs = map(pointer, argv)
    _with_callbacks(cbs) do fs
        GC.@preserve argv ptrs filters_json fs begin
            fsptr = isempty(fs) ? C_NULL : pointer(fs)
            _blocking(() -> @ccall gc_safe = true $(s.main)(length(argv)::Cint, ptrs::Ptr{Ptr{UInt8}},
                fj::Ptr{UInt8}, fjlen::Csize_t, fsptr::Ptr{_Filter}, length(fs)::Csize_t)::Cint)
        end
    end
end

# A call for a wasm filter: (output, log), or a PandocError.
_call_raw(kind::Symbol, json::String, input = nothing) =
    kind === :convert ? _convert(json, input; take = _take_raw) :
    kind === :read_many ? _read_many(json; take = _take_raw) : _query(json; take = _take_raw)
