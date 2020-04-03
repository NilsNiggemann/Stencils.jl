# Internal traits for sharing methods
struct All end
struct Read end
struct Write end

# Set up the rule data to loop over
maprule!(simdata::SimData, rule::Rule) = begin
    rkeys, rgrids = getdata(Read(), rule, simdata)
    wkeys, wgrids = getdata(Write(), rule, simdata)
    # Copy the source to dest for grids we are writing to,
    # if they need to be copied
    _maybeupdate_dest!(wgrids, rule)
    # Combine read and write grids to a temporary simdata object
    tempsimdata = @set simdata.data = combinedata(rkeys, rgrids, wkeys, wgrids)
    # Run the rule loop
    ruleloop(rule, tempsimdata, rkeys, rgrids, wkeys, wgrids)
    # Copy the source status to dest status for all write grids
    copystatus!(wgrids)
    # Swap the dest/source of grids that were written to
    wgrids = _to_readonly(swapsource(wgrids))
    # Combine the written grids with the original simdata
    replacedata(simdata, wkeys, wgrids)
end

_to_namedtuple(keys, data) = _to_namedtuple((keys,), (data,))
_to_namedtuple(keys::Tuple, data::Tuple) =
    NamedTuple{map(unwrap, keys),typeof(data)}(data)

_to_readonly(data::WritableGridData) = ReadableGridData(data)
_to_readonly(data::Tuple) = map(ReadableGridData, data)

_maybeupdate_dest!(d, rule::Rule) = d
_maybeupdate_dest!(d::Tuple, rule::PartialRule) =
    map(d -> maybeupdate_dest!(d, rule))
_maybeupdate_dest!(d::WritableGridData, rule::PartialRule) = begin
    @inbounds parent(dest(d)) .= parent(source(d))
    # Wrap overflow, or zero padding if not wrapped
    handleoverflow!(d)
end

# Separated out for both modularity and as a function barrier for type stability
ruleloop(rule::Rule, simdata, rkeys, rgrids, wkeys, wgrids) = begin
    nrows, ncols = gridsize(simdata)
    for j in 1:ncols, i in 1:nrows
        ismasked(mask(simdata), i, j) && continue
        readvals = readstate(rkeys, rgrids, i, j)
        writevals = applyrule(rule, simdata, readvals, (i, j))
        writetogrids!(wgrids, writevals, i, j)
    end
end
ruleloop(rule::PartialRule, simdata, rkeys, rgrids, wkeys, wgrids) = begin
    nrows, ncols = gridsize(data(simdata)[1])
    for j in 1:ncols, i in 1:nrows
        ismasked(mask(simdata), i, j) && continue
        read = readstate(rkeys, rgrids, i, j)
        applyrule!(rule, simdata, read, (i, j))
    end
end

@inline writetogrids!(data::Tuple, vals::NamedTuple, I...) =
    map(data, values(vals)) do d, v
        @inbounds d[I...] = v
    end
@inline writetogrids!(data::GridData, val, I...) =
    (@inbounds data[I...] = val)

