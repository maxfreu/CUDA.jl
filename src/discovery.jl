export find_library, find_binary,
       find_driver, find_toolkit, find_toolkit_version,
       find_host_compiler, find_toolchain


# names

const nvcc = "nvcc"

const libcuda = Compat.Sys.iswindows() ? "nvcuda" : "cuda"
const libcudart = if Compat.Sys.iswindows()
    tag = Sys.WORD_SIZE == 64 ? "64" : "32"
    map(ver->"cudart$(tag)_$(ver.major)$(ver.minor)", toolkits)
else
    "cudart"
end
const libcudnn = if Compat.Sys.iswindows()
    # cuDNN uses single version digit
    tag = Sys.WORD_SIZE == 64 ? "64" : "32"
    map(ver->"cudnn$(tag)_$(ver.major)", cudnns)
else
    "cudnn"
end
const libnvml = Compat.Sys.iswindows() ? "nvml" : "nvidia-ml"


# generic stuff

# TODO: make this work like find_library: always search everywhere, but prefix locations priority.
# especially for find_binary.

# wrapper for Libdl.find_library, looking for more names in more locations.
find_library(name::String, prefix::String) = find_library(name, [prefix])
function find_library(name::String, prefixes::Vector{String}=String[])
    @debug("Looking for $name library in $prefixes")

    # figure out names
    if Compat.Sys.iswindows()
        names = [name]
    else
        names = ["lib$name"]
    end

    find_library(names, prefixes)
end
find_library(names::Vector{String}, prefix::String) = find_library(names, [prefix])
function find_library(names::Vector{String}, prefixes::Vector{String}=String[])
    # figure out locations
    locations = []
    for prefix in prefixes
        push!(locations, prefix)
        push!(locations, joinpath(prefix, "lib"))
        if Sys.WORD_SIZE == 64
            push!(locations, joinpath(prefix, "lib64"))
        end
    end

    @trace("Checking for $names in $locations")
    name = Libdl.find_library(names, locations)
    if isempty(name)
        error("Could not find any of $names")
    end

    # find the full path of the library
    # NOTE: we could just as well use the result of `find_library,
    # but the user might have run this script with eg. LD_LIBRARY_PATH set
    # so we save the full path in order to always be able to load the correct library
    path = Libdl.dlpath(name)
    @debug("Using $name library at $path")
    return path
end

# similar to find_library, but for binaries.
# cfr. Libdl.find_library, looks for `name` in `prefix`, then PATH
find_binary(name, prefix::String) = find_binary(name, [prefix])
function find_binary(name, prefixes::Vector{String}=String[])
    @debug("Looking for $name binary in $prefixes")

    # figure out names
    if Compat.Sys.iswindows()
        name = "$name.exe"
    end

    # figure out locations
    locations = []
    for prefix in prefixes
        push!(locations, prefix)
        push!(locations, joinpath(prefix, "bin"))
    end
    let path = ENV["PATH"]
        dirs = split(path, Compat.Sys.iswindows() ? ';' : ':')
        filter!(path->!isempty(path), dirs)
        append!(locations, dirs)
    end

    @trace("Checking for $name in $locations")
    paths = [joinpath(location, name) for location in locations]
    try
        paths = filter(ispath, paths)
    end
    paths = unique(paths)
    if isempty(paths)
        error("Could not find $name binary")
    end

    path = first(paths)
    @debug("Using $name binary at $path")
    return path
end


# CUDA-specific

