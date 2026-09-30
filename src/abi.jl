# libpandoc's C ABI: results, errors, and filters as callbacks.

"""
    PandocError(kind, message)

A pandoc failure. `kind` is pandoc's error constructor, e.g.
`"PandocParseError"` or `"PandocUnknownReaderError"`; `message` is what the
pandoc command would print.
"""
struct PandocError <: Exception
    kind::String
    message::String
end

Base.showerror(io::IO, e::PandocError) = print(io, e.kind, ": ", e.message)

struct _Result
    status::Cint
    output::Ptr{UInt8}
    output_len::Csize_t
    error_kind::Ptr{UInt8}
    error_message::Ptr{UInt8}
    log::Ptr{UInt8}
end

_str(p::Ptr{UInt8}) = p == C_NULL ? "" : unsafe_string(p)

# A pandoc_result's parts (it is freed): status, output, error kind and
# message, log.
function _parts(p::Ptr{_Result})
    p == C_NULL && throw(OutOfMemoryError())
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
function _pinned(f)
    t = current_task()
    sticky = t.sticky
    if !sticky
        t.sticky = true
        ccall(:jl_set_task_tid, Cint, (Any, Cint), t, Threads.threadid() - 1)
    end
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
        msg = sprint(showerror, e)
        ccall(_load().buffer_set, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), out, msg, sizeof(msg))
        return Cint(1)
    end
end

struct _Filter
    fn::Ptr{Cvoid}
    userdata::Ptr{Cvoid}
end

const _ENTRY = Ref{Ptr{Cvoid}}(C_NULL)

"""
    FilterError(exception, backtrace)

Thrown when a Julia filter threw in a conversion that failed because of it:
the filter's exception, and where it was thrown. `showerror` shows both.
"""
struct FilterError <: Exception
    exception::Any
    backtrace::Any
end

function Base.showerror(io::IO, e::FilterError)
    print(io, "a filter failed: ")
    showerror(io, e.exception, e.backtrace)
end

# Call `f(filters::Vector{_Filter})` with the callbacks as libpandoc filters,
# alive meanwhile; a callback's exception is thrown after pandoc returns.
function _with_callbacks(f, cbs::Vector{_Callback})
    entry = _ENTRY[]
    fs = [_Filter(entry, pointer_from_objref(cb)) for cb in cbs]
    r = try
        GC.@preserve cbs fs _pinned(() -> f(fs))
    catch e
        for cb in cbs
            cb.error === nothing || throw(FilterError(cb.error...))
        end
        rethrow()
    end
    for cb in cbs
        cb.error === nothing || throw(FilterError(cb.error...))
    end
    r
end

# -- the calls -------------------------------------------------------------------------

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

function _convert_args(args::AbstractVector{<:AbstractString}, input)
    s = _load()
    inp = _bytes(input)
    inptr, inlen = inp === nothing ? (C_NULL, 0) : (pointer(inp), length(inp))
    argv = String.(args)
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
    s = _load()
    fj = filters_json === nothing ? C_NULL : pointer(filters_json)
    fjlen = filters_json === nothing ? 0 : sizeof(filters_json)
    ptrs = map(pointer, argv)
    _with_callbacks(cbs) do fs
        GC.@preserve argv ptrs filters_json fs begin
            fsptr = isempty(fs) ? C_NULL : pointer(fs)
            @ccall gc_safe = true $(s.main)(length(argv)::Cint, ptrs::Ptr{Ptr{UInt8}},
                fj::Ptr{UInt8}, fjlen::Csize_t, fsptr::Ptr{_Filter}, length(fs)::Csize_t)::Cint
        end
    end
end

# A call for a wasm filter: (output, log), or a PandocError.
_call_raw(kind::Symbol, json::String, input = nothing) =
    kind === :convert ? _convert(json, input; take = _take_raw) :
    kind === :read_many ? _read_many(json; take = _take_raw) : _query(json; take = _take_raw)
