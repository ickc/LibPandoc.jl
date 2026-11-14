# What pandocjl's system image (build.jl) has compiled: pandocjl as it
# runs, without a filter, with a Julia filter script and with wasm filters,
# on a document with a bit of everything.
import LibPandoc

mktempdir() do d
    md = joinpath(d, "in.md")
    write(md, """
        # Title {#id}

        Some *text*, **strong**, `code`, a [link](u "t") and ![img](i.png){width=1}.

        - a list
        - with [a span]{.c}

        > a quote

        ```python
        x
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """)
    html = ["-f", "markdown", "-t", "html", "-o", joinpath(d, "out.html"), md]
    script = joinpath(d, "upper.jl")
    write(script, "using Panir\nrun_filter(s::Str -> Str(uppercase(s.text)))\n")
    LibPandoc.main(html)
    LibPandoc.main([html; "-F"; script])
    # libpandoc-rs's example filters built for wasm32-wasip1, if given (as
    # for the tests); else one that does nothing: as a filter it fails (no
    # document), but runs the wasm host
    dir = get(ENV, "LIBPANDOC_WASM_FILTERS", "")
    wasms = filter(isfile, [joinpath(dir, "$w.wasm") for w in ("identity", "upper", "modify", "count")])
    if isempty(dir) || isempty(wasms)
        empty = joinpath(d, "empty.wasm")
        write(empty, LibPandoc._EMPTY_WASM)
        redirect_stderr(() -> LibPandoc.main([html; "-F"; empty]), devnull)
    else
        foreach(w -> LibPandoc.main([html; "-F"; w]), wasms)
    end
end
