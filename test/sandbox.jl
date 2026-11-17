# The directory sandbox (`sandbox = (read = [...], write = [...])`):
# libpandoc-rs's and libpandoc-python's tests ported: the attack suite of the
# project's sandbox study, as data, run in libpandoc.wasm with one directory
# mounted, the rules of the mounts, pandocjl with the two variables, and the
# threads.
#
# Needs libpandoc.wasm ($LIBPANDOC_WASM, or the package's download); the wasm
# filter tests libpandoc-rs's filters ($LIBPANDOC_WASM_FILTERS). The lab, made
# once: `work` (mounted, and the working directory), `secret` beside it
# (canaries, harmless files whose text says CANARY), `outside` (files the
# options name, mounted in some tests), `out` (written to), and user data
# directories.

import Sockets, Base64

const NOT_PERMITTED = "permission denied (Operation not permitted)"
const DOES_NOT_EXIST = "does not exist (No such file or directory)"

svg(text) = """<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>$text</text></svg>"""

# An absolute path as the module names it: on Windows C:\x is /c/x.
function named(p)
    s = replace(String(p), '\\' => '/')
    Sys.iswindows() && length(s) > 1 && s[2] == ':' ? "/$(lowercase(s[1]))$(s[3:end])" : s
end

struct Lab
    root::String
    work::String
    secret::String
    outside::String
    out::String
    data::String
    url::String
    connections::Threads.Atomic{Int}
end

function make_lab()
    root = realpath(mktempdir())   # (the real path: macOS's /var is /private/var)
    for d in ("work", "secret", "outside", "out", "data/pandoc/templates", "dirs/templates")
        mkpath(joinpath(root, d))
    end
    work, secret, outside, out = (joinpath(root, d) for d in ("work", "secret", "outside", "out"))
    files = ["secret.txt" => "CANARY-TXT-OUTSIDE\n", "secret.tex" => "CANARY-TEX-OUTSIDE\n",
             "secret2.sty" => "\\newcommand{\\leak}{CANARY-STY-OUTSIDE}\n", "secret.svg" => svg("CANARY-SVG-OUTSIDE"),
             "probe.png" => "not really a png", "secret.csv" => "a,b\nCANARY-CSV-OUTSIDE,x\n",
             "secret.json" => "{\"a\": \"CANARY-JSON-OUTSIDE\"}", "secret.typ" => "CANARY-TYP-OUTSIDE\n",
             "secret.org" => "CANARY-ORG-OUTSIDE\n", "secret.man" => ".PP\nCANARY-MAN-OUTSIDE\n",
             "secret.t2t" => "CANARY-T2T-OUTSIDE\n", "secret.js" => "/* CANARY-JS-OUTSIDE */\n",
             "secret.css" => "/* CANARY-CSS-OUTSIDE */\n",
             "secret.bib" => "@book{canary, title={CANARY-BIB-OUTSIDE}, author={A}, year={2000}}\n",
             "secret.csl" => "CANARY-CSL-OUTSIDE\n", "x/typst.toml" => "CANARY-TOML-OUTSIDE\n"]
    for (name, text) in files
        mkpath(dirname(joinpath(secret, name)))
        Base.write(joinpath(secret, name), text)
    end
    Base.write(joinpath(work, "inside.svg"), svg("INSIDE-OK"))
    Base.write(joinpath(work, "inside.txt"), "INSIDE-OK\n")
    Base.write(joinpath(work, "inside.tex"), "INSIDE-OK\n")
    Base.write(joinpath(work, "doc.md"), "*hi*\n")
    Base.write(joinpath(root, "data/pandoc/templates/mine.html"), "DATA-DIR-OK \$body\$\n")
    Base.write(joinpath(root, "dirs/templates/theirs.html"), "DATA-DIRS-OK \$body\$\n")
    if !Sys.iswindows()
        for ext in ("txt", "svg", "tex")
            symlink("../secret/secret.$ext", joinpath(work, "link-out.$ext"))
        end
        symlink("../secret", joinpath(work, "link-dir"))
        for f in ("template.html", "style.css", "refs.bib", "input.md")
            symlink("../outside/$f", joinpath(work, "link-$f"))
        end
    end
    # what the options name: a template, a stylesheet, a bibliography,
    # outside and (`-in`) in `work`
    for (d, tag) in ((outside, ""), (work, "-in"))
        Base.write(joinpath(d, "template$tag.html"),
                   "TEMPLATE-OK \$for(css)\$<link rel=\"stylesheet\" href=\"\$css\$\">\$endfor\$ \$body\$\n")
        Base.write(joinpath(d, "style$tag.css"), "p::after { content: \"CSS-OK\" }\n")
        Base.write(joinpath(d, "refs$tag.bib"), "@book{ok, title={BIB-OK}, author={A}, year={2000}}\n")
    end
    Base.write(joinpath(outside, "input.md"), "INPUT-OK")
    # a local web server: how many connections it got
    port, server = Sockets.listenany(Sockets.ip"127.0.0.1", 20000)
    connections = Threads.Atomic{Int}(0)
    errormonitor(@async while true
        conn = try Sockets.accept(server) catch; break end
        Threads.atomic_add!(connections, 1)
        close(conn)
    end)
    Lab(root, work, secret, outside, out, joinpath(root, "data"), "http://127.0.0.1:$(Int(port))", connections), server
end

# (directories are listed as the host names them; `named` is for what the
# module is told: on Windows the two differ)
mounted(options, read, write = String[]) = merge(options, Dict("sandbox" => Dict("read" => String[String(d) for d in read],
                                                                                 "write" => String[String(d) for d in write])))

# A conversion as the host gives it: (status, output, kind, message, log).
function convert_raw(options::Dict, input = nothing)
    dirs = P._sandbox_of(options)
    dirs === nothing && return P._convert(P._json(options), input; take = P._parts)
    m = P._Mounts(dirs)
    try
        o = Dict{String, Any}(k => v for (k, v) in options if k != "sandbox")
        status, out, kind, msg, log = P._sandbox_run(m, dirs, (:options, P._json(o)), P._bytes(input), P._Callback[])
        note = P._note(m)
        status, out, kind, status != 0 && note !== nothing ? "$msg\n$note" : msg, log
    finally
        P._close(m)
    end
end

# -- what a document could observe ----------------------------------------------

# The members of a zip file (docx, odt, epub), by its central directory;
# none if it isn't one.
function unzip(b::Vector{UInt8})
    u16(i) = Int(b[i]) | Int(b[i + 1]) << 8
    u32(i) = u16(i) | u16(i + 2) << 16
    e = findlast(i -> b[i:i + 3] == [0x50, 0x4b, 0x05, 0x06], 1:length(b) - 21)
    (length(b) < 22 || e === nothing) && return Pair{String, Vector{UInt8}}[]
    members, at = Pair{String, Vector{UInt8}}[], u32(e + 16) + 1
    for _ in 1:u16(e + 10)
        method, size, nlen, xlen, clen, local_at = u16(at + 10), u32(at + 20), u16(at + 28), u16(at + 30), u16(at + 32), u32(at + 42) + 1
        name = String(b[at + 46:at + 45 + nlen])
        start = local_at + 30 + u16(local_at + 26) + u16(local_at + 28)
        data = b[start:start + size - 1]
        push!(members, name => (method == 8 ? transcode(CodecZlib.DeflateDecompressor, data) : data))
        at += 46 + nlen + xlen + clen
    end
    members
end

