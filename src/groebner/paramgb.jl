
"""
    paramgb

Given an array of polynomials `polys` over a field of rational functions
computes the Groebner basis of the ideal generated by `polys`.

The algorithm is probabilistic and succeeds with a high probability.

Examples:

```julia
using Nemo, ParamPunPam

Rparam, (a, b) = PolynomialRing(QQ, ["a", "b"], ordering=:degrevlex)
R, (x, y, z) = PolynomialRing(FractionField(Rparam), ["x", "y", "z"], ordering=:degrevlex)

ParamPunPam.paramgb([a*x^2 + 1, y^2*z + (1//b)*y])
```

"""
function paramgb(polys::Vector{T}) where {T}
    metainfo = peek_at_input(polys)
    unified_polys = unify_input(polys, metainfo)
    _paramgb(unified_polys, metainfo)
end

# Returns the ring of polynomials in parameters
getparamring(coeffring) = throw(DomainError(coeffring, "Unknown coefficient ring."))
getparamring(coeffring::Nemo.FracField) = true, base_ring(coeffring)
getparamring(coeffring::Nemo.MPolyRing) = false, coeffring

# Checks the input and returns some meta-information about it
function peek_at_input(polys)
    @assert !isempty(polys) "Empty input is invalid."
    Rx = parent(first(polys))
    over_fractions, Rparam = getparamring(base_ring(Rx))
    K = base_ring(Rparam)
    @assert all(x -> parent(x) == Rx, polys) "All polynomials must be in the same ring."
    @assert typeof(K) === Nemo.FlintRationalField || typeof(K) === typeof(AbstractAlgebra.QQ) "Coefficient ring must be Nemo.QQ or AbstractAlgebra.QQ"
    (over_fractions=over_fractions,)
end

#=
    Does something cool with the input.
=#
function unify_input(polys, metainfo)
    filter!(!iszero, polys)
end

function _paramgb(polys, metainfo)
    # The struct to keep track of modular computation related stuff
    modular = ModularTracker(polys)
    # The struct to store the state of the computation
    state = GroebnerState(polys)
    # Discover the shape of the groebner basis:
    # its size, and the sizes of polynomials it contains
    discover_shape!(state, modular, η=2)
    # Discover the degrees of the parametric coefficients
    discover_param_degrees!(state, modular)
    # Interpolate the exponents in the parametric coefficients
    # (this uses exactly 1 prime number)
    interpolate_param_exponents!(state, modular)
    # Interpolate the rational coefficients of the parametric coefficients
    # (this is expected to use 1 prime number, but may use more)
    recover_coefficients!(state, modular)
    # Combine and return the above two 
    basis = construct_basis(state)
    basis
end

# Discovers shape of the groebner basis of the ideal from `state`
# by specializing it at a random point (preferably, modulo a prime).
#
# If η > 0 is given, the algorithm will confirm the shape
# by additionaly specializing it at η random points.
function discover_shape!(state, modular; η=2)
    iszero(η) && (@warn "Fixing the shape of the basis from 1 point is adventurous.")
    @info "Specializing at $(1) + $(η) random points to guess the basis shape.."
    # Guess the shape for 1 lucky prime:
    polysmodp = reducemodp(state.polys_fracfree, modular)
    # specialize at a random lucky point and compute GBs
    randompoints = map(_ -> randluckyspecpoint(state, modular.ff), 1:1 + η)
    polysspecmodp = map(point -> specialize(polysmodp, point), randompoints)
    @assert all(F -> ordering(parent(first(F))) === :degrevlex, polysspecmodp)
    bases = map(F -> groebner(F, linalg=:prob), polysspecmodp)
    # decide the "right" basis according to the major rule
    basis = majorrule(bases)
    state.shape = basisshape(first(bases))
    @info "The shape of the basis is: $(length(basis)) polynomials with monomials" state.shape
    @debug "" state.shape
    nothing
end

