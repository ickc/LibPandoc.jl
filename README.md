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
  `Dict` (a keyword wins over the same key in it). A value that is
  `nothing` is an absent option, as Lua's `nil` in a table (`timeout =
  nothing`: no time limit; in a sandbox, `timeout = nothing`: the
  environment's); a vector with `nothing` in it is an error. `read`'s, `write`'s and
  `read_many`'s format is an argument or the option (`from`/`reader`,
  `to`/`writer`), not both; an option a function has no use for (`read`'s
  `to`, `write`'s `from`, `read_many`'s `filters`, ...) is an
  `ArgumentError`, as is a conversion with neither input nor `input_files`
  (pandoc would read this process's standard input and close it: pass
  `read(stdin)`). `run` takes command-line arguments, parsed by pandoc
  itself. The output is a `String` for text formats and bytes for binary ones.
  Input given as a string or bytes is read from a temporary file (as
  libpandoc does), so RST's `include` and Org's `#+INCLUDE` with a
  relative path find nothing, and `$sourcefile$` names that file: give
  such documents as `input_files`.
- **Errors** throw `PandocError`, with `kind` set to pandoc's error
  constructor (`"PandocParseError"`, ...), or `"Timeout"`. pandoc's
  **warnings** are logged with `@warn`, `read_many`'s readers' too.
- **Time limit:** `timeout = seconds` (libpandoc's option, for `convert`,
  `read`, `write`, `read_many`) stops a call still running after that
  long, a `PandocError` of kind `"Timeout"` (`istimeout(e)`, as
  libpandoc-rs's `is_timeout()`); the process goes on. It stops
  pandoc's own code, JSON filters and Julia scripts run as a subprocess,
  not code in this process (a Julia
  filter runs to its end, and the call fails when it returns) nor Lua
  filters. `read_many`'s limit is the whole call's: a text not read by then
  fails on its own (`return_exceptions = true` keeps the others'
  documents). No memory limit natively: for documents from someone you
  don't trust, the directory sandbox (below), which has both limits.
- **Threads:** conversions from different tasks and threads run in
  parallel, on pandoc's own threads: one per logical core, or
  `$LIBPANDOC_NUM_THREADS`; `num_threads()`. `set_num_threads(n)` sets the
  number only before pandoc first runs something in parallel (it grows to
  it then, once), and returns the number in effect.
- **Untrusted options:** `untrusted = true` accepts only options that read
  no files, write none, fetch nothing and run nothing, with pandoc's
  sandbox on (libpandoc's list; anything else throws a `PandocError`
  naming it): for options from code you don't trust. It bounds neither
  time nor memory (above).
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
  output formats with extensions, the reader's and the writer's options,
  `writer_options` being Lua's `PANDOC_WRITER_OPTIONS`: `-N`,
  `--top-level-division`, ...; and the options). The order
  is pandoc's Lua filters' by default; `f => :topdown` or `f => :bottomup`
  for another. Consecutive Julia filters share one parse of the document.
- `RawFilter(f)`: `f(json, conversion)` on pandoc's JSON as it is.
- **Julia filter scripts** (`"foo.jl"`), in this process (below).
- **Wasm filters** (`"foo.wasm"`, or `WasmFilter(path)`), in this process.
  They, and scripts run as a subprocess, get the variables libpandoc gives
  JSON filters (`PANDOC_WRITER_OPTIONS` among them).
- pandoc's own: Lua filters, JSON filters (programs), `"citeproc"`.

A filter may call pandoc. `Pandoc.read(text, ctx.conversion)` parses a
fragment the way the document was read, and `read_many` parses many at
once, in parallel (as pantable parses table cells):

```julia
cells(b::CodeBlock, ctx) = "cells" in b.attr.classes ?
    reduce(vcat, (d.blocks for d in Pandoc.read_many(split(b.text, '\n'), ctx.conversion))) : nothing
```

Read so, a text keeps its tabs, as Lua's `pandoc.read` reads it; the
`pandoc` command first replaces them by spaces (`preserve_tabs = false`
does). A call each costs about 0.3 ms, six times `pandoc.read`'s: batch
them. amsthm's 738 notes take 0.23 s read one by one and 0.012 s in one
`read_many`.

