using QuantEcon: tauchen, MarkovChain, simulate


# ------------------------------------------------------------------- #
# Define the main Arellano Economy type
# ------------------------------------------------------------------- #

"""

I used QuantEcon to aid in the following replication. The base program is called Arellano economy (credited to Quant-econ.net).
The below is a replication of part of Hatchondo and Martinez (2009).
I replicate using only 1-quarter duration bonds.
There are a couple minor changes to the government default cost and government access to the market after default based on the Arellano model.

##### Fields
`β::Real`: Time discounting parameter
`γ::Real`: Risk aversion parameter
`r::Real`: World interest rate
`ρ::Real`: Autoregressive coefficient on income process
`η::Real`: Standard deviation of noise in income process
`θ::Real`: Probability of re-entering the world financial sector after default
`ny::Int`: Number of points to use in approximation of income process
`nB::Int`: Number of points to use in approximation of asset holdings
`ygrid::Vector{Float64}`: This is the grid used to approximate income process
`ydefgrid::Vector{Float64}`: When in default get less income than process
  would otherwise dictate
`Bgrid::Vector{Float64}`: This is grid used to approximate choices of asset
  holdings
`Π::Array{Float64, 2}`: Transition probabilities between income levels
`vf::Array{Float64, 2}`: Place to hold value function
`vd::Array{Float64, 2}`: Place to hold value function when in default
`vc::Array{Float64, 2}`: Place to hold value function when choosing to
  continue
`policy::Array{Float64, 2}`: Place to hold asset policy function
`q::Array{Float64, 2}`: Place to hold prices at different pairs of (y, B')
`defprob::Array{Float64, 2}`: Place to hold the default probabilities for
  pairs of (y, B')
"""

immutable ArellanoEconomy
    # Model Parameters
    β::Float64
    γ::Float64
    r::Float64
    ρ::Float64
    η::Float64
    θ::Float64


    # Grid Parameters
    ny::Int
    nB::Int
    ygrid::Array{Float64, 1}
    ydefgrid::Array{Float64, 1}
    Bgrid::Array{Float64, 1}
    Π::Array{Float64, 2}

    # Value function
    vf::Array{Float64, 2}
    vd::Array{Float64, 2}
    vc::Array{Float64, 2}
    policy::Array{Float64, 2}
    q::Array{Float64, 2}
    defprob::Array{Float64, 2}
end


"""
This is the default constructor for building an economy as presented
in Arellano 2008.
##### Arguments
`;β::Real(0.953)`: Time discounting parameter --> 0.95
`;γ::Real(2.0)`: Risk aversion parameter --> 2 (same)
`;r::Real(0.017)`: World interest rate --> 0.01
`;ρ::Real(0.945)`: Autoregressive coefficient on income process --> 0.9
`;η::Real(0.025)`: Standard deviation of noise in income process --> 0.027
`;θ::Real(0.282)`: Probability of re-entering the world financial sector
after default --> 1
`;mu::Real(-0.00003645)`: mean log output (-0.5*η^2)
`;ny::Int(21)`: Number of points to use in approximation of income process
`;nB::Int(251)`: Number of points to use in approximation of asset holdings
"""


function ArellanoEconomy(;β=.95, γ=2., r=0.01, ρ=0.9, η=0.027, θ=1,
                          ny=21, nB=251)

    # Create grids
    Bgrid = collect(linspace(-.4, .4, nB))
    mc = tauchen(ny, ρ, η)
    Π = mc.p
    ygrid = exp(mc.state_values) + exp(-0.00003645)
    ydefgrid = min(.969 * mean(ygrid), ygrid)

    # Define value functions (Notice ordered different than Python to take
    # advantage of column major layout of Julia)
    vf = zeros(nB, ny)
    vd = zeros(1, ny)
    vc = zeros(nB, ny)
    policy = Array(Int, nB, ny)
    q = ones(nB, ny) .* (1 / (1 + r))
    defprob = Array(Float64, nB, ny)

    return ArellanoEconomy(β, γ, r, ρ, η, θ, ny, nB, ygrid, ydefgrid, Bgrid, Π,
                            vf, vd, vc, policy, q, defprob)
end

u(ae::ArellanoEconomy, c) = c^(1 - ae.γ) / (1 - ae.γ)
_unpack(ae::ArellanoEconomy) =
    ae.β, ae.γ, ae.r, ae.ρ, ae.η, ae.θ, ae.ny, ae.nB
_unpackgrids(ae::ArellanoEconomy) =
    ae.ygrid, ae.ydefgrid, ae.Bgrid, ae.Π, ae.vf, ae.vd, ae.vc, ae.policy, ae.q, ae.defprob


