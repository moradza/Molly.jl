# Types

export
    Interaction,
    GeneralInteraction,
    SpecificInteraction,
    AbstractNeighborFinder,
    InteractionList2Atoms,
    InteractionList3Atoms,
    InteractionList4Atoms,
    Atom,
    mass,
    AtomData,
    NeighborList,
    NeighborListVec,
    System,
    is_gpu_diff_safe

const DefaultFloat = Float64

"An interaction between atoms that contributes to forces on the atoms."
abstract type Interaction end

"""
A general interaction that will apply to all or most atom pairs.
Custom general interactions should sub-type this type.
"""
abstract type GeneralInteraction <: Interaction end

"""
A specific interaction between sets of specific atoms, e.g. a bond angle.
Custom specific interactions should sub-type this type.
"""
abstract type SpecificInteraction <: Interaction end

"""
A way to find near atoms to save on simulation time.
Custom neighbor finders should sub-type this type.
"""
abstract type AbstractNeighborFinder end

"""
    InteractionList2Atoms(is, js, inters)
    InteractionList2Atoms(inter_type)

A list of specific interactions between two atoms.
"""
struct InteractionList2Atoms{T}
    is::Vector{Int}
    js::Vector{Int}
    inters::T
end

"""
    InteractionList3Atoms(is, js, ks, inters)
    InteractionList3Atoms(inter_type)

A list of specific interactions between three atoms.
"""
struct InteractionList3Atoms{T}
    is::Vector{Int}
    js::Vector{Int}
    ks::Vector{Int}
    inters::T
end

"""
    InteractionList4Atoms(is, js, ks, ls, inters)
    InteractionList4Atoms(inter_type)

A list of specific interactions between four atoms.
"""
struct InteractionList4Atoms{T}
    is::Vector{Int}
    js::Vector{Int}
    ks::Vector{Int}
    ls::Vector{Int}
    inters::T
end

InteractionList2Atoms(T) = InteractionList2Atoms{Vector{T}}([], [], T[])
InteractionList3Atoms(T) = InteractionList3Atoms{Vector{T}}([], [], [], T[])
InteractionList4Atoms(T) = InteractionList4Atoms{Vector{T}}([], [], [], [], T[])

"""
    Atom(; <keyword arguments>)

An atom and its associated information.
Properties unused in the simulation or in analysis can be left with their
default values.
The types used should be bits types if the GPU is going to be used.

# Arguments
- `index::Int`: the index of the atom in the system.
- `charge::C=0.0`: the charge of the atom, used for electrostatic interactions.
- `mass::M=0.0u"u"`: the mass of the atom.
- `σ::S=0.0u"nm"`: the Lennard-Jones finite distance at which the inter-particle
    potential is zero.
- `ϵ::E=0.0u"kJ * mol^-1"`: the Lennard-Jones depth of the potential well.
"""
struct Atom{C, M, S, E}
    index::Int
    charge::C
    mass::M
    σ::S
    ϵ::E
end

function Atom(;
                index=1,
                charge=0.0,
                mass=0.0u"u",
                σ=0.0u"nm",
                ϵ=0.0u"kJ * mol^-1")
    return Atom(index, charge, mass, σ, ϵ)
end

"""
    mass(atom)

The mass of an atom.
"""
mass(atom::Atom) = atom.mass

AtomsBase.atomic_mass(atom::Atom) = mass(atom)

function Base.show(io::IO, a::Atom)
    print(io, "Atom with index ", a.index, ", charge=", a.charge,
            ", mass=", a.mass, ", σ=", a.σ, ", ϵ=", a.ϵ)
end

"""
    AtomData(atom_type, atom_name, res_number, res_name)

Data associated with an atom.
Storing this separately allows the atom types to be bits types and hence
work on the GPU.
"""
struct AtomData
    atom_type::String
    atom_name::String
    res_number::Int
    res_name::String
    element::String
end

function AtomData(;
                    atom_type="?",
                    atom_name="?",
                    res_number=1,
                    res_name="???",
                    element="?")
    return AtomData(atom_type, atom_name, res_number, res_name, element)
end

"""
    NeighborList()
    NeighborList(n, list)

Structure to contain pre-allocated neighbor lists.
"""
mutable struct NeighborList
    n::Int # Number of neighbors in list (n <= length(list))
    list::Vector{Tuple{Int, Int, Bool}}
end

NeighborList() = NeighborList(0, [])

function Base.empty!(nl::NeighborList)
    nl.n = 0
    return nl
end

function Base.push!(nl::NeighborList, element::Tuple{Int, Int, Bool})
    nl.n += 1
    if nl.n > length(nl.list)
        push!(nl.list, element)
    else
        nl.list[nl.n] = element
    end
    return nl
end

function Base.append!(nl::NeighborList, list::AbstractVector{Tuple{Int, Int, Bool}})
    for element in list
        push!(nl, element)
    end
    return nl
end

Base.append!(nl::NeighborList, nl_app::NeighborList) = append!(nl, @view(nl_app.list[1:nl_app.n]))

