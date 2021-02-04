"""
    applyrule(data::SimData, rule::Rule{R,W}, state, index::Tuple{Int,Int}) -> cell value(s)

Apply a rule to the cell state and return values to write to the grid(s).

This is called in `maprule!` methods during the simulation,
not by the user. Custom `Rule` implementations must define this method.

### Arguments:
- `data` : [`SimData`](@ref)
- `rule` : [`Rule`](@ref)
- `state`: the value(s) of the current cell
- `index`: a (row, column) tuple of Int for the current cell coordinates

Returns the value(s) to be written to the current cell(s) of
the grids specified by the `W` type parameter.
"""
function applyrule end

"""
    applyrule!(data::SimData, rule::{R,W}, state, index::Tuple{Int,Int}) -> Nothing

Apply a rule to the cell state and manually write to the grid data array.
Used in all rules inheriting from [`SetCellRule`](@ref).

This is called in internal `maprule!` methods during the simulation, not by
the user. Custom [`SetCellRule`](@ref) implementations must define this method.

Only grids specified with the `W` type parameter will be writable from `data`.

### Arguments:
- `data` : [`SimData`](@ref)
- `rule` : [`Rule`](@ref)
- `state`: the value(s) of the current cell
- `index`: a (row, column) tuple of Int for the current cell coordinates - `t`: the current time step
"""
function applyrule! end

"""
    precalcrule(rule::Rule, data::SimData) -> Rule

Precalculates rule fields at each timestep. Define this method if a [`Rule`](@ref)
has fields that need to be updated over time.

`Rule`s are usually immutable (it's faster), so precalc is expected to returns a
new rule object with changes applied to it.  Setfield.jl or Acessors.jl may help
with updating the immutable struct.

The default behaviour is to return the existing rule without change.

Updated rules are be discarded, and the `rule` argument is always be the
original object passed in.
"""
function precalcrule end

"""
    neighbors(x::Union{Neighborhood,NeighborhoodRule}}) -> iterable

Returns an iteraterable generator over all cells in the neighborhood.

Custom `Neighborhood`s must define this method.
"""
function neighbors end

"""
    offsets(x::Union{Neighborhood,NeighborhoodRule}}) -> iterable

Returns an iteraterable over all cells as a `Tuple` of the index 
offset from the central cell.

Custom `Neighborhood`s must define this method.
"""
function offsets end

"""
    positions(x::Union{Neighborhood,NeighborhoodRule}}, cellindex::Tuple) -> iterable

Returns an iteraterable over all cells as a `Tuple` of the index 
in the main array. Useful in [`SetNeighborhoodRule`](@ref) for 
setting neighborhood values.
"""
function positions end

"""
    add!(data::WritableGridData, x, I...)

Add the value `x` to a grid cell.

## Example useage

```julia
function applyrule!(data::SimData, rule::My{A,B}, state, cellindex) where {A,B}

    dest, is_inbounds = inbounds(jump .+ cellindex, gridsize(data))

    # Update spotted cell if it's on the grid
    is_inbounds && add!(data[W], state, dest...)
end
```
"""
function add! end

"""
    sub!(data::WritableGridData, x, I...)

Subtract the value `x` from a grid cell. See `add!` for example usage.
"""
function sub! end

"""
    min!(data::WritableGridData, x, I...)

Set a gride cell to the minimum of `x` and the current value. See `add!` for example usage.
"""
function min! end

"""
    max!(data::WritableGridData, x, I...)

Set a gride cell to the maximum of `x` and the current value. See `add!` for example usage.
"""
function max! end

"""
    and!(data::WritableGridData, x, I...)
    and!(A::AbstractArray, x, I...)

Set the grid cell `c` to `c & x`. See `add!` for example usage.
"""
function and! end

"""
    or!(data::WritableGridData, x, I...)
    or!(A::AbstractArray, x, I...)

Set the grid cell `c` to `c | x`. See `add!` for example usage.
"""
function or! end

"""
    xor!(data::WritableGridData, x, I...)
    xor!(A::AbstractArray, x, I...)

Set the grid cell `c` to `xor(c, x)`. See `add!` for example usage.
"""
function xor! end

"""
    inbounds(I::Tuple, data::SimData) -> Tuple{NTuple{2,Int},Bool}

Check grid boundaries for a coordinate before writing in [`SetCellRule`](@ref).

Returns a `Tuple` containing a coordinates `Tuple` and a `Bool` - `true`
if the cell is in bounds, `false` if not.

[`BoundaryCondition`](@ref) of type [`Remove`](@ref) returns the coordinate and `false` 
to skip coordinates that boundary outside of the grid.

[`Wrap`](@ref) returns a tuple with the current position or it's
wrapped equivalent, and `true` as it is allways in-bounds.
"""
function inbounds end

"""
    isinbounds(I::Tuple, data) -> Bool

Check that a coordinate is within the grid, usually in [`SetCellRule`](@ref).

Unlike [`inbounds`](@ref), [`BoundaryCondition`](@ref) status is ignored.
"""
function isinbounds end

"""
    radius(rule, [key]) -> Int

Return the radius of a rule or ruleset if it has one, otherwise zero.
"""
function radius end

"""
    init(obj) -> Union{AbstractArray,NamedTUple}

Retrieve the mask from an [`Output`](@ref), [`Extent`](@ref) or [`SimData`](@ref) object.
"""
function init end

"""
    mask(obj) -> AbstractArray

Retrieve the mask from an [`Output`](@ref), [`Extent`](@ref) or [`SimData`](@ref) object.
"""
function mask end

"""
    aux(obj, [key])

Retrieve auxilary data `NamedTuple` from an [`Output`](@ref),
[`Extent`](@ref) or [`SimData`](@ref) object.

Given `key` specific data will be returned. `key` should be a
`Val{:symbol}` for type stability and zero-cost access inside rules.
`Symbol` will also work, but may be slow.
"""
function aux end

"""
    tspan(obj) -> AbstractRange

Retrieve the time-span `AbstractRange` from an [`Output`](@ref),
[`Extent`](@ref) or [`SimData`](@ref) object.
"""
function tspan end

"""
    timestep(obj)

Retrieve the timestep size from an [`Output`](@ref),
[`Extent`](@ref), [`Ruleset`](@ref) or [`SimData`](@ref) object.

This will be in whatever type/units you specify in `tspan`.
"""
function timestep end

"""
    currentframe(simdata::SimData) -> Int

Retrieve the current simulation frame a [`SimData`](@ref) object.
"""
function currentframe end

"""
    currenttime(simdata::SimData)

Retrieve the current simulation time from a [`SimData`](@ref) object.

This will be in whatever type/units you specify in `tspan`.
"""
function currenttime end

"""
    currenttimestep(simdata::SimData)

Retrieve the current timestep from a [`SimData`](@ref) object.

This may be different from the `timestep`. If the timestep is `Month`,
`currenttimestep` will return `Seconds` for the length of the specific month.
"""
function currenttimestep end

