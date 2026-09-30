# Filters in a conversion: Julia functions, raw JSON functions, Julia filter
# scripts, wasm filters, and pandoc's own.

"""
    RawFilter(f)

A filter on pandoc's JSON as it is: `f(json::String, conversion::Conversion)`
returns the new document's JSON (a string or bytes). For a filter that
needn't parse the document, or parses it its own way.
"""
struct RawFilter
    f::Any
end

"""
    run_filter(r::RawFilter)

`r` as a pandoc JSON filter (a document on stdin, to stdout), or handed
over to `pandocjl`, which runs the script in its process.
"""
function Panir.run_filter(r::RawFilter; traverse::Symbol = :typewise)
    h = get(task_local_storage(), Panir._HANDOFF, nothing)
    h === nothing || (h[] = (r, traverse); return nothing)
    out = r.f(Base.read(stdin, String), Conversion(ARGS, ENV))
    Base.write(stdout, out)
    nothing
end

# The conversion libpandoc describes to a filter in this process.
function _conversion(context, @nospecialize(options))
    nonempty(k) = (v = get(context, k, nothing); v === nothing || isempty(v) ? nothing : String(v))
    Conversion(; format = nonempty("format"), input_format = nonempty("input-format"),
               output_format = nonempty("output-format"),
               reader_options = get(context, "reader-options", nothing), options)
end

_user_options(@nospecialize(opts)) = opts === nothing ? nothing :
    Dict{String, Any}(k => v for (k, v) in opts if k != "filters")

# Julia filters, one after another on one parse of the document.
function _walks(group::Vector{Pair{Any, Symbol}}, @nospecialize(options))
    user = _user_options(options)
    function (json::String, context)
        c = _conversion(context, user)
        doc = Panir.parse(json)
        for (f, traverse) in group
            doc = walk!(f, doc; traverse, format = c)
            doc isa Panir.Pandoc || throw(ArgumentError("the filter $f made a $(typeof(doc)), not a Pandoc"))
        end
        Panir.serialize(doc)
    end
end

_raw(r::RawFilter, @nospecialize(options)) = (user = _user_options(options);
                               (json, context) -> r.f(json, _conversion(context, user)))

# A Julia filter given in `filters`: a function (or anything callable), or
# `f => traverse`.
_julia_filter(f::Pair{<:Any, Symbol}) = Pair{Any, Symbol}(f.first, f.second)
_julia_filter(f) = Pair{Any, Symbol}(f, :typewise)
_is_julia_filter(f) = !(f isa Union{AbstractString, AbstractDict, RawFilter, WasmFilter})

# A JSON filter's path, as pandoc reads the "filters" option.
_json_path(f::AbstractString) = (f == "citeproc" || endswith(lowercase(f), ".lua")) ? nothing : String(f)
_json_path(f::AbstractDict) = get(f, "type", nothing) == "json" ? String(f["path"]) : nothing
_json_path(f) = nothing

"""
The callbacks for the filters that run in this process, and pandoc's
"filters" option naming them. Consecutive Julia filters share one callback
(one parse of the document); a script or a wasm filter is one each.
`packages`: a JSON filter's name may be a Julia package's (pandocjl).
"""
function _plan(@nospecialize(filters), @nospecialize(options); packages::Bool = false, args = String[])
    cbs = _Callback[]
    entries = Any[]
    group = Pair{Any, Symbol}[]
    function add(run)
        push!(entries, Dict("type" => "callback", "index" => length(cbs)))
        push!(cbs, _Callback(run))
    end
    flush() = isempty(group) || (add(_walks(copy(group), options)); empty!(group))
    for f in filters
        if _is_julia_filter(f)
            push!(group, _julia_filter(f))
            continue
        end
        path = _json_path(f)
        pkg = packages && path !== nothing ? _package_filter(path) : nothing
        if pkg !== nothing && _is_julia_filter(pkg)
            push!(group, _julia_filter(pkg))
            continue
        end
        flush()
        pkg === nothing || (f = pkg)
        if f isa RawFilter
            add(_raw(f, options))
        elseif f isa WasmFilter
            add(_raw(RawFilter(f), options))
        elseif path !== nothing && endswith(lowercase(path), ".wasm")
            found = _find_filter(path, options, args)
            found === nothing && throw(ArgumentError("wasm filter $path not found"))
            add(_raw(RawFilter(_wasm_filter(found)), options))
        elseif path !== nothing && (found = _find_filter(path, options, args)) !== nothing &&
               _is_julia_script(found)
            add(_script(found, path, options))
        else
            push!(entries, f)
        end
    end
    flush()
    cbs, entries
end

# -- finding filters ---------------------------------------------------------------

"""
A filter's file as pandoc finds one: as given, else in the user data
directory's `filters/`.
"""
function _find_filter(path, @nospecialize(options), args)
    isfile(path) && return path
    d = _data_dir(options, args)
    d === nothing && return nothing
    p = joinpath(d, "filters", path)
    isfile(p) ? p : nothing
end

# pandoc's user data directory: `--data-dir` (or the option), else
# `$XDG_DATA_HOME/pandoc` if it exists, else `~/.pandoc`.
function _data_dir(@nospecialize(options), args)
    options !== nothing && haskey(options, "data-dir") && return String(options["data-dir"])
    for (i, a) in enumerate(args)
        startswith(a, "--data-dir=") && return a[length("--data-dir=") + 1:end]
        a == "--data-dir" && i < length(args) && return args[i + 1]
    end
    Sys.iswindows() && return joinpath(get(ENV, "APPDATA", homedir()), "pandoc")
    xdg = joinpath(get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share")), "pandoc")
    isdir(xdg) ? xdg : joinpath(homedir(), ".pandoc")
end

"""
A Julia package's filter, for `-F Name` in pandocjl: `Name.pandoc_filter`
where `Name` is a package in the load path (the active environment and the
default one) that defines it. `nothing` otherwise, then pandoc runs `Name`
as it would.
"""
function _package_filter(name::AbstractString)
    Base.isidentifier(name) || return nothing
    isfile(name) && return nothing
    id = Base.identify_package(name)
    id === nothing && return nothing
    m = Base.require(id)
    isdefined(m, :pandoc_filter) || return nothing
    Base.invokelatest(getproperty, m, :pandoc_filter)
end

const _WASM_FILTERS = Dict{String, Tuple{Float64, WasmFilter}}()
const _WASM_LOCK = ReentrantLock()

# A wasm filter by path, compiled once per process (again if the file changes).
function _wasm_filter(path)
    key, t = abspath(path), mtime(path)
    lock(_WASM_LOCK) do
        c = get(_WASM_FILTERS, key, nothing)
        c !== nothing && c[1] == t && return c[2]
        f = WasmFilter(path)
        _WASM_FILTERS[key] = (t, f)
        f
    end
end
