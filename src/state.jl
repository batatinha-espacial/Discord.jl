mutable struct State
    v::Int                              # Discord API version.
    session_id::String                  # Gateway session ID.
    _trace::Vector{String}              # Guilds the user is in.
    user::Union{User, Nothing}          # Bot user.
    login_presence::Dict                # Bot user's presence upon connection.
    guilds::TTL{Snowflake, AbstractGuild}     # Guild ID -> guild.
    channels::TTL{Snowflake, DiscordChannel}  # Channel ID -> channel.
    users::TTL{Snowflake, User}               # User ID -> user.
    messages::TTL{Snowflake, Message}         # Message ID -> message.
    presences::Dict{Snowflake, TTL{Snowflake, Presence}}  # Guild ID -> user ID -> presence.
    members::Dict{Snowflake, TTL{Snowflake, Member}}      # Guild ID -> member ID -> member.
    errors::Vector{Union{Dict, AbstractEvent}}            # Values which caused errors.
    lock::Threads.AbstractLock    # Internal lock.
    ttls::TTLDict                 # TTLs for creating caches without a Client.
end

State(presence::NamedTuple, ttls::TTLDict) = State(Dict(pairs(presence)), ttls)
function State(presence::Dict, ttls::TTLDict)
    return State(
        0,                          # v
        "",                         # session_id
        [],                         # _trace
        nothing,                    # user
        presence,                   # login_presence
        TTL(ttls[Guild]),           # guilds
        TTL(ttls[DiscordChannel]),  # channels
        TTL(ttls[User]),            # users
        TTL(ttls[Message]),         # messages
        Dict(),                     # presences
        Dict(),                     # members
        [],                         # errors
        Threads.SpinLock(),         # lock
        ttls,                       # ttls
    )
end

TimeToLive.TTL(s::State, ::Type{T}) where T = TTL(get(s.ttls, T, nothing))

Base.get(s::State, ::Type; kwargs...) = nothing
Base.get(s::State, ::Type{User}; kwargs...) = get(s.users, kwargs[:user], nothing)
Base.get(s::State, ::Type{Message}; kwargs...) = get(s.messages, kwargs[:message], nothing)

function Base.get(s::State, ::Type{DiscordChannel}; kwargs...)
    return get(get(s.channels, kwargs[:guild], Dict()), kwargs[:channel], nothing)
end

function Base.get(s::State, ::Type{Vector{DiscordChannel}}; kwargs...)
    guild = kwargs[:guild]
    return haskey(s.guilds, guild) ? coalesce(s.guilds[guild].channels, nothing) : nothing
end

function Base.get(s::State, ::Type{Presence}; kwargs...)
    return get(get(s.presences, kwargs[:guild], Dict()), kwargs[:user], nothing)
end

function Base.get(s::State, ::Type{Guild}; kwargs...)
    # Guilds are stored with missing members and presences fields to save memory.
    haskey(s.guilds, kwargs[:guild]) || return nothing
    g = s.guilds[kwargs[:guild]]

    ms = get(s.members, g.id, Dict())
    g = @set g.members = map(
        i -> get(s, Member; guild=g.id, user=i),
        filter(i -> haskey(ms, i), collect(coalesce(g.djl_users, Member[]))),
    )
    ps = get(s.presences, g.id, Dict())
    g = @set g.presences = map(
        i -> get(s, Presence; guild=g.id, user=i),
        filter(i -> haskey(ps, i), collect(coalesce(g.djl_users, Presence[]))),
    )
    g = @set g.djl_users = missing

    return g
end

function Base.get(s::State, ::Type{Member}; kwargs...)
    # Members are stored with a missing user field to save memory.
    haskey(s.members, kwargs[:guild]) || return nothing
    guild = s.members[kwargs[:guild]]

    haskey(guild, kwargs[:user]) || return nothing
    member = guild[kwargs[:user]]

    haskey(s.users, kwargs[:user]) || return member  # With a missing user field.
    user = s.users[kwargs[:user]]

    return @set member.user = user
end

Base.put!(s::State, val; kwargs...) = nothing
Base.put!(s::State, g::UnavailableGuild; kwargs...) = insert_or_update!(s.guilds, g)

function Base.put!(s::State, m::Message; kwargs...)
    insert_or_update!(s.messages, m)
    touch(s.channels, m.channel_id)
    touch(s.guilds, m.guild_id)
end

