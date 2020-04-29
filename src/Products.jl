export Product, LibraryProduct, FileProduct, ExecutableProduct, satisfied,
       locate, write_deps_file, variable_name
import Base: repr

"""
A `Product` is an expected result after building or installation of a package.

Examples of `Product`s include `LibraryProduct`, `ExecutableProduct` and
`FileProduct`.  All `Product` types must define the following minimum set of
functionality:

* `locate(::Product)`: given a `Product`, locate it within the wrapped `Prefix`
  returning its location as a string

* `satisfied(::Product)`: given a `Product`, determine whether it has been
  successfully satisfied (e.g. it is locateable and it passes all callbacks)

* `variable_name(::Product)`: return the variable name assigned to a `Product`

* `repr(::Product)`: Return a representation of this `Product`, useful for
  auto-generating source code that constructs `Products`, if that's your thing.
"""
abstract type Product end

"""
    satisfied(p::Product; platform::Platform = platform_key_abi(),
              verbose::Bool = false, isolate::Bool = true)

Given a `Product`, return `true` if that `Product` is satisfied, e.g. whether
a file exists that matches all criteria setup for that `Product`.  If `isolate`
is set to `true`, will isolate all checks from the main Julia process in the
event that `dlopen()`'ing or `dlclose()`'ing a library might cause issues.
"""
function satisfied(p::Product; platform::Platform = platform_key_abi(),
                               verbose::Bool = false, isolate::Bool = true)
    return locate(p; platform=platform, verbose=verbose, isolate=isolate) != nothing
end


"""
    variable_name(p::Product)

Return the variable name associated with this `Product` as a string
"""
function variable_name(p::Product)
    return string(p.variable_name)
end


"""
A `LibraryProduct` is a special kind of `Product` that not only needs to exist,
but needs to be `dlopen()`'able.  You must know which directory the library
will be installed to, and its name, e.g. to build a `LibraryProduct` that
refers to `"/lib/libnettle.so"`, the "directory" would be "/lib", and the
"libname" would be "libnettle".  Note that a `LibraryProduct` can support
multiple libnames, as some software projects change the libname based on the
build configuration.
"""
struct LibraryProduct <: Product
    dir_path::Union{String, Nothing}
    libnames::Vector{String}
    variable_name::Symbol
    prefix::Union{Prefix, Nothing}

    """
        LibraryProduct(prefix::Prefix, libname::AbstractString,
                       varname::Symbol)

    Declares a `LibraryProduct` that points to a library located within the
    `libdir` of the given `Prefix`, with a name containing `libname`.  As an
    example, given that `libdir(prefix)` is equal to `usr/lib`, and `libname`
    is equal to `libnettle`, this would be satisfied by the following paths:

        usr/lib/libnettle.so
        usr/lib/libnettle.so.6
        usr/lib/libnettle.6.dylib
        usr/lib/libnettle-6.dll

    Libraries matching the search pattern are rejected if they are not
    `dlopen()`'able.
    """
    function LibraryProduct(prefix::Prefix, libname::AbstractString,
                            varname::Symbol)
        return LibraryProduct(prefix, [libname], varname)
    end

    function LibraryProduct(prefix::Prefix, libnames::Vector{S},
                            varname::Symbol) where {S <: AbstractString}
        return new(nothing, libnames, varname, prefix)
    end

    """
        LibraryProduct(dir_path::AbstractString, libname::AbstractString,
                       varname::Symbol)

    For finer-grained control over `LibraryProduct` locations, you may directly
    pass in the `dir_path` instead of auto-inferring it from `libdir(prefix)`.
    """
    function LibraryProduct(dir_path::AbstractString, libname::AbstractString,
                            varname::Symbol)
        return LibraryProduct(dir_path, [libname], varname)
    end

    function LibraryProduct(dir_path::AbstractString, libnames::Vector{S},
                            varname::Symbol) where {S <: AbstractString}
       return new(dir_path, libnames, varname, nothing)
    end
end

function repr(p::LibraryProduct)
    libnames = repr(p.libnames)
    varname = repr(p.variable_name)
    if p.prefix === nothing
        return "LibraryProduct($(repr(p.dir_path)), $(libnames), $(varname))"
    else
        return "LibraryProduct(prefix, $(libnames), $(varname))"
    end
end

