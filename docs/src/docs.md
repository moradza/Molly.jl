# Molly documentation

This documentation will first introduce the main features of the package with some examples, then will give details on each component of a simulation.
There are further examples in the [Molly examples](@ref) section.
For more information on specific types or functions, see the [Molly API](@ref) section or call `?function_name` in Julia.
The [Differentiable simulation with Molly](@ref) section describes taking gradients through simulations.

Molly takes a modular approach to molecular simulation.
To run a simulation you create a [`System`](@ref) object and call [`simulate!`](@ref) on it.
The different components of the system and simulation can be used as defined by the package, or you can define your own versions.
An important principle of the package is that your custom components, particularly force functions, should be easy to define and just as performant as the built-in versions.

## Simulation basics

Let's look at the simulation of a fluid acting under the [Lennard-Jones](https://en.wikipedia.org/wiki/Lennard-Jones_potential) potential to start with.
First, we'll need some atoms with the relevant parameters defined.
```julia
using Molly

n_atoms = 100
atom_mass = 10.0u"u"
atoms = [Atom(mass=atom_mass, σ=0.3u"nm", ϵ=0.2u"kJ * mol^-1") for i in 1:n_atoms]
```
See the [Unitful.jl](https://github.com/PainterQubits/Unitful.jl) docs for more information on the unit annotations.
Molly re-exports Unitful.jl and [StaticArrays.jl](https://github.com/JuliaArrays/StaticArrays.jl) since they are usually required to run simulations.
Next, we'll need some starting coordinates and velocities.
```julia
box_size = SVector(2.0, 2.0, 2.0)u"nm"
coords = place_atoms(n_atoms, box_size, 0.3u"nm") # Random placement without clashing

temp = 100.0u"K"
velocities = [velocity(atom_mass, temp) for i in 1:n_atoms]
```
We store the coordinates and velocities as [static arrays](https://github.com/JuliaArrays/StaticArrays.jl) for performance.
They can be of 2 or 3 dimensions and of any number type, e.g. `Float64` or `Float32`.
Now we can define our general interactions, i.e. those between most or all atoms.
Because we have defined the relevant parameters for the atoms, we can use the built-in Lennard-Jones type.
```julia
general_inters = (LennardJones(),)
```
Finally, we can define the system and run the simulation.
We use an Andersen thermostat to keep a constant temperature, and we log the temperature and coordinates every 10 steps.
Periodic boundary conditions are used with the box we defined earlier.
```julia
sys = System(
    atoms=atoms,
    general_inters=general_inters,
    coords=coords,
    velocities=velocities,
    box_size=box_size,
    loggers=Dict(
        "temp"   => TemperatureLogger(10),
        "coords" => CoordinateLogger(10),
    ),
)

simulator = VelocityVerlet(dt=0.002u"ps", coupling=AndersenThermostat(temp, 1.0u"ps"))
simulate!(sys, simulator, 1_000)
```
By default the simulation is run in parallel on the [number of threads](https://docs.julialang.org/en/v1/manual/parallel-computing/#man-multithreading-1) available to Julia, but this can be turned off by giving the keyword argument `parallel=false` to [`simulate!`](@ref).
An animation of the stored coordinates using can be saved using [`visualize`](@ref), which is available when [GLMakie.jl](https://github.com/JuliaPlots/Makie.jl) is imported.
```julia
using GLMakie
visualize(sys.loggers["coords"], box_size, "sim_lj.mp4")
```
![LJ simulation](images/sim_lj.gif)

## GPU acceleration

To run simulations on the GPU you will need to have a CUDA-compatible device and to have [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl) installed.
Simulation setup is similar to above, but with the coordinates, velocities and atoms moved to the GPU.
This example also shows setting up a simulation to run with `Float32`, which can be a good idea for GPUs.
```julia
using Molly
using CUDA

n_atoms = 100
atom_mass = 10.0f0u"u"
box_size = SVector(2.0f0, 2.0f0, 2.0f0)u"nm"
temp = 100.0f0u"K"
atoms = cu([Atom(mass=atom_mass, σ=0.3f0u"nm", ϵ=0.2f0u"kJ * mol^-1") for i in 1:n_atoms])
coords = cu(place_atoms(n_atoms, box_size, 0.3u"nm"))
velocities = cu([velocity(atom_mass, temp) for i in 1:n_atoms])
simulator = VelocityVerlet(dt=0.002f0u"ps")

sys = System(
    atoms=atoms,
    general_inters=(LennardJones(),),
    coords=coords,
    velocities=velocities,
    box_size=box_size,
    loggers=Dict(
        "temp"   => TemperatureLogger(typeof(1.0f0u"K"), 10),
        "coords" => CoordinateLogger(typeof(1.0f0u"nm"), 10),
    ),
)

simulate!(sys, simulator, 1_000)
```

## Simulating diatomic molecules

If we want to define specific interactions between atoms, for example bonds, we can do.
Using the same definitions as the first example, let's set up the coordinates so that paired atoms are 1 Å apart.
```julia
coords = place_atoms(n_atoms ÷ 2, box_size, 0.3u"nm")
for i in 1:length(coords)
    push!(coords, coords[i] .+ [0.1, 0.0, 0.0]u"nm")
end

velocities = [velocity(atom_mass, temp) for i in 1:n_atoms]
```
Now we can use the built-in interaction list and bond types to place harmonic bonds between paired atoms.
```julia
bonds = InteractionList2Atoms(
    collect(1:(n_atoms ÷ 2)),
    collect((1 + n_atoms ÷ 2):n_atoms),
    [HarmonicBond(b0=0.1u"nm", kb=300_000.0u"kJ * mol^-1 * nm^-2") for i in 1:(n_atoms ÷ 2)],
)

specific_inter_lists = (bonds,)
```
This time, we are also going to use a neighbor list to speed up the Lennard Jones calculation.
We can use the built-in distance neighbor finder.
The arguments are a 2D array of eligible interacting pairs, the number of steps between each update and the cutoff to be classed as a neighbor.
```julia
# All pairs apart from bonded pairs are eligible to interact
nb_matrix = trues(n_atoms, n_atoms)
for i in 1:(n_atoms ÷ 2)
    nb_matrix[i, i + (n_atoms ÷ 2)] = false
    nb_matrix[i + (n_atoms ÷ 2), i] = false
end

neighbor_finder = DistanceNeighborFinder(
    nb_matrix=nb_matrix,
    n_steps=10,
    dist_cutoff=1.5u"nm",
)
```
Now we can simulate as before.
```julia
sys = System(
    atoms=atoms,
    general_inters=(LennardJones(nl_only=true),),
    specific_inter_lists=specific_inter_lists,
    coords=coords,
    velocities=velocities,
    box_size=box_size,
    neighbor_finder=neighbor_finder,
    loggers=Dict(
        "temp" => TemperatureLogger(10),
        "coords" => CoordinateLogger(10),
    ),
)

simulator = VelocityVerlet(
    dt=0.002u"ps",
    coupling=AndersenThermostat(temp, 1.0u"ps"),
)
simulate!(sys, simulator, 1_000)
```
This time when we view the trajectory we can add lines to show the bonds.
```julia
visualize(
    sys.loggers["coords"],
    box_size,
    "sim_diatomic.mp4";
    connections=[(i, i + (n_atoms ÷ 2)) for i in 1:(n_atoms ÷ 2)],
)
```
![Diatomic simulation](images/sim_diatomic.gif)

## Simulating gravity

Molly is geared primarily to molecular simulation, but can also be used to simulate other physical systems.
Let's set up a gravitational simulation.
This example also shows the use of `Float32`, a 2D simulation and no specified units.
```julia
atoms = [Atom(mass=1.0f0), Atom(mass=1.0f0)]
coords = [SVector(0.3f0, 0.5f0), SVector(0.7f0, 0.5f0)]
velocities = [SVector(0.0f0, 1.0f0), SVector(0.0f0, -1.0f0)]
general_inters = (Gravity(nl_only=false, G=1.5f0),)
simulator = VelocityVerlet(dt=0.002f0)
box_size = SVector(1.0f0, 1.0f0)

sys = System(
    atoms=atoms,
    general_inters=general_inters,
    coords=coords,
    velocities=velocities,
    box_size=box_size,
    loggers=Dict("coords" => CoordinateLogger(Float32, 10; dims=2)),
    force_units=NoUnits,
    energy_units=NoUnits,
)

simulate!(sys, simulator, 2_000)
```
When we view the simulation we can use some extra options:
```julia
visualize(
    sys.loggers["coords"],
    box_size,
    "sim_gravity.mp4";
    trails=4,
    framerate=15,
    color=[:orange, :lightgreen],
)
```
![Gravity simulation](images/sim_gravity.gif)

## Simulating a protein

The recommended way to simulate a macromolecular simulation is to read in a force field in OpenMM XML format and read in a coordinate file in a format [supported by Chemfiles.jl](https://chemfiles.org/chemfiles/latest/formats.html).
This sets up a system in the same data structures as above and is simulated in the same way.
Here a [`StructureWriter`](@ref) is used to write the trajectory as a PDB file.

```julia
ff = OpenMMForceField("ff99SBildn.xml", "tip3p_standard.xml", "his.xml")

sys = System(
    "6mrr_equil.pdb",
    ff;
    loggers=Dict(
        "energy" => TotalEnergyLogger(10),
        "writer" => StructureWriter(10, "traj_6mrr_1ps.pdb", ["HOH"]),
    ),
)

random_velocities!(sys, 298.0u"K")
simulator = VelocityVerlet(dt=0.0005u"ps")

simulate!(sys, simulator, 5_000; parallel=true)
```

Molly also has a rudimentary parser of [Gromacs](http://www.gromacs.org) topology and coordinate files.
```julia
sys = System(
    joinpath(dirname(pathof(Molly)), "..", "data", "5XER", "gmx_coords.gro"),
    joinpath(dirname(pathof(Molly)), "..", "data", "5XER", "gmx_top_ff.top");
    loggers=Dict(
        "temp"   => TemperatureLogger(10),
        "writer" => StructureWriter(10, "traj_5XER_1ps.pdb"),
    ),
)

temp = 298.0u"K"
random_velocities!(sys, temp)
simulator = VelocityVerlet(dt=0.0002u"ps", coupling=AndersenThermostat(temp, 1.0u"ps"))

simulate!(sys, simulator, 5_000)
```

## Agent-based modelling

Agent-based modelling (ABM) is conceptually similar to molecular dynamics.
Julia has [Agents.jl](https://juliadynamics.github.io/Agents.jl/stable/) for ABM, but Molly can also be used to simulate arbitrary agent-based systems in continuous space.
Here we simulate a toy SIR model for disease spread.
This example shows how atom properties can be mutable, i.e. change during the simulation, and includes custom forces and loggers (see below for more).
```julia
@enum Status susceptible infected recovered

# Custom atom type
mutable struct Person
    i::Int
    status::Status
    mass::Float64
    σ::Float64
    ϵ::Float64
end

Molly.mass(person::Person) = person.mass

# Custom GeneralInteraction
struct SIRInteraction <: GeneralInteraction
    nl_only::Bool
    dist_infection::Float64
    prob_infection::Float64
    prob_recovery::Float64
end

# Custom force function
function Molly.force(inter::SIRInteraction,
                        coord_i,
                        coord_j,
                        atom_i,
                        atom_j,
                        box_size)
    if (atom_i.status == infected && atom_j.status == susceptible) ||
                (atom_i.status == susceptible && atom_j.status == infected)
        # Infect close people randomly
        dr = vector(coord_i, coord_j, box_size)
        r2 = sum(abs2, dr)
        if r2 < inter.dist_infection ^ 2 && rand() < inter.prob_infection
            atom_i.status = infected
            atom_j.status = infected
        end
    end
    # Workaround to obtain a self-interaction
    if atom_i.i == (atom_j.i + 1)
        # Recover randomly
        if atom_i.status == infected && rand() < inter.prob_recovery
            atom_i.status = recovered
        end
    end
    return zero(coord_i)
end

# Custom Logger
struct SIRLogger
    n_steps::Int
    fracs_sir::Vector{Vector{Float64}}
end

# Custom logging function
function Molly.log_property!(logger::SIRLogger, s, neighbors, step_n)
    if step_n % logger.n_steps == 0
        counts_sir = [
            count(p -> p.status == susceptible, s.atoms),
            count(p -> p.status == infected   , s.atoms),
            count(p -> p.status == recovered  , s.atoms)
        ]
        push!(logger.fracs_sir, counts_sir ./ length(s))
    end
end

temp = 0.01
box_size = SVector(10.0, 10.0)
n_steps = 1_000
n_people = 500
n_starting = 2
atoms = [Person(i, i <= n_starting ? infected : susceptible, 1.0, 0.1, 0.02) for i in 1:n_people]
coords = place_atoms(n_people, box_size, 0.1)
velocities = [velocity(1.0, temp; dims=2) for i in 1:n_people]
general_inters = (LennardJones=LennardJones(nl_only=true), SIR=SIRInteraction(false, 0.5, 0.06, 0.01))
neighbor_finder = DistanceNeighborFinder(nb_matrix=trues(n_people, n_people), n_steps=10, dist_cutoff=2.0)
simulator = VelocityVerlet(dt=0.02, coupling=AndersenThermostat(temp, 5.0))

sys = System(
    atoms=atoms,
    general_inters=general_inters,
    coords=coords,
    velocities=velocities,
    box_size=box_size,
    neighbor_finder=neighbor_finder,
    loggers=Dict("coords" => CoordinateLogger(Float64, 10; dims=2),
                    "SIR" => SIRLogger(10, [])),
    force_units=NoUnits,
    energy_units=NoUnits,
)

simulate!(sys, simulator, n_steps)

visualize(sys.loggers["coords"], box_size, "sim_agent.mp4"; markersize=10.0)
```
![Agent simulation](images/sim_agent.gif)

We can use the logger to plot the fraction of people susceptible (blue), infected (orange) and recovered (green) over the course of the simulation:
![Fraction SIR](images/fraction_sir.png)

## Units

Molly is fairly opinionated about using [Unitful.jl](https://github.com/PainterQubits/Unitful.jl) units as shown above: you don't have to use them, but it is better if you do.
Whilst you occasionally may run into friction with dimension mismatches, using units has the major advantages of catching whole classes of errors and letting you physically interpret the numbers in your system.
The performance overhead of using units is minimal.
Units are not currently compatible with differentiable simulations.

All your interaction types need to return the same units of force and energy or the simulation will not run.
By default these are `kJ * mol^-1 * nm^-1` for force and `kJ * mol^-1` for energy, but this can be changed using the `force_units` and `energy_units` arguments to [`System`](@ref).
If you need to strip units for downstream analysis, use the `ustrip` function.
It should be noted that charges are stored as dimensionless, i.e. 1.0 is an atomic charge of +1.

## Forces

Forces define how different parts of the system interact. The force on each particle in the system is derived from the potential corresponding to the interaction.
```math
\vec{F}_i = -\sum_j \frac{dV_{ij}(r_{ij})}{dr_{ij}}\frac{\vec{r}_{ij}}{r_{ij}}
```

In Molly there are two types of interactions.
[`GeneralInteraction`](@ref)s are present between all or most atoms, and account for example for non-bonded terms.
[`SpecificInteraction`](@ref)s are present between specific atoms, and account for example for bonded terms.

The available general interactions are:
- [`LennardJones`](@ref)
- [`SoftSphere`](@ref)
- [`Mie`](@ref)
- [`Coulomb`](@ref)
- [`CoulombReactionField`](@ref)
- [`Gravity`](@ref)

The available specific interactions are:
- [`HarmonicBond`](@ref)
- [`HarmonicAngle`](@ref)
- [`PeriodicTorsion`](@ref)
- [`RBTorsion`](@ref)

To define your own [`GeneralInteraction`](@ref), first define the `struct`:
```julia
struct MyGeneralInter <: GeneralInteraction
    nl_only::Bool
    # Any other properties, e.g. constants for the interaction or cutoff parameters
end
```
The `nl_only` property is required and determines whether the neighbor list is used to omit distant atoms (`true`) or whether all atom pairs are always considered (`false`).
Next, you need to define the [`force`](@ref) function acting between a pair of atoms.
This has a set series of arguments.
For example:
```julia
function Molly.force(inter::MyGeneralInter,
                        coord_i,
                        coord_j,
                        atom_i,
                        atom_j,
                        box_size)
    dr = vector(coord_i, coord_j, box_size)

    # Replace this with your force calculation
    # A positive force causes the atoms to move apart
    f = 0.0

    # Obtain a vector for the force
    fdr = f * normalize(dr)
    return fdr
end
```
If you need to obtain the vector from atom `i` to atom `j`, use the [`vector`](@ref) function.
This gets the vector between the closest images of atoms `i` and `j` accounting for the periodic boundary conditions.
Atom properties can be accessed, e.g. `atom_i.σ`.
Typically the force function is where most computation time is spent during the simulation, so consider optimising this function if you want high performance.

To use your custom force in a simulation, add it to the list of general interactions:
```julia
general_inters = (MyGeneralInter(true),)
```
Then create a [`System`](@ref) and simulate as above.
Note that you can also use named tuples instead of tuples if you want to access interactions by name:
```julia
general_inters = (MyGeneralInter=MyGeneralInter(true),)
```
For performance reasons it is best to [avoid containers with abstract type parameters](https://docs.julialang.org/en/v1/manual/performance-tips/#man-performance-abstract-container-1), such as `Vector{GeneralInteraction}`.

To define your own [`SpecificInteraction`](@ref), first define the `struct`:
```julia
struct MySpecificInter <: SpecificInteraction
    # Properties, e.g. a bond distance corresponding to the energy minimum
end
```
Next, you need to define the [`force`](@ref) function.
The form of this will depend whether the interaction involves 2, 3 or 4 atoms.
For example in the 2 atom case:
```julia
function Molly.force(inter::MySpecificInter, coords_i, coords_j, box_size)
    dr = vector(coords_i, coords_j, box_size)

    # Replace this with your force calculation
    # A positive force causes the atoms to move apart
    f = 0.0

    fdr = f * normalize(dr)
    return SpecificForce2Atoms(-fdr, fdr)
end
```
The 3 atom case would define `Molly.force(inter::MySpecificInter, coords_i, coords_j, coords_k, box_size)` and return `SpecificForce3Atoms(f1, f2, f3)`.
To use your custom force, add it to the specific interaction lists along with the atom indices:
```julia
specific_inter_lists = (
    InteractionList2Atoms(
        [1, 3],
        [2, 4],
        [MySpecificInter(), MySpecificInter()],
    ),
)
```
For 3 atom interactions use `InteractionList3Atoms` and pass 3 sets of indices.
If using the GPU, the inner list of interactions should be moved to the GPU.

If you wish to calculate potential energies or log the energy throughout a simulation, define the `potential_energy` function.
This has the same arguments as `force` and should return a single value corresponding to the potential energy.

## Cutoffs

The total potential energy of a system is given as a sum of the individual inter-particle potentials
```math
V(\vec{r}_1, \dotsc, \vec{r}_N) = \sum_{i<j}V_{ij}(r_{ij})
```

The forces acting on the particles are given by
```math
\vec{F}_i = -\sum_j \frac{dV_{ij}(r_{ij})}{dr_{ij}}\frac{\vec{r}_{ij}}{r_{ij}}
```

In the case of the Lennard-Jones potential, the inter-particle potential is given by
```math
V_{ij}(r_{ij}) = 4\varepsilon_{ij} \left[\left(\frac{\sigma_{ij}}{r_{ij}}\right)^{12} - \left(\frac{\sigma_{ij}}{r_{ij}}\right)^{6}\right]
```
and the forces are given by
```math
\begin{aligned}
\vec{F}_i &= 24\varepsilon_{ij} \left(2\frac{\sigma_{ij}^{12}}{r_{ij}^{13}} - \frac{\sigma_{ij}^6}{r_{ij}^{7}}\right) \frac{\vec{r}_{ij}}{r_{ij}} \\
&= \frac{24\varepsilon_{ij}}{r_{ij}^2} \left[2\left(\frac{\sigma_{ij}^{6}}{r_{ij}^{6}}\right)^2 -\left(\frac{\sigma_{ij}}{r_{ij}}\right)^{6}\right] \vec{r}_{ij}
\end{aligned}
```

As the potential, and thus also the force decreases rapidly with the distance, in almost every implementation of the Lennard-Jones force calculation there is a cutoff radius beyond which the force is set to 0.

While this is often a sensible approach, it introduces a discontinuity in the force function and it requires us to also modify the potential, as beyond the cutoff radius the force would be 0, but the derivative of the unmodified potential is not. One way to truncate the potential is to shift the potential by its cutoff value.
```math
\begin{aligned}
\vec{F}_{SP}(\vec{r}) &= \begin{cases}
\vec{F}(\vec{r}), r < r_c \\
0, r > r_c
\end{cases} \\
V_{SP}(r) &= \begin{cases}
V(r) - V(r_c), r \le r_c \\
0, r > r_c
\end{cases}
\end{aligned}
```

This way the potential function is continuous and the relation between forces and potentials is satisfied. This truncation method is called shifted potential cutoff.

Another option is to shift the force in order to make it continuous
```math
\begin{aligned}
F_{SF}(r) &= \begin{cases}
F(r) - F(r_c), r \le r_c \\
0, r > r_c
\end{cases} \\
V_{SF}(r) &= \begin{cases}
V(r) - (r-r_c) V'(r_c) - V(r_c), r \le r_c \\
0, r > r_c
\end{cases}
\end{aligned}
```
This requires a more complicated change in the potential in order to satisfy the relation between them. This method is called the shifted force cutoff. The continuity of the force is desirable as it may give better energy conservation properties as shown in [Toxvaerd 2011](http://aip.scitation.org/doi/10.1063/1.3558787).

There are also more complicated truncation methods that interpolate between the original potential and 0, but we will consider those two for the moment.

The truncation approximations that we use can significantly alter the qualitative features of the simulation as shown in many articles in the molecular dynamics literature ([Fitzner 2017](https://aip.scitation.org/doi/full/10.1063/1.4997698), [van der Spoel 2006](https://pubs.acs.org/doi/10.1021/ct0502256) and others).

### Implementation

Since the truncation algorithm is independent of the interaction for which is used, each interaction is defined without including cutoffs.
The corresponding interaction `struct` has a `cutoff` field which is then used via dispatch to apply the chosen cutoff.
The available cutoffs are:
- [`NoCutoff`](@ref)
- [`DistanceCutoff`](@ref)
- [`ShiftedPotentialCutoff`](@ref)
- [`ShiftedForceCutoff`](@ref)

## Simulators

Simulators define what type of simulation is run.
This could be anything from a simple energy minimisation to complicated replica exchange MD.
The available simulators are:
- [`VelocityVerlet`](@ref)
- [`StormerVerlet`](@ref)

To define your own simulator, first define a `struct`:
```julia
struct MySimulator
    # Any properties, e.g. the time step or coupling methods
end
```
Then, define the function that carries out the simulation.
This example shows some of the helper functions you can use:
```julia
function Molly.simulate!(sys::System,
                            sim::MySimulator,
                            n_steps::Integer;
                            parallel::Bool=true)
    # Find neighbors like this
    neighbors = find_neighbors(sys, sys.neighbor_finder; parallel=parallel)

    # Show a progress bar like this, if you have imported ProgressMeter
    @showprogress for step_n in 1:n_steps
        # Apply the loggers like this
        run_loggers!(sys, neighbors, step_n)

        # Calculate accelerations like this
        accels_t = accelerations(sys, neighbors; parallel=parallel)

        # Ensure coordinates stay within the simulation box like this
        for i in 1:length(sys)
            sys.coords[i] = wrap_coords.(sys.coords[i], sys.box_size)
        end

        # Apply coupling like this
        apply_coupling!(sys, sim, sim.coupling)

        # Find new neighbors like this
        neighbors = find_neighbors(sys, sys.neighbor_finder, neighbors, step_n;
                                   parallel=parallel)
    end

    return sys
end
```
To use your custom simulator, give it as the second argument when calling [`simulate!`](@ref).

Under the hood there are two implementations for simulators: an in-place version geared towards CPUs and parallelism, and an out-of-place version geared towards GPUs and differentiable simulation.
You can define different versions of a simulator for in-place and out-of-place systems by dispatching on `System{D, false}` or `System{D, true}` respectively.
This also applies to coupling methods and neighbor lists.
You do not have to define two versions though: you may only intend to use the simulator one way, or the out-of-place version may be performant in all cases.
The above example is more similar to the in-place version; see the source code for an example of the out-of-place version.

The implementation to use is guessed when you call [`System`](@ref) based on whether `coords` is a `CuArray` but can be given explicitly with the `gpu_diff_safe` argument, for example if you want to run differentiable simulations on the CPU.
[`is_gpu_diff_safe`](@ref) will retrieve this property for a [`System`](@ref).

## Coupling

Temperature and pressure coupling allows properties to be controlled during a simulation.
The available couplers are:
- [`AndersenThermostat`](@ref)
- [`RescaleThermostat`](@ref)
- [`BerendsenThermostat`](@ref)

To define your own coupling method, first define the `struct`:
```julia
struct MyCoupler
    # Any properties, e.g. a target temperature or coupling constant
end
```
Then, define the function that implements the coupling every time step:
```julia
function apply_coupling!(sys::System, sim, coupling::MyCoupler)
    # Do something to the simulation, e.g. scale the velocities
    return sys
end
```
The functions [`velocity`](@ref), [`maxwell_boltzmann`](@ref) and [`temperature`](@ref) may be useful here.
To use your custom coupler, give it as the `coupling` argument to the simulator.

## Neighbor finders

Neighbor finders find close atoms periodically throughout the simulation, saving on computation time by allowing the force calculation between distant atoms to be omitted.
The available neighbor finders are:
- [`NoNeighborFinder`](@ref)
- [`CellListMapNeighborFinder`](@ref)
- [`TreeNeighborFinder`](@ref)
- [`DistanceNeighborFinder`](@ref)
- [`DistanceVecNeighborFinder`](@ref)

To define your own [`AbstractNeighborFinder`](@ref), first define the `struct`:
```julia
struct MyNeighborFinder <: AbstractNeighborFinder
    nb_matrix::BitArray{2}
    matrix_14::BitArray{2}
    n_steps::Int
    # Any other properties, e.g. a distance cutoff
end
```
Examples of three useful properties are given here: a matrix indicating atom pairs eligible for non-bonded interactions, a matrix indicating atoms in a 1-4 bonding arrangement, and a value determining how many time steps occur between each evaluation of the neighbor finder.
Then, define the neighbor finding function that is called every step by the simulator:
```julia
function find_neighbors(s::System,
                        nf::MyNeighborFinder,
                        current_neighbors=nothing,
                        step_n::Integer=0;
                        parallel::Bool=true)
    if step_n % nf.n_steps == 0
        if isnothing(current_neighbors)
            neighbors = NeighborList()
        else
            neighbors = current_neighbors
        end
        empty!(neighbors)
        # Add to neighbors, for example
        push!(neighbors, (1, 2, false)) # atom i, atom j and whether they are in a 1-4 bonding arrangement
        return neighbors
    else
        return current_neighbors
    end
end
```
A different setup is used for the out-of-place implementation.
To use your custom neighbor finder, give it as the `neighbor_finder` argument when creating the [`System`](@ref).

## Loggers

Loggers record properties of the simulation to allow monitoring and analysis.
The available loggers are:
- [`TemperatureLogger`](@ref)
- [`CoordinateLogger`](@ref)
- [`VelocityLogger`](@ref)
- [`TotalEnergyLogger`](@ref)
- [`KineticEnergyLogger`](@ref)
- [`PotentialEnergyLogger`](@ref)
- [`StructureWriter`](@ref)

To define your own logger, first define the `struct`:
```julia
struct MyLogger
    n_steps::Int
    # Any other properties, e.g. an Array to record values during the trajectory
end
```
Then, define the logging function that is called every step by the simulator:
```julia
function Molly.log_property!(logger::MyLogger, sys, neighbors, step_n)
    if step_n % logger.n_steps == 0
        # Record some property or carry out some action
    end
end
```
The use of `n_steps` is optional and is an example of how to record a property every n steps through the simulation.
To use your custom logger, add it to the dictionary of loggers given when creating the [`System`](@ref):
```julia
loggers = Dict("mylogger" => MyLogger(10))
```

## Analysis

Molly contains some tools for analysing the results of simulations.
The available analysis functions are:
- [`visualize`](@ref)
- [`rdf`](@ref)
- [`distances`](@ref)
- [`displacements`](@ref)
- [`velocity_autocorr`](@ref)

Julia is a language well-suited to implementing all kinds of analysis for molecular simulations.
