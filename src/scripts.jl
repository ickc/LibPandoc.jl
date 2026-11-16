# Julia filter scripts (`-F foo.jl`), run in this process.
#
# A panir script ends with `run_filter(f)`. Here it is loaded into a module
# of its own, once per process (again if the file changes), and its
# `run_filter` hands `f` over (`Panir.handoff`) instead of reading stdin:
# `f` then runs on the document in the conversion, as a Julia filter given
# as a function does. What this saves per filter is starting Julia and
# compiling the script's packages again: seconds, not milliseconds.
#
# Scripts that don't use `run_filter` (reading and writing the JSON
# themselves) run as a subprocess, with this Julia and its load path, since
# Julia's standard streams belong to the process, not to a task. So do
# scripts that say so (`# pandocjl: subprocess`) and those the user names in
# `$PANDOCJL_SUBPROCESS` (paths, file names, names without `.jl`, or `*`).
# A script that fails to load in process, or hands no filter over, is not
# run again as a subprocess (its side effects would happen twice): the
# conversion fails, saying how to opt out.
#
# A script runs in this process with all its rights: what it changes in
# `ENV`, the modules it loads and the tasks it starts stay. Its working
# directory is restored when it returns, so that pandoc writes the output
# where it was named.

const SUBPROCESS_ENV = "PANDOCJL_SUBPROCESS"
const _MARKER = r"^#\s*pandocjl:\s*subprocess\b"m
const _HANDS_OVER = r"\brun_filter\b"
const _HEAD = 4096

"A file ending in `.jl`, or with a Julia `#!` line."
function _is_julia_script(path)
    isfile(path) || return false
    endswith(lowercase(path), ".jl") && return true
    first = try
        open(io -> String(Base.read(io, 256)), path)
    catch
        return false
    end
    startswith(first, "#!") && occursin("julia", split(first, '\n')[1])
end

"Why this script runs as a subprocess, if it does."
function _subprocess_reason(path, source)
    names = Set(strip.(split(get(ENV, SUBPROCESS_ENV, ""), ',')))
    base = basename(path)
    isempty(intersect(names, ("*", path, base, first(splitext(base))))) || return "\$$SUBPROCESS_ENV"
    occursin(_MARKER, source[1:min(end, _HEAD)]) && return "# pandocjl: subprocess"
    occursin(_HANDS_OVER, source) || return "it doesn't call run_filter"
    nothing
end

struct _Loaded
    mtime::Float64
    filter::Union{Nothing, Pair{Any, Symbol}}   # nothing: a subprocess
end

const _SCRIPTS = Dict{String, _Loaded}()
const _SCRIPTS_LOCK = ReentrantLock()

# The script's filter, loaded once (again if the file changed); nothing if
# it runs as a subprocess.
function _load_script(path)
    key = abspath(path)
    t = mtime(key)
    lock(_SCRIPTS_LOCK) do
        l = get(_SCRIPTS, key, nothing)
        l !== nothing && l.mtime == t && return l.filter
        source = Base.read(key, String)
        why = _subprocess_reason(path, source)
        f = why === nothing ? _include_script(key) : nothing
        _SCRIPTS[key] = _Loaded(t, f)
        f
    end
end

"""
    ScriptFailed(path, exception, backtrace)

A Julia filter script that failed to load in process (`exception` is
`nothing` when it ran but handed no filter over). It is not run again as a
subprocess: the message says how to have it run so.
"""
struct ScriptFailed <: Exception
    path::String
    exception::Any
    backtrace::Any
end

function Base.showerror(io::IO, e::ScriptFailed)
    print(io, e.path, e.exception === nothing ? " called no run_filter in process" : " failed in process",
          ". If it needs a process of its own, add the line `# pandocjl: subprocess` to it, ",
          "or set $SUBPROCESS_ENV=", basename(e.path))
    e.exception === nothing || (print(io, ":\n"); showerror(io, e.exception, e.backtrace))
end

# `f()`, then back in the working directory it started in: a script's `cd`
# stays its own.
function _in_dir(f)
    dir = pwd()
    try
        f()
    finally
        pwd() == dir || cd(dir)
    end
end

function _include_script(path)
    m = Module(Symbol("filter:", basename(path)))
    # as `julia path` would have it: a module where `include` is relative to it
    Core.eval(m, :(include(x) = Base.include($m, x)))
    handed = try
        _in_dir(() -> Panir.handoff(() -> Base.include(m, path)))
    catch e
        throw(ScriptFailed(path, e, catch_backtrace()))
    end
    handed === nothing && throw(ScriptFailed(path, nothing, nothing))
    f, traverse = handed
    Pair{Any, Symbol}(f, traverse)
end

# The callback for a script: in process when it hands its filter over, else
# a subprocess.
function _script(path, name, @nospecialize(options))
    f = _load_script(path)
    f === nothing && return (json, context) -> _subprocess(path, json, context)
    run = f.first isa RawFilter ? _raw(f.first, options) :
          f.first isa WasmFilter ? _raw(RawFilter(f.first), options) : _walks([f], options)
    (json, context) -> _in_dir(() -> run(json, context))
end

"As libpandoc runs a JSON filter (its variables), with this Julia and its load path."
function _subprocess(path, json::String, context)
    c = _conversion(context, nothing)
    fmt = something(c.format, "")
    env = copy(ENV)
    # a format libpandoc doesn't know is unset, as for a wasm filter
    delete!(env, "PANDOC_INPUT_FORMAT"), delete!(env, "PANDOC_OUTPUT_FORMAT"), delete!(env, "PANDOC_WRITER_OPTIONS")
    merge!(env, Dict(_filter_env(c)))
    env["JULIA_LOAD_PATH"] = join(Base.load_path(), Sys.iswindows() ? ';' : ':')
    cmd = `$(Base.julia_cmd()) --startup-file=no $path $fmt`
    out = IOBuffer()
    p = Base.run(pipeline(ignorestatus(setenv(cmd, env)); stdin = IOBuffer(json), stdout = out, stderr = stderr))
    success(p) || error("$path returned error status $(p.exitcode)")
    take!(out)
end
