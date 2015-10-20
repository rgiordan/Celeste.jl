# Convert between different parameterizations.

module Transform

using Celeste
using CelesteTypes
using Compat

import Util
VERSION < v"0.4.0-dev" && using Docile

export DataTransform, ParamBounds, ParamBox
export get_mp_transform, generate_valid_parameters


immutable ParamBox{T <: @compat(Union{Float64, Vector{Float64}})}
    lb::T
    ub::T
    rescaling::T
end

# The box bounds for a symbol.  The tuple contains
# (lower bounds, upper bound, rescaling).
typealias ParamBounds Dict{Symbol, ParamBox}

#####################
# Conversion to and from vectors.

function free_vp_to_array{NumType <: Number}(vp::FreeVariationalParams{NumType},
                                             omitted_ids::Vector{Int64})
    # vp = variational parameters
    # omitted_ids = ids in ParamIndex
    #
    # There is probably no use for this function, since you'll only be passing
    # trasformations to the optimizer, but I'll include it for completeness.

    left_ids = setdiff(1:length(UnconstrainedParams), omitted_ids)
    new_P = length(left_ids)
    S = length(vp)
    x_new = zeros(NumType, new_P, S)

    for p1 in 1:length(left_ids), s=1:S
        p0 = left_ids[p1]
        x_new[p1, s] = vp[s][p0]
    end

    x_new
end

@doc """
Transform a parameter vector to variational parameters in place.

Args:
 - xs: A (param x sources) matrix created from free variational parameters.
 - vp_free: Free variational parameters.  Only the ids not in omitted_ids
            will be updated.
 - omitted_ids: Ids to omit (from ids_free)

Returns:
 - Update vp_free in place.
""" ->
function array_to_free_vp!{NumType <: Number}(
    xs::Matrix{NumType}, vp_free::FreeVariationalParams{NumType},
    omitted_ids::Vector{Int64})

    left_ids = setdiff(1:length(UnconstrainedParams), omitted_ids)
    P = length(left_ids)
    S = length(vp_free)
    @assert size(xs) == (P, S)

    for s in 1:S, p1 in 1:P
        p0 = left_ids[p1]
        vp_free[s][p0] = xs[p1, s]
    end
end


###############################################
# Functions for a "free transform".

function unbox_parameter{NumType <: Number}(
  param::@compat(Union{NumType, Array{NumType}}),
  lower_bound::@compat(Union{Float64, Array{Float64}}),
  upper_bound::@compat(Union{Float64, Array{Float64}}),
  scale::@compat(Union{Float64, Array{Float64}}))

    positive_constraint = any(upper_bound .== Inf)
    if positive_constraint && !all(upper_bound .== Inf)
      error("unbox_parameter: Some but not all upper bounds are Inf: $upper_bound")
    end

    # exp and the logit functions handle infinities correctly, so
    # parameters can equal the bounds.
    @assert(all(lower_bound .<= real(param) .<= upper_bound),
            string("unbox_parameter: param outside bounds: ",
                   "$param ($lower_bound, $upper_bound)"))

    if positive_constraint
      return log(param - lower_bound) .* scale
    else
      param_bounded = (param - lower_bound) ./ (upper_bound - lower_bound)
      return Util.inv_logit(param_bounded) .* scale
    end
end

function box_parameter{NumType <: Number}(
  free_param::@compat(Union{NumType, Array{NumType}}),
  lower_bound::@compat(Union{Float64, Array{Float64}}),
  upper_bound::@compat(Union{Float64, Array{Float64}}),
  scale::@compat(Union{Float64, Array{Float64}}))

  positive_constraint = any(upper_bound .== Inf)
  if positive_constraint && !all(upper_bound .== Inf)
    error("box_parameter: Some but not all upper bounds are Inf: $upper_bound")
  end
  if positive_constraint
    return (exp(free_param ./ scale) + lower_bound)
  else
    return Util.logit(free_param ./ scale) .*
           (upper_bound - lower_bound) + lower_bound
  end
end

@doc """
Updates free_deriv in place.  <param> is the parameter that lies
within the box constrains, and <deriv> is the derivative with respect
to these paraemters.
""" ->
function unbox_derivative{NumType <: Number}(
  param::@compat(Union{NumType, Array{NumType}}),
  deriv::@compat(Union{NumType, Array{NumType}}),
  lower_bound::@compat(Union{Float64, Array{Float64}}),
  upper_bound::@compat(Union{Float64, Array{Float64}}),
  scale::@compat(Union{Float64, Array{Float64}}))
    @assert(length(param) == length(deriv),
            "Wrong length parameters for unbox_sensitive_float")

    positive_constraint = any(upper_bound .== Inf)
    if positive_constraint && !all(upper_bound .== Inf)
      error(string("unbox_derivative: Some but not all upper bounds are Inf: ",
                   "$upper_bound"))
    end

    # Strict inequality is not required for derivatives.
    @assert(all(lower_bound .<= real(param) .<= upper_bound),
            string("unbox_derivative: param outside bounds: ",
                   "$param ($lower_bound, $upper_bound)"))

    if positive_constraint
      return deriv .* (param - lower_bound) ./ scale
    else
      # Box constraints.
      param_scaled = (param - lower_bound) ./ (upper_bound - lower_bound)
      return (deriv .* param_scaled .*
              (1 - param_scaled) .* (upper_bound - lower_bound) ./ scale)
    end
