# pandocjl's system image: LibPandoc and Panir compiled in, with what
# precompile.jl runs (pandocjl without a filter, with a Julia filter script,
# with a wasm filter), so pandocjl starts faster (README, Start-up).
#
#     julia sysimage/build.jl [OUTPUT [PROJECT]]
#
# PROJECT is the environment pandocjl runs in, whose LibPandoc and Panir go
# into the image (default: this repository); OUTPUT the image (default:
# pandocjl.so, .dylib or .dll in PROJECT). Then:
#
#     julia -J OUTPUT --project=PROJECT --startup-file=no -m LibPandoc ARGS
#
# What determines the image, written beside it (OUTPUT.txt): this Julia (an
# image loads only in the Julia that built it); PROJECT's Manifest (the
# versions of LibPandoc, Panir and the rest, which the image keeps whatever
# the environment later says: rebuild after changing them); precompile.jl,
# and the wasm filters it runs ($LIBPANDOC_WASM_FILTERS); and the CPU
# target: $JULIA_CPU_TARGET, else PackageCompiler's default, "native" (this
# machine's CPU only; for an image to copy to other machines, e.g. Julia's
# own x86-64 targets "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)",
# which take longer to build). Not the libpandoc it runs on, found at run
# time as always ($LIBPANDOC_PREFIX, ...).
#
# PackageCompiler (needs a C compiler) is this directory's environment,
# pinned in its Project.toml.
import Pkg, SHA, Dates

project = abspath(get(ARGS, 2, dirname(@__DIR__)))
output = abspath(get(ARGS, 1, joinpath(project, "pandocjl." * Base.Libc.Libdl.dlext)))
cpu_target = get(ENV, "JULIA_CPU_TARGET", "native")
precompile_file = joinpath(@__DIR__, "precompile.jl")

Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate()
using PackageCompiler

# no wasm limits while building: a timeout starts the clock thread, which
# hangs writing the image; no directory sandbox (precompile.jl's pandocjl
# would compile libpandoc.wasm, its engine's threads in the image)
seconds = withenv("LIBPANDOC_WASM_TIMEOUT" => nothing, "LIBPANDOC_WASM_MAX_MEMORY" => nothing,
                  "LIBPANDOC_SANDBOX" => nothing, "LIBPANDOC_SANDBOX_WRITE" => nothing) do
    @elapsed create_sysimage(["LibPandoc", "Panir"]; sysimage_path = output, project,
                             precompile_execution_file = precompile_file, cpu_target)
end

sha(file) = bytes2hex(open(SHA.sha256, file))
commit(dir) = (c = readchomp(pipeline(ignorestatus(`git -C $dir describe --always --dirty`); stderr = devnull)); isempty(c) ? "not in git" : c)
v = "$(VERSION.major).$(VERSION.minor)"
manifest = first(filter(isfile, joinpath.(project, ["JuliaManifest-v$v.toml", "Manifest-v$v.toml",
                                                     "JuliaManifest.toml", "Manifest.toml"])))
Pkg.activate(project; io = devnull)
record = sprint() do io
    println(io, "pandocjl system image ", output)
    println(io, "built ", Dates.now(), " in ", round(Int, seconds), " s; ", filesize(output) >> 20, " MiB")
    println(io, "Julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, ", ", Sys.MACHINE, ")")
    println(io, "cpu_target ", cpu_target)
    println(io, "PackageCompiler ", pkgversion(PackageCompiler))
    println(io, "precompile.jl sha256 ", sha(precompile_file))
    println(io, "LIBPANDOC_WASM_FILTERS ", get(ENV, "LIBPANDOC_WASM_FILTERS", ""))
    println(io, "project ", project, " (", commit(project), "); ", basename(manifest), " sha256 ", sha(manifest))
    # packages developed from a directory: its commit
    for (_, p) in Pkg.dependencies()
        p.is_tracking_path && println(io, p.name, " at ", p.source, " (", commit(p.source), ")")
    end
    Pkg.status(; mode = Pkg.PKGMODE_MANIFEST, io)
end
write(output * ".txt", record)
print(record)