function find_driver()
    # figure out locations
    dirs = String[]
    ## look for the driver library (in the case LD_LIBRARY_PATH points to the installation)
    try
        libcuda_path = find_library(libcuda)
        dir = dirname(libcuda_path)
        if ismatch(r"^lib(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end
    ## look for the SMI binary (in the case PATH points to the installation)
    try
        nvidiasmi_path = find_binary("nvidia-smi")
        dir = dirname(nvidiasmi_path)
        if ismatch(r"^bin(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end

    # filter
    dirs = filter(isdir, unique(dirs))
    if length(dirs) > 1
        warn("Found multiple CUDA driver installations: ", join(dirs, ", ", " and "))
    elseif isempty(dirs)
        error("Could not find CUDA driver")
    end

    # select
    dir = first(dirs)
    @debug("Using CUDA driver at $dir")
    return dir
end

function find_toolkit()
    # figure out locations
    dirs = ["/usr/lib/nvidia-cuda-toolkit",
            "/usr/local/cuda",
            "/opt/cuda"]
    ## look for environment variables (taking priority over default values)
    envvars = ["CUDA_PATH", "CUDA_HOME", "CUDA_ROOT"]
    envvars_set = filter(var -> haskey(ENV, var), envvars)
    if length(envvars_set) > 0
        envvals = unique(map(var->ENV[var], envvars_set))
        if length(envvals) > 1
            warn("Multiple CUDA environment variables set to different values: $(join(envvars_set, ", ", " and "))")
        end
        @trace("Considering CUDA toolkit at $(envvals...) based on environment variables")
        unshift!(dirs, envvals...)
    end
    ## look for the compiler binary (in the case PATH points to the installation)
    try
        nvcc_path = find_binary(nvcc)
        dir = dirname(nvcc_path)
        if ismatch(r"^bin(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        @trace("Considering CUDA toolkit at $dir based on nvcc at $nvcc_path")
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end
    ## look for the runtime library (in the case LD_LIBRARY_PATH points to the installation)
    try
        libcudart_path = find_library(libcudart)
        dir = dirname(libcudart_path)
        if ismatch(r"^lib(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        @trace("Considering CUDA toolkit at $dir based on libcudart at $libcudart_path")
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end

    dirs = filter(isdir, unique(dirs))
    if length(dirs) > 1
        warn("Found multiple CUDA toolkit installations: ", join(dirs, ", ", " and "))
    elseif isempty(dirs)
        error("Could not find CUDA toolkit; specify using CUDA_(dir|HOME|ROOT) environment variable")
    end

    # select
    dir = first(dirs)
    @debug("Using CUDA toolkit at $dir")
    return dir
end

# figure out the CUDA toolkit version (by looking at the `nvcc --version` output)
function find_toolkit_version(toolkit_path)
    nvcc_path = find_binary(nvcc, toolkit_path)

    # parse the nvcc version string
    re = r"\bV(?<major>\d+).(?<minor>\d+).(?<patch>\d+)\b"
    m = match(re, read(`$nvcc_path --version`, String))
    m != nothing || error("Could not get version from nvcc")

    version = VersionNumber(parse(Int, m[:major]),
                            parse(Int, m[:minor]),
                            parse(Int, m[:patch]))
    @debug("CUDA toolkit at $toolkit_path identified as $version")
    return version
end

mutable struct Toolchain
    cuda_compiler::String
    cuda_version::VersionNumber

    host_compiler::String
    host_version::VersionNumber
end
function find_toolchain(toolkit_path, toolkit_version=find_toolkit_version(toolkit_path))
    # find the CUDA compiler
    nvcc_path = find_binary(nvcc, toolkit_path)
    nvcc_version = toolkit_version

    # find a suitable host compiler
    host_compiler, host_version = find_host_compiler(toolkit_version)

    return Toolchain(nvcc_path, nvcc_version,
                     host_compiler, host_version)
end

function find_host_compiler(toolkit_version=nothing)
    if !(Compat.Sys.iswindows() || Compat.Sys.isapple())
        # Unix-like platforms: find compatible GCC binary

        # find the maximally supported version of gcc
        gcc_range = if toolkit_version != nothing
            gcc_for_cuda(toolkit_version)
            @trace("CUDA $toolkit_version supports GCC $gcc_range")
        end

        # enumerate possible names for the gcc binary
        # NOTE: this is coarse, and might list invalid, non-existing versions
        gcc_names = [ "gcc" ]
        for major in 3:7
            push!(gcc_names, "gcc-$major")
            for minor in 0:9
                push!(gcc_names, "gcc-$major.$minor")
                push!(gcc_names, "gcc$major$minor")
            end
        end

        # find the binary
        gcc_possibilities = []
        for gcc_name in gcc_names
            # check if the binary exists
            gcc_path = try
                find_binary(gcc_name)
            catch ex
                isa(ex, ErrorException) || rethrow(ex)
                continue
            end

            # parse the GCC version string
            verstring = chomp(readlines(`$gcc_path --version`)[1])
            m = match(Regex("^$gcc_name \\(.*\\) ([0-9.]+)"), verstring)
            if m === nothing
                warn("Could not parse GCC version info (\"$verstring\"), skipping this compiler.")
                continue
            end
            gcc_ver = VersionNumber(m.captures[1])
            @trace("Found GCC $gcc_ver at $gcc_path")

            if toolkit_version == nothing || in(gcc_ver, gcc_range)
                push!(gcc_possibilities, (gcc_path, gcc_ver))
            end
        end

        # select the most recent compiler
        if length(gcc_possibilities) == 0
            error("Could not find a suitable host compiler (your CUDA v$toolkit_version needs GCC <= $(get(gcc_maxver))).")
        end
        sort!(gcc_possibilities; rev=true, lt=(a, b) -> a[2]<b[2])
        host_compiler, host_version = gcc_possibilities[1]
    elseif Compat.Sys.iswindows()
        # Windows: just use cl.exe
        # TODO: discovery of all compilers, and version matching against cuda_msvc_db
        vc_versions = ["VS140COMNTOOLS", "VS120COMNTOOLS", "VS110COMNTOOLS", "VS100COMNTOOLS"]
        !any(x -> haskey(ENV, x), vc_versions) && error("Compatible Visual Studio installation cannot be found; Visual Studio 2015, 2013, 2012, or 2010 is required.")
        vs_cmd_tools_dir = ENV[vc_versions[first(find(x -> haskey(ENV, x), vc_versions))]]
        msvc_path = joinpath(dirname(dirname(dirname(vs_cmd_tools_dir))), "VC", "bin", Sys.WORD_SIZE == 64 ? "amd64" : "", "cl.exe")
        tmpfile = tempname() # cl.exe writes version info to stderr, this is the only way I know of capturing it
        readstring(pipeline(`$msvc_path`,stderr=tmpfile))
        msvc_ver_str = match(r"Version\s+(\d+(\.\d+)?(\.\d+)?)"i, readstring(tmpfile))[1]
        msvc_ver = VersionNumber(msvc_ver_str)

        host_compiler, host_version = msvc_path, msvc_ver
    elseif Compat.Sys.isapple()
        # GCC is no longer supported on MacOS so let's just use clang
        # TODO: discovery of all compilers, and version matching against the toolkit
        clang_path = find_binary("clang")
        clang_ver_str = match(r"version\s+(\d+(\.\d+)?(\.\d+)?)"i, readstring(`$clang_path --version`))[1]
        clang_ver = VersionNumber(clang_ver_str)

        host_compiler, host_version = clang_path, clang_ver
    end
    @debug("Selected host compiler version $host_version at $host_compiler")

    return host_compiler, host_version
end