**Confined when the conversion is.** Document text read this way may name
files (LaTeX's `\input`, RST's and Org's includes). When the conversion
the filter runs in is sandboxed, by pandoc's sandbox (`sandbox = true`) or
a directory sandbox (`sandbox = (read = [...],)`, `LIBPANDOC_SANDBOX`), the
fragments are read in pandoc's own sandbox: they read no files, not even in
the directories listed (the filter runs in this process, outside them). So
they are too when that can't be told: for a conversion with no options, as
`pandocjl`'s filters get (pandoc doesn't tell them about `--sandbox`, on
the command line or in a defaults file) and a script run as a subprocess
makes from its environment (`Conversion(ARGS, ENV)`). A filter that wants
the files read gives its own options, `read(text, ctx.conversion; sandbox
= false)`: its code, its choice.

It calls pandoc from its own task. A filter that waits for a conversion
with Julia filters started in another task (`@async`, `Threads.@spawn`
when it lands on the same thread) waits forever: pandoc returns to the
thread that called it, so the conversion started inside the filter waits
for the one running the filter to return, and that one for it.

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
  its load path; so do scripts with a line `# pandocjl: subprocess` and
  those named in `$PANDOCJL_SUBPROCESS` (paths, file names, names without
  `.jl`, or `*`). A script that fails to load in process, or hands no
  filter over, is not run again as a subprocess (its side effects would
  happen twice): the conversion fails (`LibPandoc.ScriptFailed`), naming
  those two ways. A script's globals persist between the documents of one
  process, and so do its changes to `ENV`, the packages it loads and the
  tasks it starts: it runs with all your rights, as any filter but a wasm
  one. Its `cd` is undone when it returns, so the output goes where it was
  named.