end

######################
# Functions to take actual parameter vectors.

# Treat the simplex bounds separately.
const simplex_min = 0.005

@doc """
Convert a variational parameter vector to an unconstrained version using
the lower bounds lbs and ubs (which are expressed)
""" ->
function vp_to_free!{NumType <: Number}(
  vp::Vector{NumType}, vp_free::Vector{NumType}, bounds::ParamBounds)
    # Simplicial constriants.

    # The original script used "a" to only
    # refer to the probability of being a galaxy, which is now the
    # second component of a.
    vp_free[ids_free.a[1]] =
      unbox_parameter(vp[ids.a[2]], simplex_min, 1 - simplex_min, 1.0)

    # In contrast, the original script used the last component of k
    # as the free parameter.
    vp_free[ids_free.k[1, :]] =
      unbox_parameter(vp[ids.k[1, :]], simplex_min, 1 - simplex_min, 1.0)

    # Box constraints.
    for (param, limits) in bounds
        vp_free[ids_free.(param)] =
          unbox_parameter(vp[ids.(param)], limits.lb, limits.ub, limits.rescaling)
    end
end


function free_to_vp!{NumType <: Number}(
  vp_free::Vector{NumType}, vp::Vector{NumType}, bounds::ParamBounds)
    # Convert an unconstrained to an constrained variational parameterization.

    # Simplicial constriants.
    vp[ids.a[2]] =
      box_parameter(vp_free[ids_free.a[1]], simplex_min, 1.0 - simplex_min, 1.0)
    vp[ids.a[1]] = 1.0 - vp[ids.a[2]]

    vp[ids.k[1, :]] =
      box_parameter(vp_free[ids_free.k[1, :]], simplex_min, 1.0 - simplex_min, 1.0)
    vp[ids.k[2, :]] = 1.0 - vp[ids.k[1, :]]

    # Box constraints.
    for (param, limits) in bounds
        vp[ids.(param)] =
          box_parameter(vp_free[ids_free.(param)], limits.lb, limits.ub, limits.rescaling)
    end
end


@doc """
Return the derviatives with respect to the unboxed
parameters given derivatives with respect to the boxed parameters.
""" ->
function unbox_param_derivative{NumType <: Number}(
  vp::Vector{NumType}, d::Vector{NumType}, bounds::ParamBounds)

  d_free = zeros(NumType, length(UnconstrainedParams))

  # TODO: write in general form.  Note that the old "a" is now a[2].
  # Simplicial constriants.
  d_free[ids_free.a[1]] =
    unbox_derivative(vp[ids.a[2]], d[ids.a[2]] - d[ids.a[1]],
                     simplex_min, 1.0 - simplex_min, 1.0)

  this_k = collect(vp[ids.k[1, :]])
  d_free[collect(ids_free.k[1, :])] =
      (d[collect(ids.k[1, :])] -
       d[collect(ids.k[2, :])]) .* this_k .* (1.0 - this_k)
  d_free[collect(ids_free.k[1, :])] =
    unbox_derivative(collect(vp[ids.k[1, :]]),
                     d[collect(ids.k[1, :])] - d[collect(ids.k[2, :])],
                     simplex_min, 1.0 - simplex_min, 1.0)

  for (param, limits) in bounds
      d_free[ids_free.(param)] =
        unbox_derivative(vp[ids.(param)], d[ids.(param)],
                         limits.lb, limits.ub, limits.rescaling)
  end

  d_free
end

@doc """
Generate parameters within the given bounds.
""" ->
function generate_valid_parameters(
  NumType::DataType, bounds::Vector{ParamBounds})

  @assert NumType <: Number
  S = length(bounds)
  vp = convert(VariationalParams{NumType},
	             [ zeros(NumType, length(ids)) for s = 1:S ])
	for s=1:S
		for (param, limits) in bounds[s]
			if (limits.ub == Inf)
	    	vp[s][ids.(param)] = limits.lb + 1.0
			else
				vp[s][ids.(param)] = 0.5 * (limits.ub - limits.lb) + limits.lb
			end
	  end
    # Simplex parameters
    vp[s][ids.a] = 1 / Ia
    vp[s][collect(ids.k)] = 1 / D
	end

  vp
end


#########################
# Define the exported variables.