const UUID_RE = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
const TIME_RE = "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[0-9.:+\\-Z]*"

# ISO 8601 times and UUIDs written {TIME} and {UUID}: nothing else.
timeless(s) = replace(s, Regex("($UUID_RE)|$TIME_RE") => m -> occursin(Regex("^$UUID_RE\$"), m) ? "{UUID}" : "{TIME}")

# Runs of base64 (as in data: URIs), decoded.
function base64_runs(s)
    out = IOBuffer()
    for m in eachmatch(r"[A-Za-z0-9+/]{24,}", s)
        run = m.match
        whole = length(run) ÷ 4 * 4
        rest = run[whole + 1:end]
        text = run[1:whole] * (length(rest) > 1 ? rest * "="^(4 - length(rest)) : "")
        Base.write(out, try Base64.base64decode(text) catch; UInt8[] end, "\n")
    end
    String(take!(out))
end

struct Seen
    output::String
    messages::String
    everything::String
end

# What a conversion gave: its output, its messages (the error, or the log),
# and everything (both, zip members inflated, the files extracted under
# `media`, runs of base64 decoded), where a canary would show.
function seen(r, media = nothing)
    status, out, kind, message, log = r
    output, messages = status == 0 ? (String(copy(out)), log) : ("", "$kind: $message")
    everything = "$output\n$messages\n"
    entries = status == 0 ? unzip(out) : Pair{String, Vector{UInt8}}[]
    for (_, entry) in entries
        everything *= String(copy(entry))
    end
    # what a document could observe of the output: a zip's members by name
    # and content (not its bytes, which hold its time), times and random
    # identifiers set aside
    isempty(entries) || (output = join("$name:\n$(String(copy(entry)))\n" for (name, entry) in entries))
    if media !== nothing && isdir(media)
        for (dir, _, files) in walkdir(media), f in sort(files)
            everything *= Base.read(joinpath(dir, f), String)
        end
    end
    Seen(timeless(output), messages, everything * base64_runs(everything))
end

# -- the attacks -------------------------------------------------------------------

# An attack: its name, the document's extension, the document ({P} where
# the path it tries goes), the path ({S} the secret directory, {W} the work
# one, {URL} the local server), the options.
function cases()
    latex = Dict{String, Any}("from" => "latex", "to" => "plain")
    embed(f) = Dict{String, Any}("from" => f, "to" => "html", "embed-resources" => true)
    md(to) = Dict{String, Any}("from" => "markdown", "to" => to)
    p(f, t = "plain") = Dict{String, Any}("from" => f, "to" => t)
    cite = Dict{String, Any}("from" => "markdown", "to" => "plain", "citeproc" => true)
    bib = "---\nbibliography: {P}\nnocite: \"@*\"\n---\n\nText.\n"
    xxe = "<?xml version=\"1.0\"?><!DOCTYPE article [<!ENTITY x SYSTEM \"file://{P}\">]><article>"
    v = Any[
        ("latex-input-rel", "tex", "\\input{{P}}", "../secret/secret", latex),
        ("latex-input-abs", "tex", "\\input{{P}}", "{S}/secret.tex", latex),
        ("latex-include", "tex", "\\include{{P}}", "../secret/secret", latex),
        ("latex-subfile", "tex", "\\subfile{{P}}", "../secret/secret.tex", latex),
        ("latex-lstinput", "tex", "\\lstinputlisting{{P}}", "../secret/secret.txt", latex),
        ("latex-lst-abs", "tex", "\\lstinputlisting{{P}}", "{S}/secret.txt", latex),
        ("latex-minted", "tex", "\\inputminted{text}{{P}}", "../secret/secret.txt", latex),
        ("latex-usepackage", "tex", "\\usepackage{{P}}\\leak", "../secret/secret2", latex),
        ("latex-graphics-probe", "tex", "\\includegraphics{{P}}", "../secret/probe", p("latex", "native")),
        ("latex-graphics-embed", "tex", "\\includegraphics{{P}}", "../secret/secret.svg", embed("latex")),
        ("latex-bibliography", "tex", "\\bibliography{{P}}\\nocite{*}", "../secret/secret", merge(latex, Dict("citeproc" => true))),
        ("latex-graphicspath", "tex", "\\graphicspath{{{P}}}\\includegraphics{secret.svg}", "../secret/", embed("latex")),
        ("rst-include", "rst", ".. include:: {P}", "../secret/secret.txt", p("rst")),
        ("rst-include-abs", "rst", ".. include:: {P}", "{S}/secret.txt", p("rst")),
        ("rst-include-literal", "rst", ".. include:: {P}\n   :literal:", "../secret/secret.txt", p("rst")),
        ("rst-raw-file", "rst", ".. raw:: html\n   :file: {P}", "../secret/secret.txt", p("rst", "html")),
        ("rst-csv-file", "rst", ".. csv-table:: T\n   :file: {P}", "../secret/secret.csv", p("rst")),
        ("rst-csv-url", "rst", ".. csv-table:: T\n   :url: {P}", "{URL}/x.csv", p("rst")),
        ("rst-literalinclude", "rst", ".. literalinclude:: {P}", "../secret/secret.txt", p("rst")),
        ("rst-image-embed", "rst", ".. image:: {P}", "../secret/secret.svg", embed("rst")),
        ("org-include", "org", "#+INCLUDE: \"{P}\" src text", "../secret/secret.txt", p("org")),
        ("org-include-plain", "org", "#+INCLUDE: \"{P}\"", "../secret/secret.org", p("org")),
        ("org-setupfile", "org", "#+SETUPFILE: {P}\n\ntext", "../secret/secret.org", p("org")),
        ("adoc-include", "adoc", "include::{P}[]", "../secret/secret.txt", p("asciidoc")),
        ("adoc-include-abs", "adoc", "include::{P}[]", "{S}/secret.txt", p("asciidoc")),
        ("man-so", "man", ".TH T 1\n.so {P}\n", "../secret/secret.man", p("man")),
        ("man-so-abs", "man", ".TH T 1\n.so {P}\n", "{S}/secret.man", p("man")),
        ("t2t-include", "t2t", "\n\n\n%!include: {P}\n", "../secret/secret.t2t", p("t2t")),
        ("typst-include", "typ", "#include \"{P}\"", "../secret/secret.typ", p("typst")),
        ("typst-read", "typ", "#read(\"{P}\")", "../secret/secret.txt", p("typst")),
        ("typst-read-abs", "typ", "#read(\"{P}\")", "{S}/secret.txt", p("typst")),
        ("typst-json", "typ", "#json(\"{P}\").a", "../secret/secret.json", p("typst")),
        ("typst-csv", "typ", "#csv(\"{P}\").at(1).at(0)", "../secret/secret.csv", p("typst")),
        ("typst-image", "typ", "#image(\"{P}\")", "../secret/secret.svg", embed("typst")),
        ("typst-import-pkg", "typ", "#import \"@preview/../../../../../../../../../../../..{P}:1\": *\n#leak",
         "{S}/x", p("typst")),
        ("djot-image", "dj", "![x]({P})", "../secret/secret.svg", embed("djot")),
        ("mediawiki-transclude", "wiki", "{{:{P}}}", "../secret/secret.txt", p("mediawiki")),
        ("dokuwiki-include", "dw", "{{page>{P}}}", "../secret/secret.txt", p("dokuwiki")),
        ("creole-image", "creole", "{{{P}|x}}", "../secret/secret.svg", embed("creole")),
        ("md-image-embed", "md", "![x]({P})", "../secret/secret.svg", embed("markdown")),
        ("md-image-abs", "md", "![x]({P})", "{S}/secret.svg", embed("markdown")),
        ("md-image-abs-dotdot", "md", "![x]({P})", "{W}/../secret/secret.svg", embed("markdown")),
        ("md-image-file-url", "md", "![x](file://{P})", "{S}/secret.svg", embed("markdown")),
        ("md-image-pct", "md", "![x]({P})", "..%2Fsecret%2Fsecret.svg", embed("markdown")),
        ("md-image-http", "md", "![x]({P})", "{URL}/x.svg", embed("markdown")),
        ("md-image-docx", "md", "![x]({P})", "../secret/secret.svg", md("docx")),
        ("md-image-odt", "md", "![x]({P})", "../secret/secret.svg", md("odt")),
        ("md-image-epub", "md", "![x]({P})", "../secret/secret.svg", md("epub")),
        ("md-image-rtf", "md", "![x]({P})", "../secret/secret.svg", md("rtf")),
        ("md-image-ipynb", "md", "![x]({P})", "../secret/secret.svg", md("ipynb")),
        ("md-image-fb2", "md", "![x]({P})", "../secret/secret.svg", md("fb2")),
        ("md-image-icml", "md", "![x]({P})", "../secret/secret.svg", md("icml")),
        ("md-extract-media", "md", "![x]({P})", "../secret/secret.svg",
         Dict{String, Any}("from" => "markdown", "to" => "html", "extract-media" => "media-md-extract-media")),
        ("md-raw-html", "md", "<script src=\"{P}.js\"></script><link rel=\"stylesheet\" href=\"{P}.css\"><img src=\"{P}.svg\">",
         "../secret/secret", Dict{String, Any}("from" => "markdown", "to" => "html", "embed-resources" => true,
                                               "standalone" => true, "metadata" => Dict("title" => "x"))),
        ("html-embed", "html", "<p><img src=\"{P}.svg\"></p><script src=\"{P}.js\"></script><link rel=\"stylesheet\" href=\"{P}.css\">",
         "../secret/secret", Dict{String, Any}("from" => "html", "to" => "html", "embed-resources" => true,
                                               "standalone" => true, "metadata" => Dict("title" => "x"))),
        ("html-iframe-http", "html", "<iframe src=\"{P}\"></iframe>", "{URL}/x.html", p("html")),
        ("html-iframe-file", "html", "<iframe src=\"file://{P}\"></iframe>", "{S}/secret.txt", p("html")),
        ("html-iframe-rel", "html", "<iframe src=\"{P}\"></iframe>", "../secret/secret.txt", p("html")),
        ("docbook-xxe", "xml", xxe * "<para>&x;</para></article>", "{S}/secret.txt", p("docbook")),
        ("docbook-xinclude", "xml",
         "<article xmlns:xi=\"http://www.w3.org/2001/XInclude\"><para><xi:include href=\"{P}\" parse=\"text\"/></para></article>",
         "../secret/secret.txt", p("docbook")),
        ("jats-xxe", "xml", xxe * "<body><p>&x;</p></body></article>", "{S}/secret.txt", p("jats")),
        ("opml-ext", "opml", "<?xml version=\"1.0\"?><opml version=\"2.0\"><head/><body><outline text=\"a\" url=\"{P}\"/></body></opml>",
         "../secret/secret.txt", p("opml")),
        ("meta-bibliography", "md", bib, "../secret/secret.bib", cite),
        ("meta-bibliography-abs", "md", bib, "{S}/secret.bib", cite),
        ("meta-bibliography-http", "md", bib, "{URL}/x.bib", cite),
        ("meta-csl", "md", "---\ncsl: {P}\n---\n\nText [@x].\n", "../secret/secret.csl", cite),
        ("meta-abbrev", "md", "---\ncitation-abbreviations: {P}\nreferences: [{id: x, title: T, type: book}]\n---\n\nText [@x].\n",
         "../secret/secret.txt", cite),
        ("meta-lang", "md", "---\nlang: {P}\n---\n\nText.\n", "../../secret/secret",
         Dict{String, Any}("from" => "markdown", "to" => "latex", "standalone" => true)),
        ("meta-header-includes", "md", "---\nheader-includes: {P}\ntitle: x\n---\n\nText.\n", "../secret/secret.txt",
         Dict{String, Any}("from" => "markdown", "to" => "html", "standalone" => true)),
        ("meta-bib-in-latex", "tex", "\\addbibresource{{P}}\\nocite{*}", "../secret/secret.bib", merge(latex, Dict("citeproc" => true))),
    ]
    if !Sys.iswindows()   # (a symbolic link needs a privilege on Windows)
        append!(v, Any[
            ("latex-input-symlink", "tex", "\\input{{P}}", "link-out", latex),
            ("latex-input-symlinkdir", "tex", "\\input{{P}}", "link-dir/secret", latex),
            ("typst-read-symlink", "typ", "#read(\"{P}\")", "link-out.txt", p("typst")),
            ("md-image-symlink", "md", "![x]({P})", "link-out.svg", embed("markdown")),
            ("md-image-symlink-abs", "md", "![x]({P})", "{W}/link-out.svg", embed("markdown")),
        ])
    end
    v