function discover_param_degrees!(state, modular)
    @info "Specializing at random points to guess the total degrees in parameters.."
    Ru, _ = PolynomialRing(modular.ff, :u)
    K = base_ring(Ru)
    Rx = parent(first(state.polys_fracfree))
    Ra = base_ring(Rx)
    n = length(gens(Ra))
    N, D = 1, 1
    npoints = N + D + 2
    all_interpolated = false
    polysmodp = reducemodp(state.polys_fracfree, modular)
    degrees = nothing
    shift = [random_point(K) for _ in 1:n]
    while !all_interpolated
        N, D = 2N, 2D
        interpolator = FasterCauchy(Ru, N, D)
        npoints = N + D + 2
        @info "Using $npoints points.."
        univ_x_points = map(_ -> random_point(K), 1:npoints)
        x_points = map(point -> repeat([point], n) .+ shift, univ_x_points)
        coeffs = Vector{Vector{Vector{elem_type(K)}}}(undef, length(state.shape))
        for i in 1:length(state.shape)
            coeffs[i] = Vector{Vector{elem_type(K)}}(undef, length(state.shape[i]))
            for j in 1:length(state.shape[i])
                coeffs[i][j] = Vector{elem_type(K)}(undef, npoints)
            end
        end
        for (idx, point) in enumerate(x_points)
            Ip = specialize(polysmodp, point)
            @assert ordering(parent(first(Ip))) === :degrevlex
            basis = groebner(Ip, linalg=:prob)
            for i in 1:length(coeffs)
                for j in 1:length(coeffs[i])
                    coeffs[i][j][idx] = coeff(basis[i], j)
                end
            end
        end
        interpolated = Vector{Vector{Tuple{elem_type(Ru), elem_type(Ru)}}}(undef, length(state.shape))
        degrees = Vector{Vector{Tuple{Int, Int}}}(undef, length(state.shape))
        flag = true
        for i in 1:length(coeffs)
            interpolated[i] = Vector{Tuple{elem_type(Ru), elem_type(Ru)}}(undef, length(coeffs[i]))
            degrees[i] = Vector{Tuple{Int, Int}}(undef, length(coeffs[i]))
            for j in 1:length(coeffs[i])
                P, Q = interpolate!(interpolator, univ_x_points, coeffs[i][j])
                interpolated[i][j] = (P, Q)
                degrees[i][j] = (degree(P), degree(Q))
                dp, dq = degree(P), degree(Q)
                if dp < div(N, 2) && dq < div(D, 2)
                                
                else
                    flag = false
                end
            end
        end
        all_interpolated = flag
    end
    state.param_degrees = degrees
    @info "Success! $(npoints) points used."
    @info "The total degrees in the coefficients" state.param_degrees
    nothing
end

function interpolate_param_exponents!(state, modular)
    @info "Interpolating the exponents in parameters.."
    Rx = parent(first(state.polys_fracfree))
    Ra = base_ring(Rx)
    Ru, _ = PolynomialRing(modular.ff, symbols(Ra))
    K = base_ring(Ru)
    n = length(gens(Ra))
    Nt, Dt = 1, 1
    degrees = state.param_degrees
    Nd = maximum(d -> maximum(dd -> dd[1], d), degrees)
    Dd = maximum(d -> maximum(dd -> dd[2], d), degrees)
    Nds, Dds = repeat([Nd], n), repeat([Dd], n)
    all_interpolated = false
    polysmodp = reducemodp(state.polys_fracfree, modular)
    param_exponents = nothing
    npoints = nothing
    @info "Interpolating for degrees:\nnumerator $Nd, denominator $Dd"
    while !all_interpolated
        Nt, Dt = 2Nt, 2Dt
        interpolator = FasterVanDerHoevenLecerf(
            Ru, Nd, Dd, Nds, Dds, Nt, Dt
        )
        x_points = get_evaluation_points!(interpolator)
        npoints = length(x_points)
        @info "Using $npoints points.."
        coeffs = Vector{Vector{Vector{elem_type(K)}}}(undef, length(state.shape))
        for i in 1:length(state.shape)
            coeffs[i] = Vector{Vector{elem_type(K)}}(undef, length(state.shape[i]))
            for j in 1:length(state.shape[i])
                coeffs[i][j] = Vector{elem_type(K)}(undef, npoints)
            end
        end
        for (idx, point) in enumerate(x_points)
            Ip = specialize(polysmodp, point)
            @assert ordering(parent(first(Ip))) === :degrevlex
            basis = groebner(Ip, linalg=:prob)
            for i in 1:length(coeffs)
                for j in 1:length(coeffs[i])
                    coeffs[i][j][idx] = coeff(basis[i], j)
                end
            end
        end
        param_exponents = Vector{Vector{Tuple{elem_type(Ru), elem_type(Ru)}}}(undef, length(state.shape))
        flag = true
        for i in 1:length(coeffs)
            param_exponents[i] = Vector{Tuple{elem_type(Ru), elem_type(Ru)}}(undef, length(coeffs[i]))
            for j in 1:length(coeffs[i])
                P, Q = interpolate!(interpolator, coeffs[i][j])
                param_exponents[i][j] = (P, Q)
                dp, dq = total_degree(P), total_degree(Q)
                @error "??Interpolated" P Q degrees[i][j][1] degrees[i][j][2]
                if dp >= degrees[i][j][1] && dq >= degrees[i][j][2]

                else
                    flag = false
                end
            end
        end
        all_interpolated = flag
    end
    state.param_exponents = param_exponents
    @info "Success! $(npoints) points used."
    @info "The exponents in the coefficients" state.param_exponents
    nothing
end

