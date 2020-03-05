# discovering binary CUDA dependencies

using Pkg, Pkg.Artifacts
using Libdl


## global state

const __dirs = Ref{Vector{String}}()
const __version = Ref{VersionNumber}()

const __libcublas = Ref{String}()
const __libcusparse = Ref{String}()
const __libcusolver = Ref{String}()
const __libcufft = Ref{String}()
const __libcurand = Ref{String}()
const __libcudnn = Ref{Union{Nothing,String}}(nothing)
const __libcutensor = Ref{Union{Nothing,String}}(nothing)


## discovery

# CUDA

# NOTE: we don't use autogenerated JLLs, because we have multiple artifacts and need to
#       decide at run time (i.e. not via package dependencies) which one to use.
const cuda_artifacts = Dict(
    v"10.2" => ()->artifact"CUDA10.2",
    v"10.1" => ()->artifact"CUDA10.1",
    v"10.0" => ()->artifact"CUDA10.0",
    v"9.2"  => ()->artifact"CUDA9.2",
    v"9.0"  => ()->artifact"CUDA9.0",
)

# utilities to look up stuff in the artifact (at known locations, so not using CUDAapi)
get_binary(artifact_dir, name) = joinpath(artifact_dir, "bin", Sys.iswindows() ? "$name.exe" : name)
function get_library(artifact_dir, name)
    filename = if Sys.iswindows()
        "$name.dll"
    elseif Sys.isapple()
        "lib$name.dylib"
    else
        "lib$name.so"
    end
    joinpath(artifact_dir, Sys.iswindows() ? "bin" : "lib", filename)
end

function use_artifact_cuda()
    @debug "Trying to use artifacts..."

    # select compatible artifacts
    if haskey(ENV, "JULIA_CUDA_VERSION")
        wanted_version = VersionNumber(ENV["JULIA_CUDA_VERSION"])
        filter!(((version,artifact),) -> version == wanted_version, cuda_artifacts)
    else
        driver_version = CUDAdrv.release()
        filter!(((version,artifact),) -> version <= driver_version, cuda_artifacts)
    end

    # download and install
    artifact = nothing
    for release in sort(collect(keys(cuda_artifacts)); rev=true)
        try
            artifact = (release=release, dir=cuda_artifacts[release]())
            break
        catch
        end
    end
    if artifact == nothing
        @debug "Could not find a compatible artifact."
        return false
    end
    __dirs[] = [artifact.dir]

    nvdisasm = get_binary(artifact.dir, "nvdisasm")
    @assert isfile(nvdisasm)
    __version[] = parse_toolkit_version(nvdisasm)

    # discover libraries
    for name in  ("cublas", "cusparse", "cusolver", "cufft", "curand")
        handle = getfield(CuArrays, Symbol("__lib$name"))

        # on Windows, the library name is version dependent
        if Sys.iswindows()
            name *= if artifact.release >= v"10.1"
                "64_$(artifact.release.major)"
            else
                "64_$(artifact.release.major)$(artifact.release.minor)"
            end
        end

        handle[] = get_library(artifact.dir, name)
        Libdl.dlopen(handle[])
    end

    @debug "Using CUDA $(__version[]) from an artifact at $(artifact.dir)"
    use_artifact_cudnn(artifact.release)
    use_artifact_cutensor(artifact.release)
    return true
end

function use_local_cuda()
    @debug "Trying to use local installation..."

    cuda_dirs = find_toolkit()
    __dirs[] = cuda_dirs

    tool = find_cuda_binary("nvdisasm")
    tool == nothing && error("Your CUDA installation does not provide the nvdisasm binary")
    cuda_version = parse_toolkit_version(tool)
    __version[] = cuda_version

    # discover libraries
    for name in  ("cublas", "cusparse", "cusolver", "cufft", "curand")
        handle = getfield(CuArrays, Symbol("__lib$name"))

        path = find_cuda_library(name, cuda_dirs, [cuda_version])
        if path !== nothing
            handle[] = path
        end
    end

    @debug "Found local CUDA $(cuda_version) at $(join(cuda_dirs, ", "))"
    use_local_cudnn(cuda_dirs)
    use_local_cutensor(cuda_dirs)
    return true
end

# CUDNN

const cudnn_artifacts = Dict(
    v"10.2" => ()->artifact"CUDNN+CUDA10.2",
    v"10.1" => ()->artifact"CUDNN+CUDA10.1",
    v"10.0" => ()->artifact"CUDNN+CUDA10.0",
    v"9.2"  => ()->artifact"CUDNN+CUDA9.2",
    v"9.0"  => ()->artifact"CUDNN+CUDA9.0",
)

