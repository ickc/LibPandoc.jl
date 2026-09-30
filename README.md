# LibPandoc.jl

[pandoc](https://pandoc.org) as a Julia library. Calls run pandoc in this
process, through [libpandoc](https://github.com/ickc/libpandoc)'s C ABI,
not by running the `pandoc` executable. Documents are
[Panir.jl](https://github.com/ickc/panir/tree/main/julia)'s types,
generated from pandoc's own type definitions. And `pandocjl`: pandoc's
command line, with Julia and wasm filters run inside the conversion.

```julia
using LibPandoc, Panir
import LibPandoc as Pandoc

Pandoc.convert("*hi*"; from = "markdown", to = "html")    # "<p><em>hi</em></p>\n"
Pandoc.convert("# Report"; to = "docx")                   # bytes
Pandoc.convert(; input_files = ["a.md"], output_file = "a.pdf", pdf_engine = "typst")
Pandoc.run(["-f", "markdown", "-t", "latex", "--citeproc"]; input = src)   # the CLI, exactly

upper(s::Str) = Str(uppercase(s.text))
demote(h::Header) = (h.level += 1; nothing)
Pandoc.convert("# Hi"; to = "html", filters = [upper, demote])   # "<h2 id=\"hi\">HI</h2>\n"

doc = Pandoc.read("Hello *world*")        # a Panir.Pandoc
Pandoc.write(walk!(upper, doc), "plain")  # "HELLO WORLD\n"
```

- **Options** are pandoc's [defaults-file](https://pandoc.org/MANUAL.html#defaults-files)
  keys, as keywords with `_` for `-` (`reference_doc = "ref.docx"`), or a
  `Dict`. `run` takes command-line arguments, parsed by pandoc itself.
  The output is a `String` for text formats and bytes for binary ones.
- **Errors** throw `PandocError`, with `kind` set to pandoc's error
  constructor (`"PandocParseError"`, ...). pandoc's **warnings** are logged
  with `@warn`.
- **Threads:** conversions from different tasks and threads run in
  parallel, on pandoc's own threads: one per logical core, or
  `$LIBPANDOC_NUM_THREADS`; `num_threads()` and `set_num_threads(n)`.
- **Queries:** `pandoc_version()`, `api_version()`, `input_formats()`,
  `output_formats()`, `extensions(format)`, `default_template(format)`,
  `query(name; params...)`.

## Filters

`filters = [...]` takes, in order, all within the one pandoc run (what a
reader keeps in memory, such as a docx's images, reaches the writer):

- **Julia functions**, with a method per node type to change, walked as
  `Panir.walk!` walks: return `nothing` to keep a node, a node to replace
  it, a vector to splice in. A method may take the context too,
  `f(x, ctx)`: `ctx.conversion` says how pandoc reads and writes (input and
  output formats with extensions, reader options, the options). The order
  is pandoc's Lua filters' by default; `f => :topdown` or `f => :bottomup`
  for another. Consecutive Julia filters share one parse of the document.
- `RawFilter(f)`: `f(json, conversion)` on pandoc's JSON as it is.
- **Julia filter scripts** (`"foo.jl"`), in this process (below).
- **Wasm filters** (`"foo.wasm"`, or `WasmFilter(path)`), in this process.
- pandoc's own: Lua filters, JSON filters (programs), `"citeproc"`.

A filter may call pandoc. `Pandoc.read(text, ctx.conversion)` parses a
fragment the way the document was read, and `read_many` parses many at
once, in parallel (as pantable parses table cells):

```julia
cells(b::CodeBlock, ctx) = "cells" in b.attr.classes ?
    reduce(vcat, (d.blocks for d in Pandoc.read_many(split(b.text, '\n'), ctx.conversion))) : nothing
```

What a Julia filter throws fails the conversion, and is thrown as a
`FilterError` holding the exception and where it was thrown.

## pandocjl

`pandocjl` is pandoc's command line in this process: it takes pandoc's
arguments and does what pandoc does. The difference is that the filters
named with `-F` that it can run itself, it runs inside the conversion:

```sh
pandocjl -F Pantable input.md -o output.html   # a package's filter, in process
pandocjl -F upper.jl input.md                  # a Julia filter script, in process
pandocjl -F upper.wasm input.md                # a wasm filter, in process
pandocjl -F other-filter input.md              # anything else: as pandoc does
```

- **A package's filter:** `-F Name`, where the package `Name` (in the active
  environment or the default one) defines `Name.pandoc_filter`: a function,
  `f => traverse`, a `RawFilter` or a `WasmFilter`.
- **A Julia filter script** that ends with Panir's `run_filter(f)` (the same
  file runs under plain pandoc as a JSON filter) is loaded into a module
  of its own, once per process (again if it changes), and its
  `run_filter` hands `f` over: it runs on the document directly. Scripts
  that read the JSON themselves run as a subprocess, with this Julia and
  its load path; so do scripts with a line `# pandocjl: subprocess`, those
  named in `$PANDOCJL_SUBPROCESS` (paths, file names, names without `.jl`,
  or `*`), and, with a warning, those that fail to load. A script's
  globals persist between the documents of one process.
- **A wasm filter** (`-F name.wasm`): a pandoc JSON filter built for WASI
  (`wasm32-wasip1`), such as any [panir](https://github.com/ickc/panir) Rust
  filter; see [libpandoc-rs](https://github.com/ickc/libpandoc-rs). It runs
  in wasmtime, sandboxed: it sees the current directory, read-only, and no
  network. It may call pandoc (libpandoc-rs's `libpandoc` crate built for
  wasm): in pandoc's sandbox, with options that name no files, as
  pandocrs and libpandoc.wasm's hosts allow.

Filters are looked for as pandoc does: as given, then in the user data
directory's `filters/`. Install it as a [Julia app](https://pkgdocs.julialang.org/v1/apps/):

```julia
pkg> app add https://github.com/ickc/LibPandoc.jl   # ~/.julia/bin/pandocjl
```

`julia -m LibPandoc ARGS` is the same command.

### Start-up

Julia compiles code as it first runs it. The package and Panir.jl
precompile a workload (a document with every kind of node, pandocjl's
path, the wasm host), so pandocjl on pandoc's MANUAL (300 KB) takes
0.78 s against pandoc's 0.58 s, and 1.1 s with a Julia script filter
(pandocpy with a Python one: 0.77 s). What is left is Julia's own start
and loading, and some compiling on a filter's first document. For less, a
system image with LibPandoc compiled in: 0.66 s, and 0.84 s with the
script filter.

```julia
using PackageCompiler
create_sysimage(["LibPandoc"]; sysimage_path = "pandocjl.so")
```
```sh
julia -J pandocjl.so --startup-file=no -m LibPandoc ARGS
```

Or, many documents, convert them from one Julia session: after the first,
a Julia filter adds about what a Python one does (MANUAL: +170–220 ms to
pandoc's 284 ms).

## Installing

LibPandoc.jl needs Julia 1.12 or later. It finds libpandoc:
`$LIBPANDOC_PATH` (the library), else `$LIBPANDOC_PREFIX` or
`$CONDA_PREFIX` (a prefix with `lib/libpandoc.so`, `.dylib`, or
`bin/pandoc.dll`), else libpandoc's release build, downloaded once into
`~/.local/share/libpandoc` (`$LIBPANDOC_DOWNLOAD_DIR`), where
libpandoc-rs keeps it too. Linux (x86-64, aarch64), macOS (Intel, Apple
silicon) and Windows (x86-64).

Status: a prototype.

## License

GPL-2.0-or-later, as pandoc: the package links pandoc.