#= Run the rule for all cells, writing the result to the dest array
The neighborhood is copied to the rules neighborhood buffer array for performance.
Empty blocks are skipped for NeighborhoodRules. =#
ruleloop(rule::Union{NeighborhoodRule,Chain{R,W,<:Tuple{<:NeighborhoodRule,Vararg}}},
         simdata, rkeys, rgrids, wkeys, wgrids) where {R,W} = begin
    r = radius(rule)
    griddata = simdata[neighborhoodkey(rule)]
    #= Blocks are cell smaller than the hood, because this works very nicely for
    #looking at only 4 blocks at a time. Larger blocks mean each neighborhood is more
    #likely to be active, smaller means handling more than 2 neighborhoods per block.
    It would be good to test if this is the sweet spot for performance,
    it probably isn't for game of life size grids. =#
    blocksize = 2r
    hoodsize = 2r + 1
    nrows, ncols = gridsize(griddata)
    # We unwrap offset arrays and work with the underlying array
    src, dst = parent(source(griddata)), parent(dest(griddata))
    srcstatus, dststatus = sourcestatus(griddata), deststatus(griddata)
    # curstatus and newstatus track active status for 4 local blocks
    newstatus = localstatus(griddata)
    # Initialise status for the dest. Is this needed?
    # deststatus(data) .= false
    # Get the preallocated neighborhood buffers
    bufs = buffers(griddata)
    # Center of the buffer for both axes
    bufcenter = r + 1

    # Wrap overflow or zero padding if not wrapped
    handleoverflow!(griddata)

    #= Run the rule row by row. When we move along a row by one cell, we access only
    a single new column of data the same hight of the nighborhood, and move the existing
    data in the neighborhood buffer array accross by one column. This saves on reads
    from the main array, and focusses reads and writes in the small buffer array that
    should be in fast local memory. =#


    # Loop down the block COLUMN
    for bi = 1:size(srcstatus, 1) - 1
        i = blocktoind(bi, blocksize)
        # Get current block
        rowsinblock = min(blocksize, nrows - blocksize * (bi - 1))
        skippedlastblock = true
        freshbuffer = true

        # Initialise block status for the start of the row
        bs11, bs12 = srcstatus[bi,     1], srcstatus[bi,     2]
        bs21, bs22 = srcstatus[bi + 1, 1], srcstatus[bi + 1, 2]
        newstatus .= false

        # Loop along the block ROW. This is faster because we are reading
        # 1 column from the main array for 2 blocks at each step, not actually along the row.
        for bj = 1:size(srcstatus, 2) - 1
            @inbounds newstatus[1, 1] = newstatus[1, 2]
            @inbounds newstatus[2, 1] = newstatus[2, 2]
            @inbounds newstatus[1, 2] = false
            @inbounds newstatus[2, 2] = false

            # Get current block status from the source status array
            bs11, bs21 = bs12, bs22
            @inbounds bs12, bs22 = srcstatus[bi, bj + 1], srcstatus[bi + 1, bj + 1]

            jstart = blocktoind(bj, blocksize)
            jstop = min(jstart + blocksize - 1, ncols)

            # Use this block unless it or its neighbors are active
            if !(bs11 | bs12 | bs21 | bs22)
                # Skip this block
                skippedlastblock = true
                # Run the rest of the chain if it exists
                # TODO: test this
                # if rule isa Chain && length(rule) > 1
                #     # Loop over the grid COLUMNS inside the block
                #     for j in jstart:jstop
                #         # Loop over the grid ROWS inside the block
                #         for b in 1:rowsinblock
                #             ii = i + b - 1
                #             ismasked(simdata, ii, j) && continue
                #             read = readstate(rkeys, rgrids, i, j)
                #             write = applyrule(tail(rule), griddata, read, (ii, j), buf)
                #             if wgrids isa Tuple
                #                 map(wgrids, write) do d, w
                #                     @inbounds dest(d)[i, j] = w
                #                 end
                #             else
                #                 @inbounds dest(wgrids)[i, j] = write
                #             end
                #         end
                #     end
                # end
                continue
            end

            # Reinitialise neighborhood buffers if we have skipped a section of the array
            if skippedlastblock
                for y = 1:hoodsize
                    for b in 1:rowsinblock
                        for x = 1:hoodsize
                            val = src[i + b + x - 2, jstart + y - 1]
                            bufs[b][x, y] = val
                        end
                    end
                end
                skippedlastblock = false
                freshbuffer = true
            end

            # Loop over the grid COLUMNS inside the block
            for j in jstart:jstop
                # Which block column are we in
                curblockj = j - jstart < r ? 1 : 2
                if freshbuffer
                    freshbuffer = false
                else
                    # Move the neighborhood buffers accross one column
                    for b in 1:rowsinblock
                        @inbounds buf = bufs[b]
                        # copyto! uses linear indexing, so 2d dims are transformed manually
                        @inbounds copyto!(buf, 1, buf, hoodsize + 1, (hoodsize - 1) * hoodsize)
                    end
                    # Copy a new column to each neighborhood buffer
                    for b in 1:rowsinblock
                        @inbounds buf = bufs[b]
                        for x in 1:hoodsize
                            @inbounds buf[x, hoodsize] = src[i + b + x - 2, j + 2r]
                        end
                    end
                end

                # Loop over the grid ROWS inside the block
                for b in 1:rowsinblock
                    I = i + b - 1, j
                    ismasked(simdata, I...) && continue
                    # Which block row are we in
                    curblocki = b <= r ? 1 : 2
                    # Run the rule using buffer b
                    @inbounds buf = bufs[b]
                    readval = readstate(keys2vals(readkeys(rule)), rgrids, I...)
                    #read = buf[bufcenter, bufcenter]
                    writeval = applyrule(rule, griddata, readval, I, buf)
                    writetogrids!(wgrids, writeval, I...)
                    # Update the status for the block
                    cellstatus = if writeval isa NamedTuple
                        @inbounds val = writeval[neighborhoodkey(rule)]
                        val != zero(val)
                    else
                        writeval != zero(writeval)
                    end
                    @inbounds newstatus[curblocki, curblockj] |= cellstatus
                end

                # Combine blocks with the previous rows / cols
                @inbounds dststatus[bi, bj] |= newstatus[1, 1]
                @inbounds dststatus[bi, bj+1] |= newstatus[1, 2]
                @inbounds dststatus[bi+1, bj] |= newstatus[2, 1]
                # Start new block fresh to remove old status
                @inbounds dststatus[bi+1, bj+1] = newstatus[2, 2]
            end
        end
    end
    copystatus!(griddata)
