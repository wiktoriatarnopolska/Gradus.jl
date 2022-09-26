"""
    tracegeodesics(
        m::AbstractMetricParams{T},
        position,
        velocity,
        time_domain::Tuple{T,T};
        solver = Tsit5(),
        μ = 0.0,
        closest_approach = 1.01,
        effective_infinity = 1200.0,
        callback = nothing,
        solver_opts...,
    )

Integrate a geodesic for metric parameterised by `m`, for some initial positions and velocities.
The positions and velocities may be

  - a single position and velocity in the form of a vector of numbers,
  - a collection of positions and velocities, as either a vector of vectors, or as a matrix,
  - a single position and a function with signature ``vel_func(i)`` which returns a four-velocity.

The matrix specification reads each corresponding column as the initial position and velocity. When a collection of
positions and velocities is supplied, this method dispatched `EnsembleProblem`, offering `ensemble` as a `solver_opts`,
specifying the ensemble method to use.

`solver_opts` are the common solver options in DifferentialEquations.
"""
function tracegeodesics(
    m::AbstractMetricParams{T},
    position,
    velocity,
    time_domain::Tuple{T,T};
    solver = Tsit5(),
    μ = 0.0,
    closest_approach = 1.01,
    effective_infinity = 1200.0,
    callback = nothing,
    solver_opts...,
) where {T}
    _velocity = if (velocity isa Function) && (eltype(position) === T)
        wrap_constraint(m, position, velocity, μ)
    else
        if eltype(position) !== eltype(velocity)
            error("Position and velocity must have the same element type.")
        end
        constrain_all(m, position, velocity, μ)
    end

    cbs = create_callback_set(m, callback, closest_approach, effective_infinity)

    __tracegeodesics(
        m,
        position,
        _velocity,
        time_domain,
        solver;
        callback = cbs,
        abstol = 1e-9,
        reltol = 1e-9,
        solver_opts...,
    )
end

function integrator_problem(
    m::AbstractMetricParams{T},
    pos::StaticVector{S,T},
    vel::StaticVector{S,T},
    time_domain,
) where {S,T}
    u_init = vcat(pos, vel)
    ODEProblem{false}(u_init, time_domain) do u, p, λ
        @inbounds let x = @view(u[1:4]), v = @view(u[5:8])
            dv = SVector{4}(geodesic_eq(m, x, v))
            SVector{8}(v[1], v[2], v[3], v[4], dv[1], dv[2], dv[3], dv[4])
        end
    end
end

function integrator_problem(
    m::AbstractMetricParams{T},
    pos::AbstractVector{T},
    vel::AbstractVector{T},
    time_domain,
) where {T}
    u_init = vcat(pos, vel)
    ODEProblem{true}(u_init, time_domain) do du, u, p, λ
        @inbounds let x = @view(u[1:4]), v = @view(u[5:8])
            dv = SVector{4}(geodesic_eq(m, x, v))

            du[1:4] = v
            du[5:8] = dv
        end
    end
end

# single position and single velocity
function __tracegeodesics(
    m::AbstractMetricParams{T},
    init_pos::AbstractVector{T},
    init_vel::AbstractVector{T},
    time_domain::Tuple{T,T},
    solver;
    kwargs...,
) where {T<:Number}
    prob = integrator_problem(m, init_pos, init_vel, time_domain)
    solve_geodesic(solver, prob; kwargs...)
end

# single position and single velocity
# ensembled with an indexable function
function __tracegeodesics(
    m::AbstractMetricParams{T},
    init_pos::AbstractVector{T},
    vel_func::Function,
    time_domain::Tuple{T,T},
    solver;
    trajectories::Int,
    ensemble = EnsembleThreads(),
    kwargs...,
) where {T<:Number}
    prob = integrator_problem(m, init_pos, vel_func(1), time_domain)
    ens_prob = EnsembleProblem(
        prob,
        prob_func = (prob, i, repeat) ->
            integrator_problem(m, init_pos, vel_func(i), time_domain),
        safetycopy = false,
    )
    solve_geodesic(solver, ens_prob, ensemble; trajectories = trajectories, kwargs...)
end

# indexables
function __tracegeodesics(
    m::AbstractMetricParams{T},
    init_positions,
    init_velocities,
    time_domain::Tuple{T,T},
    solver;
    ensemble = EnsembleThreads(),
    kwargs...,
) where {T}
    prob = integrator_problem(m, init_positions[1], init_velocities[1], time_domain)
    ens_prob = EnsembleProblem(
        prob,
        prob_func = (prob, i, repeat) ->
            integrator_problem(m, init_positions[i], init_velocities[i], time_domain),
        safetycopy = false,
    )

    solve_geodesic(
        solver,
        ens_prob,
        ensemble;
        trajectories = length(init_velocities),
        kwargs...,
    )
end

function solve_geodesic(solver, prob, ensemble; solver_opts...)
    solve(prob, solver, ensemble; solver_opts..., kwargshandle = KeywordArgError)
end

function solve_geodesic(solver, prob; solver_opts...)
    solve(prob, solver, ; solver_opts..., kwargshandle = KeywordArgError)
end

export tracegeodesics