"""
locate(lp::LibraryProduct; verbose::Bool = false,
        platform::Platform = platform_key_abi(), isolate::Bool = true)

If the given library exists (under any reasonable name) and is `dlopen()`able,
(assuming it was built for the current platform) return its location.  Note
that the `dlopen()` test is only run if the current platform matches the given
`platform` keyword argument, as cross-compiled libraries cannot be `dlopen()`ed
on foreign platforms.
"""
function locate(lp::LibraryProduct; verbose::Bool = false,
                platform::Platform = platform_key_abi(), isolate::Bool = true)
    dir_path = lp.dir_path
    if dir_path === nothing
        dir_path = libdir(lp.prefix, platform)
    end

    if !isdir(dir_path)
        if verbose
            @info("Directory $(dir_path) does not exist!")
        end
        return nothing
    end
    for f in readdir(dir_path)
        # Skip any names that aren't a valid dynamic library for the given
        # platform (note this will cause problems if something compiles a `.so`
        # on OSX, for instance)
        if !valid_dl_path(f, platform)
            continue
        end

        if verbose
            @info("Found a valid dl path $(f) while looking for $(join(lp.libnames, ", "))")
        end

        # If we found something that is a dynamic library, let's check to see
        # if it matches our libname:
        for libname in lp.libnames
            if startswith(basename(f), libname)
                dl_path = abspath(joinpath(dir_path), f)
                if verbose
                    @info("$(dl_path) matches our search criteria of $(libname)")
                end

                # If it does, try to `dlopen()` it if the current platform is good
                if platforms_match(platform, platform_key_abi())
                    if isolate
                        # Isolated dlopen is a lot slower, but safer
                        dl_esc_path = replace(dl_path, "\\"=>"\\\\")
                        if success(`$(Base.julia_cmd()) -e "import Libdl; Libdl.dlopen(\"$(dl_esc_path)\")"`)
                            return dl_path
                        end
                    else
                        hdl = Libdl.dlopen_e(dl_path)
                        if !(hdl in (C_NULL, nothing))
                            Libdl.dlclose(hdl)
                            return dl_path
                        end
                    end

                    if verbose
                        try
                            dlopen(dl_path)
                        catch dlopen_result
                            @info("$(dl_path) cannot be dlopen'ed",dlopen_result)
                        end
                    end
                else
                    # If the current platform doesn't match, then just trust in our
                    # cross-compilers and go with the flow
                    return dl_path
                end
            end
        end
    end

    if verbose
        @info("Could not locate $(join(lp.libnames, ", ")) inside $(dir_path)")
    end
    return nothing
end

"""
An `ExecutableProduct` is a `Product` that represents an executable file.

On all platforms, an ExecutableProduct checks for existence of the file.  On
non-Windows platforms, it will check for the executable bit being set.  On
Windows platforms, it will check that the file ends with ".exe", (adding it on
automatically, if it is not already present).
"""
struct ExecutableProduct <: Product
    path::AbstractString
    variable_name::Symbol
    prefix::Union{Prefix, Nothing}

    """
    `ExecutableProduct(prefix::Prefix, binname::AbstractString,
                       varname::Symbol)`

    Declares an `ExecutableProduct` that points to an executable located within
    the `bindir` of the given `Prefix`, named `binname`.
    """
    function ExecutableProduct(prefix::Prefix, binname::AbstractString,
                               varname::Symbol)
        return new(joinpath(bindir(prefix), binname), varname, prefix)
    end

    """
    `ExecutableProduct(binpath::AbstractString, varname::Symbol)`

    For finer-grained control over `ExecutableProduct` locations, you may directly
    pass in the full `binpath` instead of auto-inferring it from `bindir(prefix)`.
    """
    function ExecutableProduct(binpath::AbstractString, varname::Symbol)
        return new(binpath, varname, nothing)
    end
end

function repr(p::ExecutableProduct)
    varname = repr(p.variable_name)
    if p.prefix === nothing
        return "ExecutableProduct($(repr(p.path)), $(varname))"
    else
        rp = relpath(p.path, bindir(p.prefix))
        return "ExecutableProduct(prefix, $(repr(rp)), $(varname))"
    end
end

