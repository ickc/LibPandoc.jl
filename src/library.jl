# Finding libpandoc, loading it, and its C functions.

# The release downloaded when no libpandoc is installed; `continuous` is the
# latest build of libpandoc's main (as libpandoc-rs's `download` feature).
const RELEASE = "continuous"

_libname() = Sys.iswindows() ? joinpath("bin", "pandoc.dll") :
             Sys.isapple() ? joinpath("lib", "libpandoc.dylib") : joinpath("lib", "libpandoc.so")

function _target()
    arch = Sys.ARCH === :x86_64 ? "64" : Sys.ARCH === :aarch64 ? (Sys.isapple() ? "arm64" : "aarch64") :
           error("libpandoc has no release build for $(Sys.ARCH)")
    os = Sys.islinux() ? "linux" : Sys.isapple() ? "osx" : Sys.iswindows() ? "win" : error("libpandoc has no release build for this OS")
    os == "win" && arch != "64" && error("libpandoc has no release build for Windows on $(Sys.ARCH)")
    "$os-$arch"
end

# Where per-user data goes, as libpandoc-rs puts its download: the two share it.
function _download_root()
    d = get(ENV, "LIBPANDOC_DOWNLOAD_DIR", "")
    isempty(d) || return d
    base = Sys.iswindows() ? get(ENV, "LOCALAPPDATA", "") :
           Sys.isapple() ? joinpath(homedir(), "Library", "Application Support") :
           (x = get(ENV, "XDG_DATA_HOME", ""); isempty(x) ? joinpath(homedir(), ".local", "share") : x)
    joinpath(base, "libpandoc")
end

"""
    LibPandoc.library_path()

The libpandoc this package loads: the first of
- `\$LIBPANDOC_PATH` (the library itself);
- `\$LIBPANDOC_PREFIX`, `\$CONDA_PREFIX` (a prefix with `lib/libpandoc.so`,
  `.dylib`, or `bin/pandoc.dll`), as libpandoc-python and libpandoc-rs;
- libpandoc's release build, downloaded once into `\$LIBPANDOC_DOWNLOAD_DIR`,
  else the user's data directory (`~/.local/share/libpandoc/$RELEASE/<target>`),
  where libpandoc-rs keeps it too.
"""
function library_path(; download::Bool = true)
    p = get(ENV, "LIBPANDOC_PATH", "")
    isempty(p) || return p
    for var in ("LIBPANDOC_PREFIX", "CONDA_PREFIX")
        prefix = get(ENV, var, "")
        isempty(prefix) && continue
        lib = joinpath(prefix, _libname())
        isfile(lib) && return lib
        var == "LIBPANDOC_PREFIX" && error("\$LIBPANDOC_PREFIX: no $(_libname()) in $prefix")
    end
    prefix = joinpath(_download_root(), RELEASE, _target())
    lib = joinpath(prefix, _libname())
    isfile(lib) && return lib
    download || error("libpandoc not found (set \$LIBPANDOC_PREFIX)")
    _download(prefix)
    lib
end

function _download(prefix)
    url = get(ENV, "LIBPANDOC_DOWNLOAD_URL",
              "https://github.com/ickc/libpandoc/releases/download/$RELEASE/libpandoc-$(_target()).tar.gz")
    @info "Downloading libpandoc ($RELEASE, $(_target())) into $prefix"
    tarball = isfile(url) ? url : Downloads.download(url)
    # unpacked beside, then moved into place: never half there
    mkpath(dirname(prefix))
    tmp = "$prefix.tmp$(getpid())"
    rm(tmp; force = true, recursive = true)
    open(tarball) do io
        Tar.extract(GzipDecompressorStream(io), tmp)
    end
    try
        mv(tmp, prefix)
    catch
        rm(tmp; force = true, recursive = true)  # another process got there first
    end
    isfile(joinpath(prefix, _libname())) || error("$url: no $(_libname()) in it")
    nothing
end

# The library's C functions, found once.
struct _Syms
    init::Ptr{Cvoid}
    abi_version::Ptr{Cvoid}
    set_num_threads::Ptr{Cvoid}
    convert::Ptr{Cvoid}
    convert_args::Ptr{Cvoid}
    convert_filters::Ptr{Cvoid}
    convert_args_filters::Ptr{Cvoid}
    main::Ptr{Cvoid}
    read_many::Ptr{Cvoid}
    query::Ptr{Cvoid}
    result_free::Ptr{Cvoid}
    buffer_set::Ptr{Cvoid}
end

const _SYMS = Ref{Union{Nothing, _Syms}}(nothing)
const _LOAD_LOCK = ReentrantLock()

# The ABI version this package is written against (libpandoc.h).
const ABI_MAJOR = 1
const ABI_MINOR = 6

function _load()
    s = _SYMS[]
    s === nothing || return s
    lock(_LOAD_LOCK) do
        _SYMS[] === nothing || return _SYMS[]
        h = Libdl.dlopen(library_path())
        f(name) = Libdl.dlsym(h, Symbol("pandoc_", name))
        s = _Syms((f(n) for n in (:init, :abi_version, :set_num_threads, :convert, :convert_args,
                                   :convert_filters, :convert_args_filters, :main, :read_many,
                                   :query, :result_free, :buffer_set))...)
        v = ccall(s.abi_version, Cint, ())
        (v ÷ 1000 == ABI_MAJOR && v % 1000 >= ABI_MINOR) || error(
            "libpandoc's ABI is $(v ÷ 1000).$(v % 1000); this package needs $ABI_MAJOR.$ABI_MINOR or later")
        ccall(s.init, Cint, ()) == 0 || error("libpandoc: the Haskell runtime didn't start")
        _SYMS[] = s
    end
end
