# The directory sandbox: the whole of pandoc runs inside libpandoc.wasm
# (pandoc built for WebAssembly), under wasmtime, which gives it the
# directories the caller lists and nothing else, as a container's mounts do.
# libpandoc-rs's host (libpandoc/src/sandbox.rs) and libpandoc-python's
# (_sandbox.py), in Julia: the same settings, rules and messages.
#
# The setting: `sandbox = (read = [dirs], write = [dirs])` (or a Dict, or
# the JSON form `"sandbox": {"read": [...], "write": [...]}`), with if given
# `timeout` (seconds) and `max_memory` (bytes; `"max-memory"`), in a
# conversion's options; or $LIBPANDOC_SANDBOX and $LIBPANDOC_SANDBOX_WRITE
# (lists as PATH is) for `run` and pandocjl. `sandbox = true` keeps meaning
# pandoc's own sandbox in the native library.
#
# What the module sees: each listed directory at its own absolute path (on
# Windows C:\x is /c/x), read-only, or writable if in the write list;
# nothing else (not the user data directory, not PANDOC_DATA_DIRS, unless
# listed: pandoc inside is then told where they are); a private, writable
# temporary directory, removed after; as its working directory, the
# process's if it is inside a listed directory, else an empty one; no
# network, no programs; of the environment, SOURCE_DATE_EPOCH only.
#
# The options and arguments go to pandoc untouched. Lua filters run inside;
# JSON filters (programs) fail, as a PDF engine does; Julia filters and wasm
# filters run in this process, called back by the module (its import
# `libpandoc.filter`), a wasm filter seeing the same directories.
#
# Threads: the module runs on the calling task, and the filters it calls
# back run there too, inside wasmtime's call. wasmtime keeps per-thread
# state for the calls into wasm under way (a stack of them), and a Julia
# filter may yield (to print, sleep or wait). So the run holds what a call
# into libpandoc with callbacks holds (`_pinned`): its task stays on this OS
# thread (else it would return into wasm from another thread, whose state
# knows nothing of the call), and no other task on this thread enters wasm
# with callbacks meanwhile (else the two would return to wasmtime out of
# order, each unwinding the other's state). A wasm filter run by itself
# never yields inside wasm, so it nests whole inside the yielded call and
# needs neither. GHC keeps its stack in the module's memory; wasmtime stops
# wasm's own recursion at 512 KiB of this task's stack.

const READ_VAR = "LIBPANDOC_SANDBOX"
const WRITE_VAR = "LIBPANDOC_SANDBOX_WRITE"
const WASM_VAR = "LIBPANDOC_WASM"

# The host's own directories in the module: the private temporary one, and
# an empty one, read-only, as the working directory when the process's
# isn't mounted (pandoc's command needs one).
const _OWN = "/.libpandoc"
const _TMP = "/.libpandoc/tmp"
const _NOWHERE = "/.libpandoc/nowhere"

_refused(msg, kind = "PandocOptionError") = PandocError(kind, msg)

# A sandbox: the directories to read, those to write (and read), and its
# own limits (`missing`: the environment's; `nothing`: none).
struct _Dirs
    read::Vector{String}
    write::Vector{String}
    timeout::Union{Missing, Nothing, Float64}
    max_memory::Union{Missing, Nothing, Int}
end

# The sandbox of the options' "sandbox", if it is one (true or false: pandoc's
# own). Its limits are a wasm filter's: 0 or more (0: none), bytes an integer.
function _sandbox_of(@nospecialize(opts))
    s = get(opts, "sandbox", nothing)
    s isa Union{AbstractDict, NamedTuple} || return nothing
    read, write, timeout, max_memory = String[], String[], missing, missing
    for (k, v) in pairs(s)
        k = _key(k)
        v === nothing && continue   # (absent: no directories, the environment's limit)
        if k in ("read", "write")
            v isa Union{AbstractVector, Tuple} && all(d -> d isa AbstractString, v) ||
                throw(_refused("sandbox: \"$k\" lists directories as strings"))
            append!(k == "read" ? read : write, String.(v))
        elseif k == "timeout" && v isa Real
            timeout = _limit("sandbox: \"timeout\"", v; seconds = true)
        elseif k == "max-memory" && v isa Integer
            max_memory = _limit("sandbox: \"max-memory\"", v; seconds = false)
        elseif k in ("timeout", "max-memory")
            throw(ArgumentError("sandbox: \"$k\": $(k == "timeout" ? "seconds" : "bytes"), 0 or more " *
                                "(0: no limit), not $(repr(v))"))
        else
            throw(_refused("sandbox: \"$k\": only \"read\", \"write\", \"timeout\" and \"max-memory\""))
        end
    end
    _Dirs(read, write, timeout, max_memory)