"""
`locate(fp::ExecutableProduct; platform::Platform = platform_key_abi(),
                               verbose::Bool = false, isolate::Bool = true)`

If the given executable file exists and is executable, return its path.

On all platforms, an ExecutableProduct checks for existence of the file.  On
non-Windows platforms, it will check for the executable bit being set.  On
Windows platforms, it will check that the file ends with ".exe", (adding it on
automatically, if it is not already present).
"""
function locate(ep::ExecutableProduct; platform::Platform = platform_key_abi(),
                verbose::Bool = false, isolate::Bool = true)
    # On windows, we always slap an .exe onto the end if it doesn't already
    # exist, as Windows won't execute files that don't have a .exe at the end.
    path = if platform isa Windows && !endswith(ep.path, ".exe")
        "$(ep.path).exe"
    else
        ep.path
    end

    if !isfile(path)
        if verbose
            @info("$(ep.path) does not exist, reporting unsatisfied")
        end
        return nothing
    end

    # If the file is not executable, fail out (unless we're on windows since
    # windows doesn't honor these permissions on its filesystems)
    @static if !Sys.iswindows()
        if uperm(path) & 0x1 == 0
            if verbose
                @info("$(path) is not executable, reporting unsatisfied")
            end
            return nothing
        end
    end

    return path
end

"""
A `FileProduct` represents a file that simply must exist to be satisfied.
"""
struct FileProduct <: Product
    path::AbstractString
    variable_name::Symbol
    prefix::Union{Prefix, Nothing}

    """
        FileProduct(prefix::Prefix, relative_path::AbstractString,
                                    varname::Symbol)`

    Declares a `FileProduct` that points to a file located relative to a the
    root of a `Prefix`.
    """
    function FileProduct(prefix::Prefix, relative_path::AbstractString,
                                         varname::Symbol)
        file_path = joinpath(prefix.path, relative_path)
        return new(file_path, varname, prefix)
    end

    """
        FileProduct(file_path::AbstractString, varname::Symbol)

    For finer-grained control over `FileProduct` locations, you may directly
    pass in the full `file_pathpath` instead of defining it in reference to
    a root `Prefix`.
    """
    function FileProduct(file_path::AbstractString, varname::Symbol)
        return new(file_path, varname, nothing)
    end
end

function repr(p::FileProduct)
    varname = repr(p.variable_name)
    if p.prefix === nothing
        return "FileProduct($(repr(p.path)), $(varname))"
    else
        rp = relpath(p.path, p.prefix.path)
        return "FileProduct(prefix, $(repr(rp)), $(varname))"
    end
end

"""
locate(fp::FileProduct; platform::Platform = platform_key_abi(),
                        verbose::Bool = false, isolate::Bool = true)

If the given file exists, return its path.  The platform argument is ignored
here, but included for uniformity.
"""
function locate(fp::FileProduct; platform::Platform = platform_key_abi(),
                                 verbose::Bool = false, isolate::Bool = true)
    # Limited variable expansion capabilities
    mappings = Dict()

    for (var, val) in [("target", triplet(platform)), ("nbits", wordsize(platform))]
        mappings["\$$(var)"] = string(val)
        mappings["\${$(var)}"] = string(val)
    end

    expanded = fp.path
    for (old, new) in mappings
        expanded = replace(expanded, old => new)
    end

    if isfile(expanded)
        if verbose
            @info("FileProduct $(fp.path) found at $(realpath(expanded))")
        end
        return expanded
    end
    if verbose
        @info("FileProduct $(fp.path) not found")
    end
    return nothing
end

