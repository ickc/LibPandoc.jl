"""
pandoc as a Julia library, in process, through libpandoc's C ABI: no
`pandoc` executable, no subprocess. Documents are Panir.jl's types.

```julia
using LibPandoc, Panir
import LibPandoc as Pandoc

Pandoc.convert("*hi*"; from = "markdown", to = "html")    # "<p><em>hi</em></p>\\n"
Pandoc.convert("# Report"; to = "docx")                   # bytes
Pandoc.run(["-f", "markdown", "-t", "latex"]; input = "*hi*")
doc = Pandoc.read("Hello *world*")                        # a Panir.Pandoc
Pandoc.write(doc, "rst")

upper(s::Str) = Str(uppercase(s.text))
Pandoc.convert("hi"; to = "html", filters = [upper])      # "<p>HI</p>\\n"
```

- **Options** are pandoc's defaults-file keys, as keywords (`_` for `-`)
  or a `Dict`. Failures throw `PandocError`; pandoc's warnings are logged
  (`@warn`).
- **Filters** (`filters = [...]`), in order, all in one pandoc run:
  - a Julia function with methods for the nodes to change, walked as
    `Panir.walk!` does, `ctx.conversion` saying how pandoc reads and writes;
    `f => :topdown` (or `:bottomup`) for another order. Consecutive ones
    share one parse of the document;
  - `RawFilter(f)`, on pandoc's JSON as it is;
  - a Julia filter script (`"foo.jl"`), a wasm filter (`"foo.wasm"` or a
    `WasmFilter`), both in process;
  - pandoc's own: Lua filters, JSON filters (programs), `"citeproc"`.

  A filter may call pandoc: `LibPandoc.read(text, ctx.conversion)` reads a
  fragment as the document was read. What a Julia filter throws fails the
  conversion, as a `FilterError`.
- `pandocjl` (`LibPandoc.main`) is pandoc's command line with these
  filters in process.
- **Threads:** conversions from different tasks and threads run in
  parallel, on pandoc's own threads (`num_threads`).
"""
module LibPandoc

using Panir: Panir, Conversion, walk!
import JSON
import Libdl
import Downloads
import Tar
using CodecZlib: GzipDecompressorStream
import Wasmtime_jll
using PrecompileTools: @setup_workload, @compile_workload

export PandocError, FilterError, RawFilter, WasmFilter

include("library.jl")
include("abi.jl")
include("api.jl")
include("wasm.jl")
include("filters.jl")
include("scripts.jl")
include("cli.jl")

function __init__()
    # what precompiling (its workload) left in these would be stale
    _SYMS[] = nothing
    _WASMTIME[] = nothing
    _VERSION[] = nothing
    empty!(_SCRIPTS)
    empty!(_WASM_FILTERS)
    _ENTRY[] = @cfunction(_callback_entry, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ptr{Cvoid}))
    append!(empty!(_THREAD_LOCKS), [ReentrantLock() for _ in 1:Threads.maxthreadid()])
end

include("precompile.jl")

end
