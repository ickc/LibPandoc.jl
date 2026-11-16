# The API: convert, run, read, read_many, write, and pandoc's queries.

# Options as pandoc's defaults-file keys: `_` for `-` in keyword names.
_key(k) = replace(String(k), '_' => '-')

function _options(options::AbstractDict, kw)
    opts = Dict{String, Any}(String(k) => v for (k, v) in options)
    for (k, v) in kw
        opts[_key(k)] = v
    end
    opts
end

# The format: an argument, or an option under either of pandoc's names
# (`names`), not both; else `default`.
function _format!(opts, given, names, default)
    there = [k for k in names if haskey(opts, k)]
    length(there) + (given !== nothing) > 1 &&
        throw(ArgumentError("the format given twice: $(join([given === nothing ? String[] : ["as an argument"]; there], ", "))"))
    if isempty(there)
        opts[first(names)] = given === nothing ? default : given
    elseif first(there) != first(names)
        opts[first(names)] = pop!(opts, first(there))
    end
    opts
end

# Options a function has no use for: refused rather than ignored.
function _refuse(opts, keys, what)
    bad = [k for k in keys if haskey(opts, k)]
    isempty(bad) || throw(ArgumentError("$what takes no $(join(bad, ", "))"))
end

# A conversion with no input would read this process's standard input, and
# pandoc closes it: refused (pass `read(stdin)`).
function _input(input, opts)
    input === nothing && isempty(something(get(opts, "input-files", nothing), ())) &&
        throw(ArgumentError("no input: give the document (`read(stdin)` for standard input) or `input_files`"))
    input
end

# What libpandoc is given as JSON: UTF-8, as JSON is (a file name that isn't
# would be refused as "Invalid UTF-8 stream", or read as another name).
function _json(x)
    s = JSON.json(x)
    isvalid(s) || throw(ArgumentError("text that isn't UTF-8 (a file name?): libpandoc takes " *
                                      "options, queries and read_many's texts as JSON, which is UTF-8"))
    s
end

"""
    LibPandoc.query(name; params...)

One of libpandoc's queries (`libpandoc.h`), its answer as parsed JSON:
`query("extensions-for-format"; format = "gfm")`.
"""
query(name::AbstractString; params...) =
    JSON.parse(String(_query(_json(Dict{String, Any}("query" => name, (String(k) => v for (k, v) in params)...)))))

const _VERSION = _Once{String}()

# as pandoc writes it ("3.12"), for PANDOC_VERSION
function _version_string()
    v = _VERSION[]
    v === nothing || return v
    _VERSION[] = String(query("version"))
end

"The version of the pandoc library in use, e.g. `v\"3.12.0\"`."
pandoc_version() = VersionNumber(_version_string())

"The pandoc-types API version of its AST, e.g. `(1, 23, 1)`."
api_version() = Tuple(Int.(query("api-version")))

"Reader names, as `pandoc --list-input-formats`."
input_formats() = Vector{String}(query("input-formats"))

"Writer names, as `pandoc --list-output-formats`."
output_formats() = Vector{String}(query("output-formats"))

"The extensions a format supports, and whether each is on by default."
extensions(format::AbstractString) = Dict{String, Bool}(query("extensions-for-format"; format))

"The default template for a format, as `pandoc -D FORMAT`."
default_template(format::AbstractString) = String(query("default-template"; format))

"""
How many threads pandoc runs on (or, before it has grown to them, will):
one per logical core this process may use, unless `\$LIBPANDOC_NUM_THREADS`
or [`set_num_threads`](@ref) says otherwise. pandoc starts on one and grows
to that number once, the first time it runs something in parallel (calls
from two threads at once, or `read_many` of several texts). Conversions
from different Julia tasks and threads, and `read_many`, run in parallel on
them.
"""
num_threads() = Int(query("num-threads"))