"""
    NeighborListVec(n, list)

Structure to contain neighbor lists for broadcasting.
"""
struct NeighborListVec{T}
    nbsi::Vector{Int} # Sorted ascending
    nbsj::Vector{Int}
    atom_bounds_i::Vector{Int}
    atom_bounds_j::Vector{Int}
    sortperm_j::Vector{Int}
    weights_14::T
end

"""
    System(; <keyword arguments>)

A physical system to be simulated.
Properties unused in the simulation or in analysis can be left with their
default values.
`atoms`, `atoms_data`, `coords` and `velocities` should have the same length.
This is a sub-type of `AbstractSystem` from AtomsBase.jl and implements the
interface described there.

# Arguments
- `atoms::A`: the atoms, or atom equivalents, in the system. Can be
    of any type but should be a bits type if the GPU is used.
- `atoms_data::AD`: other data associated with the atoms, allowing the atoms to
    be bits types and hence work on the GPU.
- `general_inters::GI=()`: the general interactions in the system, i.e.
    interactions between all or most atoms such as electrostatics. Typically a
    `Tuple`.
- `specific_inter_lists::SI=()`: the specific interactions in the system,
    i.e. interactions between specific atoms such as bonds or angles. Typically
    a `Tuple`.
- `coords::C`: the coordinates of the atoms in the system. Typically a
    vector of `SVector`s of 2 or 3 dimensions.
- `velocities::V=zero(coords)`: the velocities of the atoms in the system.
- `box_size::B`: the size of the box in which the simulation takes place.
    Typically a `SVector` of 2 or 3 dimensions.
- `neighbor_finder::NF=NoNeighborFinder()`: the neighbor finder used to find
    close atoms and save on computation.
- `loggers::L=Dict()`: the loggers that record properties of interest during a
    simulation.
- `force_units::F=u"kJ * mol^-1 * nm^-1"`: the units of force of the system.
- `energy_units::E=u"kJ * mol^-1"`: the units of energy of the system.
- `gpu_diff_safe::Bool`: whether to use the code path suitable for the
    GPU and taking gradients. Defaults to `isa(coords, CuArray)`.
"""
mutable struct System{D, G, A, AD, GI, SI, C, V, B, NF, L, F, E} <: AbstractSystem{D}
    atoms::A
    atoms_data::AD
    general_inters::GI
    specific_inter_lists::SI
    coords::C
    velocities::V
    box_size::B
    neighbor_finder::NF
    loggers::L
    force_units::F
    energy_units::E
end

function System(;
                atoms,
                atoms_data=[],
                general_inters=(),
                specific_inter_lists=(),
                coords,
                velocities=zero(coords),
                box_size,
                neighbor_finder=NoNeighborFinder(),
                loggers=Dict(),
                force_units=u"kJ * mol^-1 * nm^-1",
                energy_units=u"kJ * mol^-1",
                gpu_diff_safe=isa(coords, CuArray))
    D = length(box_size)
    A = typeof(atoms)
    AD = typeof(atoms_data)
    GI = typeof(general_inters)
    SI = typeof(specific_inter_lists)
    C = typeof(coords)
    V = typeof(velocities)
    B = typeof(box_size)
    NF = typeof(neighbor_finder)
    L = typeof(loggers)
    F = typeof(force_units)
    E = typeof(energy_units)
    return System{D, gpu_diff_safe, A, AD, GI, SI, C, V, B, NF, L, F, E}(
                    atoms, atoms_data, general_inters, specific_inter_lists,
                    coords, velocities, box_size, neighbor_finder, loggers,
                    force_units, energy_units)
end

"""
    is_gpu_diff_safe(sys)

Whether a `System` uses the code path suitable for the GPU and
    for taking gradients.
"""
is_gpu_diff_safe(::System{D, G}) where {D, G} = G

AtomsBase.species_type(s::System) = eltype(s.atoms)

Base.getindex(s::System, i::Integer) = s.atoms[i]
Base.length(s::System) = length(s.atoms)

AtomsBase.position(s::System) = s.coords
AtomsBase.position(s::System, i::Integer) = s.coords[i]

AtomsBase.velocity(s::System) = s.velocities
AtomsBase.velocity(s::System, i::Integer) = s.velocities[i]

AtomsBase.boundary_conditions(::System{3}) = SVector(Periodic(), Periodic(), Periodic())
AtomsBase.boundary_conditions(::System{2}) = SVector(Periodic(), Periodic())

edges_to_box(bs::SVector{3}, z) = SVector{3}([SVector(bs[1], z, z), SVector(z, bs[2], z),
                                                SVector(z, z, bs[3])])
edges_to_box(bs::SVector{2}, z) = SVector{2}([SVector(bs[1], z), SVector(z, bs[2])])

function AtomsBase.bounding_box(s::System)
    bs = s.box_size
    z = zero(bs[1])
    bb = edges_to_box(bs, z)
    return unit(z) == NoUnits ? (bb)u"nm" : bb # Assume nm without other information
end

function Base.show(io::IO, s::System)
    print(io, "System with ", length(s), " atoms, box size ", s.box_size)
end