end


#= Wrap overflow where required. This optimisation allows us to ignore
bounds checks on neighborhoods and still use a wraparound grid. =#
handleoverflow!(griddata) = handleoverflow!(griddata, overflow(griddata))
handleoverflow!(griddata::GridData{T,2}, ::WrapOverflow) where T = begin
    r = radius(griddata)

    # TODO optimise this. Its mostly a placeholder so wrapping still works in GOL tests.
    src = source(griddata)
    nrows, ncols = gridsize(griddata)
    # Left
    @inbounds copyto!(src, CartesianIndices((1:nrows, 1-r:0)),
                      src, CartesianIndices((1:nrows, ncols+1-r:ncols)))
    # Right
    @inbounds copyto!(src, CartesianIndices((1:nrows, ncols+1:ncols+r)),
                      src, CartesianIndices((1:nrows, 1:r)))
    # Top
    @inbounds copyto!(src, CartesianIndices((1-r:0, 1:ncols)),
                      src, CartesianIndices((ncols+1-r:ncols, 1:ncols)))
    # Bottom
    @inbounds copyto!(src, CartesianIndices((ncols+1:ncols+r, 1:ncols)),
                      src, CartesianIndices((1:r, 1:ncols)))

    # Copy four corners
    @inbounds copyto!(src, CartesianIndices((1-r:0, 1-r:0)),
                      src, CartesianIndices((nrows+1-r:nrows, ncols+1-r:ncols)))
    @inbounds copyto!(src, CartesianIndices((1-r:0, ncols+1:ncols+r)),
                      src, CartesianIndices((nrows+1-r:nrows, 1:r)))
    @inbounds copyto!(src, CartesianIndices((nrows+1:nrows+r, ncols+1:ncols+r)),
                      src, CartesianIndices((1:r, 1:r)))
    @inbounds copyto!(src, CartesianIndices((nrows+1:nrows+r, 1-r:0)),
                      src, CartesianIndices((1:r, ncols+1-r:ncols)))

    # Wrap status
    status = sourcestatus(griddata)
    # status[:, 1] .|= status[:, end-1] .| status[:, end-2]
    # status[1, :] .|= status[end-1, :] .| status[end-2, :]
    # status[end-1, :] .|= status[1, :]
    # status[:, end-1] .|= status[:, 1]
    # status[end-2, :] .|= status[1, :]
    # status[:, end-2] .|= status[:, 1]
    # FIXME: Buggy currently, just running all in Wrap mode
    status .= true