end

# The sandbox of $LIBPANDOC_SANDBOX and $LIBPANDOC_SANDBOX_WRITE, if either
# is set (set but empty: no directory).
function _sandbox_from_env()
    r, w = get(ENV, READ_VAR, nothing), get(ENV, WRITE_VAR, nothing)
    r === nothing && w === nothing && return nothing
    dirs(v) = String[d for d in split(something(v, ""), Sys.iswindows() ? ';' : ':') if !isempty(d)]
    _Dirs(dirs(r), dirs(w), missing, missing)
end

# The limits: the sandbox's, else the environment's.
_sandbox_limits(d::_Dirs) =
    (d.timeout === missing ? _parse_timeout(get(ENV, TIMEOUT_VAR, "")) : d.timeout,
     d.max_memory === missing ? _parse_memory(get(ENV, MAX_MEMORY_VAR, "")) : d.max_memory)

# -- the mounts ---------------------------------------------------------------------

# An absolute host path as the module names it: `/` and its parts (C:\x is /c/x).
function _guest(path::AbstractString)
    isvalid(path) || throw(_refused("$(repr(path)): not UTF-8"))
    p = abspath(path)   # (`.` and `..` resolved as written)
    parts = if Sys.iswindows()
        drive, rest = splitdrive(chopprefix(p, "\\\\?\\"))   # (not \\?\'s verbatim form)
        occursin(r"^[A-Za-z]:$", drive) || throw(_refused("$path: not supported in a sandbox"))
        [lowercase(drive[1:1]); split(rest, ('\\', '/'))]
    else
        split(p, '/')
    end
    "/" * join(filter(s -> !isempty(s) && s != ".", parts), "/")
end

# Whether the module's path `p` is `d` or inside it.
_within(p, d) = d == "/" || p == d || startswith(p, d * "/")

# pandoc's default user data directory, if it exists: $XDG_DATA_HOME/pandoc
# (~/.local/share/pandoc), else ~/.pandoc; %APPDATA%\pandoc on Windows.
function _user_data_dir()
    env(k) = (v = get(ENV, k, ""); isempty(v) ? nothing : v)
    if Sys.iswindows()
        candidates = env("APPDATA") === nothing ? String[] : [joinpath(env("APPDATA"), "pandoc")]
    else
        home = env("HOME")
        xdg = something(env("XDG_DATA_HOME"), home === nothing ? nothing : joinpath(home, ".local", "share"), Some(nothing))
        candidates = [joinpath(d, n) for (d, n) in ((xdg, "pandoc"), (home, ".pandoc")) if d !== nothing]
    end
    i = findfirst(isdir, candidates)
    i === nothing ? nothing : candidates[i]
end

# What one conversion's module sees: the mounts (the module's path, the
# host's, whether writable), its environment, its working directory and
# whether that is inside a mount (nothing if not, else whether writable),
# and a private directory (`root`), removed by `_close`.
struct _Mounts
    root::String
    mounts::Vector{Tuple{String, String, Bool}}
    env::Vector{Pair{String, String}}
    cwd::String
    cwd_mounted::Union{Nothing, Bool}
end