function recover_coefficients!(state, modular)
    @info "Recovering the coefficients.."
    Rx = parent(first(state.polys_fracfree))
    Rorig = parent(first(state.polys))
    Rparam = base_ring(Rorig)
    Ra = base_ring(Rx)
    n = length(gens(Ra))
    polysreconstructed = Vector{elem_type(Rorig)}(undef, length(state.shape))
    p = convert(Int, characteristic(modular.ff))
    for i in 1:length(state.shape)
        coeffsrec = Vector{elem_type(Rparam)}(undef, length(state.shape[i]))
        for j in 1:length(state.shape[i])
            P, Q = state.param_exponents[i][j]
            Prec = map_coefficients(c -> rational_reconstruction(Int(data(c)), p), P)
            Qrec = map_coefficients(c -> rational_reconstruction(Int(data(c)), p), Q)
            coeffsrec[j] = Prec // Qrec
        end
        polysreconstructed[i] = Rorig(coeffsrec, map(e -> exponent_vector(e, 1), state.shape[i]))
    end
    state.param_coeffs = polysreconstructed
    @info "Success! Used $(1) prime in total :)"
    nothing
end

function reducemodp(polys, modular::ModularTracker)
    ff = modular.ff
    @info "Reducing modulo $(ff).."
    polysmodp = map(
        poly -> map_coefficients(
            f -> map_coefficients(
                c -> ff(c), 
                f
            ), 
            poly
        ), 
        polys
    )
    @info "Reduced!!"
    polysmodp
end

function construct_basis(state)
    state.param_coeffs
end

function specialize(polys, point)
    map(f -> map_coefficients(c -> evaluate(c, point), f), polys)
end

function majorrule(bases)
    if length(bases) == 1
        return first(bases)
    end
    # placeholder for now
    first(bases)
end

function basisshape(basis)
    map(collect ∘ monomials, basis)
end

# # Stores everything we need to know about the Groebner basis.
# mutable struct ShapeOfGb{Poly1, Poly2, Poly3, Poly4}
#     polys::Vector{Poly2}
#     fracfreepolys::Vector{Poly1}
#     specializedbasis::Vector{Poly3}
#     shape::Vector{Vector{Poly3}}
#     degrees::Vector{Vector{Tuple{Int, Int}}}
#     interpolator
#     prime::Int
#     polysmodp::Vector{Poly4}
#     count::Int
#     polysreconstructed::Vector{Poly2}
# end

# function ShapeOfGb(polys::Vector{Poly}) where {Poly}
#     Rx = parent(first(polys))
#     Ra = base_ring(base_ring(Rx))
#     K = base_ring(Ra)
#     @info "Given $(length(polys)) polynomials in K(y)[x]"
#     @info "Variables: $(gens(Rx))"
#     @info "Parameters: $(gens(Ra))"
#     # Remove denominators from the input by lifting it to a polynomial ring
#     Rspec, _ = PolynomialRing(K, map(string, gens(Rx)))
#     Rlifted, _ = PolynomialRing(Ra, map(string, gens(Rx)))
#     fractionfreepolys = liftcoeffs(polys, Rlifted)
#     @info "Lifting to K[y][x].."
#     prime = 2^31-1
#     Ramodp,_ = PolynomialRing(GF(prime), map(string, gens(Ra)))
#     Rxmodp, _ = PolynomialRing(Ramodp, map(string, gens(Rx)))
#     ShapeOfGb(
#         polys,
#         fractionfreepolys, 
#         Vector{elem_type(Ramodp)}(), 
#         Vector{Vector{elem_type(Ramodp)}}(), 
#         Vector{Vector{Tuple{Int, Int}}}(),
#         0,
#         prime,
#         Vector{elem_type(Rxmodp)}(),
#         0,
#         Vector{elem_type(Rx)}(),
#     )
# end

# function rationalreconstruct!(shapeof::ShapeOfGb)
#     Rx = parent(first(shapeof.polys))
#     Rparam = base_ring(Rx)
#     polysreconstructed = Vector{elem_type(Rx)}(undef, length(shapeof.shape))
#     p = Int(characteristic(base_ring(parent(ExactSparseInterpolations.getresult(shapeof.interpolator, 1)[2]))))
#     acc = 0
#     for i in 1:length(shapeof.shape)
#         coeffsrec = Vector{elem_type(Rparam)}(undef, length(shapeof.shape[i]))
#         for j in 1:length(shapeof.shape[i])
#             idx = acc + j
#             flag, P, Q = ExactSparseInterpolations.getresult(shapeof.interpolator, idx)
#             @assert flag
#             Prec = map_coefficients(c -> rational_reconstruction(Int(data(c)), p), P)
#             Qrec = map_coefficients(c -> rational_reconstruction(Int(data(c)), p), Q)
#             coeffsrec[j] = Prec // Qrec
#         end
#         polysreconstructed[i] = Rx(coeffsrec, map(e -> exponent_vector(e, 1), shapeof.shape[i]))
#         acc += length(shapeof.shape[i])
#     end
#     shapeof.polysreconstructed = polysreconstructed
#     nothing
# end

