# Filters compiled to WebAssembly, run in process by wasmtime (its C API,
# from Wasmtime_jll).
#
# A wasm filter is a pandoc JSON filter built for WASI (`wasm32-wasip1`):
# the document on stdin, the new one on stdout, the output format as its
# first argument, pandoc's variables in its environment. It runs sandboxed:
# it sees only the directories it is given (the current one, read-only, by
# default), no network. It may call pandoc through the imports of module
# `libpandoc` (libpandoc-rs's `guest.rs`), which this host answers on this
# process's pandoc, marked `"untrusted": true`: libpandoc then allows pandoc's
# sandbox only, and no options that read or write files, fetch or run anything
# (its list, which every host shares).

const libwasmtime = Wasmtime_jll.libwasmtime

struct _Vec              # wasm_byte_vec_t, wasm_name_t, wasm_message_t
    size::Csize_t
    data::Ptr{UInt8}
end

struct _Extern           # wasmtime_extern_t: a kind, then a 24-byte union
    kind::UInt8
    of::NTuple{3, UInt64}   # wasmtime_memory_t is 24 bytes; wasmtime_func_t the first 16
end

const _EXTERN_FUNC = 0x00
const _EXTERN_MEMORY = 0x03
const _WASM_I32 = 0x00

function _vec_string(v::Ref{_Vec})
    s = v[].size == 0 ? "" : unsafe_string(v[].data, v[].size)
    @ccall libwasmtime.wasm_byte_vec_delete(v::Ptr{_Vec})::Cvoid
    rstrip(s, '\0')
end

function _error_message(err::Ptr{Cvoid})
    v = Ref(_Vec(0, C_NULL))
    @ccall libwasmtime.wasmtime_error_message(err::Ptr{Cvoid}, v::Ptr{_Vec})::Cvoid
    _vec_string(v)
end

_error_delete(err) = @ccall libwasmtime.wasmtime_error_delete(err::Ptr{Cvoid})::Cvoid

function _check(err::Ptr{Cvoid}, what)
    err == C_NULL && return
    msg = _error_message(err)
    _error_delete(err)
    error("$what: $msg")
end

function _trap_message(trap::Ptr{Cvoid})
    v = Ref(_Vec(0, C_NULL))
    @ccall libwasmtime.wasm_trap_message(trap::Ptr{Cvoid}, v::Ptr{_Vec})::Cvoid
    @ccall libwasmtime.wasm_trap_delete(trap::Ptr{Cvoid})::Cvoid
    _vec_string(v)
end

# -- a filter ------------------------------------------------------------------------

