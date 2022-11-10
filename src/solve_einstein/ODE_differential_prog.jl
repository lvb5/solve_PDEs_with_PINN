#=
Author: Miles Cochran-Branson
Date: Fall 2022

We solve the Einstein field equations to obtain the Schwarzschild metrix. 

Here, we start from ODEs given via simplification analytically. In order to 
make our solution match Newtonian gravity, we consider a solution to classical
=#
using NeuralPDE, Lux, ModelingToolkit
using DifferentialEquations, Statistics, SciMLSensitivity
using Random, CUDA, StaticArrays
using Optimization, OptimizationOptimisers, OptimizationOptimJL
import ModelingToolkit: Interval, infimum, supremum

include("../utils/general_utils.jl")

# define some consts
const G = 6.67e-11 # m²/kg²
const M = 1.989e30 #kg
const AU = 1.496e11 # meters
const yr = 3.154e7 #seconds
# change units
const GM = G*M*yr^2 / AU^3 # AU^3/yr^2; Kepler III says this is 4π^2
const c = 3e8 * (yr/AU) # AU / yr
const ricci_r = 2*GM/c^2

@parameters r
vars = @variables A(..) B(..)

Dr = Differential(r)
Drr = Differential(r)^2

eqns = [
    4*Dr(A(r))*((B(r))^2) - 2*r*Drr(B(r))*A(r)*B(r) + 2*Dr(A(r))*Dr(B(r))*B(r) + r*((Dr(B(r)))^2)*A(r) ~ 0,
    r*Dr(A(r))*B(r) + 2*((A(r))^2)*B(r) - 2*A(r)*B(r) - r*Dr(B(r))*A(r) ~ 0,
    -2*r*Drr(B(r))*A(r)*B(r) + r*Dr(A(r))*Dr(B(r))*B(r) + r*((Dr(B(r)))^2)*A(r) - 4*Dr(B(r))*A(r)*B(r) ~ 0
]

r_min = 1.0
r_max = 10.0
bcs = [
    B(r_max) ~ -1,
    A(r_max) ~ 1,
]

domains = [r ∈ Interval(r_min, r_max)]

@named pde_sys = PDESystem(eqns, bcs, domains, [r], [A(r), B(r)])

@info "Problem set-up complete"

# -------------------------------------------------------------------------------------
# Solve for Newtonian Gravity!
function newton_gravity(ddu,du,u,p,t)
    r = sqrt(u[1]^2 + u[2]^2)
    ddu[1] = GM*u[1]/r^1.5
    ddu[2] = GM*u[2]/r^1.5
end

# initial conditions
x0 = [1.0, 0.0] # units of AU
dx0 = [0.0, 10.0] # units of AU/yr
tspan = (0.0, 10.0)

# solve problem
dx = 0.5
prob_newton = SecondOrderODEProblem(newton_gravity, dx0, x0, tspan)
@time sol_newton = solve(prob_newton, saveat=dx)
sol_nts = [[sol_newton[i][3], sol_newton[i][4]] for i in eachindex(sol_newton)]

@info "Solved ODE problem!"

"""
    distance2(x1,x2,y1,y2)

Compute Euclidean distance between points (x1,y1) and (x2,y2)
"""
function distance2(x1,x2,y1,y2)
    return sqrt((x1-x2)^2 + (y1-y2)^2)
end