@doc """
Functions to move between a single source's variational parameters and a
transformation of the data for optimization.

to_vp: A function that takes transformed parameters and returns
       variational parameters
from_vp: A function that takes variational parameters and returned
         transformed parameters
to_vp!: A function that takes (transformed paramters, variational parameters)
        and updates the variational parameters in place
from_vp!: A function that takes (variational paramters, transformed parameters)
          and updates the transformed parameters in place
...
transform_sensitive_float: A function that takes (sensitive float, model
  parameters) where the sensitive float contains partial derivatives with
  respect to the variational parameters and returns a sensitive float with total
  derivatives with respect to the transformed parameters. """ ->
type DataTransform
	to_vp::Function
	from_vp::Function
	to_vp!::Function
	from_vp!::Function
  vp_to_array::Function
  array_to_vp!::Function
	transform_sensitive_float::Function
  bounds::Vector{ParamBounds}
end

DataTransform(bounds::Vector{ParamBounds}) = begin

  # Make sure that each variable has its bounds set.
  for s=1:length(bounds)
    @assert Set(keys(bounds[s])) == Set(setdiff(fieldnames(ids), [:a, :k]))
  end

  function from_vp!{NumType <: Number}(
    vp::VariationalParams{NumType}, vp_free::VariationalParams{NumType})
      S = length(vp)
      @assert S == length(bounds)
      for s=1:S
        vp_to_free!(vp[s], vp_free[s], bounds[s])
      end
  end

  function from_vp{NumType <: Number}(vp::VariationalParams{NumType})
      vp_free = [ zeros(NumType, length(ids_free)) for s = 1:length(vp)]
      from_vp!(vp, vp_free)
      vp_free
  end

  function to_vp!{NumType <: Number}(
    vp_free::FreeVariationalParams{NumType}, vp::VariationalParams{NumType})
      S = length(vp_free)
      @assert S == length(bounds)
      for s=1:S
        free_to_vp!(vp_free[s], vp[s], bounds[s])
      end
  end

  function to_vp{NumType <: Number}(vp_free::FreeVariationalParams{NumType})
      vp = [ zeros(length(CanonicalParams)) for s = 1:length(vp_free)]
      to_vp!(vp_free, vp)
      vp
  end

  function vp_to_array{NumType <: Number}(vp::VariationalParams{NumType},
                                           omitted_ids::Vector{Int64})
      vp_trans = from_vp(vp)
      free_vp_to_array(vp_trans, omitted_ids)
  end

  function array_to_vp!{NumType <: Number}(xs::Matrix{NumType},
                                           vp::VariationalParams{NumType},
                                           omitted_ids::Vector{Int64})
      # This needs to update vp in place so that variables in omitted_ids
      # stay at their original values.
      vp_trans = from_vp(vp)
      array_to_free_vp!(xs, vp_trans, omitted_ids)
      to_vp!(vp_trans, vp)
  end

  # Given a sensitive float with derivatives with respect to all the
  # constrained parameters, calculate derivatives with respect to
  # the unconstrained parameters.
  #
  # Note that all the other functions in ElboDeriv calculated derivatives with
  # respect to the constrained parameterization.
  function transform_sensitive_float{NumType <: Number}(
    sf::SensitiveFloat, mp::ModelParams{NumType})

      # Require that the input have all derivatives defined.
      @assert size(sf.d) == (length(CanonicalParams), mp.S)
      @assert mp.S == length(bounds)

      sf_free = zero_sensitive_float(UnconstrainedParams, NumType, mp.S)
      sf_free.v = sf.v

      for s in 1:mp.S
        sf_free.d[:, s] =
          unbox_param_derivative(mp.vp[s], sf.d[:, s][:], bounds[s])
      end

      sf_free
  end

  DataTransform(to_vp, from_vp, to_vp!, from_vp!, vp_to_array, array_to_vp!,
                transform_sensitive_float, bounds)
end

function get_mp_transform(mp::ModelParams; loc_width::Float64=1e-3)
  bounds = Array(ParamBounds, mp.S)

  # Note that, for numerical reasons, the bounds must be on the scale
  # of reasonably meaningful changes.
  for s=1:mp.S
    bounds[s] = ParamBounds()
    u = mp.vp[s][ids.u]
    bounds[s][:u] = ParamBox(u - loc_width, u + loc_width, ones(2))
    bounds[s][:r1] = ParamBox(1e-4, Inf, 1e-2)
    bounds[s][:r2] = ParamBox(1e-4, 0.1, 1.0)
    bounds[s][:c1] = ParamBox(-10., 10., 1.0)
    bounds[s][:c2] = ParamBox(1e-4, 1., 1.0)
    bounds[s][:e_dev] = ParamBox(1e-2, 1 - 1e-2, 1.0)
    bounds[s][:e_axis] = ParamBox(1e-2, 1 - 1e-2, 1.0)
    bounds[s][:e_angle] = ParamBox(-10.0, 10.0, 1.0)
    bounds[s][:e_scale] = ParamBox(0.1, 70., 1.0)
  end
  DataTransform(bounds)
end


end