# function constructbasis(shapeof::ShapeOfGb)
#     shapeof.polysreconstructed
# end

# function initialize_interpolators!(shapegb::ShapeOfGb)
#     @info "Initializing interpolation routines.."
#     Rparammodp = base_ring(parent(first(shapegb.polysmodp)))
#     N, D = 0, 0
#     for i in 1:length(shapegb.degrees)
#         for j in 1:length(shapegb.degrees[i])
#             N = max(N, shapegb.degrees[i][j][1])
#             D = max(D, shapegb.degrees[i][j][2])
#         end
#     end
#     count = sum(map(length, shapegb.degrees))
#     @info "Interpolating $count coefficients at once. Interpolation is bound by degrees $N, $D"
#     shapegb.count = count
#     shapegb.interpolator = ExactSparseInterpolations.SimultaneousAdaptiveVanDerHoevenLecerf(Rparammodp, count, N, D)
# end

# function try_interpolate!(shapegb::ShapeOfGb)
#     K = base_ring(base_ring(parent(first(shapegb.polysmodp))))
#     xs = ExactSparseInterpolations.nextpoints!(shapegb.interpolator)
#     vals = Vector{Vector{elem_type(K)}}(undef, shapegb.count)
#     for i in 1:shapegb.count
#         vals[i] = Vector{elem_type(K)}(undef, length(xs))
#     end
#     for (ii, x) in enumerate(xs)
#         Ip = specializemodp(shapegb, x)
#         basis = groebner(Groebner.change_ordering(Ip, :degrevlex))
#         acc = 0
#         for i in 1:length(basis)
#             for j in 1:length(basis[i])
#                 idx = acc + j
#                 vals[idx][ii] = coeff(basis[i], j)
#             end
#             acc += length(basis[i])
#         end
#     end
#     ExactSparseInterpolations.nextevaluations!(shapegb.interpolator, vals)
#     (success=ExactSparseInterpolations.allready(shapegb.interpolator), npoints=length(xs),)
# end

# #=
#     Discovers the exponents in the groebner basis
#     by specializing it at random points.

#     If η > 0 is given, the algorithm will take η 
#     additional steps in the interpolation to confirm the degrees.
# =#
# function discover_degrees!(shapegb::ShapeOfGb; η=2)
#     @info "Specializing at random points to guess the exponents in the coefficients.."
#     Ru, _ = PolynomialRing(base_ring(base_ring(first(shapegb.polysmodp))), :u)
#     interpolators = [
#         [
#             ExactSparseInterpolations.AdaptiveCauchy(Ru)
#             for _ in 1:length(shapegb.shape[i])
#         ]
#         for i in 1:length(shapegb.shape)
#     ]
#     statuses = [
#         [false for _ in 1:length(shapegb.shape[i])]
#         for i in 1:length(shapegb.shape)
#     ]
#     ηs = [
#         [η for _ in 1:length(shapegb.shape[i])]
#         for i in 1:length(shapegb.shape)
#     ]
#     degrees = [
#         [(-1, -1) for _ in 1:length(shapegb.shape[i])]
#         for i in 1:length(shapegb.shape)
#     ]
#     one_of_a_kind = ExactSparseInterpolations.AdaptiveCauchy(Ru)
#     all_interpolated = false
#     a = randpointmodp(shapegb)
#     s = randpointmodp(shapegb)
#     ip = 0
#     while !all_interpolated
#         ip += 1
#         if ispow2(ip)
#             @info "$ip points used.."
#         end
#         x_point = ExactSparseInterpolations.next_point!(one_of_a_kind)
#         # shift !!!
#         Ip = specializemodp(shapegb, a .* x_point .+ s)
#         basis = groebner(Groebner.change_ordering(Ip, :degrevlex))
#         # !assert_shape!(shapegb, basis) && continue
#         for i in 1:length(basis)
#             for (j, (interpolator, status)) in enumerate(zip(interpolators[i], statuses[i]))
#                 # if already interpolated
#                 status && continue
#                 y_point = coeff(basis[i], j)
#                 success, (P, Q) = ExactSparseInterpolations.next!(interpolator, x_point, y_point)
#                 degrees[i][j] = (degree(P), degree(Q))
#                 statuses[i][j] = success
#                 # if more than one consecutive success is needed
#                 if success && !iszero(ηs[i][j])
#                     statuses[i][j] = false
#                     ηs[i][j] -= 1
#                 end
#             end
#         end
#         all_interpolated = all(map(all, statuses))
#     end
#     shapegb.degrees = degrees
#     @info "Success! $(ip) points used."
#     @info "The exponents in the coefficients" degrees
#     shapegb.degrees
# end