end
handleoverflow!(griddata::WritableGridData, ::RemoveOverflow) = begin
    r = radius(griddata)
    # Zero edge padding, as it can be written to in writable rules.
    src = parent(source(griddata))
    nrows, ncols = size(src)
    for j = 1:r, i = 1:nrows
        src[i, j] = zero(eltype(src))
    end
    for j = ncols-r+1:ncols, i = 1:nrows
        src[i, j] = zero(eltype(src))
    end
    for j = 1:ncols, i = 1:r
        src[i, j] = zero(eltype(src))
    end
    for j = 1:ncols, i = nrows-r+1:nrows
        src[i, j] = zero(eltype(src))
    end
end


@inline readstate(keys::Tuple, data::Union{<:Tuple,<:NamedTuple}, I...) = begin
    vals = map(d -> readstate(keys, d, I...), data)
    NamedTuple{map(unwrap, keys),typeof(vals)}(vals)
end
@inline readstate(keys, data::GridData, I...) = data[I...]


# getdata retreives GridDatGridData to match the requirements of a Rule.

# Choose key source
getdata(context::All, simdata::AbstractSimData) =
    getdata(context, keys(simdata), keys(simdata), simdata)
getdata(context::Write, rule::Rule, simdata::AbstractSimData) =
    getdata(context, keys(simdata), writekeys(rule), simdata::AbstractSimData)
getdata(context::Read, rule::Rule, simdata::AbstractSimData) =
    getdata(context, keys(simdata), readkeys(rule), simdata)
@inline getdata(context, gridkeys, rulekeys, simdata::AbstractSimData) =
    getdata(context, keys2vals(rulekeys), simdata)
# When there is only one grid, use its key and ignore the rule key
# This can make scripting easier as you can safely ignore the keys
# for smaller models.
@inline getdata(context, gridkeys::Tuple{Symbol}, rulekeys::Tuple{Symbol}, simdata::AbstractSimData) =
    getdata(context, (Val(gridkeys[1]),), simdata)
@inline getdata(context, gridkeys::Tuple{Symbol}, rulekey::Symbol, simdata::AbstractSimData) =
    getdata(context, Val(gridkeys[1]), simdata)

# Iterate when keys are a tuple
@inline getdata(context, keys::Tuple{Val,Vararg}, simdata::AbstractSimData) = begin
    k, d = getdata(context, keys[1], simdata)
    ks, ds = getdata(context, tail(keys), simdata)
    (k, ks...), (d, ds...)
end
@inline getdata(context, keys::Tuple{}, simdata::AbstractSimData) = (), ()

# Choose data source
@inline getdata(::Write, key::Val{K}, simdata::AbstractSimData) where K =
    key, WritableGridData(simdata[K])
@inline getdata(::Union{Read,All}, key::Val{K}, simdata::AbstractSimData) where K =
    key, simdata[K]


combinedata(rkey, rgrids, wkey, wgrids) =
    combinedata((rkey,), (rgrids,), (wkey,), (wgrids,))
combinedata(rkey, rgrids, wkeys::Tuple, wgrids::Tuple) =
    combinedata((rkey,), (rgrids,), wkeys, wgrids)
combinedata(rkeys::Tuple, rgrids::Tuple, wkey, wgrids) =
    combinedata(rkeys, rgrids, (wkey,), (wgrids,))
@generated combinedata(rkeys::Tuple{Vararg{<:Val}}, rgrids::Tuple,
                       wkeys::Tuple{Vararg{<:Val}}, wgrids::Tuple) = begin
    rkeys = _vals2syms(rkeys)
    wkeys = _vals2syms(wkeys)
    keysexp = Expr(:tuple, QuoteNode.(wkeys)...)
    dataexp = Expr(:tuple, :(wgrids...))

    for (i, key) in enumerate(rkeys)
        if !(key in wkeys)
            push!(dataexp.args, :(rgrids[$i]))
            push!(keysexp.args, QuoteNode(key))
        end
    end

    quote
        NamedTuple{$keysexp}($dataexp)
    end
