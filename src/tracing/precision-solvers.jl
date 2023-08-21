function _find_offset_for_measure(
    measure,
    m::AbstractMetric,
    u,
    d::AbstractAccretionGeometry,
    θₒ;
    zero_atol = 1e-7,
    offset_max = 20.0,
    max_time = 2 * u[2],
    β₀ = 0,
    α₀ = 0,
    μ = 0,
    solver_opts...,
)
    function _velfunc(r::T) where {T}
        α = r * cos(θₒ) + T(α₀)
        β = r * sin(θₒ) + T(β₀)
        constrain_all(m, u, map_impact_parameters(m, u, α, β), μ)
    end

    # init a reusable integrator
    integ = _init_integrator(
        m,
        u,
        _velfunc(0.0),
        d,
        (0.0, max_time);
        save_on = false,
        solver_opts...,
    )

    function f(r)
        if r < 0
            return -1000 * r
        end
        gp = _solve_reinit!(integ, vcat(u, _velfunc(r)))
        measure(gp)
    end

    # use adaptive Order0 method : https://juliamath.github.io/Roots.jl/dev/reference/#Roots.Order0
    r0 = Roots.find_zero(f, offset_max / 2, Roots.Order0(); atol = zero_atol)

    gp0 = _solve_reinit!(integ, vcat(u, _velfunc(r0)))
    r0, gp0
end

"""
    find_offset_for_radius(
        m::AbstractMetric,
        u,
        d::AbstractAccretionDisc,
        radius,
        θₒ;
        zero_atol = 1e-7,
        offset_max = 20.0,
        kwargs...,
    )

Find the offset ``r_\\text{o}`` on the observer's image plane that gives impact parameters
```math
\\alpha = r_\\text{o} \\cos \\theta_\\text{o},
\\quad \\text{and} \\quad
\\beta = r_\\text{o} \\sin \\theta_\\text{o},
```
that trace a geodesic to intersect the disc geometry at an emission radius ``r_\\text{e}``.

Returns ``NaN`` if no offset exists. This may occur of the geometry is not present at this location
(though this more commonly gives a bracketing interval error), or if the emission radius is within 
the event horizon.
"""
function find_offset_for_radius(
    m::AbstractMetric,
    u,
    d::AbstractAccretionGeometry,
    rₑ,
    θₒ;
    kwargs...,
)
    function _measure(gp::GeodesicPoint{T}) where {T}
        r = if gp.status == StatusCodes.IntersectedWithGeometry
            _equatorial_project(gp.x)
        else
            zero(T)
        end
        rₑ - r
    end
    r0, gp0 = _find_offset_for_measure(_measure, m, u, d, θₒ; kwargs...)

    if (r0 < 0)
        @warn("Root finder found negative radius for rₑ = $rₑ, θₑ = $θₒ")
    end
    if !isapprox(_measure(gp0), 0.0, atol = 1e-4)
        @warn("Poor offset radius found for rₑ = $rₑ, θₑ = $θₒ")
        return NaN, gp0
    end
    r0, gp0
end
function find_offset_for_radius(
    m::AbstractMetric,
    u,
    d::AbstractThickAccretionDisc,
    rₑ,
    θₒ;
    kwargs...,
)
    plane = datumplane(d, rₑ)
    find_offset_for_radius(m, u, plane, rₑ, θₒ; kwargs...)
end

"""
    impact_parameters_for_radius!(
        αs::AbstractVector,
        βs::AbstractVector,
        m::AbstractMetric,
        u::AbstractVector{T},
        d::AbstractAccretionDisc,
        rₑ;
        kwargs...,
    )

Finds ``\\alpha`` and ``\\beta`` impact parameters which trace geodesics to a given emission radius
`rₑ` on the accretion disc.

This function assigns the values in-place to `αs` and `βs`.
The keyword arguments are forwarded to [`find_offset_for_radius`](@ref).

This function is threaded.
"""
function impact_parameters_for_radius!(
    αs::AbstractVector,
    βs::AbstractVector,
    m::AbstractMetric,
    u::AbstractVector{T},
    d::AbstractAccretionDisc,
    rₑ;
    β₀ = zero(T),
    α₀ = zero(T),
    kwargs...,
) where {T}
    if size(αs) != size(βs)
        throw(DimensionMismatch("α, β must have the same dimensions and size."))
    end
    θs = range(0, 2π, length(αs))
    @inbounds @threads for i in eachindex(θs)
        θ = θs[i]
        r, _ = find_offset_for_radius(m, u, d, rₑ, θ; α₀ = α₀, β₀ = β₀, kwargs...)
        αs[i] = r * cos(θ) + α₀
        βs[i] = r * sin(θ) + β₀
    end
    (αs, βs)