"""
    set_num_threads(n) -> Int

The number of threads pandoc is to grow to (see [`num_threads`](@ref)),
clamped to between 1 and one per logical core this process may use; the
number in effect. Only until pandoc has grown: after that it changes
nothing, and returns the number pandoc runs on. So a result other than `n`
means `n` was out of range, or came too late: set it before the first
conversions run in parallel.
"""
set_num_threads(n::Integer) = Int(ccall(_load().set_num_threads, Cint, (Cint,), n))

const _BINARY = ("docx", "odt", "epub", "epub2", "epub3", "pptx", "pdf", "chunkedhtml", "xlsx")

# Whether pandoc writes `to` as text (a String) or bytes.
function _text_output(to)
    to isa AbstractString || return true
    base = first(split(to, r"[+-]"))
    endswith(base, ".lua") || base ∉ _BINARY
end

"""
    LibPandoc.convert(input = nothing, options = Dict(); options...)

Convert `input` (a string or bytes, what pandoc would read on standard
input; `nothing` for the options' `input_files`, which are then required)
as `pandoc` would, with these options: pandoc's defaults-file keys, as
keywords with `_` for `-` (`reference_doc = "ref.docx"`) or as a `Dict`
(a keyword wins over the same key in it). The output: a `String` for text
formats, bytes for binary ones (docx, pdf, ...), and `""` when
`output_file` names a file.

`filters` may mix pandoc's (Lua or JSON filter paths, `"citeproc"`) with
Julia ones, in order, all inside the one pandoc run (see [`LibPandoc`](@ref)).

libpandoc's own options: `untrusted = true` (for options from code you
don't trust: only those that read, write, fetch and run nothing, with
pandoc's sandbox on), and `timeout` (seconds): a conversion still running
after that long is stopped, a `PandocError` of kind `"Timeout"`, and the
process goes on. It stops pandoc's own code (readers, writers, templates,
citeproc), a JSON filter pandoc runs and a Julia script run as a
subprocess, not code in this process or in Lua: a Julia filter (a function, a script, a wasm filter, which has its own
limits) runs to its end, and the conversion then fails when it returns; a
Lua filter isn't stopped at all. There is no memory limit: for documents
from someone you don't trust, `sandbox = (read = [dirs], write = [dirs])`
runs the whole conversion in libpandoc.wasm, seeing only those
directories, within `\$LIBPANDOC_WASM_TIMEOUT` and
`\$LIBPANDOC_WASM_MAX_MEMORY` (or the sandbox's `timeout` and
`max_memory`): the README's "Security". Else give it a process of its own
and a `timeout`, with `sandbox = true` or `untrusted = true` so that it
reads nothing the document names.

```julia
upper(s::Str) = Str(uppercase(s.text))
LibPandoc.convert("*hi*"; from = "markdown", to = "html", filters = [upper])
LibPandoc.convert(; input_files = ["a.md"], output_file = "a.docx")
```
"""
function convert(input = nothing, options::AbstractDict = Dict{String, Any}(); kw...)
    opts = _options(options, kw)
    _input(input, opts)
    dirs = _sandbox_of(opts)
    out = if dirs !== nothing
        _sandboxed_convert(opts, input, dirs)
    else
        cbs, entries = _plan(get(opts, "filters", ()), opts)
        isempty(cbs) || (opts = merge(opts, Dict("filters" => entries)))
        _convert(_json(opts), input, cbs)
    end
    # (output-file null or "-": pandoc's standard output, which is `out`)
    get(opts, "output-file", nothing) isa AbstractString && opts["output-file"] != "-" && return ""
    _text_output(something(get(opts, "to", nothing), get(opts, "writer", nothing), "html")) ? String(out) : out
end