function use_artifact_cudnn(release)
    artifact_dir = try
        cudnn_artifacts[release]()
    catch ex
        @debug "Could not use CUDNN from artifacts" exception=(ex, catch_backtrace())
        return false
    end

    __libcudnn[] = get_library(artifact_dir, Sys.iswindows() ? "cudnn64_7" : "cudnn")
    Libdl.dlopen(__libcudnn[])
    @debug "Using CUDNN from an artifact at $(artifact_dir)"
    return true
end

function use_local_cudnn(cuda_dirs)
    path = find_cuda_library("cudnn", cuda_dirs, [v"7"])
    path === nothing && return false

    __libcudnn[] = path
    @debug "Using local CUDNN at $(path)"
    return true
end

# CUTENSOR

const cutensor_artifacts = Dict(
    v"10.2" => ()->artifact"CUTENSOR+CUDA10.2",
    v"10.1" => ()->artifact"CUTENSOR+CUDA10.1",
)

function use_artifact_cutensor(release)
    artifact_dir = try
        cutensor_artifacts[release]()
    catch ex
        @debug "Could not use CUTENSOR from artifacts" exception=(ex, catch_backtrace())
        return false
    end

    __libcutensor[] = get_library(artifact_dir, "cutensor")
    Libdl.dlopen(__libcutensor[])
    @debug "Using CUTENSOR from an artifact at $(artifact_dir)"
    return true
end

function use_local_cutensor(cuda_dirs)
    path = find_cuda_library("cutensor", cuda_dirs, [v"1"])
    path === nothing && return false

    __libcutensor[] = path
    @debug "Using local CUTENSOR at $(path)"
    return true
end


## initialization

const __initialized__ = Ref{Union{Nothing,Bool}}(nothing)

"""
    functional(show_reason=false)

Check if the package has been initialized successfully and is ready to use.

This call is intended for packages that support conditionally using an available GPU. If you
fail to check whether CUDA is functional, actual use of functionality might warn and error.
"""
function functional(show_reason::Bool=false)
    if __initialized__[] === nothing
        __runtime_init__(show_reason)
    end
    __initialized__[]
end

function __runtime_init__(show_reason::Bool)
    __initialized__[] = false

    # if any dependent GPU package failed, expect it to have logged an error and bail out
    if !CUDAdrv.functional(show_reason) || !CUDAnative.functional(show_reason)
        show_reason && @warn "CuArrays.jl did not initialize because CUDAdrv.jl or CUDAnative.jl failed to"
        return
    end


    # CUDA toolkit

    if parse(Bool, get(ENV, "JULIA_CUDA_USE_BINARYBUILDER", "true"))
        __initialized__[] = use_artifact_cuda()
    end

    if !__initialized__[]
        __initialized__[] = use_local_cuda()
    end

    if !__initialized__[]
        show_reason && @error "Could not find a suitable CUDA installation"
        return
    end

    # library compatibility
    cuda = version()
    if has_cutensor()
        cutensor = CUTENSOR.version()
        if cutensor < v"1"
             @warn("CuArrays.jl only supports CUTENSOR 1.0 or higher")
        end

        cutensor_cuda = CUTENSOR.cuda_version()
        if cutensor_cuda.major != cuda.major || cutensor_cuda.minor != cuda.minor
            @warn("You are using CUTENSOR $cutensor for CUDA $cutensor_cuda with CUDA toolkit $cuda; these might be incompatible.")
        end
    end
    if has_cudnn()
        cudnn = CUDNN.version()
        if cudnn < v"7.6"
            @warn("CuArrays.jl only supports CUDNN v7.6 or higher")
        end

        cudnn_cuda = CUDNN.cuda_version()
        if cudnn_cuda.major != cuda.major || cudnn_cuda.minor != cuda.minor
            @warn("You are using CUDNN $cudnn for CUDA $cudnn_cuda with CUDA toolkit $cuda; these might be incompatible.")
        end
    end
end


## getters

macro initialized(ex)
    quote
        @assert functional(true) "CuArrays.jl is not functional"
        $(esc(ex))
    end
end

"""
    prefix()

Returns the installation prefix directories of the CUDA toolkit in use.
"""
prefix() = @initialized(__dirs[])

"""
    version()

Returns the version of the CUDA toolkit in use.
"""
version() = @initialized(__version[])

"""
    release()

Returns the CUDA release part of the version as returned by [`version`](@ref).
"""
release() = @initialized(VersionNumber(__version[].major, __version[].minor))

libcublas() = @initialized(__libcublas[])
libcusparse() = @initialized(__libcusparse[])
libcusolver() = @initialized(__libcusolver[])
libcufft() = @initialized(__libcufft[])
libcurand() = @initialized(__libcurand[])
libcudnn() = @initialized(__libcudnn[])
libcutensor() = @initialized(__libcutensor[])

export has_cudnn, has_cutensor
has_cudnn() = libcudnn() !== nothing
has_cutensor() = libcutensor() !== nothing