"""
    write_deps_file(depsjl_path::AbstractString, products::Vector{Product};
                    verbose::Bool = false)

Generate a `deps.jl` file that contains the variables referred to by the
products within `products`.  As an example, running the following code:

    fooifier = ExecutableProduct(..., :foo_exe)
    libbar = LibraryProduct(..., :libbar)
    write_deps_file(joinpath(@__DIR__, "deps.jl"), [fooifier, libbar])

Will generate a `deps.jl` file that contains definitions for the two variables
`foo_exe` and `libbar`.  If any `Product` object cannot be satisfied (e.g.
`LibraryProduct` objects must be `dlopen()`-able, `FileProduct` objects must
exist on the filesystem, etc...) this method will error out.  Ensure that you
have used `install()` to install the binaries you wish to write a `deps.jl`
file for.

The result of this method is a `deps.jl` file containing variables named as
defined within the `Product` objects passed in to it, holding the full path to the
installed binaries.  Given the example above, it would contain code similar to:

    global const foo_exe = "<pkg path>/deps/usr/bin/fooifier"
    global const libbar = "<pkg path>/deps/usr/lib/libbar.so"

This `deps.jl` file is intended to be `include()`'ed from within the top-level
source of your package.  Note that all files are checked for consistency on
package load time, and if an error is discovered, package loading will fail,
asking the user to re-run `Pkg.build("package_name")`.
"""
function write_deps_file(depsjl_path::AbstractString, products::Vector{P};
                         verbose::Bool=false, isolate::Bool=true) where {P <: Product}
    # helper function to escape paths
    escape_path = path -> replace(path, "\\" => "\\\\")

    # Grab the package name as the name of the top-level directory of a package
    # Auto-detect being placed within the `~/.julia/packages/XXXXX` directory
    if basename(dirname(dirname(dirname(dirname(depsjl_path))))) == "packages"
        package_name = basename(dirname(dirname(dirname(depsjl_path))))
    else
        # otherwise assume same as folder name
        # TODO: check Project.toml
        package_name = basename(dirname(dirname(depsjl_path)))
    end
    # We say this a couple of times
    rebuild = strip("""
    Please re-run Pkg.build(\\\"$(package_name)\\\"), and restart Julia.
    """)

    # Begin by ensuring that we can satisfy every product RIGHT NOW
    for p in products
        if !satisfied(p; verbose=verbose, isolate=isolate)
            error("$p is not satisfied, cannot generate deps.jl!")
        end
    end

    # If things look good, let's generate the `deps.jl` file
    open(depsjl_path, "w") do depsjl_file
        # First, dump the preamble
        println(depsjl_file, strip("""
        ## This file autogenerated by BinaryProvider.write_deps_file().
        ## Do not edit.
        ##
        ## Include this file within your main top-level source, and call
        ## `check_deps()` from within your module's `__init__()` method

        if isdefined((@static VERSION < v"0.7.0-DEV.484" ? current_module() : @__MODULE__), :Compat)
            import Compat.Libdl
        elseif VERSION >= v"0.7.0-DEV.3382"
            import Libdl
        end
        """))

        # Next, spit out the paths of all our products
        for product in products
            # Escape the location so that e.g. Windows platforms are happy with
            # the backslashes in a string literal
            product_path = locate(product, platform=platform_key_abi(),
                                           verbose=verbose, isolate=isolate)
            product_path = relpath(product_path, dirname(depsjl_path))
            product_path = escape_path(product_path)
            vp = variable_name(product)
            println(depsjl_file, strip("""
            const $(vp) = joinpath(dirname(@__FILE__), \"$(product_path)\")
            """))
        end

        # Next, generate a function to check they're all on the up-and-up
        println(depsjl_file, "function check_deps()")

        for product in products
            varname = variable_name(product)

            # Add a `global $(name)`
            println(depsjl_file, "    global $(varname)");

            # Check that any file exists
            println(depsjl_file, """
                if !isfile($(varname))
                    error("\$($(varname)) does not exist, $(rebuild)")
                end
            """)

            # For Library products, check that we can dlopen it:
            if typeof(product) <: LibraryProduct
                println(depsjl_file, """
                    if Libdl.dlopen_e($(varname)) in (C_NULL, nothing)
                        error("\$($(varname)) cannot be opened, $(rebuild)")
                    end
                """)
            end
        end

        # If any of the products are `ExecutableProduct`s, we need to add Julia's
        # library directory onto the end of {DYLD,LD}_LIBRARY_PATH
        @static if !Sys.iswindows()
            if any(p isa ExecutableProduct for p in products)
                dllist = Libdl.dllist()
                libjulia = filter(x -> occursin("libjulia", x), dllist)[1]
                julia_libdir = repr(joinpath(dirname(libjulia), "julia"))
                envvar_name = @static if Sys.isapple()
                    "DYLD_LIBRARY_PATH"
                else Sys.islinux()
                    "LD_LIBRARY_PATH"
                end
                envvar_name = repr(envvar_name)

                println(depsjl_file, """
                    libpaths = split(get(ENV, $(envvar_name), ""), ":")
                    if !($(julia_libdir) in libpaths)
                        push!(libpaths, $(julia_libdir))
                    end
                    ENV[$(envvar_name)] = join(filter(!isempty, libpaths), ":")
                """)
            end
        end

        # Close the `check_deps()` function
        println(depsjl_file, "end")
    end
end
