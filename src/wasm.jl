# Filters compiled to WebAssembly, run in process by wasmtime (its C API,
# from Wasmtime_jll).
#
# A wasm filter is a pandoc JSON filter built for WASI (`wasm32-wasip1`):
# the document on stdin, the new one on stdout, the output format as its
# first argument, the variables libpandoc gives JSON filters in its
# environment (PANDOC_WRITER_OPTIONS among them). It runs sandboxed: no
# network, and only the directories it is given: by default none, as a wasm
# filter is for code you don't trust. $LIBPANDOC_WASM_DIRS gives every filter
# some, read-only: directories as PATH lists them (`:`, `;` on Windows; unset
# or empty: none), read when the filter runs, as its limits are. A program
# gives one filter its own instead (WasmFilter's `dirs` and `preopens`),
# whatever the variable says. In a directory sandbox too: the document's list
# and the filters' are different lists.
#
# The filter sees each such directory under its absolute path (C:\x as /c/x
# on Windows), its real one too if a link leads to it, and its path relative
# to the working directory (`.`, `..`, `../common`, `img`; none on another
# drive), and the working directory as `.` when it lies inside one: so
# `../common/part.txt`, `here.txt` and absolute names work as for a native
# filter. wasi-libc matches the beginning of a path against those names as
# written, without normalising it: `./../common/x` and `img/../../common/x`
# don't work, nor `./img/x` when only `img` is given, nor a symbolic link
# leaving a directory given. (libpandoc-rs's rule, the same in every host.)
#
# It may call pandoc through the imports of module
# `libpandoc` (libpandoc-rs's `guest.rs`), which this host answers on this
# process's pandoc, marked `"untrusted": true`: libpandoc then allows pandoc's
# sandbox only, and no options that read or write files, fetch or run anything
# (its list, which every host shares).
#
# Limits, which pandoc has for no filter: a timeout (wall-clock, its calls to
# pandoc included: each runs with the time the filter has left as its
# "timeout") and a memory limit (the filter's own memory), from
# $LIBPANDOC_WASM_TIMEOUT (seconds, as pandoc-server's --timeout) and
# $LIBPANDOC_WASM_MAX_MEMORY (bytes, or with k, m or g, as pandoc's +RTS -M),
# or per filter; none by default, as pandoc.

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
const _TRAP_INTERRUPT = 0x0a   # WASMTIME_TRAP_CODE_INTERRUPT
const _EXTERN_MEMORY = 0x03
const _WASM_I32 = 0x00

function _vec_string(v::Ref{_Vec})
    s = v[].size == 0 ? "" : unsafe_string(v[].data, v[].size)   # (wasmtime's vector, copied, then deleted)
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
    WasmFilter(path; dirs = nothing, preopens = nothing, timeout = missing, max_memory = missing)

A wasm filter: a pandoc JSON filter built for WASI (`wasm32-wasip1`), such
as a panir Rust filter, run in this process by wasmtime, sandboxed. It
sees no network, pandoc's filter variables, and only the directories it is
given: by default (`nothing`) those of `\$LIBPANDOC_WASM_DIRS` when it runs
(directories as `PATH` lists them; none if unset or empty), read-only, in a
directory sandbox too. A program gives it its own instead, whatever the
variable says:

- `dirs`, directories of this machine seen as the variable's are, read-only:
  under their absolute paths (`C:\\x` as `/c/x`), their real paths, and
  their paths relative to the working directory (`.`, `..`, `../common`),
  and the working directory as `.` when it lies inside one. Looked at when
  the filter runs: one that doesn't exist, or isn't a directory, fails it
  then. `dirs = String[]`: none.
- `preopens`, `(host, guest, writable)` tuples: the directory `host` seen as
  `guest` exactly, writable if so.