# ------------------------------------------------------------------- #
# Write the value function iteration
# ------------------------------------------------------------------- #
"""
This function performs the one step update of the value function for the
Arellano model-- Using current value functions and their expected value,
it updates the value function at every state by solving for the optimal
choice of savings
##### Arguments
`ae::ArellanoEconomy`: This is the economy we would like to update the
  value functions for
`EV::Matrix{Float64}`: Expected value function at each state
`EVd::Matrix{Float64}`: Expected value function of default at each state
`EVc::Matrix{Float64}`: Expected value function of continuing at each state
##### Notes
This function updates value functions and policy functions in place.
"""



function one_step_update!(ae::ArellanoEconomy, EV::Matrix{Float64},
                          EVd::Matrix{Float64}, EVc::Matrix{Float64})


# Unpack stuff
β, γ, r, ρ, η, θ, ny, nB = _unpack(ae)
ygrid, ydefgrid, Bgrid, Π, vf, vd, vc, policy, q, defprob = _unpackgrids(ae)
zero_ind = searchsortedfirst(Bgrid, 0.)

for iy=1:ny
    y = ae.ygrid[iy]
    ydef = ae.ydefgrid[iy]

    # Value of being in default with income y
    defval = u(ae, ydef) + β*(θ*EVc[zero_ind, iy] + (1-θ)*EVd[1, iy])
    ae.vd[1, iy] = defval

    for ib=1:nB
        B = ae.Bgrid[ib]
        current_max = -1e14
        pol_ind = 0
        for ib_next=1:nB
            c = max(y - ae.q[ib_next, iy]*Bgrid[ib_next] + B, 1e-14)
            m = u(ae, c) + β * EV[ib_next, iy]

            if m > current_max
                current_max = m
                pol_ind = ib_next
            end
        end

        # Update value and policy functions
        ae.vc[ib, iy] = current_max
        ae.policy[ib, iy] = pol_ind
        ae.vf[ib, iy] = defval > current_max ? defval: current_max
    end
end

Void
end


"""
This function takes the Arellano economy and its value functions and
policy functions and then updates the prices for each (y, B') pair
##### Arguments
`ae::ArellanoEconomy`: This is the economy we would like to update the
  prices for
##### Notes
This function updates the prices and default probabilities in place
"""