function _Mounts(dirs::_Dirs)
    root = mktempdir(; cleanup = false)   # (mode 0o700)
    try
        mkdir(joinpath(root, "tmp")), mkdir(joinpath(root, "nowhere"))
        mounts = Tuple{String, String, Bool}[]
        for (list, writable) in ((dirs.read, false), (dirs.write, true)), d in list
            _mount!(mounts, d, writable)
        end
        # pandoc's own way to a reproducible docx, odt or epub; nothing else
        # of the environment goes in
        env = ["TMPDIR" => _TMP]
        haskey(ENV, "SOURCE_DATE_EPOCH") && push!(env, "SOURCE_DATE_EPOCH" => ENV["SOURCE_DATE_EPOCH"])
        # The user data directory and PANDOC_DATA_DIRS are not mounted by
        # themselves: pandoc inside is told where they are only if listed.
        inside(d) = any(n -> any(m -> _within(n, m[1]), mounts), (_guest(realpath(d)), _guest(d)))
        data = _user_data_dir()
        if data !== nothing && inside(data)
            push!(env, (basename(data) == ".pandoc" ? "HOME" : "XDG_DATA_HOME") => _guest(dirname(abspath(data))))
        end
        listed = [_guest(d) for d in split(get(ENV, "PANDOC_DATA_DIRS", ""), Sys.iswindows() ? ';' : ':')
                  if isabspath(d) && isdir(d) && inside(d)]
        isempty(listed) || push!(env, "PANDOC_DATA_DIRS" => join(listed, ':'))
        here = try
            realpath(pwd())
        catch e
            throw(_refused("the working directory: $(_message(e))", "PandocIOError"))
        end
        cwd = _guest(here)
        around = filter(m -> _within(cwd, m[1]), mounts)
        _Mounts(root, mounts, env, cwd, isempty(around) ? nothing : argmax(m -> length(m[1]), around)[3])
    catch
        rm(root; recursive = true, force = true)
        rethrow()
    end
end

_close(m::_Mounts) = rm(m.root; recursive = true, force = true)

# A directory at its own absolute path (its real one, and as named if that
# differs, as macOS's /tmp for /private/tmp); writable if listed so anywhere.
function _mount!(mounts, d, writable)
    ispath(d) || throw(_refused("sandbox: $d: no such file or directory"))
    isdir(d) || throw(_refused("sandbox: $d: not a directory"))
    real = realpath(d)
    for g in unique((_guest(real), _guest(d)))
        _within(g, _OWN) && throw(_refused("sandbox: $d: reserved"))
        i = findfirst(m -> m[1] == g, mounts)
        i === nothing ? push!(mounts, (g, real, writable)) : (mounts[i] = (g, mounts[i][2], mounts[i][3] | writable))
    end
end

# What a failure says when the working directory isn't mounted.
_note(m::_Mounts) = m.cwd_mounted === nothing ?
    "(the working directory, $(m.cwd), is not in the sandbox: relative names find nothing)" : nothing

# The directories a wasm filter in the conversion sees: the same, and the
# working directory as "." when it is mounted.
function _wasm_dirs(m::_Mounts)
    dirs = [(host, guest, w) for (guest, host, w) in m.mounts]
    m.cwd_mounted === nothing || push!(dirs, (".", ".", m.cwd_mounted))
    dirs
end

# -- the module --------------------------------------------------------------------

# libpandoc.wasm compiled, by path, and the linker that gives it WASI and
# `libpandoc.filter`: made once (never freed), under the lock.
const _MODULES = Dict{String, Ptr{Cvoid}}()
const _SANDBOX_LINKER = Ref{Ptr{Cvoid}}(C_NULL)
const _MODULES_LOCK = ReentrantLock()

_wasm_given() = !isempty(get(ENV, WASM_VAR, ""))
_wasm_path() = _wasm_given() ? ENV[WASM_VAR] : joinpath(_download_root(), RELEASE, "libpandoc.wasm")

