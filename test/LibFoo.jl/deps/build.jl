using BinaryProvider

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))

# These are the two binary objects we care about
products = Product[
    LibraryProduct(prefix, "libfoo", :libfoo),
    ExecutableProduct(prefix, "fooifier", :fooifier),
]

# Download binaries from hosted location
bin_prefix = "https://github.com/staticfloat/small_bin/raw/51b13b44feb2a262e2e04690bfa54d03167533f2/libfoo"
download_info = Dict(
    Linux(:aarch64, :glibc) => ("$bin_prefix/libfoo.aarch64-linux-gnu.tar.gz", "36886ac25cf5678c01fe20630b413f9354b7a3721c6a2c2043162f7ebd147ff5"),
    Linux(:armv7l, :glibc)  => ("$bin_prefix/libfoo.arm-linux-gnueabihf.tar.gz", "147ebaeb1a722da43ee08705689aed71ac87c3c2c907af047c6721c0025ba383"),
    Linux(:powerpc64le, :glibc) => ("$bin_prefix/libfoo.powerpc64le-linux-gnu.tar.gz", "5c35295ac161272ada9a77d1f6b770e30ea864e521e31853258cbc36ad4c4468"),
    Linux(:i686, :glibc)    => ("$bin_prefix/libfoo.i686-linux-gnu.tar.gz", "97655b6a218d61284723b6923d7c96e6a256fa68b9419d723c588aa24404b102"),
    Linux(:x86_64, :glibc)  => ("$bin_prefix/libfoo.x86_64-linux-gnu.tar.gz", "5208c63a9d07e592c78f541fc13caa8cd191b11e7e77b31d407237c2b13ec391"),

    Linux(:aarch64, :musl)  => ("$bin_prefix/libfoo.aarch64-linux-musl.tar.gz", "81751477c1e3ee6c93e1c28ee7db2b99d1eed0d6ce86dc30d64c2e5dd4dfe88d"),
    Linux(:armv7l, :musl)   => ("$bin_prefix/libfoo.arm-linux-musleabihf.tar.gz", "bb65aad58f2e6fc39dc9688da1bca5e8103a3a3fa67dc589debbd2e98176f0e1"),
    Linux(:i686, :musl)     => ("$bin_prefix/libfoo.i686-linux-musl.tar.gz", "5f02fd1fe19f3a565fb128d3673b35c7b3214a101cef9dcbb202c0092438a87b"),
    Linux(:x86_64, :musl)   => ("$bin_prefix/libfoo.x86_64-linux-musl.tar.gz", "ea630600a12d2c1846bc93bcc8d9638a4991f63329205c534d93e0a3de5f641d"),

    FreeBSD(:x86_64)        => ("$bin_prefix/libfoo.x86_64-unknown-freebsd11.1.tar.gz", "5f6edd6247b3685fa5c42c98a53d2a3e1eef6242c2bb3cdbb5fe23f538703fe4"),
    MacOS(:x86_64)          => ("$bin_prefix/libfoo.x86_64-apple-darwin14.tar.gz", "fcc268772d6f21d65b45fcf3854a3142679b78e53c7673dac26c95d6ccc89a24"),

    Windows(:i686)          => ("$bin_prefix/libfoo.i686-w64-mingw32.tar.gz", "79181cf62ca8e0b2e0851fa0ace52f4ab335d0cad26fb7f9cd4ff356a9a96e70"),
    Windows(:x86_64)        => ("$bin_prefix/libfoo.x86_64-w64-mingw32.tar.gz", "7f8939e9529835b83810d3ae7e2556f6e002d571f619894e54ece42ea5262b7f"),
)
# First, check to see if we're all satisfied
if any(!satisfied(p; verbose=verbose) for p in products)
    try
        # Download and install binaries
        url, tarball_hash = choose_download(download_info)
        install(url, tarball_hash; prefix=prefix, force=true, verbose=true)
    catch e
        if typeof(e) <: ArgumentError || typeof(e) <: MethodError
            error("Your platform $(Sys.MACHINE) is not supported by this package!")
        else
            rethrow(e)
        end
    end

    # Finally, write out a deps.jl file
    write_deps_file(joinpath(@__DIR__, "deps.jl"), products)
end