end

replacedata(simdata::AbstractSimData, wkeys, wgrids) =
    @set simdata.data = replacedata(data(simdata), wkeys, wgrids)
@generated replacedata(allgrids::NamedTuple, wkeys::Tuple, wgrids::Tuple) = begin
    writekeys = map(unwrap, wkeys.parameters)
    allkeys = allgrids.parameters[1]
    expr = Expr(:tuple)
    for key in allkeys
        if key in writekeys
            i = findfirst(k -> k == key, writekeys)
            push!(expr.args, :(wgrids[$i]))
        else
            push!(expr.args, :(allgrids.$key))
        end
    end
    quote
        vals = $expr
        NamedTuple{$allkeys,typeof(vals)}(vals)
    end
end
@generated replacedata(allgrids::NamedTuple, wkey::Val, wgrids::GridData) = begin
    writekey = unwrap(wkey)
    allkeys = allgrids.parameters[1]
    expr = Expr(:tuple)
    for key in allkeys
        if key == writekey
            push!(expr.args, :(wgrids))
        else
            push!(expr.args, :(allgrids.$key))
        end
    end
    quote
        vals = $expr
        NamedTuple{$allkeys,typeof(vals)}(vals)
    end
end

_vals2syms(x::Type{<:Tuple}) = map(v -> _vals2syms(v), x.parameters)
_vals2syms(::Type{<:Val{X}}) where X = X




#= Runs simulations over the block grid. Inactive blocks do not run.
This can lead to order of magnitude performance improvments in sparse
simulations where large areas of the grid are filled with zeros. =#
blockrun!(data::GridData, context, args...) = begin
    nrows, ncols = gridsize(data)
    r = radius(data)
    if r > 0
        blocksize = 2r
        status = sourcestatus(data)

        @inbounds for bj in 1:size(status, 2) - 1, bi in 1:size(status, 1) - 1
            status[bi, bj] || continue
            # Convert from padded block to init dimensions
            istart = blocktoind(bi, blocksize) - r
            jstart = blocktoind(bj, blocksize) - r
            # Stop at the init row/column size, not the padding or block multiple
            istop = min(istart + blocksize - 1, nrows)
            jstop = min(jstart + blocksize - 1, ncols)
            # Skip the padding
            istart = max(istart, 1)
            jstart = max(jstart, 1)

            for j in jstart:jstop, i in istart:istop
                celldo!(data, context, (i, j), args...)
            end
        end
    else
        for j in 1:ncols, i in 1:nrows
            celldo!(data, context, (i, j), args...)
        end
    end
end

# Run rule for particular cell. Applied to active cells inside blockrun!
@inline celldo!(data::GridData, rule::Rule, I) = begin
    @inbounds state = source(data)[I...]
    @inbounds dest(data)[I...] = applyrule(rule, data, state, I)
    nothing
end


# """
# Parital rules must copy the grid to dest as not all cells will be written.
# Block status is also updated.
# """
# maprule!(data::GridData, rule::PartialRule) = begin
#     data = WritableGridData(data)
#     # Update active blocks in the dest array
#     @inbounds parent(dest(data)) .= parent(source(data))
#     # Run the rule for active blocks
#     blockrun!(data, rule)
#     copystatus!(data)
# end

# @inline celldo!(data::WritableGridData, rule::PartialRule, I) = begin
#     state = source(data)[I...]
#     state == zero(state) && return
#     applyrule!(rule, data, state, I)
# end

# @inline celldo!(data::WritableGridData, rule::PartialNeighborhoodRule, I) = begin
#     state = source(data)[I...]
#     state == zero(state) && return
#     applyrule!(rule, data, state, I)
#     _zerooverflow!(data, overflow(data), radius(data))
# end