# The module and the linker: $LIBPANDOC_WASM, else the release's, downloaded
# once beside the library's download. Compiled on the shared engine, and
# cached on disk by wasmtime: the first compilation takes about 20 s and 8 GB.
function _sandbox_module()
    w = _wasmtime()
    path = _wasm_path()
    lock(_MODULES_LOCK) do
        _SANDBOX_LINKER[] == C_NULL && (_SANDBOX_LINKER[] = _sandbox_linker(w))
        mod = get!(_MODULES, path) do
            _wasm_given() || isfile(path) || _download_wasm(path)
            bytes = try
                Base.read(path)
            catch e
                throw(_refused("$path: $(_message(e))", "PandocAppError"))
            end
            mod = Ref{Ptr{Cvoid}}(C_NULL)
            err = @ccall gc_safe = true libwasmtime.wasmtime_module_new(w.engine::Ptr{Cvoid}, bytes::Ptr{UInt8},
                length(bytes)::Csize_t, mod::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
            if err != C_NULL
                msg = _error_message(err)
                _error_delete(err)
                throw(_refused("$path: not libpandoc.wasm: $msg", "PandocAppError"))
            end
            mod[]
        end
        mod, _SANDBOX_LINKER[]
    end
end

const _WASM_URL = "https://github.com/ickc/libpandoc/releases/download/$RELEASE/libpandoc.wasm"

# libpandoc.wasm of the release, checked against its SHA256SUMS, written
# beside `path` and then moved there (never half there).
function _download_wasm(path; url = _WASM_URL)
    @warn "Downloading libpandoc.wasm (libpandoc $RELEASE, about 60 MB) into $path, once; " *
          "its first compilation takes about 20 s and 8 GB of memory"
    try
        file = _fetch(url)
        _check_sum(url, file)
        mkpath(dirname(path))
        part = "$path.$(getpid()).part"
        cp(file, part; force = true)
        mv(part, path; force = true)
    catch e
        throw(_refused("downloading libpandoc.wasm: $(_message(e)) (or set $WASM_VAR)", "PandocAppError"))
    end
end

# libpandoc's rule: the same major version, a minor at least this package's.
function _wasm_abi_check(abi, path)
    _abi_ok(abi) && return
    throw(_refused("libpandoc.wasm $(abi ÷ 1000).$(abi % 1000) is loaded, and LibPandoc.jl needs " *
                   "$ABI_MAJOR.$ABI_MINOR or a later $ABI_MAJOR.x: " *
                   (_wasm_given() ? "set $WASM_VAR to another" : "remove $path, and the current one is downloaded"),
                   "PandocAppError"))
end

# wasmtime_val_t (wasmtime/val.h, as Wasmtime_jll 46 builds it, with GC): a
# kind, then a 24-byte union, an i32 in its first 4 bytes.
struct _Val
    kind::UInt8
    of::NTuple{3, UInt64}
end

# The module stopped: a trap (its time limit: `interrupted`), or its runtime
# exited (with `status`).
struct _Stopped <: Exception
    message::String
    interrupted::Bool
    status::Union{Nothing, Int}
end
Base.showerror(io::IO, e::_Stopped) = print(io, e.message)

_stop_on(err) = err == C_NULL ||
    (msg = _error_message(err); _error_delete(err); throw(_Stopped(msg, false, nothing)))

# Call a function of the module's with i32 arguments; its i32 results.
# wasmtime checks the types; a trap or an exit is a _Stopped.
function _invoke(ctx, func::Ref, args, nresults)
    a = [_Val(_WASM_I32, (UInt64(x % UInt32), 0, 0)) for x in args]
    r = fill(_Val(0, (0, 0, 0)), nresults)
    trap = Ref{Ptr{Cvoid}}(C_NULL)
    err = GC.@preserve a r @ccall gc_safe = true libwasmtime.wasmtime_func_call(ctx::Ptr{Cvoid},
        func::Ptr{NTuple{2, UInt64}}, a::Ptr{_Val}, length(a)::Csize_t, r::Ptr{_Val}, nresults::Csize_t,
        trap::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
    if err != C_NULL
        status = Ref{Cint}(0)
        exited = @ccall libwasmtime.wasmtime_error_exit_status(err::Ptr{Cvoid}, status::Ptr{Cint})::Bool
        msg = _error_message(err)
        _error_delete(err)
        throw(_Stopped(msg, false, exited ? Int(status[]) : nothing))
    end
    if trap[] != C_NULL
        code = Ref{UInt8}(0xff)
        known = @ccall libwasmtime.wasmtime_trap_code(trap[]::Ptr{Cvoid}, code::Ptr{UInt8})::Bool
        throw(_Stopped(_trap_message(trap[]), known && code[] == _TRAP_INTERRUPT, nothing))
    end
    [x.of[1] % UInt32 for x in r]
end

# The module's exports, from the instance (or, in a host function, the caller).
function _export(ctx, inst, name, kind)
    ext = Ref{_Extern}()
    found = inst isa Ptr ?   # (a caller)
        @ccall(libwasmtime.wasmtime_caller_export_get(inst::Ptr{Cvoid}, name::Cstring, sizeof(name)::Csize_t,
               ext::Ptr{_Extern})::Bool) :
        @ccall(libwasmtime.wasmtime_instance_export_get(ctx::Ptr{Cvoid}, inst::Ptr{NTuple{2, UInt64}},
               name::Cstring, sizeof(name)::Csize_t, ext::Ptr{_Extern})::Bool)
    found && ext[].kind == kind || throw(_Stopped("libpandoc.wasm exports no $name", false, nothing))
    kind == _EXTERN_FUNC ? Ref(ext[].of[1:2]) : Ref(ext[].of)
end

# The module's memory now: its address and size (it moves when it grows).
function _memory(ctx, mem::Ref)
    data = @ccall libwasmtime.wasmtime_memory_data(ctx::Ptr{Cvoid}, mem::Ptr{NTuple{3, UInt64}})::Ptr{UInt8}
    size = @ccall libwasmtime.wasmtime_memory_data_size(ctx::Ptr{Cvoid}, mem::Ptr{NTuple{3, UInt64}})::Csize_t
    data, size
end

# `bytes` copied into memory the module's malloc gives; where.
function _put(ctx, inst, bytes)
    p = only(_invoke(ctx, _export(ctx, inst, "malloc", _EXTERN_FUNC), (max(length(bytes), 1),), 1))
    p == 0 && throw(_Stopped("libpandoc.wasm is out of memory", false, nothing))
    data, size = _memory(ctx, _export(ctx, inst, "memory", _EXTERN_MEMORY))
    UInt64(p) + length(bytes) <= size || throw(_Stopped("out of bounds memory access", false, nothing))
    GC.@preserve bytes unsafe_copyto!(data + p, pointer(bytes), length(bytes))   # (within its memory: checked)
    p
end

# Bytes of the module's memory, copied: `n` from `p`, or up to a NUL.
function _peek(ctx, mem, p, n = nothing)
    data, size = _memory(ctx, mem)
    p < size || throw(_Stopped("libpandoc.wasm: out of its memory", false, nothing))
    rest = unsafe_wrap(Vector{UInt8}, data + p, size - p)   # (within its memory, read before it can change)
    n === nothing && (n = something(findfirst(==(0x00), rest), 0) - 1)
    0 <= n <= length(rest) || throw(_Stopped("libpandoc.wasm: out of its memory", false, nothing))
    rest[1:n]
end

# A run's state, the store's data: the callbacks, by index.
mutable struct _SandboxRun
    cbs::Vector{_Callback}
end

# `libpandoc.filter(index, doc, doc_len, context, context_len, out)`: the
# callback numbered `index`, here; its answer given with pandoc_buffer_set.
# What it throws is kept for the call to throw, as natively.
function _import_filter(env::Ptr{Cvoid}, caller::Ptr{Cvoid}, args::Ptr{UInt64}, n::Csize_t)::Ptr{Cvoid}
    _host(caller) do
        i, doc, dl, ctx, cl, out = (_arg(args, k) for k in 1:6)
        run = _store_data(caller)::_SandboxRun
        status, answer = Int32(1), codeunits("no such filter")
        if 0 <= i < length(run.cbs)
            cb = run.cbs[i + 1]
            try
                d, c = _guest_bytes(caller, doc, dl), _guest_bytes(caller, ctx, cl)
                result = Base.invokelatest(cb.run, String(d), JSON.parse(String(c)))
                status, answer = Int32(0), result isa AbstractString ? codeunits(String(result)) : result::AbstractVector{UInt8}
            catch e
                cb.error === nothing && (cb.error = (e, catch_backtrace()))
                answer = codeunits(_message(e))
            end
        end
        c = @ccall libwasmtime.wasmtime_caller_context(caller::Ptr{Cvoid})::Ptr{Cvoid}
        p = _put(c, caller, answer)
        _invoke(c, _export(c, caller, "pandoc_buffer_set", _EXTERN_FUNC), (out, p, length(answer)), 0)
        _invoke(c, _export(c, caller, "free", _EXTERN_FUNC), (p,), 0)
        _ret!(args, status)
    end
end

function _sandbox_linker(w)
    linker = @ccall libwasmtime.wasmtime_linker_new(w.engine::Ptr{Cvoid})::Ptr{Cvoid}
    _check((@ccall libwasmtime.wasmtime_linker_define_wasi(linker::Ptr{Cvoid})::Ptr{Cvoid}), "wasmtime")
    _define(linker, "filter", 6, 1, @cfunction(_import_filter, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt64}, Csize_t)))
    linker
