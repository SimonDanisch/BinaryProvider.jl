module BinaryProvider

using Libdl, Logging
using Pkg, Pkg.PlatformEngines, Pkg.BinaryPlatforms
import Pkg.PlatformEngines: package, download
import Pkg.BinaryPlatforms: Linux
export platform_key, platform_key_abi, platform_dlext, valid_dl_path,
       triplet, select_platform, platforms_match,
       Linux, MacOS, Windows, FreeBSD,
       parse_7z_list, parse_tar_list, verify,
       download_verify, unpack, package, download_verify_unpack,
       list_tarball_files, list_tarball_symlinks

# Some compatibility mapping
const choose_download = Pkg.BinaryPlatforms.select_platform
Linux(arch::Symbol, libc::Symbol) = Linux(arch; libc=libc)
function platform_key(machine::AbstractString = Sys.MACHINE)
    Base.depwarn("platform_key() is deprecated, use platform_key_abi() from now on", :binaryprovider_platform_key)
    platkey = platform_key_abi(machine)
    return typeof(platkey)(arch(platkey); libc=libc(platkey), call_abi=call_abi(platkey))
end

# Utilities for controlling verbosity
include("LoggingUtils.jl")
# Include our subprocess running functionality
include("OutputCollector.jl")
# Everything related to file/path management
include("Prefix.jl")
# Abstraction of "needing" a file, that would trigger an install
include("Products.jl")

function __init__()
    global global_prefix

    # Initialize our global_prefix
    global_prefix = Prefix(joinpath(@__DIR__, "..", "global_prefix"))

    # Find the right download/compression engines for this platform
    probe_platform_engines!()
end

# gotta go fast
include("precompile.jl")
_precompile_()

end # module