end

fill_in(lab, s) = replace(s, "{S}" => named(lab.secret), "{W}" => named(lab.work), "{URL}" => lab.url)

# A path that doesn't exist, inside the directory, as long as the attack's
# and with its extension (its other characters `q`): what a refusal must
# look like.
function missing_path(lab, attack)
    w = named(lab.work) * "/"
    prefix, rest = startswith(attack, lab.url) ? (lab.url, attack[length(lab.url) + 1:end]) :
                   startswith(attack, "/") || occursin(":/", attack) ? (w, attack[min(length(w), length(attack)) + 1:end]) :
                   ("", attack)
    last = split(rest, '/')[end]
    ext = occursin('.', last) ? last[findlast('.', last):end] : ""
    stem = rest[1:length(rest) - length(ext)]
    prefix * map(c -> c == '/' ? c : 'q', stem) * ext
end

# Convert the case with the document naming `p`; what came out, with `p`
# written {P}.
function attempt(lab, case, p, tag)
    name, ext, doc, _, options = case
    stem = "doc-$name-$tag"
    Base.write(joinpath(lab.work, "$stem.$ext"), replace(doc, "{P}" => p))
    options = mounted(merge(options, Dict("input-files" => ["$stem.$ext"])), [lab.work])
    media = nothing
    if haskey(options, "extract-media")
        options["extract-media"] = m = "$(options["extract-media"])-$tag"
        media = joinpath(lab.work, m)
    end
    s = seen(convert_raw(options), media)
    general(t) = replace(replace(t, p => "{P}", replace(p, "%2F" => "/") => "{P}"), stem => "{FILE}")
    Seen(general(s.output), general(s.messages), s.everything)
end

function check(lab, case)
    problems = String[]
    path = fill_in(lab, case[4])
    attack = attempt(lab, case, path, "attack")
    contains(attack.everything, "CANARY") && push!(problems, "LEAK: $(attack.everything)")
    control = attempt(lab, case, missing_path(lab, path), "missing")
    same = attack.output == control.output
    # `..` or a symbolic link leading out of the directory is "not permitted"
    # in WASI, a file outside every directory "does not exist": documented
    # (README, "Security"), not hidden
    if same && attack.messages == control.messages
    elseif same && replace(attack.messages, NOT_PERMITTED => DOES_NOT_EXIST) == control.messages
        push!(problems, "ERRNO")
    else
        push!(problems, "DISTINGUISHABLE:\n  refused: $(attack.messages)\n$(attack.output)\n" *
                        "  missing: $(control.messages)\n$(control.output)")
    end
    case[1], problems
