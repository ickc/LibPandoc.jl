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
    Panir.hand_over(r, traverse) && return nothing
    out = r.f(Base.read(stdin, String), Conversion(ARGS, ENV))
    Base.write(stdout, out)
    nothing
end

# The conversion libpandoc describes to a filter in this process (its
# context), and the conversion's options when known.
_conversion(context, @nospecialize(options)) = Conversion(context; options)

_user_options(@nospecialize(opts)) = opts === nothing ? nothing :
    Dict{String, Any}(k => v for (k, v) in opts if k != "filters")

# -- runs: consecutive filters of this process, one exchange with pandoc --------------

"The environment variable that makes each filter its own exchange with pandoc (`1`)."
const SEPARATE_VAR = "LIBPANDOC_SEPARATE_FILTERS"

# Whether each filter is its own exchange: `given` (the options'
# "separate-filters") if not `nothing`, else $LIBPANDOC_SEPARATE_FILTERS: `1`
# yes; unset, empty or `0` no; anything else an error, as a safety switch is
# not to be ignored.
function _separate(given)
    if given !== nothing
        given isa Bool || throw(_refused("\"separate-filters\": true or false, not $(repr(given))"))
        return given
    end
    v = get(ENV, SEPARATE_VAR, "")
    v in ("", "0") && return false
    v == "1" && return true
    error("$SEPARATE_VAR: 1 (each filter its own exchange with pandoc), or 0 or empty, not $(repr(v))")
end

# A member of a run on the parsed document: a Julia filter walked with
# `traverse`; `script`: a script's, its `cd` undone when it returns.
struct _Walk
    f::Any
    traverse::Symbol
    script::Bool
end

# A member of a run on pandoc's JSON: `run(json::String, context)` returns
# the new document's (a string or bytes): a RawFilter, a wasm filter, a
# script run as a subprocess. `trace`: whether its failure's backtrace is
# worth keeping (a RawFilter's: its function's frames), or only this
# package's frames under a message that says it all (a wasm filter's, a
# subprocess's), which the FilterError then goes without.
struct _OnJson
    run::Any
    trace::Bool
end
_OnJson(run) = _OnJson(run, true)

"""
One callback of libpandoc's, one exchange with pandoc: consecutive filters
of this process, each with its place in the list given (from 1). From one
to the next: to a Julia filter after another, the same `Panir.Pandoc`; to
one on JSON after a Julia filter, written once; to a Julia filter after one
on JSON, parsed once; to one on JSON after another, the JSON as it was
written, unchecked. `token`, the call's: a cancelled one stops the run
before the next filter.
"""
mutable struct _Run
    members::Vector{Pair{Int, Any}}
    options::Any   # the conversion's, without "filters" (a filter's ctx.conversion.options)
    token::Union{Nothing, CancelToken}
end

_text(x::String) = x
_text(x::AbstractString) = String(x)
_text(x::AbstractVector{UInt8}) = String(copy(x))   # (the filter may keep its vector)

function (r::_Run)(json::String, context)
    doc = nothing          # the document parsed, or
    data::Any = json       # as JSON: pandoc's, written, or what the filter at `wrote` wrote, unchecked
    wrote = nothing
    for (k, (i, m)) in enumerate(r.members)
        # (pandoc stops a cancelled conversion only when the callback returns)
        k > 1 && r.token !== nothing && iscancelled(r.token) && throw(PandocError("Cancelled", _CANCELLED))
        if m isa _Walk
            if doc === nothing
                doc = try
                    Panir.parse(_text(data))
                catch e
                    throw(FilterError(e, catch_backtrace(), i, wrote, true))
                end
            end
            c = _conversion(context, r.options)
            walk() = walk!(m.f, doc; traverse = m.traverse, format = c)
            doc = try
                m.script ? _in_dir(walk) : walk()
            catch e
                throw(_named(e, catch_backtrace(), i, nothing))
            end
            data, wrote = nothing, nothing
        else
            data === nothing && (data = Panir.serialize(doc))
            data = try
                m.run(_text(data), context)
            catch e
                throw(_named(e, m.trace ? catch_backtrace() : nothing, i, wrote))
            end
            doc, wrote = nothing, i
        end
    end
    data === nothing ? Panir.serialize(doc) : data
end

# A filter's failure, naming it: a FilterError, but a time limit's or a
# cancel's PandocError as it is (`istimeout`, `iscancelled`).
_named(e, bt, i, from) = istimeout(e) || iscancelled(e) ? e : FilterError(e, bt, i, from, false)