function Base.put!(s::State, g::Guild; kwargs...)
    # Replace members and presences with IDs that can be looked up later.
    ms = coalesce(g.members, Member[])
    ps = coalesce(g.presences, Presence[])
    ids = map(m -> m.user.id, filter(m -> m.user !== nothing, ms))
    unique!(append!(ids, map(p -> p.user.id, ps)))
    g = @set g.members = missing
    g = @set g.presences = missing
    g = @set g.djl_users = Set(ids)

    insert_or_update!(s.guilds, g)

    put!(s, coalesce(g.channels, DiscordChannel[]); kwargs...)

    for m in ms
        put!(s, m; kwargs..., guild=g.id)
    end

    for p in ps
        put!(s, p; kwargs..., guild=g.id)
    end
end

function Base.put!(s::State, ms::Vector{Message}; kwargs...)
    for m in ms
        put!(s, m; kwargs...)
    end
end

function Base.put!(s::State, ch::DiscordChannel; kwargs...)
    insert_or_update!(s.channels, ch)

    for u in coalesce(ch.recipients, [])
        put!(s, u; kwargs...)
    end

    if haskey(s.guilds, ch.guild_id)
        g = s.guilds[ch.guild_id]
        g isa Guild || return
        if ismissing(g.channels)
            s.guilds[ch.guild_id] = @set g.channels = [ch]
        else
            insert_or_update!(g.channels, ch)
        end
    end
end

function Base.put!(s::State, chs::Vector{DiscordChannel}; kwargs...)
    for ch in chs
        put!(s, ch; kwargs...)
    end
end

function Base.put!(s::State, u::User; kwargs...)
    insert_or_update!(s.users, u)

    for ms in values(s.members)
        if haskey(ms, u.id)
            m = ms[u.id]
            m = @set m.user = merge(m.user, u)
            ms[u.id] = m
        end
    end
end

function Base.put!(s::State, p::Presence; kwargs...)
    guild = coalesce(get(kwargs, :guild, missing), p.guild_id)
    ismissing(guild) && return

    haskey(s.presences, guild) || (s.presences[guild] = TTL(s, Presence))
    insert_or_update!(s.presences[guild], p.user.id, p)

    if haskey(s.guilds, guild)
        g = s.guilds[guild]
        g isa Guild || return
        push!(g.djl_users, p.user.id)
   end
end

function Base.put!(s::State, m::Member; kwargs...)
    ismissing(m.user) && return
    guild = kwargs[:guild]

    # Members are stored with a missing user field to save memory.
    user = m.user
    m = @set m.user = missing

    haskey(s.members, guild) || (s.members[guild] = TTL(s, Member))
    ms = s.members[guild]
    insert_or_update!(ms, user.id, m)

    insert_or_update!(s.users, user)

    if haskey(s.guilds, guild)
        g = s.guilds[guild]
        g isa Guild || return
        push!(g.djl_users, user.id)
    end
end

function Base.put!(s::State, ms::Vector{Member}; kwargs...)
    for m in ms
        put!(s, m; kwargs...)
    end
end

function Base.put!(s::State, r::Role; kwargs...)
    guild = kwargs[:guild]
    haskey(s.guilds, guild) || return
    g = s.guilds[guild]
    g isa Guild || return

    if ismissing(g.roles)
        s.guilds[guild] = @set g.roles = [r]
    else
        insert_or_update!(g.roles, r)
    end
end

# This handles emojis being added to a guild.
function Base.put!(s::State, es::Vector{Emoji}; kwargs...)
    guild = kwargs[:guild]

    if haskey(s.guilds, guild)
        g = s.guilds[guild]
        g isa Guild || return
        g = @set g.emojis = es
        s.guilds[guild] = g
    end
end

# This handles a single emoji being added as a reaction.
function Base.put!(s::State, e::Emoji; kwargs...)
    message = kwargs[:message]
    user = kwargs[:user]
    haskey(s.messages, message) || return

    locked(s.lock) do
        m = s.messages[message]
        isclient = !ismissing(s.user) && s.user.id == user
        if ismissing(m.reactions)
            s.messages[message] = @set m.reactions = [Reaction(1, isclient, e)]
        else
            idx = findfirst(r -> r.emoji.name == e.name, m.reactions)
            if idx === nothing
                push!(m.reactions, Reaction(1, isclient, e))
            else
                r = m.reactions[idx]
                r = @set r.count += 1
                r = @set r.me = r.me | isclient  # TODO: |= (Setfield#55).
                r = @set r.emoji = merge(r.emoji, e)
                m.reactions[idx] = r
            end
        end
    end
end

insert_or_update!(d, k, v; kwargs...) = d[k] = haskey(d, k) ? merge(d[k], v) : v
function insert_or_update!(d::Vector, k, v; key::Function=x -> x.id)
    idx = findfirst(x -> key(x) == k, d)
    if idx === nothing
        push!(d, v)
    else
        d[idx] = merge(d[idx], v)
    end
end
function insert_or_update!(d, v; key::Function=x -> x.id)
    insert_or_update!(d, key(v), v; key=key)
end
