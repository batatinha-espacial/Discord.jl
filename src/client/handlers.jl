# An event handler.
abstract type AbstractHandler{T<:AbstractEvent} end

# Default handler and predicate functions.
donothing(args...; kwargs...) = nothing
alwaystrue(args...; kwargs...) = true

# The event type that a handler accepts.
Base.eltype(::AbstractHandler{T}) where T = T

# Put and take a handler's results.
Base.put!(::AbstractHandler, ::Vector) = nothing
Base.take!(::AbstractHandler) = []

# handler, predicate, and expiry.
func(::AbstractHandler) = donothing
pred(::AbstractHandler) = alwaystrue
expiry(::AbstractHandler) = nothing

# Update the handler's expiry.
dec!(::AbstractHandler) = nothing

# Check expiry and collection status.
isexpired(::AbstractHandler) = false
iscollecting(::AbstractHandler) = false

# Collect the handler's results.
results(::AbstractHandler) = []

# A generic event handler.
mutable struct Handler{T} <: AbstractHandler{T}
    func::Function
    pred::Function
    remaining::Union{Int, Nothing}
    expiry::Union{DateTime, Nothing}
    collect::Bool
    results::Vector{Any}
    chan::Channel{Vector{Any}}

    function Handler{T}(
        func::Function,
        pred::Function,
        remaining::Union{Int, Nothing},
        expiry::Union{DateTime, Nothing},
        collect::Bool,
    ) where T <: AbstractEvent
        return new{T}(func, pred, remaining, expiry, collect, [], Channel{Vector{Any}}(1))
    end
    function Handler{T}(
        func::Function,
        pred::Function,
        remaining::Union{Int, Nothing},
        expiry::Period,
        collect::Bool,
    ) where T <: AbstractEvent
        return new{T}(
            func,
            pred,
            remaining,
            now() + expiry,
            collect,
            [],
            Channel{Vector{Any}}(1),
        )
    end
end

func(h::Handler) = h.func
pred(h::Handler) = h.pred
expiry(h::Handler) = h.expiry
dec!(h::Handler) = h.remaining isa Int && (h.remaining -= 1)
iscollecting(h::Handler) = h.collect
results(h::Handler) = h.results
Base.put!(h::Handler, v::Vector) = put!(h.chan, v)

function isexpired(h::Handler)
    return if h.remaining isa Int && h.remaining <= 0
        true
    elseif h.expiry isa DateTime && now() > h.expiry
        true
    else
        false
    end
end

function Base.take!(h::Handler)
    iscollecting(h) || return []

    # Only wait for one condition.
    while true
        h.remaining === nothing || h.remaining > 0 || break
        h.expiry === nothing || h.expiry > now() || break
        sleep(Millisecond(100))
    end

    # Expired handlers don't always get cleaned up immediately.
    isready(h.chan) ? take!(h.chan) : results(h)
end