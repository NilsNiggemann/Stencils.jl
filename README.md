# Stencils

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://rafaqz.github.io/Stencils.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://rafaqz.github.io/Stencils.jl/dev)
[![CI](https://github.com/rafaqz/Stencils.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/rafaqz/Stencils.jl/actions/workflows/ci.yml)
[![codecov.io](http://codecov.io/github/rafaqz/Stencils.jl/coverage.svg?branch=master)](http://codecov.io/github/rafaqz/Stencils.jl?branch=master)
[![Aqua.jl Quality Assurance](https://img.shields.io/badge/Aqua.jl-%F0%9F%8C%A2-aqua.svg)](https://github.com/JuliaTesting/Aqua.jl)

Stencils.jl streamlines working with stencils and neighborhoods - 
cellular automata, convolutions and filters, for neighborhoods of any 
(smallish) size and shape. 

Stencils.jl builds on StaticArrays.jl and KernelAbstractions.jl to provide high 
performance tools on CPUs and most GPUs, but keep a simple code base.


## What is a `Stencil` in Stencils.jl?

A `Stencil` is a StaticArrays.jl `StaticVector` of values cut from an array in the
specified shape, initially it is filled with `nothing`s. Stencils.jl provides methods to 
update stenctil values (by rebuilding) for any center index in an array, handling boundary conditions
by either padding or checking bounds.

Stencils.jl also provides functions to retreive the `offsets`, `indices`, `distances`
from the center pixel, and other information about the stencil. These are all compile time
operations, usable in fast inner loops or in GPU kernels. `@generated`
functions are used in most cases to guarantee compiling performant, type-stable
code for all arbitrary stencil shapes and sizes.

Stencils are defined with radius and number of dimensions: 
```julia
radius = 1
ndims = 2
julia> Moore(radius, ndims)
Moore{1, 2, 8, Nothing}
█▀█
▀▀▀
```

The third number - here `8` - is the calculated length of the Stencil. Note
that no matter what you use for `ndims`, the stencil is still `<: StaticVector`,
because the potential for missing positions mean we need to collapse the 
dimensions into one to keep things generic.

You can also define stencils using the type parameters directly:

```julia
julia> Circle{3,2}()
Circle{3, 2, 37, Nothing}
 ▄███▄ 
███████
▀█████▀
  ▀▀▀  
```

There are a lot of default stencils built-in, with customisable size and
dimensionality, for example:

```julia
# Most shapes look pretty similar in 1d (and they all look better in a terminal!)
julia> Moore(2, 1)
Moore{2, 1, 4, Nothing}
█
▄
▀

# 2D is the default
julia> Moore(1)
Moore{1, 2, 8, Nothing}
█▀█
▀▀▀

# Some shapes include the center
julia> Window(3)
Window{3, 2, 49, Nothing}
███████
███████
███████
▀▀▀▀▀▀▀

# This shape is 3d, we just cant easily show that...
julia> VonNeumann(2, 3)
VonNeumann{2, 3, 24, Nothing}
 ▄█▄ 
▀█▄█▀
  ▀  

# This is 4d
julia> Cross(3, 4)
Cross{3, 4, 25, Nothing}
   █   
▄▄▄█▄▄▄
   █   
   ▀   
```

But you can also make up arbitrary shapes:

```julia
julia> Positional((-1, 1), (-2, -1), (1, 0), (-2, 2))
Positional{((-1, 1), (-2, -1), (1, 0), (-2, 2)), 2, 2, 4, Nothing}
 ▀ ▄▀
  ▄  
```


## How can we use stencils?

Stencils.jl defines only direct methods, no FFTs. But it's very fast at 
mapping direct kernels over arrays. The `StencilArray` provides a wrapper
for these operations that will properly handle boundary conditions.

### Example: mean blur

_benchmarked on an 8-core thinkpad T14:_

```julia
using Stencils, Statistics, BenchmarkTools
# Define a random array
r = rand(1000, 1000)
# Use a square 3x3/radius 1 stencil
stencil = Window(1)
# Wrap them both as a StencilArray
A = StencilArray(r, stencil)
# Map `mean` over all stencils in the array. You can use any function here - 
# `identity` would return an array of `Window` stencils.
@benchmark mapstencil(mean, A)

BenchmarkTools.Trial: 1058 samples with 1 evaluation.
 Range (min … max):  2.755 ms … 9.693 ms  ┊ GC (min … max): 0.00% … 0.00%
 Time  (median):     5.373 ms             ┊ GC (median):    0.00%
 Time  (mean ± σ):   4.718 ms ± 1.326 ms  ┊ GC (mean ± σ):  2.92% ± 5.78%

    ▆▂                                   ▁█▅                 
  ▂▇██▄▁▂▂▁▂▂▄▅▂▂▁▂▁▁▁▂▁▁▁▂▂▁▂▂▂▂▂▂▂▂▂▅▄▂███▆▄▁▁▁▁▂▁▁▂▁▁▂▄▄ ▂
  2.75 ms        Histogram: frequency by time       6.82 ms <

 Memory estimate: 7.64 MiB, allocs estimate: 110.
```

_and on the Thinkpads tiny onboard Nvidia GeForce MX330:_

```julia
using CUDA, CUDAKernels
r = CuArray(rand(1000, 1000))
A = StencilArray(r, Window(1))
@benchmark mapstencil(mean, A)

BenchmarkTools.Trial: 3256 samples with 1 evaluation.
 Range (min … max):  916.833 μs …  10.147 ms  ┊ GC (min … max): 0.00% … 0.00%
 Time  (median):       1.414 ms               ┊ GC (median):    0.00%
 Time  (mean ± σ):     1.521 ms ± 553.722 μs  ┊ GC (mean ± σ):  0.51% ± 2.45%

      ▂█▂                                                        
  ▂▃▄▆██████████▇▆▆▅▄▃▃▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▁▂▂▂▂▂▁▁▂▂▂▂▂ ▃
  917 μs           Histogram: frequency by time         4.11 ms <

 Memory estimate: 4.06 KiB, allocs estimate: 74.
```

(That is less than a nanosecond per operation - reading each 3*3 stencil, calling `mean` on it, and writing the result)

Stencils can be used standalone, outside of `mapstencil`. For example
in iterative cost-distance models. Stencils provides a stencil `indices`
method to retreive array indices for the stencil, so you can use them to 
write values into an array for the stencil shape around your specified center index.

## Note

Expect occasional API breakages, Stencils.jl is being extracted from DynamicGrids.jl, 
and some coordination and changes may be required over 2023.