end

as_missing(m) = replace(m, NOT_PERMITTED => DOES_NOT_EXIST)
walk(d) = isdir(d) ? sort([joinpath(r, f) for (r, _, fs) in walkdir(d) for f in fs]) : String[]
refused_with(f) = try f(); nothing catch e; e end

# pandocjl in `work` with the environment given (a user data directory of the
# lab's, a time limit of 60 s unless given): (status, out, err).
function pandocjl_in(lab, args...; input = "", env = Dict{String, String}())
    e = Dict{String, Any}("LIBPANDOC_SANDBOX" => nothing, "LIBPANDOC_SANDBOX_WRITE" => nothing,
                          "LIBPANDOC_WASM_MAX_MEMORY" => nothing, "PANDOC_DATA_DIRS" => nothing,
                          "LIBPANDOC_WASM_TIMEOUT" => "60", "XDG_DATA_HOME" => lab.data, "APPDATA" => lab.data)
    merge!(e, env)
    status, out, err = withenv(e...) do
        pandocjl(args...; input, dir = lab.work)
    end
    status, out, replace(err, "\r\n" => "\n")
end

const HERE = Dict("LIBPANDOC_SANDBOX" => ".")

if !isfile(P._wasm_path())
    @info "the directory sandbox: set LIBPANDOC_WASM to libpandoc.wasm (or download it: LibPandoc._sandbox_module()) to test it"