end

# NUL-terminated, for C: an argument with a NUL in it is refused (_argv).
_cbytes(s) = [codeunits(s); 0x00]

"""
Run `call` in a fresh instance of the module seeing the mounts:
`(:options, json)` (pandoc_convert_filters, the callbacks `cbs` named by
index in its "filters"), `(:args, argv)` (pandoc_convert_args) or `(:main,
argv, filters_json)` (pandoc_main): (status, output, kind, message, log),
`output` etc. empty for :main. A callback's exception is thrown after it
returns, as natively; a limit met, a PandocError.
"""
function _sandbox_run(m::_Mounts, dirs::_Dirs, call, input, cbs::Vector{_Callback})
    timeout, max_memory = _sandbox_limits(dirs)
    mod, linker = _sandbox_module()
    w = _wasmtime()
    timeout === nothing || _ticking(w)
    ticks = timeout === nothing ? _NO_DEADLINE : min(_NO_DEADLINE, ceil(timeout / _TICK) + 1)
    wasi = @ccall libwasmtime.wasi_config_new()::Ptr{Cvoid}
    argv, names, values = ["libpandoc"], first.(m.env), last.(m.env)
    ok = GC.@preserve argv names values begin
        a, k, v = map(pointer, argv), map(pointer, names), map(pointer, values)
        (@ccall libwasmtime.wasi_config_set_argv(wasi::Ptr{Cvoid}, 1::Csize_t, a::Ptr{Ptr{UInt8}})::Bool) &&
        (@ccall libwasmtime.wasi_config_set_env(wasi::Ptr{Cvoid}, length(k)::Csize_t, k::Ptr{Ptr{UInt8}}, v::Ptr{Ptr{UInt8}})::Bool)
    end
    @ccall libwasmtime.wasi_config_inherit_stdout(wasi::Ptr{Cvoid})::Cvoid
    @ccall libwasmtime.wasi_config_inherit_stderr(wasi::Ptr{Cvoid})::Cvoid
    # pandoc reads standard input when it has no input file, as the command does
    input === nothing && @ccall libwasmtime.wasi_config_inherit_stdin(wasi::Ptr{Cvoid})::Cvoid
    preopens = [(joinpath(m.root, "tmp"), _TMP, true); (joinpath(m.root, "nowhere"), _NOWHERE, false);
                [(host, guest, w) for (guest, host, w) in m.mounts]]
    for (host, guest, writable) in preopens
        ok &= @ccall libwasmtime.wasi_config_preopen_dir(wasi::Ptr{Cvoid}, host::Cstring, guest::Cstring,
                                                         (writable ? 3 : 1)::Csize_t, (writable ? 3 : 1)::Csize_t)::Bool
    end
    ok || (@ccall libwasmtime.wasi_config_delete(wasi::Ptr{Cvoid})::Cvoid; throw(_refused("sandbox: wasmtime can't open a directory or take the environment")))
    run = _SandboxRun(cbs)
    store = @ccall libwasmtime.wasmtime_store_new(w.engine::Ptr{Cvoid}, pointer_from_objref(run)::Ptr{Cvoid}, C_NULL::Ptr{Cvoid})::Ptr{Cvoid}
    started = _now()
    function body()
        ctx = @ccall libwasmtime.wasmtime_store_context(store::Ptr{Cvoid})::Ptr{Cvoid}
        @ccall libwasmtime.wasmtime_store_limiter(store::Ptr{Cvoid}, something(max_memory, -1)::Int64,
                                                  (-1)::Int64, (-1)::Int64, (-1)::Int64, (-1)::Int64)::Cvoid
        @ccall libwasmtime.wasmtime_context_set_epoch_deadline(ctx::Ptr{Cvoid}, UInt64(ticks)::UInt64)::Cvoid
        _stop_on(@ccall libwasmtime.wasmtime_context_set_wasi(ctx::Ptr{Cvoid}, wasi::Ptr{Cvoid})::Ptr{Cvoid})
        inst = Ref{NTuple{2, UInt64}}()
        trap = Ref{Ptr{Cvoid}}(C_NULL)
        err = @ccall gc_safe = true libwasmtime.wasmtime_linker_instantiate(linker::Ptr{Cvoid}, ctx::Ptr{Cvoid},
            mod::Ptr{Cvoid}, inst::Ptr{NTuple{2, UInt64}}, trap::Ptr{Ptr{Cvoid}})::Ptr{Cvoid}
        _stop_on(err)
        trap[] == C_NULL || throw(_Stopped(_trap_message(trap[]), false, nothing))
        _call_in(ctx, inst, call, input, m, length(cbs))
    end
    result = try
        # (the store's data alive meanwhile; the task on this thread, and
        # alone in wasm on it with callbacks: above, "Threads")
        GC.@preserve run _blocking(() -> _pinned(body))
    catch e
        e isa _Stopped || rethrow()
        throw(_stopped(e, dirs, timeout, max_memory, started))
    finally
        @ccall libwasmtime.wasmtime_store_delete(store::Ptr{Cvoid})::Cvoid
    end
    for cb in cbs
        cb.error === nothing || throw(_filter_error(cb.error...))
    end
    result
