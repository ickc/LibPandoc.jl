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

_json(x) = JSON.json(x)

"""
    LibPandoc.query(name; params...)

One of libpandoc's queries (`libpandoc.h`), its answer as parsed JSON:
`query("extensions-for-format"; format = "gfm")`.
"""
query(name::AbstractString; params...) =
    JSON.parse(String(_query(_json(Dict{String, Any}("query" => name, (String(k) => v for (k, v) in params)...)))))

const _VERSION = Ref{Union{Nothing, String}}(nothing)

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
How many threads pandoc runs on: one per logical core this process may use,
unless `\$LIBPANDOC_NUM_THREADS` (read at start) or `set_num_threads` says
otherwise. Conversions from different Julia tasks and threads, and
`read_many`, run in parallel on them.
"""
num_threads() = Int(query("num-threads"))

"Run pandoc on `n` threads from now on (at least 1); the new number."
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
input; `nothing` for the options' `input_files`) as `pandoc` would, with
these options: pandoc's defaults-file keys, as keywords with `_` for `-`
(`reference_doc = "ref.docx"`) or as a `Dict`. The output: a `String`
for text formats, bytes for binary ones (docx, pdf, ...), and `""` when
`output_file` is set.

`filters` may mix pandoc's (Lua or JSON filter paths, `"citeproc"`) with
Julia ones, in order, all inside the one pandoc run (see [`LibPandoc`](@ref)):

```julia
upper(s::Str) = Str(uppercase(s.text))
LibPandoc.convert("*hi*"; from = "markdown", to = "html", filters = [upper])
LibPandoc.convert(; input_files = ["a.md"], output_file = "a.docx")
```
"""
function convert(input = nothing, options::AbstractDict = Dict{String, Any}(); kw...)
    opts = _options(options, kw)
    cbs, entries = _plan(get(opts, "filters", ()), opts)
    isempty(cbs) || (opts = merge(opts, Dict("filters" => entries)))
    out = _convert(_json(opts), input, cbs)
    haskey(opts, "output-file") && return ""
    _text_output(get(opts, "to", "html")) ? String(out) : out
end

"""
    LibPandoc.run(args; input = nothing) -> Vector{UInt8}

Run pandoc with command-line arguments, as `pandoc ARGS`: what it writes to
standard output. `input` is standard input. Informational options
(`--version`, `--list-*`) are refused: use [`pandoc_version`](@ref) and the
like instead.
"""
run(args::AbstractVector{<:AbstractString}; input = nothing) = _convert_args(args, input)

"""
    LibPandoc.read(text, from = "markdown"; options...) -> Panir.Pandoc
    LibPandoc.read(text, conversion::Panir.Conversion; options...)

Parse `text` into a document. Given the conversion a filter runs in
(`ctx.conversion`), read it the way that conversion reads its input, as
[`read_many`](@ref) does: for a filter that parses a fragment.
"""
function read(text, from::AbstractString = "markdown"; kw...)
    opts = _options(Dict{String, Any}(), kw)
    opts["from"] = from
    opts["to"] = "json"
    delete!(opts, "output-file")
    Panir.parse(String(_convert(_json(opts), text)))
end

read(text, c::Conversion; kw...) = only(read_many([text], c; kw...))

"""
    LibPandoc.read_many(texts, from = "markdown"; options...) -> Vector{Panir.Pandoc}

Parse many texts, each on its own, in parallel: one call into pandoc,
which sets up the reader once and reads the texts on all its threads, much
cheaper than a `read` each. `from` is a format, or the conversion a filter
runs in (`ctx.conversion`), to read the texts the way it reads its input.

```julia
cells(b::CodeBlock, ctx) =
    reduce(vcat, (d.blocks for d in LibPandoc.read_many(split(b.text, '\\n'), ctx.conversion)))
```
"""
function read_many(texts, from::Union{AbstractString, Conversion} = "markdown"; kw...)
    opts = from isa Conversion ? read_options(from) : Dict{String, Any}("from" => from)
    merge!(opts, _options(Dict{String, Any}(), kw))
    inputs = String[t isa AbstractVector{UInt8} ? String(copy(t)) : String(t) for t in texts]
    out = JSON.parse(String(_read_many(_json(Dict("options" => opts, "inputs" => inputs)))))
    map(enumerate(out)) do (i, j)
        if haskey(j, "error")
            e = j["error"]
            throw(PandocError(e["kind"], "reading input $i: $(e["message"])"))
        end
        Panir.fromjson(Panir.Pandoc, j)
    end
end

# The conversion's options that also apply to reading a fragment of it.
const _READ_OPTIONS = ("abbreviations", "data-dir", "default-image-extension", "indented-code-classes",
                       "preserve-tabs", "resource-path", "sandbox", "strip-comments", "tab-stop",
                       "track-changes")
# Reader options (as pandoc gives filters) that have a defaults-file key.
const _READER_OPTIONS = ("default-image-extension", "indented-code-classes", "strip-comments", "tab-stop")
const _TRACK_CHANGES = Dict("accept-changes" => "accept", "reject-changes" => "reject", "all-changes" => "all")

"""
    read_options(conversion, format = nothing) -> Dict

Options (defaults-file keys) to read a fragment as `conversion` reads its
input: its input format (or `format`), and the options that affect
reading; not filters, templates, metadata or the output.
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
    given = something(c.options, Dict{String, Any}())
    opts["from"] = something(format, c.input_format, get(given, "from", nothing),
                             get(given, "reader", nothing), "markdown")
    opts
end

"""
    LibPandoc.write(doc::Panir.Pandoc, to = "html"; options...)

Render a document, as `convert` from JSON would.
"""
function write(doc::Panir.Pandoc, to::AbstractString = "html"; kw...)
    opts = _options(Dict{String, Any}(), kw)
    opts["from"] = "json"
    opts["to"] = to
    convert(Panir.serialize(doc), opts)
end