else
@testset "the directory sandbox" begin
    lab, server = make_lab()
    P._sandbox_module()   # compiled (or loaded from wasmtime's cache) once
    # relative paths resolve from `work`, as pandoc run there would
    cd(lab.work) do

    @testset "the attacks leak nothing" begin
        # the study's cases: nothing of `secret` comes out, no connection is
        # made, and a refusal reads as a missing file does
        all_cases = cases()
        results = asyncmap(c -> fetch(Threads.@spawn check(lab, c)), all_cases; ntasks = 8)
        errno = [name for (name, problems) in results if "ERRNO" in problems]
        report = join(("$name:\n  " * join(filter(!=("ERRNO"), problems), "\n  ") * "\n"
                       for (name, problems) in results if any(!=("ERRNO"), problems)))
        @info "refused as \"not permitted\", not \"does not exist\": $errno; $(length(results)) cases"
        @test length(results) == (Sys.iswindows() ? 70 : 75)
        @test lab.connections[] == 0
        isempty(report) || println(report)
        @test isempty(report)
    end

    @testset "an image inside is embedded" begin
        r = convert_raw(mounted(Dict{String, Any}("from" => "markdown", "to" => "html", "embed-resources" => true), [lab.work]),
                        "![x](inside.svg)")
        @test contains(seen(r).everything, "INSIDE-OK")
    end

    @testset "without the sandbox they leak" begin
        # the canaries are found where they are (so that "nothing leaked" means something)
        byname = Dict(c[1] => c for c in cases())
        for name in ("latex-input-rel", "md-image-embed", "md-image-docx", "rst-include")
            _, ext, doc, path, options = byname[name]
            Base.write(joinpath(lab.work, "doc-$name-native.$ext"), replace(doc, "{P}" => fill_in(lab, path)))
            r = convert_raw(merge(options, Dict("input-files" => ["doc-$name-native.$ext"])))
            @test contains(seen(r).everything, "CANARY")
        end
    end

    @testset "outputs compare across seconds" begin
        # two conversions a second apart differ in their bytes (ODT and docx
        # hold the time, EPUB a fresh identifier), not in what `seen` keeps
        run(to) = (r = convert_raw(mounted(Dict{String, Any}("from" => "markdown", "to" => to, "metadata" => Dict("title" => "t")),
                                           [lab.work]), "*x*"); (r[2], seen(r).output))
        for to in ("odt", "docx", "epub")
            a = run(to)
            sleep(1.1)
            b = run(to)
            @test a[1] != b[1] && a[2] == b[2]
        end
        @test timeless("at 2026-11-15T04:51:42.5Z, urn:uuid:0b2f4a8e-1c3d-4e5f-8a9b-0c1d2e3f4a5b.") ==
              "at {TIME}, urn:uuid:{UUID}."
    end

    @testset "what the options name must be mounted" begin
        options(template, css, bib) = Dict{String, Any}("from" => "markdown", "to" => "html", "standalone" => true,
            "embed-resources" => true, "citeproc" => true, "template" => template, "css" => [css], "bibliography" => [bib])
        doc = "---\nnocite: \"@*\"\n---\n\nText."
        ok(r) = all(x -> contains(seen(r).everything, x), ("TEMPLATE-OK", "CSS-OK", "BIB-OK"))
        abs_(f) = named(joinpath(lab.outside, f))
        # inside: relative to the working directory, and absolute
        @test ok(convert_raw(mounted(options("template-in.html", "style-in.css", "refs-in.bib"), [lab.work]), doc))
        @test ok(convert_raw(mounted(options(abs_("template.html"), abs_("style.css"), abs_("refs.bib")),
                                     [lab.work, lab.outside]), doc))
        function o(what, p)
            what == "template" && return Dict{String, Any}("from" => "markdown", "to" => "html", "standalone" => true, "template" => p)
            what == "css" && return Dict{String, Any}("from" => "markdown", "to" => "html", "standalone" => true,
                                                      "embed-resources" => true, "css" => [p], "metadata" => Dict("title" => "t"))
            what == "bib" && return Dict{String, Any}("from" => "markdown", "to" => "plain", "citeproc" => true, "bibliography" => [p])
            Dict{String, Any}("from" => "markdown", "to" => "plain", "input-files" => [p])
        end
        # outside, each way of naming it, against a missing file inside;
        # `..` from one mount into another fails too
        table = String[]
        for (what, file) in (("template", "template.html"), ("css", "style.css"), ("bib", "refs.bib"), ("input", "input.md"))
            ways = [("relative", "../outside/$file", "qqqqqqqqqq/$file"),
                    ("absolute", abs_(file), named(joinpath(lab.work, "qqqqqqq", file))),
                    ("dotdot-between", "../outside/$file", "qqqqqqqqqq/$file")]
            Sys.iswindows() || push!(ways, ("symlink", "link-$file", "qqqqq$file"))
            for (way, path, miss) in ways
                dirs = way == "dotdot-between" ? [lab.work, lab.outside] : [lab.work]
                given = what == "input" ? nothing : doc
                s = seen(convert_raw(mounted(o(what, path), dirs), given))
                @test !contains(s.everything, "-OK")
                a = replace(s.messages, path => "{P}")
                b = replace(seen(convert_raw(mounted(o(what, miss), dirs), given)).messages, miss => "{P}")
                push!(table, "$what $way: " * (a == b ? "missing" : as_missing(a) == b ? "not permitted" : "other"))
            end
        end
        expected = ["template relative: missing", "template absolute: missing", "template dotdot-between: missing",
                    "template symlink: missing", "css relative: missing", "css absolute: missing",
                    "css dotdot-between: missing", "css symlink: missing", "bib relative: missing",
                    "bib absolute: missing", "bib dotdot-between: missing", "bib symlink: missing",
                    "input relative: not permitted", "input absolute: missing",
                    "input dotdot-between: not permitted", "input symlink: not permitted"]
        @test table == filter(e -> !Sys.iswindows() || !contains(e, "symlink"), expected)
    end

    @testset "outputs go only into writable mounts" begin
        o(out, media) = Dict{String, Any}("from" => "markdown", "to" => "html", "standalone" => true,
            "metadata" => Dict("title" => "t"), "output-file" => named(joinpath(out, "doc.html")),
            "extract-media" => named(joinpath(media, "media")), "log-file" => named(joinpath(out, "log.json")))
        doc = "![x](inside.svg)"
        d = mkpath(joinpath(lab.out, "writable"))
        r = convert_raw(mounted(o(d, d), [lab.work], [d]), doc)
        @test r[1] == 0 && isempty(r[2])
        @test contains(Base.read(joinpath(d, "doc.html"), String), "media/")
        @test startswith(Base.read(joinpath(d, "log.json"), String), "[")
        media = walk(joinpath(d, "media"))
        @test length(media) == 1 && contains(Base.read(media[1], String), "INSIDE-OK")
        # relative to the working directory, when it is writable (the API)
        @test P.convert("x"; to = "html", output_file = "doc-relative.html", sandbox = (write = [lab.work],)) == ""
        @test isfile(joinpath(lab.work, "doc-relative.html"))
        # a read-only mount, and a directory that isn't mounted
        ro, unmounted = mkpath(joinpath(lab.out, "read-only")), mkpath(joinpath(lab.out, "unmounted"))
        for (out, med, read, why) in ((ro, d, [lab.work, ro], NOT_PERMITTED), (d, ro, [lab.work, ro], NOT_PERMITTED),
                                      (unmounted, d, [lab.work], DOES_NOT_EXIST), (d, unmounted, [lab.work], DOES_NOT_EXIST))
            r = convert_raw(mounted(o(out, med), read, [d]), doc)
            @test r[1] != 0 && contains(r[4], why)
        end
        @test isempty(walk(ro)) && isempty(walk(unmounted))
    end

    @testset "a notebook attachment stays inside the media directory" begin
        doc = """{"cells":[{"cell_type":"markdown","metadata":{},"attachments":{"../../../x.svg":""" *
              """{"image/svg+xml":"PHN2Zy8+"}},"source":["![x](attachment:../../../x.svg)"]}],""" *
              """"metadata":{},"nbformat":4,"nbformat_minor":5}"""
        d = mkpath(joinpath(lab.out, "ipynb"))
        r = convert_raw(mounted(Dict{String, Any}("from" => "ipynb", "to" => "html", "extract-media" => named(joinpath(d, "media"))),
                                String[], [d]), doc)
        @test r[1] == 0
        files = walk(d)
        @test length(files) == 1 && startswith(files[1], joinpath(d, "media"))
    end

    @testset "what is refused" begin
        function refused(sandbox, why)
            e = refused_with(() -> P.convert("x"; to = "html", sandbox))
            @test e isa PandocError && e.kind == "PandocOptionError" && contains(e.message, why)
        end
        refused((read = ["no-such-directory"],), "no-such-directory")
        refused((write = ["no-such-directory"],), "no-such-directory")
        refused((read = [joinpath(lab.work, "inside.txt")],), "not a directory")
        refused((read = String[], network = true), "\"network\"")
        refused(Dict("read" => "."), "lists directories")
        refused(Dict("read" => [1]), "lists directories")
        # the limits: as a wasm filter's
        for bad in (-1, NaN, Inf, "1", true)
            @test_throws ArgumentError P.convert("x"; to = "html", sandbox = (read = String[], timeout = bad))
            @test_throws ArgumentError P.convert("x"; to = "html", sandbox = Dict("read" => String[], "max-memory" => bad))
        end
        @test_throws ArgumentError P.convert("x"; to = "html", sandbox = (max_memory = 1.5,))
        # read_many reads in this process: a directory sandbox is refused
        e = refused_with(() -> P.read_many(["x"]; sandbox = (read = String[],)))
        @test e isa PandocError && contains(e.message, "for conversions")
        # nothing is absent: no directories, the environment's limits (as
        # libpandoc-python's None, libpandoc-rs's null); in a list, refused
        none = (read = nothing, write = nothing, timeout = nothing, max_memory = nothing)
        @test P.convert("x"; to = "html", sandbox = none) == "<p>x</p>\n"
        for var in ("LIBPANDOC_WASM_TIMEOUT", "LIBPANDOC_WASM_MAX_MEMORY")
            e = withenv(var => "-1") do   # (the environment's is read, and refused)
                refused_with(() -> P.convert("x"; to = "html", sandbox = none))
            end
            @test e isa ErrorException && contains(e.msg, var)
        end
        refused((read = [nothing],), "lists directories")
        # pandoc's own sandbox stays the native library's
        @test P.convert("*x*"; to = "html", sandbox = true) == "<p><em>x</em></p>\n"
    end

    @testset "the limits from the environment are checked" begin
        for (var, bad) in (("LIBPANDOC_WASM_TIMEOUT", "-1"), ("LIBPANDOC_WASM_TIMEOUT", "nan"), ("LIBPANDOC_WASM_TIMEOUT", "inf"),
                           ("LIBPANDOC_WASM_MAX_MEMORY", "-1"), ("LIBPANDOC_WASM_MAX_MEMORY", "1x"))
            e = withenv(var => bad) do
                refused_with(() -> P.convert("x"; to = "html", sandbox = (read = String[],)))
            end
            @test e isa ErrorException && contains(e.msg, var)
        end
    end

    @testset "PDF needs a program" begin
        r = convert_raw(mounted(Dict{String, Any}("from" => "markdown", "to" => "pdf"), [lab.work]), "x")
        @test r[1] != 0 && contains(r[4], "pdflatex") && contains(r[4], "unsupported operation")
    end

    @testset "a call has a time limit" begin
        # libpandoc's "timeout" works in the module too, and so does the
        # sandbox's own (the module's clock: it stops Lua as well)
        for opts in ((timeout = 1, sandbox = (read = [lab.work],)), (sandbox = (read = [lab.work], timeout = 1),))
            t = @elapsed e = refused_with(() -> P.convert(">"^100_000; opts...))
            @test e isa PandocError && e.kind == "Timeout" && t < 10
        end
        Base.write(joinpath(lab.work, "forever.lua"), "function Pandoc(d) while true do end end\n")
        e = refused_with(() -> P.convert("x"; filters = ["forever.lua"], sandbox = (read = [lab.work], timeout = 1)))
        @test e isa PandocError && e.kind == "Timeout" && contains(e.message, "the sandbox's \"timeout\"")
        # and the memory limit: a string doubled without end
        typst = "#let s = \"xxxxxxxx\"\n#while true { s = s + s }\n"
        e = refused_with(() -> P.convert(typst; from = "typst", to = "plain",
                                         sandbox = (read = String[], max_memory = 128 << 20, timeout = 60)))
        @test e isa PandocError && contains(e.message, "out of memory") && contains(e.message, "the sandbox's \"max-memory\"")
        @test P.convert("*x*"; to = "plain", sandbox = (read = String[], timeout = 0, max_memory = 0)) == "x\n"   # 0: none
        @test P.convert("*x*"; to = "plain", sandbox = (read = String[], timeout = 1e300)) == "x\n"   # none in practice
    end

    @testset "no directory at all" begin
        # the input given, and nothing else
        r = convert_raw(Dict{String, Any}("from" => "markdown", "to" => "html", "embed-resources" => true,
                                          "sandbox" => Dict{String, Any}()), "*hi* ![x](inside.svg)")
        @test r[1] == 0 && contains(String(copy(r[2])), "<em>hi</em>") && !contains(seen(r).everything, "INSIDE-OK")
    end

    @testset "the working directory" begin
        # relative names resolve from the process's working directory when it
        # is mounted; when it isn't they find nothing, and the error says why
        @test P.convert(; to = "plain", input_files = ["inside.txt"], sandbox = (read = [lab.work],)) == "INSIDE-OK\n"
        e = refused_with(() -> P.convert(; to = "plain", input_files = ["inside.txt"], sandbox = (read = [lab.outside],)))
        @test e isa PandocError && contains(e.message, "does not exist") && contains(e.message, "is not in the sandbox")
    end

    @testset ".. inside a mount" begin
        # `..` that stays inside one mounted directory resolves; one that
        # leaves it does not, even towards another mounted directory
        mkpath(joinpath(lab.work, "sub"))
        Base.write(joinpath(lab.work, "sub/t.html"), "DOTDOT-OK \$body\$")
        @test contains(P.convert(; input_files = ["sub/../doc.md"], standalone = true, template = "sub/../sub/t.html",
                                 sandbox = (read = [lab.work],)), "DOTDOT-OK")
        @test_throws PandocError P.convert(; input_files = ["../outside/input.md"], sandbox = (read = [lab.work, lab.outside],))
    end

    @testset "a Lua filter is confined" begin
        # it runs inside, confined as the document is: it reads and writes only
        # in the mounts, runs no program, and is found only inside
        d = mkpath(joinpath(lab.out, "lua"))
        mark = Dict(k => named(joinpath(d, k)) for k in ("written.txt", "executed", "popen", "pipe"))
        lua = """
            function Pandoc(doc)
              local out = {}
              local function read(f)
                local h = io.open(f)
                out[#out + 1] = f .. "=" .. (h and h:read("a"):sub(1, 9) or "none")
              end
              local function write(f)
                local h = io.open(f, "w")
                out[#out + 1] = f .. "=" .. (h and "written" or "refused")
                if h then h:close() end
              end
              read("inside.txt")
              read("../secret/secret.txt")
              read("$(named(joinpath(lab.secret, "secret.txt")))")
              write("written-by-lua.txt")
              write("$(mark["written.txt"])")
              os.execute("touch $(mark["executed"])")
              pcall(io.popen, "touch $(mark["popen"])")
              pcall(pandoc.pipe, "touch", {"$(mark["pipe"])"}, "")
              return pandoc.Pandoc({pandoc.Para(table.concat(out, " "))})
            end
            """
        Base.write(joinpath(lab.work, "confined.lua"), lua)
        text = P.convert("x"; to = "plain", filters = ["confined.lua"], wrap = "none",
                         sandbox = (read = [lab.work], write = [d]))
        @test !contains(text, "CANARY")
        for x in ("inside.txt=INSIDE-OK", "../secret/secret.txt=none", "secret.txt=none",
                  "written-by-lua.txt=refused", "written.txt=written")
            @test contains(text, x)
        end
        @test readdir(d) == ["written.txt"]
        # a Lua filter outside the mounts isn't found
        Base.write(joinpath(lab.outside, "confined.lua"), lua)
        @test_throws PandocError P.convert("x"; to = "plain", filters = [joinpath(lab.outside, "confined.lua")],
                                           sandbox = (read = [lab.work],))
    end

    @testset "Julia filters run here" begin
        # in this process, inside the conversion, on the task running the
        # module (the calling task; on thread 1, with another thread, the
        # task the call runs in there, for Ctrl-C); what they throw is a
        # FilterError, as natively
        seen_by = []
        up(s::Str, ctx) = (push!(seen_by, (current_task(), ctx.conversion.format)); Str(uppercase(s.text)))
        @test P.convert("hello"; to = "plain", filters = [up], sandbox = (read = [lab.work],)) == "HELLO\n"
        @test only(seen_by)[2] == "plain"
        @test (only(seen_by)[1] === current_task()) == (P._other_thread() === nothing)
        boom(s::Str) = error("no")
        e = refused_with(() -> P.convert("hello"; to = "plain", filters = [boom], sandbox = (read = [lab.work],)))
        @test e isa FilterError && contains(sprint(showerror, e), "no")
        # a fragment, read as the conversion reads: in pandoc's own sandbox here
        function fragment(d::Panir.Pandoc, ctx)
            @test P.read_options(ctx.conversion)["sandbox"] === true
            P.read("\\input{inside} y", ctx.conversion)
        end
        out = @test_logs (:warn, r"Could not load include file") match_mode = :any P.convert(
            "x"; from = "latex", to = "plain", filters = [fragment], sandbox = (read = [lab.work],))
        @test out == "y\n"
        # many: there is no cap
        @test P.convert("x"; to = "plain", filters = [RawFilter((j, c) -> j) for _ in 1:100],
                        sandbox = (read = String[],)) == "x\n"
    end

    @testset "threads and tasks" begin
        # a Julia filter that yields inside the module's call (sleep, yield,
        # I/O) wakes up on its thread and returns into wasm there
        function napper(s::Str)
            tid = Threads.threadid()
            sleep(0.01); yield(); print(devnull, s.text); flush(stdout)
            @assert Threads.threadid() == tid
            Str(uppercase(s.text))
        end
        @test P.convert("a b"; to = "plain", filters = [napper], sandbox = (read = String[],)) == "A B\n"
        # several at once from Threads.@spawn, each yielding inside
        outs = fetch.([Threads.@spawn P.convert("t$i *x*"; to = "plain", filters = [napper],
                                                sandbox = (read = [lab.work],)) for i in 1:16])
        @test outs == ["T$i X\n" for i in 1:16]
        # and with @async on one thread, interleaving
        outs = fetch.([@async P.convert("a$i"; to = "plain", filters = [napper], sandbox = (read = String[],)) for i in 1:8])
        @test outs == ["A$i\n" for i in 1:8]
        # a sandboxed conversion inside a filter of another conversion,
        # sandboxed or not, and the other way round
        inner(s::Str) = Str(strip(P.convert(s.text; to = "plain", filters = [napper], sandbox = (read = String[],))))
        @test P.convert("x y"; to = "plain", filters = [inner]) == "X Y\n"
        @test P.convert("x y"; to = "plain", filters = [inner], sandbox = (read = String[],)) == "X Y\n"
        native(s::Str) = Str(strip(P.convert(s.text; to = "plain", filters = [napper])))
        @test P.convert("x y"; to = "plain", filters = [native], sandbox = (read = String[],)) == "X Y\n"
        # a deep document: GHC's stack is in the module's memory, not this task's
        @test count("<blockquote>", fetch(Threads.@spawn P.convert("> "^2000 * "x"; to = "html", sandbox = (read = String[],)))) == 2000
    end

    @testset "a JSON filter is refused" begin
        # wasm starts no process, and the message says so, whether the
        # program is a file or on PATH
        f = joinpath(lab.work, "filter.sh")
        ran = joinpath(lab.out, "json-filter-ran")
        Base.write(f, "#!/bin/sh\ntouch '$ran'\ncat\n")
        chmod(f, 0o755)
        for filter in (f, "cat")
            e = refused_with(() -> P.convert("hello"; to = "plain", filters = [filter], sandbox = (read = [lab.work],)))
            @test e isa PandocError && e.kind == "PandocFilterError" && contains(e.message, "runs no programs")
        end
        @test !ispath(ran)
    end

    if !isempty(WASM)
        @testset "a wasm filter sees the mounts" begin
            run(file) = P.convert("```{.include}\n$file\n```\n"; to = "plain", filters = [WasmFilter(wasm("include"))],
                                  sandbox = (read = [lab.work], write = [lab.out]))
            @test contains(run("inside.txt"), "INSIDE-OK")
            Base.write(joinpath(lab.out, "input.md"), Base.read(joinpath(lab.outside, "input.md")))
            @test contains(run(named(joinpath(lab.out, "input.md"))), "INPUT-OK")
            for outside in ("../secret/secret.txt", named(joinpath(lab.secret, "secret.txt")), named(joinpath(lab.outside, "input.md")))
                e = refused_with(() -> run(outside))
                @test e !== nothing && !contains(sprint(showerror, e), "CANARY")
            end
        end
    end

    @testset "the module is checked" begin
        # a module this package can't use fails, naming what to do; a download
        # is checked against the release's SHA256SUMS and written whole
        withenv("LIBPANDOC_WASM" => nothing) do
            e = refused_with(() -> P._wasm_abi_check(1001, "/x/libpandoc.wasm"))
            @test e isa PandocError && contains(e.message, "remove /x/libpandoc.wasm")
        end
        mktempdir() do d
            withenv("LIBPANDOC_WASM" => joinpath(d, "nope.wasm")) do
                e = refused_with(() -> P.convert("x"; to = "html", sandbox = (read = String[],)))
                @test e isa PandocError && contains(e.message, "nope.wasm")
            end
            Base.write(joinpath(d, "bad.wasm"), "\0asm-not-really")
            withenv("LIBPANDOC_WASM" => joinpath(d, "bad.wasm")) do
                e = refused_with(() -> P.convert("x"; to = "html", sandbox = (read = String[],)))
                @test e isa PandocError && contains(e.message, "not libpandoc.wasm")
            end
            served = mkpath(joinpath(d, "release"))
            Base.write(joinpath(served, "libpandoc.wasm"), "\0asm-not-really")
            Base.write(joinpath(served, P._NOTICES), "notices\n")
            notices = "$(bytes2hex(SHA.sha256("notices\n")))  $(P._NOTICES)\n"
            Base.write(joinpath(served, "SHA256SUMS"), "$("0"^64)  libpandoc.wasm\n" * notices)
            target = joinpath(d, "cache", "libpandoc.wasm")
            e = @test_logs (:warn,) refused_with(() -> P._download_wasm(target; url = joinpath(served, "libpandoc.wasm")))
            @test e isa PandocError && contains(e.message, "says 0000")
            @test !ispath(target)
            Base.write(joinpath(served, "SHA256SUMS"), "$(bytes2hex(SHA.sha256("\0asm-not-really"))) *libpandoc.wasm\n" * notices)
            @test_logs (:warn,) P._download_wasm(target; url = joinpath(served, "libpandoc.wasm"))
            # the module, and its licence notices beside it
            @test Base.read(target, String) == "\0asm-not-really"
            @test readdir(dirname(target)) == sort([P._NOTICES, "libpandoc.wasm"])
            @test Base.read(joinpath(dirname(target), P._NOTICES), String) == "notices\n"
        end
    end

    # -- pandocjl with LIBPANDOC_SANDBOX and LIBPANDOC_SANDBOX_WRITE --------------------

    @testset "pandocjl reads only inside" begin
        Base.write(joinpath(lab.work, "doc.tex"), "\\input{inside}\n\n\\input{../secret/secret}\n")
        status, out, err = pandocjl_in(lab, "doc.tex", "-t", "plain"; env = HERE)
        @test status == 0 && contains(out, "INSIDE-OK") && !contains(out, "CANARY")
        @test contains(err, "[WARNING] Could not load include file ../secret/secret")
        # standard input, as pandoc reads it
        status, out, _ = pandocjl_in(lab, "-f", "latex", "-t", "plain"; input = "\\input{inside}", env = HERE)
        @test (status, strip(out)) == (0, "INSIDE-OK")
        # an input file outside: as pandoc fails for a file it can't read
        status, out, err = pandocjl_in(lab, named(joinpath(lab.secret, "secret.tex")), "-t", "plain"; env = HERE)
        @test status == 1 && out == "" && contains(err, "does not exist")
        # no directory at all: the input only
        status, out, _ = pandocjl_in(lab, "-f", "latex", "-t", "plain"; input = "\\input{inside} x",
                                     env = Dict("LIBPANDOC_SANDBOX" => ""))
        @test (status, strip(out)) == (0, "x")
        status, out, _ = pandocjl_in(lab, "--version"; env = HERE)
        @test status == 0 && contains(out, "-lua")
    end

    @testset "pandocjl writes only where listed" begin
        env = merge(HERE, Dict("LIBPANDOC_SANDBOX_WRITE" => lab.out))
        status, _, err = pandocjl_in(lab, "doc.md", "-o", named(joinpath(lab.out, "doc.html")); env)
        @test status == 0 && replace(Base.read(joinpath(lab.out, "doc.html"), String), "\r\n" => "\n") == "<p><em>hi</em></p>\n"
        status, _, err = pandocjl_in(lab, "doc.md", "-o", "doc.html"; env = Dict("LIBPANDOC_SANDBOX_WRITE" => "."))
        @test status == 0 && isfile(joinpath(lab.work, "doc.html"))
        status, _, err = pandocjl_in(lab, "doc.md", "-o", "x.html"; env = HERE)
        @test status != 0 && contains(err, "permission denied") && !isfile(joinpath(lab.work, "x.html"))
        # `..` from one mount into another: an absolute path works, this not
        status, _, err = pandocjl_in(lab, "doc.md", "-o", "../out/rel.html"; env)
        @test status != 0 && contains(err, "permission denied")
    end

    @testset "pandocjl: the working directory must be listed" begin
        status, _, err = pandocjl_in(lab, "doc.md"; env = Dict("LIBPANDOC_SANDBOX" => lab.out))
        @test status != 0 && contains(err, "is not in the sandbox")
    end

    @testset "pandocjl: the data directories" begin
        # not mounted by themselves: pandoc finds nothing there unless they
        # are listed, and then they are readable and not writable
        dirs = joinpath(lab.root, "dirs")
        templates = (("mine.html", "DATA-DIR-OK"), ("theirs.html", "DATA-DIRS-OK"))
        for (template, ok) in templates
            status, out, _ = pandocjl_in(lab, "doc.md", "-s", "--template", template;
                                         env = merge(HERE, Dict("PANDOC_DATA_DIRS" => dirs)))
            @test status != 0 && !contains(out, ok)
        end
        sep = Sys.iswindows() ? ";" : ":"
        env = Dict("LIBPANDOC_SANDBOX" => join([".", joinpath(lab.data, "pandoc"), dirs], sep), "PANDOC_DATA_DIRS" => dirs)
        for (template, ok) in templates
            status, out, _ = pandocjl_in(lab, "doc.md", "-s", "--template", template; env)
            @test status == 0 && contains(out, ok)
        end
        targets = (named(joinpath(lab.data, "pandoc/new.txt")), named(joinpath(dirs, "new.txt")))
        Base.write(joinpath(lab.work, "write-data.lua"),
                   "function Pandoc(d)\n  for _, f in ipairs({'$(targets[1])', '$(targets[2])'}) do\n" *
                   "    if io.open(f, 'w') then error('wrote ' .. f) end\n  end\nend\n")
        status, _, err = pandocjl_in(lab, "doc.md", "-L", "write-data.lua"; env)
        @test status == 0
        @test !ispath(joinpath(lab.data, "pandoc/new.txt")) && !ispath(joinpath(dirs, "new.txt"))
    end

    @testset "pandocjl: SOURCE_DATE_EPOCH makes the output reproducible" begin
        env = merge(HERE, Dict("LIBPANDOC_SANDBOX_WRITE" => lab.out, "SOURCE_DATE_EPOCH" => "1700000000"))
        for ext in ("docx", "odt")
            made = map(0:1) do n
                status, _, _ = pandocjl_in(lab, "doc.md", "-o", named(joinpath(lab.out, "dated-$n.$ext")); env)
                @test status == 0
                sleep(1.1)
                Base.read(joinpath(lab.out, "dated-$n.$ext"))
            end
            @test made[1] == made[2]
        end
    end

    @testset "pandocjl refuses what it can't confine" begin
        status, _, err = pandocjl_in(lab, "-t", "plain"; input = "x", env = Dict("LIBPANDOC_SANDBOX" => "no-such-dir"))
        @test status == 1 && contains(err, "no-such-dir")
        # a program: a JSON filter, a PDF engine
        status, _, err = pandocjl_in(lab, "-t", "plain", "-F", "some-program"; input = "x", env = HERE)
        @test status == 83 && contains(err, "runs no programs")
        status, _, err = pandocjl_in(lab, "-t", "pdf"; input = "x", env = HERE)
        @test status != 0 && contains(err, "pdflatex")
        # pandoc's subcommands aren't in the module
        status, _, _ = pandocjl_in(lab, "lua", "-e", "print(1)"; env = HERE)
        @test status == 4
    end

    @testset "pandocjl: Julia filter scripts run here" begin
        # the user's code, as the command line is: in this process, unconfined
        # (the script runs on the host: the file by the host's name)
        outside = joinpath(lab.outside, "input.md")
        Base.write(joinpath(lab.work, "upper.jl"), "using Panir\nrun_filter(s::Str -> Str(strip(read($(repr(outside)), String))))\n")
        status, out, err = pandocjl_in(lab, "-t", "plain", "-F", "upper.jl"; input = "x", env = HERE)
        @test (status, strip(out)) == (0, "INPUT-OK")
    end

    @testset "pandocjl: pandoc's own messages and statuses" begin
        Base.write(joinpath(lab.work, "warns.tex"), "\\input{../secret/secret}\n\nx\n")
        env = merge(HERE, Dict("LIBPANDOC_SANDBOX_WRITE" => lab.out))
        warning = "[WARNING] Could not load include file"
        status, _, err = pandocjl_in(lab, "warns.tex", "-t", "plain"; env)
        @test status == 0 && contains(err, warning)
        status, _, err = pandocjl_in(lab, "warns.tex", "-t", "plain", "--quiet"; env)
        @test status == 0 && !contains(err, "WARNING")
        status, _, err = pandocjl_in(lab, "warns.tex", "-s", "-t", "html", "--verbose"; env)
        @test status == 0 && contains(err, "[INFO]")
        status, _, err = pandocjl_in(lab, "warns.tex", "-t", "plain", "--log", named(joinpath(lab.out, "warns.log")); env)
        @test status == 0 && contains(Base.read(joinpath(lab.out, "warns.log"), String), "CouldNotLoadIncludeFile")
        status, _, err = pandocjl_in(lab, "warns.tex", "-t", "plain", "--fail-if-warnings"; env)
        @test status == 3 && contains(err, warning)
        for args in (["missing.md"], ["-f", "nope", "doc.md"], ["-t", "nope", "doc.md"], ["--no-such-option"])
            native = pandocjl_in(lab, args...)[1]
            status = pandocjl_in(lab, args...; env)[1]
            @test native != 0 && status == native
        end
    end

    if !isempty(WASM)
        @testset "pandocjl: a wasm filter on the command line" begin
            status, out, _ = pandocjl_in(lab, "-t", "plain", "-F", wasm("include"), "-F", wasm("upper");
                                         input = "```include\ninside.tex\n```\n", env = HERE)
            @test (status, strip(out)) == (0, "INSIDE-OK")
            status, out, err = pandocjl_in(lab, "-t", "plain", "-F", wasm("include");
                                           input = "```include\n../secret/secret.tex\n```\n", env = HERE)
            @test status == 83 && !contains(out * err, "CANARY")
        end
    end

    @testset "pandocjl: the memory limit stops a loop" begin
        # a string doubled without end is stopped by the memory limit (Typst's
        # bare `#while true {}` is the time limit's); within the same limit,
        # an ordinary document converts
        env = merge(HERE, Dict("LIBPANDOC_WASM_MAX_MEMORY" => "128m"))
        status, _, err = pandocjl_in(lab, "-f", "typst", "-t", "plain"; input = "#let s = \"xxxxxxxx\"\n#while true { s = s + s }\n", env)
        @test status != 0 && contains(err, "out of memory")
        status, out, _ = pandocjl_in(lab, "-f", "markdown", "-t", "html"; input = "*hi*", env)
        @test (status, out) == (0, "<p><em>hi</em></p>\n")
    end

    @testset "pandocjl: the time limit stops nested quotes" begin
        Base.write(joinpath(lab.work, "quotes.md"), ">"^100_000)
        status, _, err = pandocjl_in(lab, "quotes.md", "-t", "html"; env = merge(HERE, Dict("LIBPANDOC_WASM_TIMEOUT" => "2")))
        after = match(r"stopped after ([0-9.]+) ", err)
        @test status != 0 && after !== nothing && 2.0 <= parse(Float64, after[1]) < 4.0
        status, out, _ = pandocjl_in(lab, "doc.md", "-t", "html"; env = merge(HERE, Dict("LIBPANDOC_WASM_TIMEOUT" => "10")))
        @test (status, out) == (0, "<p><em>hi</em></p>\n")
    end

    @testset "pandocjl: a large standard input" begin
        status, out, _ = pandocjl_in(lab, "-f", "markdown", "-t", "plain"; input = "Some *words* here.\n\n"^20_000, env = HERE)
        @test status == 0 && count("Some words here.", out) == 20_000
    end

    if !Sys.iswindows()
        @testset "pandocjl: a writer and a reader slower than it" begin
            # Julia's libuv makes its standard pipes non-blocking, WASI's
            # inherited streams aren't made for that ("hardware fault" as soon
            # as a pipe was empty or full): blocking while the module runs
            Base.write(joinpath(lab.work, "big.md"), "Some *words* here.\n\n"^20_000)
            jl = Base.shell_escape(`$(Base.julia_cmd()) --startup-file=no --project=$PROJECT -m LibPandoc -f markdown -t plain`)
            out = withenv(HERE...) do
                cd(() -> Base.read(`sh -c "(sleep 2; cat big.md) | $jl | (sleep 3; cat)"`, String), lab.work)
            end
            @test count("Some words here.", out) == 20_000
        end
    end

    @testset "run with the variables" begin
        withenv(HERE...) do
            @test String(P.run(["-f", "latex", "-t", "plain"]; input = "\\input{inside} \\input{../secret/secret}")) |> strip == "INSIDE-OK"
        end
    end

    end   # cd
    close(server)
end
end