"""
    WasmFilter(path; dirs = ["." => "."], writable = false)

A wasm filter: a pandoc JSON filter built for WASI (`wasm32-wasip1`), such
as a panir Rust filter, run in this process by wasmtime, sandboxed. It
sees the directories `dirs` (host => guest; by default the current one,
read-only unless `writable`), no network, and pandoc's filter variables.
It may call pandoc (libpandoc-rs's `libpandoc` crate built for wasm): in
pandoc's sandbox, with options that name no files.

Compiled once (and cached on disk by wasmtime); a fresh instance per run.
In `filters`, a path ending in `.wasm` is one too.
"""
mutable struct WasmFilter
    name::String
    mod::Ptr{Cvoid}
    dirs::Vector{Pair{String, String}}
    writable::Bool
    function WasmFilter(path::AbstractString; dirs = ["." => "."], writable::Bool = false)
        w = _wasmtime()
        bytes = Base.read(path)
        mod = Ref{Ptr{Cvoid}}(C_NULL)
        err = @ccall libwasmtime.wasmtime_module_new(w.engine::Ptr{Cvoid}, bytes::Ptr{UInt8},
                                                     length(bytes)::Csize_t, mod::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
        _check(err, "$path: not a wasm filter")
        _version_string()  # now, not from inside a conversion
        f = new(String(path), mod[], Pair{String, String}[String(h) => String(g) for (h, g) in dirs], writable)
        finalizer(f) do f
            @ccall libwasmtime.wasmtime_module_delete(f.mod::Ptr{Cvoid})::Cvoid
        end
    end
end

Base.show(io::IO, f::WasmFilter) = print(io, "WasmFilter(", repr(f.name), ")")

# A run's state, the store's data: the filter's stdout, and the result of
# its last call to pandoc.
mutable struct _WasmRun
    stdout::IOBuffer
    result::Any   # nothing, (output, log) or a PandocError
end

function _stdout_write(data::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Csize_t)::Cssize_t
    run = unsafe_pointer_to_objref(data)::_WasmRun
    unsafe_write(run.stdout, buf, len)
    Cssize_t(len)
end

"The environment pandoc gives a JSON filter, as libpandoc does."
function _filter_env(c::Conversion)
    env = ["PANDOC_VERSION" => _version_string(),
           "PANDOC_READER_OPTIONS" => JSON.json(something(c.reader_options, Dict()))]
    c.input_format === nothing || push!(env, "PANDOC_INPUT_FORMAT" => c.input_format)
    c.output_format === nothing || push!(env, "PANDOC_OUTPUT_FORMAT" => c.output_format)
    env
end

"""
    (f::WasmFilter)(json, conversion) -> Vector{UInt8}

Run the filter on a document, as pandoc's JSON.
"""
function (f::WasmFilter)(json::Union{AbstractString, AbstractVector{UInt8}}, c::Conversion)
    w = _wasmtime()
    doc = _bytes(json)
    run = _WasmRun(IOBuffer(), nothing)
    wasi = @ccall libwasmtime.wasi_config_new()::Ptr{Cvoid}
    argv = [f.name, something(c.format, "")]
    env = _filter_env(c)
    names, values = first.(env), last.(env)
    GC.@preserve argv names values begin
        a, n, v = map(pointer, argv), map(pointer, names), map(pointer, values)
        @ccall libwasmtime.wasi_config_set_argv(wasi::Ptr{Cvoid}, length(a)::Csize_t, a::Ptr{Ptr{UInt8}})::Bool
        @ccall libwasmtime.wasi_config_set_env(wasi::Ptr{Cvoid}, length(n)::Csize_t, n::Ptr{Ptr{UInt8}}, v::Ptr{Ptr{UInt8}})::Bool
    end
    stdin = Ref(_Vec(0, C_NULL))
    GC.@preserve doc @ccall libwasmtime.wasm_byte_vec_new(stdin::Ptr{_Vec}, length(doc)::Csize_t, doc::Ptr{UInt8})::Cvoid
    @ccall libwasmtime.wasi_config_set_stdin_bytes(wasi::Ptr{Cvoid}, stdin::Ptr{_Vec})::Cvoid
    write_cb = @cfunction(_stdout_write, Cssize_t, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t))
    @ccall libwasmtime.wasi_config_set_stdout_custom(wasi::Ptr{Cvoid}, write_cb::Ptr{Cvoid},
                                                     pointer_from_objref(run)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Cvoid
    @ccall libwasmtime.wasi_config_inherit_stderr(wasi::Ptr{Cvoid})::Cvoid
    perms = f.writable ? 3 : 1
    for (host, guest) in f.dirs
        ok = @ccall libwasmtime.wasi_config_preopen_dir(wasi::Ptr{Cvoid}, host::Cstring, guest::Cstring,
                                                        perms::Csize_t, perms::Csize_t)::Bool
        ok || (@ccall libwasmtime.wasi_config_delete(wasi::Ptr{Cvoid})::Cvoid; error("$(f.name): can't give it $host"))
    end
    store = GC.@preserve run @ccall libwasmtime.wasmtime_store_new(w.engine::Ptr{Cvoid},
        pointer_from_objref(run)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Ptr{Cvoid}
    try
        GC.@preserve run begin
            ctx = @ccall libwasmtime.wasmtime_store_context(store::Ptr{Cvoid})::Ptr{Cvoid}
            _check((@ccall libwasmtime.wasmtime_context_set_wasi(ctx::Ptr{Cvoid}, wasi::Ptr{Cvoid})::Ptr{Cvoid}), f.name)
            inst = Ref{NTuple{2, UInt64}}()
            trap = Ref{Ptr{Cvoid}}(C_NULL)
            err = @ccall libwasmtime.wasmtime_linker_instantiate(w.linker::Ptr{Cvoid}, ctx::Ptr{Cvoid}, f.mod::Ptr{Cvoid},
                inst::Ptr{NTuple{2, UInt64}}, trap::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
            _check(err, f.name)
            trap[] == C_NULL || error("$(f.name): $(_trap_message(trap[]))")
            ext = Ref{_Extern}()
            found = @ccall libwasmtime.wasmtime_instance_export_get(ctx::Ptr{Cvoid}, inst::Ptr{NTuple{2, UInt64}},
                "_start"::Cstring, 6::Csize_t, ext::Ptr{_Extern})::Bool
            found && ext[].kind == _EXTERN_FUNC || error("$(f.name): not a WASI command (no _start)")
            func = Ref(ext[].of[1:2])
            err = @ccall gc_safe = true libwasmtime.wasmtime_func_call(ctx::Ptr{Cvoid}, func::Ptr{NTuple{2, UInt64}},
                C_NULL::Ptr{Cvoid}, 0::Csize_t, C_NULL::Ptr{Cvoid}, 0::Csize_t, trap::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
            if err != C_NULL
                status = Ref{Cint}(0)
                exited = @ccall libwasmtime.wasmtime_error_exit_status(err::Ptr{Cvoid}, status::Ptr{Cint})::Bool
                exited ? _error_delete(err) : _check(err, f.name)
                status[] == 0 || error("$(f.name) exited with status $(status[])")
            end
            trap[] == C_NULL || error("$(f.name): $(_trap_message(trap[]))")
        end
    finally
        @ccall libwasmtime.wasmtime_store_delete(store::Ptr{Cvoid})::Cvoid
    end
    take!(run.stdout)
end

# -- the libpandoc imports -------------------------------------------------------------

_run(caller) = unsafe_pointer_to_objref(@ccall libwasmtime.wasmtime_context_get_data(
    (@ccall libwasmtime.wasmtime_caller_context(caller::Ptr{Cvoid})::Ptr{Cvoid})::Ptr{Cvoid})::Ptr{Cvoid})::_WasmRun

_arg(args::Ptr{UInt64}, i) = unsafe_load(Ptr{Int32}(args + 16 * (i - 1)))  # wasmtime_val_raw_t: 16 bytes
_ret!(args::Ptr{UInt64}, v) = unsafe_store!(Ptr{Int32}(args), Int32(v))

# The filter's memory: its address and size, now (it may grow when the filter runs).
function _memory(caller)
    ext = Ref{_Extern}()
    ok = @ccall libwasmtime.wasmtime_caller_export_get(caller::Ptr{Cvoid}, "memory"::Cstring, 6::Csize_t, ext::Ptr{_Extern})::Bool
    ok && ext[].kind == _EXTERN_MEMORY || error("the filter exports no memory")
    mem = Ref(ext[].of)
    ctx = @ccall libwasmtime.wasmtime_caller_context(caller::Ptr{Cvoid})::Ptr{Cvoid}
    data = @ccall libwasmtime.wasmtime_memory_data(ctx::Ptr{Cvoid}, mem::Ptr{NTuple{3, UInt64}})::Ptr{UInt8}
    size = @ccall libwasmtime.wasmtime_memory_data_size(ctx::Ptr{Cvoid}, mem::Ptr{NTuple{3, UInt64}})::Csize_t
    data, size
end

function _guest_bytes(caller, ptr::Int32, len::Int32)
    data, size = _memory(caller)
    p, n = reinterpret(UInt32, ptr), reinterpret(UInt32, len)
    UInt64(p) + n <= size || error("out of bounds memory access")
    copy(unsafe_wrap(Vector{UInt8}, data + p, n))
end

# A host function's body: a trap for what it throws (nothing may unwind
# through wasmtime's frames).
function _host(f, caller)
    try
        f()
        C_NULL
    catch e
        msg = sprint(showerror, e)
        @ccall libwasmtime.wasmtime_trap_new(msg::Cstring, sizeof(msg)::Csize_t)::Ptr{Cvoid}
    end
end

# A call's answer, kept for result_len and result_read; the status.
function _answer!(run::_WasmRun, f)
    run.result = try
        f()
    catch e
        e isa PandocError || rethrow()
        e
    end
    Int32(run.result isa PandocError)
end

_guest_json(caller, p, l) = try
    JSON.parse(String(_guest_bytes(caller, p, l)))
catch e
    e isa ErrorException && startswith(e.msg, "out of bounds") && rethrow()
    throw(PandocError("PandocOptionError", sprint(showerror, e)))
end

function _import_convert(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        o, ol, i, il, has = (_arg(args, k) for k in 1:5)
        run = _run(caller)
        input = has != 0 ? _guest_bytes(caller, i, il) : nothing
        _ret!(args, _answer!(run, () -> begin
            opts = _untrusted(_guest_json(caller, o, ol))
            input === nothing && throw(PandocError("PandocOptionError", "a wasm filter gives convert its input"))
            _call_raw(:convert, JSON.json(opts), input)
        end))
    end
end

function _import_read_many(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        p, l = _arg(args, 1), _arg(args, 2)
        run = _run(caller)
        _ret!(args, _answer!(run, () -> begin
            req = _guest_json(caller, p, l)
            req isa AbstractDict || _refuse("a request that isn't an object")
            req = Dict{String, Any}(req)
            req["options"] = _untrusted(get(req, "options", Dict{String, Any}()))
            _call_raw(:read_many, JSON.json(req))
        end))
    end
end

function _import_query(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        p, l = _arg(args, 1), _arg(args, 2)
        run = _run(caller)
        _ret!(args, _answer!(run, () -> begin
            _call_raw(:query, JSON.json(_untrusted(_guest_json(caller, p, l))))
        end))
    end
end

function _part(run::_WasmRun, part)
    r = run.result
    r === nothing && return UInt8[]
    if r isa PandocError
        part == 2 && return codeunits(r.kind)
        part == 3 && return codeunits(r.message)
    else
        part == 0 && return r[1]
        part == 1 && return codeunits(r[2])
    end
    UInt8[]
end

function _import_result_len(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        _ret!(args, length(_part(_run(caller), _arg(args, 1))))
    end
end

function _import_result_read(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        b = _part(_run(caller), _arg(args, 1))
        data, size = _memory(caller)
        to = reinterpret(UInt32, _arg(args, 2))
        UInt64(to) + length(b) <= size || error("out of bounds memory access")
        GC.@preserve b unsafe_copyto!(data + to, pointer(b), length(b))
    end
end

# -- what a wasm filter may ask of pandoc ----------------------------------------------

# What a filter gives pandoc (options, or a query), marked `"untrusted": true`
# for libpandoc (1.7) to check: it accepts only what reads and writes no files,
# fetches nothing and runs nothing, and turns pandoc's sandbox on. The list is
# libpandoc's, the same for every host.
function _untrusted(x)
    v = ccall(_load().abi_version, Cint, ())
    v >= 1007 || _refuse("a call from a wasm filter needs libpandoc 1.7 (\"untrusted\"), not $(v ÷ 1000).$(v % 1000)")
    x isa AbstractDict || _refuse("options that aren't an object")
    o = Dict{String, Any}(x)
    o["untrusted"] = true
    o
end

_refuse(what) = throw(PandocError("PandocOptionError", "not allowed for untrusted code: $what"))

# -- the engine and the linker, shared by every filter ---------------------------

struct _Wasmtime
    engine::Ptr{Cvoid}
    linker::Ptr{Cvoid}
end

const _WASMTIME = Ref{Union{Nothing, _Wasmtime}}(nothing)
const _WASMTIME_LOCK = ReentrantLock()

function _wasmtime()
    w = _WASMTIME[]
    w === nothing || return w
    lock(_WASMTIME_LOCK) do
        _WASMTIME[] === nothing || return _WASMTIME[]
        cfg = @ccall libwasmtime.wasm_config_new()::Ptr{Cvoid}
        # compiled code cached on disk (e.g. ~/.cache/wasmtime), when it can be
        err = @ccall libwasmtime.wasmtime_config_cache_config_load(cfg::Ptr{Cvoid}, C_NULL::Ptr{UInt8})::Ptr{Cvoid}
        err == C_NULL || _error_delete(err)
        # bounds checks instead of signal handlers, which are Julia's
        @ccall libwasmtime.wasmtime_config_signals_based_traps_set(cfg::Ptr{Cvoid}, false::Bool)::Cvoid
        engine = @ccall libwasmtime.wasm_engine_new_with_config(cfg::Ptr{Cvoid})::Ptr{Cvoid}
        engine == C_NULL && error("wasmtime: no engine")
        linker = @ccall libwasmtime.wasmtime_linker_new(engine::Ptr{Cvoid})::Ptr{Cvoid}
        _check((@ccall libwasmtime.wasmtime_linker_define_wasi(linker::Ptr{Cvoid})::Ptr{Cvoid}), "wasmtime")
        _define(linker, "convert", 5, 1, @cfunction(_import_convert, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Csize_t)))
        _define(linker, "read_many", 2, 1, @cfunction(_import_read_many, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Csize_t)))
        _define(linker, "query", 2, 1, @cfunction(_import_query, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Csize_t)))
        _define(linker, "result_len", 1, 1, @cfunction(_import_result_len, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Csize_t)))
        _define(linker, "result_read", 2, 0, @cfunction(_import_result_read, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Csize_t)))
        _WASMTIME[] = _Wasmtime(engine, linker)
    end
end

# An import of module `libpandoc` taking `nparams` i32s and returning `nresults`.
function _define(linker, name, nparams, nresults, cb)
    function types(n)
        v = Ref(_Vec(0, C_NULL))
        ts = Ptr{Cvoid}[@ccall(libwasmtime.wasm_valtype_new(_WASM_I32::UInt8)::Ptr{Cvoid}) for _ in 1:n]
        @ccall libwasmtime.wasm_valtype_vec_new(v::Ptr{_Vec}, n::Csize_t, ts::Ptr{Ptr{Cvoid}})::Cvoid
        v
    end
    params, results = types(nparams), types(nresults)
    ty = @ccall libwasmtime.wasm_functype_new(params::Ptr{_Vec}, results::Ptr{_Vec})::Ptr{Cvoid}
    err = @ccall libwasmtime.wasmtime_linker_define_func_unchecked(
        linker::Ptr{Cvoid}, "libpandoc"::Cstring, 9::Csize_t, name::Cstring, sizeof(name)::Csize_t,
        ty::Ptr{Cvoid}, cb::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Ptr{Cvoid}
    @ccall libwasmtime.wasm_functype_delete(ty::Ptr{Cvoid})::Cvoid
    _check(err, "wasmtime: defining libpandoc.$name")
end