end

# The module stopped, as an error: its time limit, its memory limit (most
# likely: wasmtime's limiter refuses a growth, and the module's runtime then
# exits or traps), or something else.
function _stopped(e::_Stopped, dirs, timeout, max_memory, started)
    if e.interrupted && timeout !== nothing
        given = dirs.timeout === missing ? TIMEOUT_VAR : "the sandbox's \"timeout\""
        return PandocError("Timeout", "the conversion was stopped after $(round(_now() - started; digits = 1)) s, " *
                                      "its time limit ($given: $timeout)")
    end
    why = e.status === nothing ? last(split(strip(e.message), '\n')) : "its runtime exited with status $(e.status)"
    max_memory === nothing && e.status === nothing && return PandocError("Exception", "libpandoc.wasm stopped: $why")
    limit = max_memory === nothing ? "wasm's 4 GiB" :
            "$max_memory bytes, $(dirs.max_memory === missing ? MAX_MEMORY_VAR : "the sandbox's \"max-memory\"")"
    PandocError("Exception", "libpandoc.wasm stopped ($why), most likely out of memory (its limit: $limit)")
end

function _call_in(ctx, inst, call, input, m, n)
    f(name) = _export(ctx, inst, name, _EXTERN_FUNC)
    _invoke(ctx, f("_initialize"), (), 0)
    _wasm_abi_check(Int(only(_invoke(ctx, f("pandoc_abi_version"), (), 1))), _wasm_path())
    only(_invoke(ctx, f("pandoc_init"), (), 1)) == 0 || throw(_Stopped("pandoc didn't start", false, nothing))
    put(b) = _put(ctx, inst, b)
    words(v) = collect(reinterpret(UInt8, htol.(UInt32.(v))))   # (little-endian, as wasm)
    argv(args) = put(words([put(_cbytes(a)) for a in _argv(args)]))
    # the module's callback filters, all this process's: pandoc_filter
    # {fn = NULL, userdata = i}, 8 bytes on wasm32
    filters = words([isodd(j) ? 0 : j ÷ 2 - 1 for j in 1:2n])
    _invoke(ctx, f("chdir"), (put(_cbytes(only(_argv([m.cwd_mounted === nothing ? _NOWHERE : m.cwd])))),), 1)
    ip, il = input === nothing ? (0, 0) : (put(input), length(input))
    r = if call[1] === :options
        only(_invoke(ctx, f("pandoc_convert_filters"), (put(codeunits(call[2])), sizeof(call[2]), ip, il, put(filters), n), 1))
    elseif call[1] === :args
        only(_invoke(ctx, f("pandoc_convert_args"), (length(call[2]), argv(call[2]), ip, il), 1))
    else
        fj = call[3]
        jp, jl = fj === nothing ? (0, 0) : (put(codeunits(fj)), sizeof(fj))
        status = only(_invoke(ctx, f("pandoc_main"), (length(call[2]), argv(call[2]), jp, jl, put(filters), n), 1))
        return reinterpret(Int32, status), UInt8[], "", "", "[]"
    end
    r == 0 && throw(_Stopped("libpandoc.wasm returned no result", false, nothing))
    # pandoc_result on wasm32: status, output, output_len, error_kind,
    # error_message, log; 4 bytes each
    mem = _export(ctx, inst, "memory", _EXTERN_MEMORY)
    w = ltoh.(reinterpret(UInt32, _peek(ctx, mem, r, 24)))   # (a copy)
    text(p) = p == 0 ? "" : String(_peek(ctx, mem, p))
    kind, log = text(w[4]), text(w[6])
    reinterpret(Int32, w[1]), w[1] == 0 ? _peek(ctx, mem, w[2], w[3]) : UInt8[],
        isempty(kind) ? "Exception" : kind, text(w[5]), isempty(log) ? "[]" : log