A filter that fails while it was given no directory says so, `(it was given
no directory: LIBPANDOC_WASM_DIRS)` (or `(it was given no directory)` when
the program said none). Paths aren't normalised inside: `./../x` and
`img/../../x` don't work, nor a symbolic link leaving a directory given
(the README's wasm filter item).

It may call pandoc (libpandoc-rs's `libpandoc` crate built for wasm): in
pandoc's sandbox, with options that name no files.

It fails when it runs longer than `timeout` seconds (its calls to pandoc
included: each runs with the time the filter has left as its `"timeout"`,
and one made after that fails at once) or its memory would grow past
`max_memory` bytes, or its output (standard output, which this process
keeps, and standard error, passed on to this process's) would: `nothing`
or 0 for
no limit, `missing` (the default) for what `\$LIBPANDOC_WASM_TIMEOUT` and
`\$LIBPANDOC_WASM_MAX_MEMORY` say when it runs (seconds; bytes, or with `k`,
`m` or `g`), none if unset.

Compiled once (and cached on disk by wasmtime); a fresh instance per run.
In `filters`, a path ending in `.wasm` is one too.
"""
mutable struct WasmFilter
    name::String
    mod::Ptr{Cvoid}
    dirs::Union{Nothing, Vector{String}}   # nothing: the variable's, when it runs
    preopens::Union{Nothing, Vector{Tuple{String, String, Bool}}}
    timeout::Union{Nothing, Missing, Float64}
    max_memory::Union{Nothing, Missing, Int}
    function WasmFilter(path::AbstractString; dirs = nothing, preopens = nothing,
                        timeout::Union{Nothing, Missing, Real} = missing,
                        max_memory::Union{Nothing, Missing, Integer} = missing)
        # (before compiling it, which may take seconds)
        _limit("timeout", timeout; seconds = true), _limit("max_memory", max_memory; seconds = false)
        dirs, preopens = _given_dirs(dirs, preopens)
        w = _wasmtime()
        bytes = Base.read(path)
        mod = Ref{Ptr{Cvoid}}(C_NULL)
        err = @ccall libwasmtime.wasmtime_module_new(w.engine::Ptr{Cvoid}, bytes::Ptr{UInt8},
                                                     length(bytes)::Csize_t, mod::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
        _check(err, "$path: not a wasm filter")
        _version_string()  # now, not from inside a conversion
        f = new(String(path), mod[], dirs, preopens,
                _limit("timeout", timeout; seconds = true), _limit("max_memory", max_memory; seconds = false))
        finalizer(f) do f
            @ccall libwasmtime.wasmtime_module_delete(f.mod::Ptr{Cvoid})::Cvoid
        end
    end
end

Base.show(io::IO, f::WasmFilter) = print(io, "WasmFilter(", repr(f.name), ")")

# WasmFilter's `dirs` (paths) and `preopens` ((host, guest, writable)), checked.
function _given_dirs(dirs, preopens)
    list(x) = x isa Union{AbstractVector, Tuple} && !(x isa AbstractString)
    dirs === nothing || list(dirs) && all(d -> d isa AbstractString, dirs) ||
        throw(ArgumentError("dirs: a list of directories (paths), not $(repr(dirs)): dirs = [d]; " *
                            "for a directory under a name of your own, preopens = [(host, guest, writable)]"))
    preopens === nothing || list(preopens) &&
        all(p -> p isa Tuple{AbstractString, AbstractString, Bool}, preopens) ||
        throw(ArgumentError("preopens: a list of (host, guest, writable), not $(repr(preopens))"))
    (dirs === nothing ? nothing : String[d for d in dirs],
     preopens === nothing ? nothing : Tuple{String, String, Bool}[(String(h), String(g), w) for (h, g, w) in preopens])
end

# -- the directories it sees ---------------------------------------------------------

"The environment variable giving every wasm filter directories, read-only."
const DIRS_VAR = "LIBPANDOC_WASM_DIRS"

# The directories $LIBPANDOC_WASM_DIRS gives (empty entries skipped).
_env_dirs() = String[d for d in split(get(ENV, DIRS_VAR, ""), Sys.iswindows() ? ';' : ':') if !isempty(d)]

# Whether the program said which directories (else the variable's).
_named(f::WasmFilter) = f.dirs !== nothing || f.preopens !== nothing

"""
The names a filter sees the host's directory `d` by, read-only, as (host,
guest, writable): its absolute path (as the directory sandbox names its
mounts), and its real one if a link leads to it; its path relative to the
working directory, from their real paths; and the working directory as `.`
if it lies strictly inside. A message instead, naming `d`, if it doesn't
exist, isn't a directory, or can't be resolved.
"""
function _seen(d::String)
    st = try
        stat(d)
    catch e
        return "$d: $(_message(e))"
    end
    ispath(st) || return "$d does not exist"   # (a part of it a file too)
    isdir(st) || return "$d is not a directory"
    real, cwd = try
        realpath(d), realpath(pwd())
    catch e
        return "$d: $(_message(e))"
    end
    names = Tuple{String, String, Bool}[]
    # (a name WASI can't have, as a UNC path or one not UTF-8: left out)
    for p in (d, real)
        g = try _guest(p) catch e; e isa PandocError || rethrow(); nothing end
        g === nothing || push!(names, (real, g, false))
    end
    rel = _relative(cwd, real)
    rel === nothing || push!(names, (real, rel, false))
    real != cwd && _inside(cwd, real) && push!(names, (cwd, ".", false))
    names
end

# Whether the real path `p` is the real path `d` or inside it, by their parts.
function _inside(p, d)
    a, b = splitpath(p), splitpath(d)   # (the root first: `/`, or the drive)
    length(a) >= length(b) && _same_root(a[1], b[1]) && a[2:length(b)] == b[2:end]
end

_same_root(a, b) = Sys.iswindows() ? lowercase(a) == lowercase(b) : a == b

# The path from the directory `from` to `to`, both real paths, with `/`:
# `.`, `..`, `../common`, `img`; nothing on another drive, or not UTF-8.
function _relative(from, to)
    a, b = splitpath(from), splitpath(to)
    _same_root(a[1], b[1]) || return nothing
    common = 1
    while common < min(length(a), length(b)) && a[common + 1] == b[common + 1]
        common += 1
    end
    parts = [fill("..", length(a) - common); b[common + 1:end]]
    rel = isempty(parts) ? "." : join(parts, "/")
    isvalid(rel) ? rel : nothing
end

# What the filter sees when it runs: the program's exact names, then the
# host's directories by theirs (the first of a name kept). One that doesn't
# exist, or isn't a directory, fails the filter, naming it (and the
# variable, if it came from there).
function _preopens(f::WasmFilter)
    named = _named(f)
    out = Tuple{String, String, Bool}[]
    add(p) = any(q -> q[2] == p[2], out) || push!(out, p)
    foreach(add, something(f.preopens, ()))
    for d in (named ? something(f.dirs, String[]) : _env_dirs())
        names = _seen(d)
        names isa String && error(named ? "$(f.name): $names" : "$(f.name): $DIRS_VAR: $names")
        foreach(add, names)
    end
    out
end

# A run's state, the store's data: the filter's stdout, the result of its
# last call to pandoc, its deadline (`_now()`'s; nothing for none), whether
# its time ran out in a call to pandoc, and its output (standard output and
# error) so far, what it may write (its memory limit), and the stream that
# went past that.
mutable struct _WasmRun
    stdout::IOBuffer
    result::Any   # nothing, (output, log) or a PandocError
    deadline::Union{Nothing, Float64}
    out_of_time::Bool
    written::Int
    max_output::Int
    over::Union{Nothing, String}
end
_WasmRun(max_output = typemax(Int)) = _WasmRun(IOBuffer(), nothing, nothing, false, 0, max_output, nothing)

# Seconds, monotonic.
_now() = time_ns() / 1e9

# A write of the filter's to its standard output (kept) or error (passed on
# to this process's, without yielding: a task switch inside wasmtime's call
# is not safe), counted against its memory limit: past it the write fails
# (ENOSPC), and so does the filter. Nothing may unwind through wasmtime's frames.
function _output(data::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Csize_t, stream::String)::Cssize_t
    try
        run = unsafe_pointer_to_objref(data)::_WasmRun   # (alive: the store's data, preserved)
        if len > run.max_output - run.written
            run.over = stream
            return Cssize_t(-28)
        end
        run.written += Int(len)
        # (buf, len: wasmtime's, valid for this call)
        stream == "standard output" ? unsafe_write(run.stdout, buf, len) : unsafe_write(Core.stderr, buf, len)
        Cssize_t(len)
    catch
        Cssize_t(-28)
    end
end
_stdout_write(data::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Csize_t) = _output(data, buf, len, "standard output")
_stderr_write(data::Ptr{Cvoid}, buf::Ptr{UInt8}, len::Csize_t) = _output(data, buf, len, "standard error")

"""
The environment variables a JSON filter run by libpandoc gets: pandoc's
(`PANDOC_VERSION`, `PANDOC_READER_OPTIONS`) and libpandoc's (the formats
with extensions, `PANDOC_WRITER_OPTIONS`: without `variables` if it would
be longer than 32,000 bytes, an environment variable's limit on Windows,
as libpandoc does; `PANDOC_SANDBOX`, `"true"` or `"false"`, whether the
conversion is sandboxed: true in the directory sandbox).
"""
function _filter_env(c::Conversion)
    env = ["PANDOC_VERSION" => _version_string(),
           "PANDOC_READER_OPTIONS" => JSON.json(something(c.reader_options, Dict()))]
    c.input_format === nothing || push!(env, "PANDOC_INPUT_FORMAT" => c.input_format)
    c.output_format === nothing || push!(env, "PANDOC_OUTPUT_FORMAT" => c.output_format)
    w = c.writer_options
    if w !== nothing
        text = JSON.json(w)
        sizeof(text) > 32_000 && (text = JSON.json(Dict(k => v for (k, v) in w if k != "variables")))
        push!(env, "PANDOC_WRITER_OPTIONS" => text)
    end
    c.sandbox === nothing || push!(env, "PANDOC_SANDBOX" => string(c.sandbox))
    env
end

"""
    (f::WasmFilter)(json, conversion) -> Vector{UInt8}

Run the filter on a document, as pandoc's JSON (in a directory sandbox
too, seeing its own directories, not the sandbox's).
"""
function (f::WasmFilter)(json::Union{AbstractString, AbstractVector{UInt8}}, c::Conversion)
    w = _wasmtime()
    timeout = f.timeout === missing ? _parse_timeout(get(ENV, TIMEOUT_VAR, "")) : f.timeout
    max_memory = f.max_memory === missing ? _parse_memory(get(ENV, MAX_MEMORY_VAR, "")) : f.max_memory
    dirs = _preopens(f)
    # the epoch's ticks: a huge limit is none in practice
    ticks = timeout === nothing ? _NO_DEADLINE : min(_NO_DEADLINE, ceil(timeout / _TICK) + 1)
    doc = _bytes(json)
    run = _WasmRun(something(max_memory, typemax(Int)))
    argv = [f.name, something(c.format, "")]
    env = _filter_env(c)
    names, values = first.(env), last.(env)
    wasi = @ccall libwasmtime.wasi_config_new()::Ptr{Cvoid}
    ok = GC.@preserve argv names values begin
        a, n, v = map(pointer, argv), map(pointer, names), map(pointer, values)
        (@ccall libwasmtime.wasi_config_set_argv(wasi::Ptr{Cvoid}, length(a)::Csize_t, a::Ptr{Ptr{UInt8}})::Bool) &&
        (@ccall libwasmtime.wasi_config_set_env(wasi::Ptr{Cvoid}, length(n)::Csize_t, n::Ptr{Ptr{UInt8}}, v::Ptr{Ptr{UInt8}})::Bool)
    end
    # (wasmtime takes them as text)
    ok || (@ccall libwasmtime.wasi_config_delete(wasi::Ptr{Cvoid})::Cvoid; error("$(f.name): its arguments or environment aren't UTF-8"))
    stdin = Ref(_Vec(0, C_NULL))
    GC.@preserve doc @ccall libwasmtime.wasm_byte_vec_new(stdin::Ptr{_Vec}, length(doc)::Csize_t, doc::Ptr{UInt8})::Cvoid
    @ccall libwasmtime.wasi_config_set_stdin_bytes(wasi::Ptr{Cvoid}, stdin::Ptr{_Vec})::Cvoid
    write_cb = @cfunction(_stdout_write, Cssize_t, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t))
    @ccall libwasmtime.wasi_config_set_stdout_custom(wasi::Ptr{Cvoid}, write_cb::Ptr{Cvoid},
                                                     pointer_from_objref(run)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Cvoid
    err_cb = @cfunction(_stderr_write, Cssize_t, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t))
    @ccall libwasmtime.wasi_config_set_stderr_custom(wasi::Ptr{Cvoid}, err_cb::Ptr{Cvoid},
                                                     pointer_from_objref(run)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Cvoid
    for (host, guest, writable) in dirs
        perms = writable ? 3 : 1
        ok = @ccall libwasmtime.wasi_config_preopen_dir(wasi::Ptr{Cvoid}, host::Cstring, guest::Cstring,
                                                        perms::Csize_t, perms::Csize_t)::Bool
        ok || (@ccall libwasmtime.wasi_config_delete(wasi::Ptr{Cvoid})::Cvoid; error("$(f.name): can't give it $host"))
    end
    store = GC.@preserve run @ccall libwasmtime.wasmtime_store_new(w.engine::Ptr{Cvoid},
        pointer_from_objref(run)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Ptr{Cvoid}
    # (the clock, if it has a time limit, while it runs)
    body() = GC.@preserve run begin
        ctx = @ccall libwasmtime.wasmtime_store_context(store::Ptr{Cvoid})::Ptr{Cvoid}
        @ccall libwasmtime.wasmtime_store_limiter(store::Ptr{Cvoid}, something(max_memory, -1)::Int64,
                                                  (-1)::Int64, (-1)::Int64, (-1)::Int64, (-1)::Int64)::Cvoid
        @ccall libwasmtime.wasmtime_context_set_epoch_deadline(ctx::Ptr{Cvoid}, UInt64(ticks)::UInt64)::Cvoid
        started = _now()
        timeout === nothing || (run.deadline = started + timeout)
        # a failure, with the limit it may have met
        function failed(msg; interrupted = false)
            interrupted && error("$(f.name): stopped after $(round(_now() - started; digits = 1)) s, " *
                                 "its time limit ($TIMEOUT_VAR: $timeout)")
            max_memory === nothing && error(msg)
            error("$msg (its memory limit: $max_memory bytes, $MAX_MEMORY_VAR)")
        end
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
        msg, interrupted = nothing, false
        if err != C_NULL
            status = Ref{Cint}(0)
            exited = @ccall libwasmtime.wasmtime_error_exit_status(err::Ptr{Cvoid}, status::Ptr{Cint})::Bool
            msg = exited ? (status[] == 0 ? nothing : "$(f.name) exited with status $(status[])") :
                  "$(f.name): $(_error_message(err))"
            _error_delete(err)
        end
        if trap[] != C_NULL
            code = Ref{UInt8}(0xff)
            @ccall libwasmtime.wasmtime_trap_code(trap[]::Ptr{Cvoid}, code::Ptr{UInt8})::Bool
            interrupted = timeout !== nothing && code[] == _TRAP_INTERRUPT
            msg = "$(f.name): $(_trap_message(trap[]))"   # (which deletes the trap)
        end
        # its time ran out in a call to pandoc: stopped, whatever it did after
        run.out_of_time && failed(""; interrupted = true)
        # its output went past its limit (whether it noticed the failed write or not)
        run.over === nothing || failed("$(f.name): its $(run.over) went past its memory limit")
        # it was given no directory, which may be why it failed (its memory
        # limit too: wasmtime's C API doesn't say whether it refused a growth)
        msg === nothing || interrupted || !isempty(dirs) ||
            (msg *= _named(f) ? " (it was given no directory)" : " (it was given no directory: $DIRS_VAR)")
        msg === nothing || failed(msg; interrupted)
    end
    try
        timeout === nothing ? body() : _with_clock(body, w)
    finally
        @ccall libwasmtime.wasmtime_store_delete(store::Ptr{Cvoid})::Cvoid
    end
    take!(run.stdout)
end

# -- the libpandoc imports -------------------------------------------------------------

# (the store's data: the object the run keeps alive, GC.@preserve; a
# _WasmRun, or a sandbox's _SandboxRun)
_store_data(caller) = unsafe_pointer_to_objref(@ccall libwasmtime.wasmtime_context_get_data(
    (@ccall libwasmtime.wasmtime_caller_context(caller::Ptr{Cvoid})::Ptr{Cvoid})::Ptr{Cvoid})::Ptr{Cvoid})
_run(caller) = _store_data(caller)::_WasmRun

# A host function's arguments and result: wasmtime's array of
# wasmtime_val_raw_t (16 bytes each), as long as the function type says
# (the linker checked the filter's import against it), valid during the call.
_arg(args::Ptr{UInt64}, i) = unsafe_load(Ptr{Int32}(args + 16 * (i - 1)))
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
    copy(unsafe_wrap(Vector{UInt8}, data + p, n))   # (checked within the memory just above; copied)
end

# A host function's body: a trap for what it throws (nothing may unwind
# through wasmtime's frames).
function _host(f, caller)
    try
        f()
        C_NULL
    catch e
        msg = _message(e)
        @ccall libwasmtime.wasmtime_trap_new(msg::Ptr{UInt8}, sizeof(msg)::Csize_t)::Ptr{Cvoid}
    end
end

# A call's answer, kept for result_len and result_read; the status. A call
# that ends past the filter's deadline ends the filter.
function _answer!(run::_WasmRun, f)
    run.result = try
        f()
    catch e
        e isa PandocError || rethrow()
        e
    end
    run.deadline === nothing || _now() < run.deadline || (run.out_of_time = true)
    Int32(run.result isa PandocError)
end

# The seconds the filter has left (nothing: no limit); a call made with none
# left fails at once, as a "Timeout".
function _time_left(run::_WasmRun)
    run.deadline === nothing && return nothing
    left = run.deadline - _now()
    left > 0 && return left
    run.out_of_time = true
    throw(PandocError("Timeout", "the filter's time limit is reached"))
end

# Options a filter gives pandoc, within its time: their "timeout" the time
# it has left, or its own if shorter.
function _within(opts::Dict{String, Any}, left)
    own = get(opts, "timeout", nothing)
    left === nothing || own isa Real && !(own isa Bool) && 0 < own < left || (opts["timeout"] = left)
    opts
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
            left = _time_left(run)
            opts = _within(_untrusted(_guest_json(caller, o, ol)), left)
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
            left = _time_left(run)
            req = _guest_json(caller, p, l)
            req isa AbstractDict || _refuse("a request that isn't an object")
            req = Dict{String, Any}(req)
            req["options"] = _within(_untrusted(get(req, "options", Dict{String, Any}())), left)
            _call_raw(:read_many, JSON.json(req))
        end))
    end
end

function _import_query(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        p, l = _arg(args, 1), _arg(args, 2)
        run = _run(caller)
        _ret!(args, _answer!(run, () -> begin
            _time_left(run)
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
        GC.@preserve b unsafe_copyto!(data + to, pointer(b), length(b))   # (checked just above)
    end
end

# -- what a wasm filter may ask of pandoc ----------------------------------------------

# What a filter gives pandoc (options, or a query), marked `"untrusted": true`
# for libpandoc to check: it accepts only what reads and writes no files,
# fetches nothing and runs nothing, and turns pandoc's sandbox on. The list is
# libpandoc's, the same for every host.
function _untrusted(x)
    x isa AbstractDict || _refuse("options that aren't an object")
    o = Dict{String, Any}(x)
    o["untrusted"] = true
    o
end

_refuse(what) = throw(PandocError("PandocOptionError", "not allowed for untrusted code: $what"))

# -- limits ------------------------------------------------------------------------------

const TIMEOUT_VAR = "LIBPANDOC_WASM_TIMEOUT"
const MAX_MEMORY_VAR = "LIBPANDOC_WASM_MAX_MEMORY"

"How often the engine's epoch advances, once a filter has a timeout (seconds)."
const _TICK = 0.01
const _NO_DEADLINE = typemax(UInt64) ÷ 2   # ticks: never, in practice

# A limit given to WasmFilter or a sandbox, in seconds or bytes: `nothing`
# (none: 0 too, as the variables) or `missing` as they are; negative, NaN
# or infinite refused; a size past what an Int holds: as large as it does
# (none in practice).
function _limit(name, x; seconds::Bool)
    (x === nothing || x === missing) && return x
    x isa Real && !(x isa Bool) && isfinite(x) && x >= 0 ||
        throw(ArgumentError("$name: $(seconds ? "seconds" : "bytes"), 0 or more (0: no limit), not $(repr(x))"))
    x == 0 && return nothing
    seconds ? Float64(x) : Int(min(x, typemax(Int)))
end

"A timeout in seconds (\$LIBPANDOC_WASM_TIMEOUT): `nothing` if empty or 0."
function _parse_timeout(s::AbstractString)
    s = strip(s)
    isempty(s) && return nothing
    t = tryparse(Float64, s)
    t !== nothing && isfinite(t) && t >= 0 || error("$TIMEOUT_VAR: seconds, not $(repr(s))")
    t == 0 ? nothing : t
end

"A size in bytes, or with k, m or g (\$LIBPANDOC_WASM_MAX_MEMORY, as pandoc's +RTS -M): `nothing` if empty or 0."
function _parse_memory(s::AbstractString)
    s = strip(s)
    isempty(s) && return nothing
    m = match(r"^([0-9]+)([kKmMgG]?)$", s)
    m === nothing && error("$MAX_MEMORY_VAR: bytes, or with k, m or g, not $(repr(s))")
    n = parse(BigInt, m[1]) << Dict("" => 0, "k" => 10, "m" => 20, "g" => 30)[lowercase(m[2])]
    n == 0 ? nothing : Int(min(n, typemax(Int)))   # (more than an Int holds: none in practice)
end

# The epoch's clock: a thread of its own (not a task: a Julia thread may be
# the one running the filter, the main one included), running while a call
# with a time limit runs. The first such call starts it, and it ends within a
# tick of the last: `users` counts the calls running, under a lock the thread
# shares (it ends when it finds none, and says so in `alive`). The next start
# joins the thread that ended before starting another (`thread`, its handle).
mutable struct _Clock
    const lock::Threads.SpinLock
    users::Int
    alive::Bool
    thread::UInt64   # uv_thread_t: pthread_t, or a HANDLE on Windows; 0: none
end
const _CLOCK = _Clock(Threads.SpinLock(), 0, false, 0)
const _CLOCK_START = ReentrantLock()   # (one start at a time: `thread` is theirs)

# What an image holds of an earlier process (precompiling's, a system
# image's): not this one's.
function _clock_reset!()
    _CLOCK.users, _CLOCK.alive, _CLOCK.thread = 0, false, 0
end

# The clock thread's loop: sleep (letting the GC run meanwhile), then advance
# the epoch by the time that has passed, in _TICKs. By the time passed, not
# by the sleeps: a system may stretch a short sleep (macOS does), and a
# limit then comes late. It ends when no call with a time limit runs.
function _clock(engine::Ptr{Cvoid})::Cvoid
    c = _CLOCK
    tick = round(UInt64, 1e9 * _TICK)
    started, done = time_ns(), UInt64(0)
    while true
        @ccall gc_safe = true uv_sleep(round(Cuint, 1000 * _TICK)::Cuint)::Cvoid
        lock(c.lock)
        ending = c.users == 0
        ending && (c.alive = false)
        unlock(c.lock)
        ending && return
        due = (time_ns() - started) ÷ tick
        for _ in (done + 1):due
            @ccall libwasmtime.wasmtime_engine_increment_epoch(engine::Ptr{Cvoid})::Cvoid
        end
        done = due
    end
end

# `f()`, a call with a time limit: the clock runs meanwhile.
function _with_clock(f, w)
    c = _CLOCK
    lock(_CLOCK_START) do
        start = begin
            lock(c.lock)
            c.users += 1
            s = !c.alive
            c.alive = true
            unlock(c.lock)
            s
        end
        start || return
        # the thread that ended (it found no call running), joined: its last
        # step is to return
        c.thread == 0 || @ccall gc_safe = true uv_thread_join(Ref(c.thread)::Ptr{UInt64})::Cint
        c.thread = 0
        tid = Ref{UInt64}(0)
        entry = @cfunction(_clock, Cvoid, (Ptr{Cvoid},))
        err = @ccall uv_thread_create(tid::Ptr{UInt64}, entry::Ptr{Cvoid}, w.engine::Ptr{Cvoid})::Cint
        if err != 0
            lock(c.lock)
            c.users -= 1
            c.alive = false
            unlock(c.lock)
            error("a thread for wasm filters' timeouts: libuv error $err")
        end
        c.thread = tid[]
    end
    try
        f()
    finally
        lock(c.lock)
        c.users -= 1
        unlock(c.lock)
    end
end

# -- stopped from outside: a cancel token ------------------------------------------

# Advance the epoch, if wasm ran in this process: a store a token watches
# then looks at it at once (every other store's time limit comes one tick,
# 10 ms, nearer).
function _interrupt()
    w = _WASMTIME[]
    w === nothing || @ccall libwasmtime.wasmtime_engine_increment_epoch(w.engine::Ptr{Cvoid})::Cvoid
    nothing
end

# A store a cancel token stops (`_interrupt`), or its time limit (checked
# at each tick of the clock): its epoch deadline is the next tick, and at
# each one `_on_epoch` decides. `reason`: :cancelled or :timeout once it
# stopped the store (its call fails then).
mutable struct _Watch
    token::CancelToken
    deadline::Union{Nothing, Float64}   # `_now()`'s
    @atomic reason::Union{Nothing, Symbol}
end

# wasmtime's epoch deadline callback: going on (a tick more), or an error.
# Nothing may throw or yield here (inside wasmtime's call).
function _on_epoch(ctx::Ptr{Cvoid}, env::Ptr{Cvoid}, delta::Ptr{UInt64}, kind::Ptr{UInt8})::Ptr{Cvoid}
    w = unsafe_pointer_to_objref(env)::_Watch   # (alive: preserved by the run)
    if iscancelled(w.token)
        @atomic w.reason = :cancelled
    elseif w.deadline !== nothing && _now() >= w.deadline
        @atomic w.reason = :timeout
    else
        unsafe_store!(delta, UInt64(1))
        unsafe_store!(kind, 0x00)   # WASMTIME_UPDATE_DEADLINE_CONTINUE
        return C_NULL
    end
    msg = "stopped from outside"
    @ccall libwasmtime.wasmtime_error_new(msg::Cstring)::Ptr{Cvoid}
end

# Watch `store` (its context `ctx`) with `w`: kept alive by the caller.
function _watch!(store, ctx, w::_Watch)
    cb = @cfunction(_on_epoch, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Ptr{UInt8}))
    @ccall libwasmtime.wasmtime_store_epoch_deadline_callback(store::Ptr{Cvoid}, cb::Ptr{Cvoid},
        pointer_from_objref(w)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Cvoid
    @ccall libwasmtime.wasmtime_context_set_epoch_deadline(ctx::Ptr{Cvoid}, UInt64(1)::UInt64)::Cvoid
end

# -- the engine and the linker, shared by every filter ---------------------------

struct _Wasmtime
    engine::Ptr{Cvoid}
    linker::Ptr{Cvoid}
end

const _WASMTIME = _Once{_Wasmtime}()
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
        # libpandoc.wasm's Lua is built with wasm's exception handling
        @ccall libwasmtime.wasmtime_config_wasm_exceptions_set(cfg::Ptr{Cvoid}, true::Bool)::Cvoid
        # for timeouts: wasm code checks an epoch the clock advances
        @ccall libwasmtime.wasmtime_config_epoch_interruption_set(cfg::Ptr{Cvoid}, true::Bool)::Cvoid
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
