# pandocjl: pandoc's command line, in process, running Julia and wasm filters
# inside the conversion.

const PROG = "pandocjl"

"pandoc's exit status for a failed filter."
const FILTER_FAILED = 83

# An app's shim gives Julia only the app's own environment; filters are
# looked up in the user's too (the active project, then the default one).
function _user_load_path!()
    for p in ("@", "@v#.#", "@stdlib")
        p in LOAD_PATH || push!(LOAD_PATH, p)
    end
end

"""
    LibPandoc.main(args = ARGS) -> Int

`pandocjl ARGS`: what `pandoc ARGS` does (pandoc parses the arguments,
reads, writes and reports errors itself), the exit status. Except that
filters named with `-F`/`--filter`, on the command line or in a defaults
file, run in this process, inside the conversion, when they are

- a Julia package's: `-F Name` where the package `Name` (in the active or
  the default environment) defines `Name.pandoc_filter`, a filter as
  `filters` takes one (a function, or `f => traverse`);
- a Julia filter script: `-F foo.jl` that ends with Panir's `run_filter`
  (others run as a subprocess of this Julia, see `LibPandoc` on scripts);
- a wasm filter: `-F foo.wasm`, run by wasmtime, seeing no directory
  unless `\$LIBPANDOC_WASM_DIRS` gives some and no variable of this
  process's environment unless `\$LIBPANDOC_WASM_ENV` names it (see
  [`WasmFilter`](@ref)).

Consecutive ones are one exchange with pandoc (one callback, one
`Running filter libpandoc:callback/N` in pandoc's log);
`\$LIBPANDOC_SEPARATE_FILTERS=1` makes each its own.

With `\$LIBPANDOC_SANDBOX` or `\$LIBPANDOC_SANDBOX_WRITE` set, it is the
pandoc command of libpandoc.wasm, in the directory sandbox they list (the
README's "Security"): the filters above run in this process as without it
(a wasm filter seeing its own directories, not the sandbox's), Lua
filters inside, JSON filters not at all.

They are looked for as pandoc does (as given, then in the user data
directory's `filters/`). Other filters run as with pandoc. `-F panclude`
is libpandoc's include step, never a package, script or program of that
name (a program runs as `-F ./panclude`). Installed as an
app (`pkg> app add LibPandoc`) this is the `pandocjl` command; `julia -m
LibPandoc ARGS` is the same. Outside the REPL (`isinteractive()` false) it
makes Ctrl-C end the process at once, as pandoc's does
(`Base.exit_on_sigint(true)`, a script's default, which `julia -m` doesn't
set).
"""
function (@main)(args = ARGS)
    # Ctrl-C ends the command at once, as pandoc's (`julia -m` leaves Julia
    # throwing it, which a call into pandoc takes only when it returns); not
    # when called from the REPL
    isinteractive() || Base.exit_on_sigint(true)
    try
        _main(String.(args))
    catch e
        e isa Base.IOError && e.code == Base.UV_EPIPE || rethrow()
        0  # cut short, as by `| head`
    end
end

function _main(args::Vector{String})
    _user_load_path!()
    dirs = _sandbox_from_env()
    dirs === nothing && return _main(args, nothing, nothing)
    m = try
        _Mounts(dirs)
    catch e
        e isa PandocError || rethrow()
        println(stderr, PROG, ": ", e.message)
        return 1
    end
    try
        _main(args, m, dirs)
    finally
        _close(m)
    end
end

# pandocjl, natively, or in the directory sandbox `dirs` with the mounts `m`.
function _main(args::Vector{String}, m, dirs)
    parsed = try
        # as text: a file name that isn't UTF-8 is U+FFFD here, which matters
        # only if it names a filter; pandoc_main gets the bytes
        query("parse-args"; args = [map(c -> isvalid(c) ? c : '\ufffd', a) for a in args])
    catch e
        e isa PandocError || rethrow()
        Dict{String, Any}()  # pandoc_main reports it, as pandoc does
    end
    filters_json, cbs = nothing, _Callback[]
    if haskey(parsed, "filters")
        separate = try
            !isempty(parsed["filters"]) && _separate(nothing)
        catch e
            e isa ErrorException || rethrow()
            println(stderr, PROG, ": ", e.msg)
            return 1
        end
        cbs, entries = try
            _plan(parsed["filters"], nothing; packages = true, args, separate)
        catch e
            println(stderr, PROG, ": ", sprint(showerror, e))
            return FILTER_FAILED
        end
        isempty(cbs) || (filters_json = JSON.json(entries))
    end
    flush(stdout)
    flush(stderr)
    status = try
        m === nothing ? _pandoc_main([PROG; args], filters_json, cbs) :
                        first(_sandbox_run(m, dirs, (:main, [PROG; args], filters_json), nothing, cbs))
    catch e
        # (the sandbox's own: a limit, the module)
        e isa PandocError && (println(stderr, PROG, ": ", e.message); return 1)
        e isa FilterError || rethrow()
        println(stderr, PROG, ": ", sprint(showerror, e))
        return FILTER_FAILED
    end
    if m !== nothing
        flush(stdout)
        status == 0 || (note = _note(m)) === nothing || println(stderr, note)
    end
    info = get(parsed, "informational", nothing)
    if info == "Help"
        println("\nRun in process: Julia packages defining pandoc_filter (-F Name), Julia filter ",
                "scripts (-F name.jl), wasm filters (-F name.wasm).")
    elseif info == "VersionInfo"
        println("$PROG: pandoc in process, through libpandoc (LibPandoc.jl $(pkgversion(LibPandoc)), Julia $VERSION)")
    end
    Int(status)
end