end

# Julia's libuv puts the standard streams that are pipes in non-blocking
# mode (uv_pipe_open does), which GHC's runtime handles natively and WASI's
# inherited streams do not: pandoc failed with "hardware fault" (EAGAIN) as
# soon as a pipe was empty or full. So they are blocking while the module
# runs, as for any other program, and as they were once no module runs.
# (Windows: no such mode.)
const _O_NONBLOCK = Sys.isapple() || Sys.isbsd() ? Cint(0x0004) : Cint(0x0800)
const _STD_LOCK = ReentrantLock()
const _STD_FLAGS = Cint[]   # the streams' flags before, while runs go on

function _blocking(f)
    Sys.iswindows() && return f()
    lock(_STD_LOCK) do
        isempty(_STD_FLAGS) || return push!(_STD_FLAGS, -1)   # (one more run)
        for fd in 0:2
            flags = @ccall fcntl(fd::Cint, 3::Cint)::Cint   # F_GETFL
            flags >= 0 && @ccall fcntl(fd::Cint, 4::Cint; (flags & ~_O_NONBLOCK)::Cint)::Cint   # F_SETFL
            push!(_STD_FLAGS, flags)
        end
    end
    try
        f()
    finally
        lock(_STD_LOCK) do
            length(_STD_FLAGS) > 3 && return pop!(_STD_FLAGS)
            for (fd, flags) in zip(0:2, _STD_FLAGS)
                flags >= 0 && @ccall fcntl(fd::Cint, 4::Cint; flags::Cint)::Cint
            end
            empty!(_STD_FLAGS)
        end
    end
