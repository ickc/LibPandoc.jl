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

# Where the release build is unpacked.
_download_prefix() = joinpath(_download_root(), RELEASE, _target())

"""
    LibPandoc.library_path()

The libpandoc this package loads: the first of
- `\$LIBPANDOC_PATH` (the library itself);
- `\$LIBPANDOC_PREFIX`, `\$CONDA_PREFIX` (a prefix with `lib/libpandoc.so`,
  `.dylib`, or `bin/pandoc.dll`), as libpandoc-python and libpandoc-rs;
- libpandoc's release build, downloaded once into `\$LIBPANDOC_DOWNLOAD_DIR`,
  else the user's data directory (`~/.local/share/libpandoc/$RELEASE/<target>`),
  where libpandoc-rs keeps it too (from `\$LIBPANDOC_DOWNLOAD_URL` if set: a
  URL or a file, with `SHA256SUMS` beside it). The download is checked against the
  release's `SHA256SUMS`. It is not downloaded again: one too old for this
  package fails when it is loaded, saying to remove it.
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
    prefix = _download_prefix()
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
    tarball = _fetch(url)
    _check_sum(url, tarball)
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

# A local file as it is (a mirror, offline), else downloaded into a temporary file.
_fetch(url) = isfile(url) ? url : Downloads.download(url)

# `url`'s directory and file name (a local path, or a URL).
_split_url(url) = isfile(url) ? (dirname(url), basename(url)) :
                  (i = findlast('/', url); i === nothing ? ("", url) : (url[1:prevind(url, i)], url[i + 1:end]))

"""
The file downloaded from `url` against the release's `SHA256SUMS` beside it
(`sha256sum`'s lines; libpandoc's releases have one since 1.12): that it
arrived whole and is not half replaced (`continuous` changes file by file),
not that it is the one meant (the sums come from the same place). A
mismatch, a file it doesn't list, or no `SHA256SUMS` is an error.
"""
function _check_sum(url, file)
    dir, name = _split_url(url)
    sums_url = isfile(url) ? joinpath(dir, "SHA256SUMS") : "$dir/SHA256SUMS"
    sums = try
        Base.read(_fetch(sums_url), String)
    catch e
        error("$sums_url, to check $name: $(sprint(showerror, e))")
    end
    want = nothing
    for line in eachline(IOBuffer(sums))
        m = match(r"^([0-9a-fA-F]{64}) [ *](.+?)\r?$", line)
        m !== nothing && m[2] == name && (want = lowercase(m[1]); break)
    end
    want === nothing && error("$name is not in $sums_url")
    got = bytes2hex(open(SHA.sha256, file))
    got == want || error("$url: SHA-256 $got, but $sums_url says $want " *
                         "(the release may be being replaced: try again in a few minutes)")
    nothing
end

# A value made once, under a lock, and read without one: atomically, so that
# a thread reading it while another stores it sees all of it or nothing (a
# plain read then is a data race, which may see half of it: the first calls
# from several threads at once).
mutable struct _Once{T}
    @atomic value::Union{Nothing, T}
end
_Once{T}() where {T} = _Once{T}(nothing)
Base.getindex(o::_Once) = @atomic :acquire o.value
Base.setindex!(o::_Once, v) = (@atomic :release o.value = v; v)

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

const _SYMS = _Once{_Syms}()
const _LOAD_LOCK = ReentrantLock()

# The ABI version this package relies on (libpandoc.h): a library with the
# same major and a minor at least this one works (libpandoc.h, Versions).
const ABI_MAJOR = 1
const ABI_MINOR = 11

# Whether a library's pandoc_abi_version() is one this package works with.
_abi_ok(v::Integer) = v ÷ 1000 == ABI_MAJOR && v % 1000 >= ABI_MINOR

function _abi_check(v::Integer, path)
    _abi_ok(v) && return
    msg = "libpandoc at $path has ABI $(v ÷ 1000).$(v % 1000); LibPandoc.jl needs " *
          "$ABI_MAJOR.$ABI_MINOR or a later $ABI_MAJOR.x"
    # an old download, which is never refreshed by itself
    path == joinpath(_download_prefix(), _libname()) &&
        (msg *= ". It is an earlier download of libpandoc's release: remove $(_download_prefix()) " *
                "to download the current one (libpandoc-rs shares it: rebuild that after)")
    error(msg)
end

function _load()
    s = _SYMS[]
    s === nothing || return s
    lock(_LOAD_LOCK) do
        _SYMS[] === nothing || return _SYMS[]
        path = library_path()
        h = Libdl.dlopen(path)
        f(name) = Libdl.dlsym(h, Symbol("pandoc_", name))
        s = _Syms((f(n) for n in (:init, :abi_version, :set_num_threads, :convert, :convert_args,
                                   :convert_filters, :convert_args_filters, :main, :read_many,
                                   :query, :result_free, :buffer_set))...)
        # before anything else: an older library's meanings differ
        _abi_check(ccall(s.abi_version, Cint, ()), path)
        ccall(s.init, Cint, ()) == 0 || error("libpandoc: the Haskell runtime didn't start")
        _SYMS[] = s
    end
end