ϵ = sqrt(eps(Float32)) # machine epsilon for derivative
"""
    additional_loss(phi,θ,p)

Term of loss function to match newtonian gravity!
"""
function additional_loss(phi, θ, p)

    # 00 component of metric from neural network
    g00(x,y) = phi[1](sqrt(x^2+y^2), θ.depvar[:A])[1]

    # set-up the problem using current 
    function simple_geodesic(ddu,du,u,p,t)
        ddu[1] = -(c^2)/2 * ((g00(u[1]+ϵ,u[2]) - g00(u[1],u[2]))/ϵ)
        ddu[2] = -(c^2)/2 * ((g00(u[1],u[2]+ϵ) - g00(u[1],u[2]))/ϵ)
    end
    # function simple_geodesic(ddu,du,u,p,t)
    #     ddu[1] = -(c^2)/2 * ((phi[1](sqrt((u[1]+ϵ)^2 + u[2]^2), θ.depvar[:A])[1] - phi[1](sqrt(u[1]^2 + u[2]^2), θ.depvar[:A])[1])/ϵ)
    #     ddu[2] = -(c^2)/2 * ((phi[1](sqrt((u[1])^2 + (u[2]+ϵ)^2), θ.depvar[:A])[1] - phi[1](sqrt(u[1]^2 + u[2]^2), θ.depvar[:A])[1])/ϵ)
    # end

    # solve system of diff-eqs 
    prob = SecondOrderODEProblem(simple_geodesic, dx0, x0, tspan)
    sol = solve(prob, Tsit5(), reltol=0.1, abstol=0.1, saveat=dx)

    return sum(distance2(sol_nts[i][1],sol[i][3],
        sol_nts[i][2],sol[i][4]) for i in eachindex(sol_nts))
end

# -------------------------------------------------------------------------------------
# define neural network
numChains = length(vars)
dim = length(domains) # number of dimensions
activation = Lux.σ
nnodes = 10
chains = [Lux.Chain(Lux.Dense(dim, nnodes, activation), 
            Lux.Dense(nnodes, 1)) for _ in 1:numChains]

# run training on GPU if actailible 
ps = [Lux.setup(Random.default_rng(), chains[i])[1] for i in 1:numChains]
ps = [ps[i] |> Lux.ComponentArray |> gpu .|> Float32 for i in 1:numChains]

# discretize
strategy = QuasiRandomTraining(20)
discretization = PhysicsInformedNN(chains, strategy,
    additional_loss=additional_loss, init_params = ps)
@time prob = discretize(pde_sys, discretization)

@info "Discretization complete. Beginning training"

# some decoration for reporting the loss
i = 0
loss_history = []

# solve the problem!
res = Optimization.solve(prob, ADAM(1e-3); callback = callback, maxiters=2)
phi = discretization.phi

@info "Training complete. Beginning analysis"

# -------------------------------------------------------------------------------------
using Plots, LaTeXStrings

## plot loss as a function of Epoch
plot(1:length(loss_history), loss_history, xlabel="Epoch", ylabel="Loss",
        size=(400,400), dpi=200, label="")
savefig("./plots/EPE_ODE_solution/loss.png")

## Compare solution to analytic!
u_analytic(ρ) = [1 - ricci_r/ρ, -1/(1 - ricci_r/ρ)]

dep_vars = [:A, :B]
minimizers = [res.u.depvar[dep_vars[i]] for i in eachindex(dep_vars)]

dr = 0.01
rs = [infimum(d.domain):dr:supremum(d.domain) for d in domains][1]

u_real = [[u_analytic(r)[i] for r in rs] for i in 1:numChains]
u_predict = [[phi[i]([r], minimizers[i])[1] for r in rs] for i in 1:numChains]

plot(rs, u_real[1], xlabel=L"r", ylabel=L"A(r)", label="True Solution",
        size=(400,400), dpi=200, legend=:bottomright)
plot!(rs, u_predict[1], 
        label="Predicted Solution, \$\\chi^2/dof = $(round(χ²(u_predict[1], 
            u_real[1])/length(u_predict[1]),digits=2))\$")
savefig("./plots/EPE_ODE_solution/A.png")

plot(rs, u_real[2], xlabel=L"r", ylabel=L"B(r)", label="True Solution",
        size=(400,400), dpi=200, legend=:bottomright)
plot!(rs, u_predict[2], 
        label="Predicted Solution, \$\\chi^2/dof = $(round(χ²(u_predict[2], 
            u_real[2])/length(u_predict[2]),digits=2))\$")
savefig("./plots/EPE_ODE_solution/B.png")