end

# -- the entry points -----------------------------------------------------------------

# A conversion's output, after reporting its log; a PandocError if it failed,
# saying so when the working directory isn't mounted.
function _sandbox_take((status, out, kind, msg, log), m::_Mounts)
    _report(log)
    note = _note(m)
    status == 0 || throw(PandocError(kind, note === nothing ? msg : "$msg\n$note"))
    out
end

# `convert` in the sandbox: the options as they are but for "sandbox", the
# filters of this process called back.
function _sandboxed_convert(opts, input, dirs::_Dirs)
    m = _Mounts(dirs)
    try
        cbs, entries = _plan(get(opts, "filters", ()), opts; mounts = m)
        o = Dict{String, Any}(k => v for (k, v) in opts if k != "sandbox")
        isempty(cbs) || (o["filters"] = entries)
        _sandbox_take(_sandbox_run(m, dirs, (:options, _json(o)), _bytes(input), cbs), m)
    finally
        _close(m)
    end
end

# `run` in the sandbox: the arguments as they are.
function _sandboxed_args(args, input, dirs::_Dirs)
    m = _Mounts(dirs)
    try
        _sandbox_take(_sandbox_run(m, dirs, (:args, args), _bytes(input), _Callback[]), m)
    finally
        _close(m)
    end
end