function compute_prices!(ae::ArellanoEconomy)
    # Unpack parameters
    β, γ, r, ρ, η, θ, ny, nB = _unpack(ae)

    # Create default values with a matching size
    vd_compat = repmat(ae.vd, nB)
    default_states = vd_compat .> ae.vc

    # Update default probabilities and prices
    copy!(ae.defprob, default_states * ae.Π')
    copy!(ae.q, (1 - ae.defprob) / (1 + r))

    Void
end


"""
This performs value function iteration and stores all of the data inside
the ArellanoEconomy type.
##### Arguments
`ae::ArellanoEconomy`: This is the economy we would like to solve
`;tol::Float64(1e-8)`: Level of tolerance we would like to achieve
`;maxit::Int(10000)`: Maximum number of iterations
##### Notes
This updates all value functions, policy functions, and prices in place.
"""

function vfi!(ae::ArellanoEconomy; tol=1e-8, maxit=10000)

    # Unpack stuff
    β, γ, r, ρ, η, θ, ny, nB = _unpack(ae)
    ygrid, ydefgrid, Bgrid, Π, vf, vd, vc, policy, q, defprob = _unpackgrids(ae)
    Πt = Π'

    # Iteration stuff
    it = 0
    dist = 10.

    # Allocate memory for update
    V_upd = zeros(ae.vf)

    while dist > tol && it < maxit
        it += 1

        # Compute expectations for this iterations
        # (We need Π' because of order value function dimensions)
        copy!(V_upd, ae.vf)
        EV = ae.vf * Πt
        EVd = ae.vd * Πt
        EVc = ae.vc * Πt

        # Update Value Function
        one_step_update!(ae, EV, EVd, EVc)

        # Update prices
        compute_prices!(ae)

        dist = max(V_upd - ae.vf)

        if it%25 == 0
            println("Finished iteration $(it) with dist of $(dist)")
        end
    end

    Void
end


"""
This function simulates the Arellano economy
##### Arguments
`ae::ArellanoEconomy`: This is the economy we would like to solve
`capT::Integer`: Number of periods to simulate
`;y_init::AbstratFloat(mean(ae.ygrid)`: The level of income we would like to
  start with
`;B_init::AbstratFloat(mean(ae.Bgrid)`: The level of asset holdings we would like
  to start with
##### Returns
`B_sim_val::Vector{TI}`: Simulated values of assets
`y_sim_val::Vector{TF}`: Simulated values of income
`q_sim_val::Vector{TF}`: Simulated values of prices
`default_status::Vector{Bool}`: Simulated default status
  (true if in default)
##### Notes
This updates all value functions, policy functions, and prices in place.
"""

function QuantEcon.simulate(ae::ArellanoEconomy, capT::Int=5000;
                            y_init=mean(ae.ygrid), B_init=mean(ae.Bgrid))

    # Get initial indices
    zero_index = searchsortedfirst(ae.Bgrid, 0.)
    y_init_ind = searchsortedfirst(ae.ygrid, y_init)
    B_init_ind = searchsortedfirst(ae.Bgrid, B_init)

    # Create a QE MarkovChain
    mc = MarkovChain(ae.Π)
    y_sim_indices = simulate(mc, capT+1; init=y_init_ind)

    # Allocate and Fill output
    y_sim_val = Array(Float64, capT+1)
    Con_sim_val = Array(Float64, capT+1)
    B_sim_val, q_sim_val = similar(y_sim_val), similar(y_sim_val)
    B_sim_indices = Array(Int, capT+1)
    default_status = fill(false, capT+1)
    B_sim_indices[1], default_status[1] = B_init_ind, false
    y_sim_val[1], B_sim_val[1] = ae.ygrid[y_init_ind], ae.Bgrid[B_init_ind]

    for t=1:capT
        # Get today's indexes
        yi, Bi = y_sim_indices[t], B_sim_indices[t]
        defstat = default_status[t]

        # If you are not in default
        if !defstat
            default_today = ae.vc[Bi, yi] < ae.vd[yi] ? true: false

            if default_today
                # Default values
                default_status[t] = true
                default_status[t+1] = true
                y_sim_val[t] = ae.ydefgrid[y_sim_indices[t]]
                B_sim_indices[t+1] = zero_index
                B_sim_val[t+1] = 0.
                q_sim_val[t] = ae.q[zero_index, y_sim_indices[t]]
            else
                default_status[t] = false
                y_sim_val[t] = ae.ygrid[y_sim_indices[t]]
                B_sim_indices[t+1] = ae.policy[Bi, yi]
                B_sim_val[t+1] = ae.Bgrid[B_sim_indices[t+1]]
                q_sim_val[t] = ae.q[B_sim_indices[t+1], y_sim_indices[t]]
            end

        # If you are in default
        else
            B_sim_indices[t+1] = zero_index
            B_sim_val[t+1] = 0.
            y_sim_val[t] = ae.ydefgrid[y_sim_indices[t]]
            q_sim_val[t] = ae.q[zero_index, y_sim_indices[t]]

            # With probability θ exit default status
            if rand() < ae.θ
                default_status[t+1] = false
            else
                default_status[t+1] = true
            end
        end
    end

    for t=1:capT # number of periods to simulate
        Con_sim_val[t] = y_sim_val[t] - q_sim_val[t]*B_sim_val[t] - B_sim_val[t]
    end

    return (y_sim_val[1:capT], B_sim_val[1:capT], q_sim_val[1:capT],
    default_status[1:capT], Con_sim_val[1:capT])
end



ae = ArellanoEconomy(β=.953,     # time discount rate
                     γ=2.,       # risk aversion
                     r=0.017,    # international interest rate
                     ρ=.9,     # persistence in output
                     η=0.027,    # st dev of output shock
                     θ=1,    # prob of regaining access
                     ny=21,      # number of points in y grid
                     nB=251)     # number of points in B grid

# now solve the model on the grid.
vfi!(ae)

# Solutions

using Gadfly, Compose, ColorTypes, DataFrames # DataFrames can use it for storing and exploring a set of related data values

# sample size
N = 500

# Parameters of interest from Hatchondo and Martinez (2009)
mean_Rs = Float64
sigma_Rs = Float64
mean_y = Float64
sigma_y = Float64
sigma_c = Float64
rho_cy = Float64
rho_Rsy = Float64



length(mean_Rs) < N

T = 1000
y_vec, B_vec, q_vec, Cons_vec = simulate(ae, T), default_vec # originally default_vec = simulate(ae, T), but change simulation


# If the the government defaults

if any(default_vec)

    #find default period
    defs = find(default_vec)
    def_breaks = diff(defs) .> 1
    def_start = defs[[true; def_breaks]]
    def_end = defs[[def_breaks; true]]
end
end

# report average of parameters of interest
println(mean(mean_Rs))
println(mean(sigma_Rs))
println(mean(sigma_y))
println(mean(sigma_c))
println(mean(rho_cy))
println(mean(rho_Rsy))

using Gadfly
plot(x = mean_y, y = mean_Rs, Guide.xlabel("Output"), Guide.ylabel("Annual Spread"), Geom.point)

# Note: I was unsure how to do the part for 32 consecutive periods, but ran out of time...