"""
    LibPandoc.run(args; input = nothing) -> Vector{UInt8}

Run pandoc with command-line arguments, as `pandoc ARGS`: what it writes to
standard output. `input` is standard input; with no `input` and no input
file among the arguments, pandoc reads this process's standard input, as
the command does (and closes it). Informational options (`--version`,
`--list-*`) are refused: use [`pandoc_version`](@ref) and the like instead.
With `\$LIBPANDOC_SANDBOX` or `\$LIBPANDOC_SANDBOX_WRITE` set, in the
directory sandbox (the README's "Security").
"""
function run(args::AbstractVector{<:AbstractString}; input = nothing)
    all(isvalid, args) || throw(ArgumentError("run's arguments are UTF-8 (libpandoc's pandoc_convert_args): " *
                                              "for a file name that isn't, main (pandocjl) takes any"))
    dirs = _sandbox_from_env()
    dirs === nothing ? _convert_args(args, input) : _sandboxed_args(args, input, dirs)
end

"""
    LibPandoc.read(text, from = "markdown"; options...) -> Panir.Pandoc
    LibPandoc.read(text, conversion::Panir.Conversion; options...)

Parse `text` (a string or bytes; `nothing` for the options'
`input_files`) into a document, converting as [`convert`](@ref) does
(filters, `timeout`, ...) to pandoc's JSON. The format is an argument or
the option `from` (or `reader`), not both. Given the conversion a filter
runs in (`ctx.conversion`), read it the way that conversion reads its
input, as [`read_many`](@ref) does: for a filter that parses a fragment.
"""
function read(text, from::Union{Nothing, AbstractString} = nothing; kw...)
    opts = _options(Dict{String, Any}(), kw)
    _refuse(opts, ("to", "writer", "output-file"), "read (its output is the document)")
    _format!(opts, from, ("from", "reader"), "markdown")
    opts["to"] = "json"
    Panir.parse(convert(text, opts))
end

read(text, c::Conversion; kw...) = only(read_many([text], c; kw...))

"""
    LibPandoc.read_many(texts, from = "markdown"; return_exceptions = false, options...) -> Vector{Panir.Pandoc}

Parse many texts (a vector of strings), each on its own, in parallel: one call into pandoc,
which sets up the reader once and reads the texts on all its threads, much
cheaper than a `read` each. `from` is a format, or the conversion a filter
runs in (`ctx.conversion`), to read the texts the way it reads its input
(the format: an argument or the option `from`, not both). Only options
that affect reading are taken (`tab_stop`, `abbreviations`,
`resource_path`, `sandbox`, ...), and `timeout` (seconds), the whole
call's: it returns within about that long, a text not read by then failing
with a `PandocError` of kind `"Timeout"`. The readers' warnings (an include
file not found) are logged, as `convert`'s.

A text that can't be read throws its `PandocError` (the first one's); with
`return_exceptions = true` each such error is in the result in its text's
place instead, the others' documents kept.

```julia
cells(b::CodeBlock, ctx) =
    reduce(vcat, (d.blocks for d in LibPandoc.read_many(split(b.text, '\\n'), ctx.conversion)))
```
"""
function read_many(texts, from::Union{Nothing, AbstractString, Conversion} = nothing;
                   return_exceptions::Bool = false, kw...)
    texts isa Union{AbstractString, AbstractVector{UInt8}} &&
        throw(ArgumentError("read_many takes texts, not one: read_many([text])"))
    opts = _options(Dict{String, Any}(), kw)
    bad = setdiff(keys(opts), _READ_MANY_OPTIONS)
    isempty(bad) || throw(ArgumentError("read_many takes only options that affect reading, not $(join(sort!(collect(bad)), ", "))"))
    if from isa Conversion
        # the conversion's way, in another format if the options name one
        _format!(opts, nothing, ("from", "reader"), nothing)
        opts = merge(read_options(from, opts["from"]), filter(p -> p.first != "from", opts))
    else
        _format!(opts, from, ("from", "reader"), "markdown")
    end
    get(opts, "sandbox", nothing) isa Union{AbstractDict, NamedTuple} &&
        throw(PandocError("PandocOptionError", "read_many: a directory sandbox is for conversions " *
                                               "(\"sandbox\": true reads no files)"))
    inputs = String[t isa AbstractVector{UInt8} ? String(copy(t)) : String(t) for t in texts]
    out = JSON.parse(String(_read_many(_json(Dict("options" => opts, "inputs" => inputs)))))
    docs = Any[]
    for (i, j) in enumerate(out)
        if haskey(j, "error")
            e = PandocError(j["error"]["kind"], "reading input $i: $(j["error"]["message"])")
            return_exceptions || throw(e)
            push!(docs, e)
        else
            push!(docs, Panir.fromjson(Panir.Pandoc, j))
        end
    end
    return_exceptions ? docs : Vector{Panir.Pandoc}(docs)
