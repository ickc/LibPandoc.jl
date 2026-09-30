# Compiled ahead, into the package's image: what every conversion with a
# Julia filter runs (the callback, parsing and writing the JSON, the walk:
# Panir's own workload has the rest), pandocjl's path, and the wasm host.
# Only when libpandoc is there already: precompiling downloads nothing.

# The smallest WASI command: exports a memory and a `_start` that does nothing.
const _EMPTY_WASM = UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
                          0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00,
                          0x05, 0x03, 0x01, 0x00, 0x01,
                          0x07, 0x13, 0x02, 0x06, codeunits("memory")..., 0x02, 0x00,
                          0x06, codeunits("_start")..., 0x00, 0x00,
                          0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b]

precompile(_include_script, (String,))
precompile(_load_script, (String,))

@setup_workload begin
    have = try
        library_path(; download = false)
        true
    catch
        false
    end
    @compile_workload begin
        if have
            __init__()
            upper(s::Panir.Str) = Panir.Str(uppercase(s.text))
            convert("# Hi *there*\n\ntext"; from = "markdown", to = "html", filters = [upper])
            convert("x"; to = "html", filters = [RawFilter((json, c) -> json)])
            read_many(["a", "*b*"], "markdown")
            write(read("*hi*"), "markdown")
            mktempdir() do d
                md, wasm = joinpath(d, "in.md"), joinpath(d, "empty.wasm")
                Base.write(md, "*hi*")
                Base.write(wasm, _EMPTY_WASM)
                redirect_stdout(devnull) do
                    main(["--version"])
                    main([md, "-o", joinpath(d, "out.html")])
                end
                WasmFilter(wasm)("{}", Conversion())
                # pandocjl's filters: planned with no options
                _plan(Any[Dict{String, Any}("type" => "json", "path" => wasm)], nothing; packages = true, args = [md])
                _plan(Any[Dict{String, Any}("type" => "json", "path" => "NoSuchPackage")], nothing; packages = true, args = [md])
            end
        end
    end
end
