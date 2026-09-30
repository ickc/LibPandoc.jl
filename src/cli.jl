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
- a wasm filter: `-F foo.wasm`, run by wasmtime.

They are looked for as pandoc does (as given, then in the user data
directory's `filters/`). Other filters run as with pandoc. Installed as an
app (`pkg> app add LibPandoc`) this is the `pandocjl` command; `julia -m
LibPandoc ARGS` is the same.
"""
function (@main)(args = ARGS)
    try
        _main(String.(args))
    catch e
        e isa Base.IOError && e.code == Base.UV_EPIPE || rethrow()
        0  # cut short, as by `| head`
    end
end

function _main(args::Vector{String})
    _user_load_path!()
    parsed = try
        query("parse-args"; args)
    catch e
        e isa PandocError || rethrow()
        Dict{String, Any}()  # pandoc_main reports it, as pandoc does
    end
    filters_json, cbs = nothing, _Callback[]
    if haskey(parsed, "filters")
        cbs, entries = try
            _plan(parsed["filters"], nothing; packages = true, args)
        catch e
            println(stderr, PROG, ": ", sprint(showerror, e))
            return FILTER_FAILED
        end
        isempty(cbs) || (filters_json = JSON.json(entries))
    end
    flush(stdout)
    flush(stderr)
    status = try
        _pandoc_main([PROG; args], filters_json, cbs)
    catch e
        e isa FilterError || rethrow()
        println(stderr, PROG, ": ", sprint(showerror, e))
        return FILTER_FAILED
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