end

# What read_many takes: pandoc's options that affect reading (libpandoc.h),
# and libpandoc's own.
const _READ_MANY_OPTIONS = ("from", "reader", "abbreviations", "data-dir", "default-image-extension",
                            "indented-code-classes", "preserve-tabs", "resource-path", "sandbox",
                            "strip-comments", "tab-stop", "track-changes", "timeout", "untrusted")

# The conversion's options that also apply to reading a fragment of it.
const _READ_OPTIONS = ("abbreviations", "data-dir", "default-image-extension", "indented-code-classes",
                       "preserve-tabs", "resource-path", "strip-comments", "tab-stop", "track-changes")
# Whether a conversion is sandboxed, for what a filter reads through it; with
# no options, that can't be told: sandboxed, failing closed.
function _sandboxed(c::Conversion)
    c.options === nothing && return true
    s = get(c.options, "sandbox", nothing)
    !(s === nothing || s === false)
end

# Reader options (as pandoc gives filters) that have a defaults-file key.
const _READER_OPTIONS = ("default-image-extension", "indented-code-classes", "strip-comments", "tab-stop")
const _TRACK_CHANGES = Dict("accept-changes" => "accept", "reject-changes" => "reject", "all-changes" => "all")

"""
    read_options(conversion, format = nothing) -> Dict

Options (defaults-file keys) to read a fragment as `conversion` reads its
input: its input format (or `format`), and the options that affect
reading; not filters, templates, metadata or the output.

When the conversion is sandboxed, or when that can't be told, a fragment
is read in pandoc's own sandbox (`"sandbox" => true`: it reads no files,
as LaTeX's `\\input` or an RST or Org include would). A conversion is
sandboxed when its options' `"sandbox"` is `true` or a directory sandbox
(whose filters run in this process, outside it); it can't be told for a
conversion with no options: pandocjl's (pandoc doesn't tell its filters
about `--sandbox`, on the command line or in a defaults file), a script's
run as a subprocess (made from its environment), one made by hand. Options
given to `read` or `read_many` beside the conversion win over these
(`sandbox = false` reads files again: the filter's author's choice).
"""
function read_options(c::Conversion, format = nothing)
    opts = Dict{String, Any}()
    if c.options !== nothing
        for (k, v) in c.options
            k in _READ_OPTIONS && (opts[k] = v)
        end
    elseif c.reader_options !== nothing
        ro = c.reader_options
        for k in _READER_OPTIONS
            haskey(ro, k) && (opts[k] = ro[k])
        end
        tc = get(_TRACK_CHANGES, get(ro, "track-changes", ""), nothing)
        tc === nothing || (opts["track-changes"] = tc)
    end
    delete!(opts, "sandbox")
    _sandboxed(c) && (opts["sandbox"] = true)
    given = something(c.options, Dict{String, Any}())
    opts["from"] = something(format, c.input_format, get(given, "from", nothing),
                             get(given, "reader", nothing), "markdown")
    opts
end

"""
    LibPandoc.write(doc::Panir.Pandoc, to = "html"; options...)

Render a document, as `convert` from JSON would. The format is an argument
or the option `to` (or `writer`), not both.
"""
function write(doc::Panir.Pandoc, to::Union{Nothing, AbstractString} = nothing; kw...)
    opts = _options(Dict{String, Any}(), kw)
    _refuse(opts, ("from", "reader", "input-files"), "write (its input is the document)")
    _format!(opts, to, ("to", "writer"), "html")
    opts["from"] = "json"
    convert(Panir.serialize(doc), opts)
end