- **A wasm filter** (`-F name.wasm`): a pandoc JSON filter built for WASI
  (`wasm32-wasip1`), such as any [panir](https://github.com/ickc/panir) Rust
  filter; see [libpandoc-rs](https://github.com/ickc/libpandoc-rs). It runs
  in wasmtime, sandboxed: it sees the current directory, read-only, and no
  network. It may call pandoc (libpandoc-rs's `libpandoc` crate built for
  wasm): in pandoc's sandbox, with options that name no files (libpandoc
  checks them, `"untrusted"`: the same for every host). Limits, which
  pandoc has for no filter: `$LIBPANDOC_WASM_TIMEOUT` (seconds, as
  pandoc-server's `--timeout`; its calls to pandoc included: each runs
  with the time the filter has left as its `"timeout"`) and
  `$LIBPANDOC_WASM_MAX_MEMORY` (bytes, or with `k`, `m`, `g`, as pandoc's
  `+RTS -M`; its output, standard output and error, counts too) stop a
  filter past them; none by default (or 0), as pandoc; negative ones are
  refused. `WasmFilter(path; timeout, max_memory)` for one filter. Its
  standard error goes to this process's.

  Unlike Julia, Lua and JSON filters, which can do anything you can
  (pandoc's `--sandbox` doesn't limit filters), a wasm filter can't reach
  past these bounds whatever pandoc's options: a filter from anywhere risks
  the document, not your machine.

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
system image with LibPandoc and Panir compiled in: 0.66 s, and 0.84 s with
the script filter. In a clone of this repository:

```sh
julia sysimage/build.jl [IMAGE [PROJECT]]
julia -J IMAGE --project=PROJECT --startup-file=no -m LibPandoc ARGS
```

PROJECT is the environment pandocjl runs in (default: the clone, as the
app runs when developed from it, `pkg> app develop .`: then `pandocjl -J
IMAGE -- ARGS`), IMAGE `pandocjl.so` in it by default. The image works
only with the Julia that built it (the app's: `julia_command` in
`~/.julia/environments/apps/AppManifest.toml`) and keeps the packages as
they were: rebuild it after updating them. `IMAGE.txt` records what it was
built from (`sysimage/build.jl` says what matters).

Or, many documents, convert them from one Julia session: after the first,
a Julia filter adds about what a Python one does (MANUAL: +170–220 ms to
pandoc's 284 ms).

## Security: documents you don't trust

pandoc reads what a document asks for: LaTeX's `\input`, RST, Org,
AsciiDoc, man and Typst includes, images (embedded with
`embed_resources`, in a docx or an EPUB), a `bibliography:` or `csl:` in
its metadata. Run on a document from elsewhere, it can put any file you
can read into its output. pandoc's own sandbox (`sandbox = true`) is all
or nothing: the document reads no file at all, not even its own images.

A **directory sandbox** is a container at the level of mounts: pandoc runs
whole inside libpandoc.wasm (pandoc built for WebAssembly) under wasmtime,
in this process, and sees only the directories you list, as a container
sees only its mounts. The same as libpandoc-rs's and libpandoc-python's.

```julia
html = Pandoc.convert(; input_files = ["paper.tex"], to = "html",
                      sandbox = (read = ["."], write = ["out"]))
```

```sh
LIBPANDOC_SANDBOX=. LIBPANDOC_SANDBOX_WRITE=out pandocjl paper.tex -s -o out/paper.html
```

**What is mounted.** The read list (`read`, `$LIBPANDOC_SANDBOX`) and the
write list (`write`, `$LIBPANDOC_SANDBOX_WRITE`, readable too), each
directory at its own absolute path. The option (a named tuple, or a `Dict`
as in JSON: `"sandbox" => Dict("read" => [...])`) is for `convert`, `read`
and `write`; the variables, lists as `PATH` is (`:`, `;` on Windows), for
`run` and `pandocjl`. A directory that doesn't exist is an error; a
variable set but empty, or an empty list, mounts nothing. A private
temporary directory. No network, no programs. Of the environment, only
`SOURCE_DATE_EPOCH` (for a reproducible docx, odt or epub). Nothing else:
**not the user data directory, not `PANDOC_DATA_DIRS`**: list them if
pandoc is to find your templates and filters there.

**Everything pandoc reads must be in a mounted directory**: what the
document names, and what you name too (input files, template, CSS,
bibliography, defaults files, Lua filters). Outside, a file is missing.
Output goes to standard output (the returned value), or into a directory
of the write list (`output_file`, `extract_media`, `log_file`; `-o`,
`--extract-media`, `--log`). The options and arguments reach pandoc
untouched. Listing a directory opens all of it to the document: list the
document's own directory, not your home.

**Filters.** Lua filters run inside, confined as the document is (in
plain pandoc a Lua filter can do anything you can). Filters that are
programs (JSON filters) fail (status 83 in `pandocjl`): wasm starts no
process, and a filter run outside would read whatever the document names.
Julia filters (functions, `RawFilter`s, a package's `pandoc_filter`) and
Julia filter scripts (`-F foo.jl`) are your code, as trusted as the
command line: they run in this process as they do without the sandbox,
called back by the module, unconfined. Wasm filters run in this process
too, seeing the same mounts. `pandocjl lua` and `pandoc server` are not in
the module (status 4). A filter that reads fragments with
`read(text, ctx.conversion)` or `read_many` reads them in pandoc's own
sandbox: no files, not even in the directories listed ("Filters").
`read_many` reads in this process: a directory sandbox there is an error.

**Limits.** `$LIBPANDOC_WASM_TIMEOUT` (seconds) and
`$LIBPANDOC_WASM_MAX_MEMORY` (bytes, or with `k`, `m`, `g`), or for one
call the sandbox's `timeout` and `max_memory` (bytes, an integer;
`"max-memory"` in a `Dict`), stop a conversion past them, counted from the
module's start; none by default (or 0), wasm's 4 GiB at most. A negative,
infinite or NaN one is an `ArgumentError`. A conversion stopped by the
time limit throws a `PandocError` of kind `"Timeout"`, as one past
libpandoc's `timeout` (which works inside too, but doesn't stop Lua); one
out of memory a `PandocError` saying it is most likely that (wasmtime's C
API refuses the growth past the limit and doesn't say so: the module then
stops). A document can be built to take time or memory (Typst's `#while
true {}`: 3 GB in 4.5 s natively; 100,000 nested `>`: over 15 s): set
**both** for documents from the internet. The memory limit alone does not
stop every such document: a loop that grows slowly, or not at all, runs on
until the time limit. The time limit covers pandoc and Lua inside the
module, not filters run in this process (a Julia filter runs to its end; a
wasm filter has its own limits).

**Threads.** The module runs on the calling task, and calls the Julia
filters back on it. As for any conversion with Julia filters, the task
stays on its thread meanwhile, and another task on that thread waits for
it to finish before it starts one (wasmtime, as pandoc, returns to the
thread that called it, in order): conversions from different threads run
in parallel.

**What to know.**

- `..` from one mounted directory into another fails (each mount resolves
  alone), in an absolute path too; a path without `..` works.
- Relative names resolve from the working directory, which must be in a
  mounted directory; if it isn't, they find nothing and the error says so.
- On Windows a path with a drive letter means nothing inside: use relative
  names with `/`, or `/c/...` for `C:\...`.
- A path leaving a mount by `..` or a symbolic link fails as "permission
  denied", where a missing file "does not exist": a document can tell the
  two apart where pandoc shows the error (an input file, an AsciiDoc or
  Typst include), though it reads nothing. A template, CSS or bibliography
  reads as missing either way.
- PDF output needs a program and fails, saying so: write LaTeX, HTML or
  Typst and make the PDF outside.
- `pandocjl --version` says what runs: the module's pandoc
  (`Features: -server -lua`).

**What it doesn't protect from:** a hard link inside a mounted directory
to a file elsewhere (it is that file), and anything else you put in the
directories; documents built to use time or memory beyond the limits you
set; your own filters; bugs in wasmtime or in this host.

**The module.** `$LIBPANDOC_WASM=/path/to/libpandoc.wasm`, else
libpandoc's `continuous` release's, downloaded once (about 60 MB) beside
the library's download (`~/.local/share/libpandoc/continuous`, see
Installing; libpandoc-rs keeps it there too) and checked against the
release's `SHA256SUMS`. A cached module older than this package needs
fails, naming the file to remove. Its **first compilation takes about 20 s
and 8 GB of memory**, RAM and swap together (no setting of wasmtime's
lowers that; with less, the process is killed); wasmtime's cache
(`~/.cache/wasmtime`) keeps the result, and later processes load it in
about 0.4 s. Precompiling the package and building the system image never
touch it, whatever the variables say. wasmtime comes with the package
(Wasmtime_jll): the setting is never ignored.

**What it costs** (pandoc's MANUAL, markdown to HTML, one run of
`pandocjl`): 3.1 s and 1.8 GB at most against 0.85 s and 0.71 GB natively;
in a process that has loaded the module (0.5 s), 2.1 s a conversion against
0.23 s, and a small one takes 4.5 ms. The first run: 25 s and 9.0 GB. (Of
the 2.1 s, about 0.3 are wasmtime's bounds checks in the module's code:
this package leaves signals to Julia, where libpandoc-rs and
libpandoc-python let wasmtime catch out-of-bounds accesses with them.)

**For real isolation**, run the conversion where only the directory
exists, a container at least, a virtual machine better.

## Installing

LibPandoc.jl needs Julia 1.12 or later, and libpandoc 1.11 or a later
1.x (its ABI version, checked when the library is loaded). It finds libpandoc:
`$LIBPANDOC_PATH` (the library), else `$LIBPANDOC_PREFIX` or
`$CONDA_PREFIX` (a prefix with `lib/libpandoc.so`, `.dylib`, or
`bin/pandoc.dll`), else libpandoc's release build, downloaded once into
`~/.local/share/libpandoc` (`$LIBPANDOC_DOWNLOAD_DIR`; from
`$LIBPANDOC_DOWNLOAD_URL`, a URL or a file, for a mirror), where
libpandoc-rs keeps it too. Linux (x86-64, aarch64), macOS (Intel, Apple
silicon) and Windows (x86-64).

The download is checked against the release's `SHA256SUMS`: that it
arrived whole, not that it is the one meant (the sums come from the same
release). It is the `continuous` release, which changes, but the copy is
not downloaded again by itself: one too old for this package fails when
it is loaded, naming the directory to remove to download the current one.

Status: a prototype.

## License

GPL-2.0-or-later, as pandoc: the package links pandoc.