end

"""
    function impact_parameters_for_radius(
        m::AbstractMetric,
        u::AbstractVector{T},
        d::AbstractAccretionDisc,
        radius;
        N = 500,
        kwargs...,
    )

Pre-allocating version of [`impact_parameters_for_radius!`](@ref), which allocates
for `N` impact paramter pairs. Filters for `NaN` and returns `(αs, βs)`.
"""
function impact_parameters_for_radius(
    m::AbstractMetric,
    u::AbstractVector{T},
    d::AbstractAccretionDisc,
    radius;
    N = 500,
    kwargs...,
) where {T}
    α = zeros(T, N)
    β = zeros(T, N)
    impact_parameters_for_radius!(α, β, m, u, d, radius; kwargs...)
    α, β
end

function jacobian_∂αβ_∂gr(
    m,
    u,
    d,
    α,
    β,
    max_time;
    μ = 0.0,
    redshift_pf = ConstPointFunctions.redshift(m, u),
    solver_opts...,
)

    # these type hints are crucial for forward diff to be type stable
    function _jacobian_f(x::SVector{2,T})::SVector{2,T} where {T}
        # use underscores to avoid boxing
        _α, _β = x

        v = constrain_all(m, u, map_impact_parameters(m, u, _α, _β), μ)
        sol = tracegeodesics(m, u, v, d, (0.0, max_time); save_on = false, solver_opts...)
        gp = unpack_solution(sol)
        g = redshift_pf(m, gp, max_time)
        # return disc r and redshift g
        SVector(_equatorial_project(gp.x), g)
    end

    j = ForwardDiff.jacobian(_jacobian_f, SVector(α, β))
    abs(inv(det(j)))
end

function _make_target_objective(
    target::SVector,
    m::AbstractMetric,
    x0,
    args...;
    d_tol = 1e-2,
    max_time = 2x0[2],
    callback = nothing,
    μ = 0.0,
    solver_opts...,
)
    # convenience velocity function
    velfunc = (α, β) -> begin
        constrain_all(m, x0, map_impact_parameters(m, x0, α, β), μ)
    end

    # used to track how close the current solver got
    closest_approach = Ref(x0[2])
    # convert target to cartesian once
    target_cart = to_cartesian(target)
    distance_callback = ContinuousCallback(
        (u, λ, integrator) -> begin
            # get vector distance between current u and target
            k = target_cart - to_cartesian(u)
            distance = √sum(i -> i^2, k)
            # update best
            closest_approach[] = min(closest_approach[], distance)
            # if within d_tol, just immediately terminate
            distance - d_tol
        end,
        terminate!,
        interp_points = 8,
        save_positions = (false, false),
    )

    # init a reusable integrator
    integ = _init_integrator(
        m,
        x0,
        velfunc(0.0, 0.0),
        args...,
        (0.0, max_time);
        save_on = false,
        callback = merge_callbacks(callback, distance_callback),
        solver_opts...,
    )

    function _solver(α, β)
        v = velfunc(α, β)
        _solve_reinit!(integ, vcat(x0, v))
    end

    # map impact parameters to a closest approach 
    function _target_objective(impact_params)
        α = impact_params[1]
        β = impact_params[2]
        # reset the closest approach
        closest_approach[] = x0[2]
        _ = _solver(α, β)
        closest_approach[]
    end

    return _target_objective, _solver
end

function optimize_for_target(
    target::SVector,
    m::AbstractMetric,
    x0::SVector{4,T},
    args...;
    optimizer = NelderMead(),
    p0 = zeros(T, 2),
    kwargs...,
) where {T}
    f, solver = _make_target_objective(target, m, x0, args...; kwargs...)
    res = optimize(f, p0, optimizer)
    out = Optim.minimizer(res)
    # return α, β, accuracy
    α, β = out[1], out[2]
    accuracy = Optim.minimum(res)

    α, β, unpack_solution(solver(α, β)), accuracy
end

function impact_parameters_for_target(
    target::SVector,
    m::AbstractMetric,
    x0,
    args...;
    kwargs...,
)
    α, β, _, accuracy = optimize_for_target(target, m, x0, args...; kwargs...)
    α, β, accuracy
end

export find_offset_for_radius, impact_parameters_for_radius, impact_parameters_for_radius!