# A Julia filter given in `filters`: a function (or anything callable), or
# `f => traverse`.
_julia_filter(f::Pair{<:Any, Symbol}) = Pair{Any, Symbol}(f.first, f.second)
_julia_filter(f) = Pair{Any, Symbol}(f, :typewise)
_is_julia_filter(f) = !(f isa Union{AbstractString, AbstractDict, RawFilter, WasmFilter})

# A JSON filter's path, as pandoc reads the "filters" option. Not the
# include step's name (libpandoc 1.15: "panclude", -F panclude), which
# libpandoc runs, whatever a file or package of that name is (a program
# named so runs as ./panclude).
const _PANCLUDE = "panclude"
_not_panclude(path) = path == _PANCLUDE ? nothing : path
_json_path(f::AbstractString) = (f == "citeproc" || endswith(lowercase(f), ".lua")) ? nothing : _not_panclude(String(f))
_json_path(f::AbstractDict) = get(f, "type", nothing) == "json" ? _not_panclude(String(f["path"])) : nothing
_json_path(f) = nothing

_walk(f, script = false) = (p = _julia_filter(f); _Walk(p.first, p.second, script))
_on_json(r::RawFilter, @nospecialize(options)) = (user = _user_options(options);
                                                  _OnJson((json, context) -> r.f(json, _conversion(context, user))))
_on_json(w::WasmFilter, @nospecialize(options)) = _OnJson(_on_json(RawFilter(w), options).run, false)

"""
The callbacks for the filters that run in this process, and pandoc's
"filters" option naming them: each stretch of consecutive ones is one
callback (a `_Run`, one exchange with pandoc), or with `separate` each its
own. `packages`: a JSON filter's name may be a Julia package's (pandocjl).
"""
function _plan(@nospecialize(filters), @nospecialize(options); packages::Bool = false, args = String[],
               separate::Bool = false)
    filters isa Union{AbstractVector, Tuple} ||
        throw(ArgumentError("filters: a vector of filters, not $(repr(filters)): filters = [f]"))
    cbs = _Callback[]
    entries = Any[]
    user = _user_options(options)
    open = false   # whether the last entry is a run that takes the next filter
    for (i, f) in enumerate(filters)
        # (an absent option is nothing, but a list holding it is an error)
        f === nothing && throw(ArgumentError("filters: `nothing` is not a filter"))
        m = _member(f, options, packages, args)
        if m === nothing
            push!(entries, f)
            open = false
            continue
        end
        if open
            push!(last(cbs).run.members, i => m)
        else
            push!(entries, Dict("type" => "callback", "index" => length(cbs)))
            push!(cbs, _Callback(_Run(Pair{Int, Any}[i => m], user, nothing)))
        end
        open = !separate
    end
    cbs, entries
end

# A filter as a member of a run, or `nothing` for one of pandoc's own.
function _member(@nospecialize(f), @nospecialize(options), packages, args)
    _is_julia_filter(f) && return _walk(f)
    path = _json_path(f)
    pkg = packages && path !== nothing ? _package_filter(path) : nothing
    if pkg !== nothing
        _is_julia_filter(pkg) && return _walk(pkg)
        f = pkg
    end
    f isa Union{RawFilter, WasmFilter} && return _on_json(f, options)
    if path !== nothing && endswith(lowercase(path), ".wasm")
        found = _find_filter(path, options, args)
        found === nothing && throw(ArgumentError("wasm filter $path not found"))
        return _on_json(_wasm_filter(found), options)
    end
    if path !== nothing && (found = _find_filter(path, options, args)) !== nothing && _is_julia_script(found)
        return _script(found, options)
    end
    nothing
end

# The call's cancel token, for the runs among `cbs` to look at.
function _told!(cbs::Vector{_Callback}, token)
    for cb in cbs
        cb.run.token = token
    end
    cbs
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

const _WASM_FILTERS = Dict{String, Tuple{Tuple, WasmFilter}}()
const _WASM_LOCK = ReentrantLock()

# What tells that a file changed: its modification time, size and inode (a
# file replaced within the time's resolution, or with the same time, is
# another file).
_file_version(path) = (s = stat(path); (s.mtime, s.size, s.inode))

# A wasm filter by path, compiled once per process (again if the file changes).
function _wasm_filter(path)
    key, t = abspath(path), _file_version(path)
    lock(_WASM_LOCK) do
        c = get(_WASM_FILTERS, key, nothing)
        c !== nothing && c[1] == t && return c[2]
        f = WasmFilter(path)
        _WASM_FILTERS[key] = (t, f)
        f
    end
end
