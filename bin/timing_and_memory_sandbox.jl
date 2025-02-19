
using Celeste
using CelesteTypes
using Base.Test
using SampleData
import Synthetic
import Transform
import ForwardDiff



function foo{VecType <: Union{Number, Array{Number}}}(
  x::VecType)
  sum(x)
end



blob, mp, bodies, tiled_blob = gen_two_body_dataset();

trans = Transform.get_mp_transform(mp);

function unwrap_param_vector{NumType <: Number}(
    vp_vec::Vector{NumType}, S::Int64, P::Int64)

  function source_indices(s::Int64)
    s1 = P * (s - 1) + 1
    s1:(s1 + P - 1)
  end

  Array{NumType, 1}[ vp_vec[source_indices(s)] for s=1:S ]
end

vp_vec = reduce(vcat, mp.vp)
function from_vp_wrapper{NumType <: Number}(vp_vec::Vector{NumType})
  vp = unwrap_param_vector(vp_vec, mp.S, length(CanonicalParams))
  reduce(vcat, trans.from_vp(vp))
end

function from_vp_component_wrapper{NumType <: Number}(vp_vec::Vector{NumType}, i::Int64)
  vp = unwrap_param_vector(vp_vec, mp.S, length(CanonicalParams))
  reduce(vcat, trans.from_vp(vp))[i]
end


trans_derivs = TransformDerivatives{Float64}(mp.S);
for (param, limits) in trans.bounds
    d_free[ids_free.(param)] =
      unbox_derivative(vp[ids.(param)], d[ids.(param)],
                       limits.lb, limits.ub, limits.rescaling)
end






# Matrix multiplication is faster than for loops even with a transpose.
trials = 100000
n1 = 7
n2 = 3
x = rand(n2, n1);
y = rand(n2);
z = zeros(n1);

function TransMult!(z, x, y)
  fill!(z, 0.0);
  for i = 1:n1, j = 1:n2
    z[i] += x[j, i] * y[j]
  end
end

@time begin
for t in 1:trials
  TransMult!(z, x, y)
end
end

@time begin
for t in 1:trials
  fill!(z, 0.0);
  z = (x') * y;
end
end

# Tensor multiplication
trials = 100000
n = 3

x = rand(n, n, n);
y = rand(n);
z = zeros(n, n);

@time begin
for t in 1:trials
  fill!(z, 0.0)
  for i=1:n, j=1:n, k=1:n
    z[i, j] += x[i, j, k] * y[k]
  end
end
end

@time begin
for t in 1:trials
  z = Float64[ dot(y, x[i, j, :][:]) for i=1:n, j=1:n]
end
end



# For loops are comparable to direct computations, but slightly slower here.
# (In BivariateNormals for loops are faster for some reason.)
trials = 10000
n = 10
x = rand(3, n);
y = rand(3);
z = zeros(n);

@time begin
for t in 1:trials
  fill!(z, 0.0);
  for i = 1:n, j = 1:3
    z[i] += x[j, i] * y[j]
  end
end
end

@time begin
for t in 1:trials
  for i = 1:n
    z[i] = x[1, i] * y[1] + x[2, i] * y[2] + x[2, i] * y[2]
  end
end
end



# Are types making it slower?
trials = 100000
n = 10
type MyType
  z::Vector{Float64}
end

type MyType2
  x::Matrix{Float64}
end

x = rand(n, n);
y = rand(n);
z = zeros(n);

ztype = MyType(z);
xtype = MyType2(x);

@time begin
for t in 1:trials
  ztype.z[:] = x * y
end
end

@time begin
for t in 1:trials
    ztype.z[:] = xtype.x * y
end
end









################# Experimenting with BLAS and timing and memory

n = 1000
a = rand(n);
b = rand(n);
c = zeros(n, n);

@time BLAS.gemm!('N', 'T', 1.0, a, b, 1.0, c);
@time c[:,:] = a * b';


a = rand(n, 2);
b = rand(n, 2);
c = zeros(2 * n, 2 * n);
@time BLAS.ger!(1.0, a[:], b[:], c);
cblas = deepcopy(c);

# A little faster.
@time af = a[:]; bf = b[:];
c = zeros(2 * n, 2 * n);
@time BLAS.ger!(1.0, af, bf, c);

c = zeros(2 * n, 2 * n);
@time c = a[:] * b[:]';
cjul = deepcopy(c);
@test_approx_eq cjul cblas;

n = 3000
r1 = rand(n, n);

function f1!(r0, r)
  r0[:, :] = r + r0
end

function f2!(r0, r)
  for i1 = 1:n, i2 = 1:n
    r0[i1, i2] = r[i1, i2] + r0[i1, i2]
  end
end

function f3!(r0, r)
  r0 += r
end

function f4!(r0, r)
  r0[:, :] = r[:, :] + r0[:, :]
end


r0 = ones(n, n);
@time f1!(r0, r1);

# So slow
# r0 = ones(n, n);
# @time f2!(r0, r1);

r0 = ones(n, n);
@time f3!(r0, r1);

r0 = ones(n, n);
@time f4!(r0, r1);


using Base.Test
n = 1000;
x = rand(n, n);
y = zeros(n, n);
@time BLAS.blascopy!(n * n, x, 1, y, 1);
@test_approx_eq x y

@time x = deepcopy(y);


n = 1000;
y = rand(2 * n, 2 * n);
y_sub = y[1:n, 1:n];

x = zeros(n, n);
@time x[:, :] += 3.0 * y[1:n, 1:n];
x = zeros(n, n);
@time BLAS.axpy!(3.0, y[1:n, 1:n], x);
x = zeros(n, n);
@time BLAS.axpy!(3.0, y_sub, x);

######
n = 100;
x = rand(n, n);
sub_ind = 2 * (1:n)
sub_ind_col = collect(sub_ind);

y = zeros(2 * n, 2 * n);
@time y[sub_ind, sub_ind] += 3.0 * x;
y = zeros(2 * n, 2 * n);

# These each allocate less memory as you go down.
@time y[sub_ind_col, sub_ind_col] += 3.0 * x;
@time y[sub_ind_col, sub_ind_col] = 3.0 * x;
@time y[sub_ind, sub_ind] = x;
@time y[sub_ind_col, sub_ind_col] = x;

# Dig that this doesn't work.
y = zeros(2 * n, 2 * n);
@time BLAS.axpy!(3.0, x, y[sub_ind, sub_ind]);

# Neither does this.
y = zeros(2 * n, 2 * n);
y_sub = y[sub_ind, sub_ind];
@time BLAS.axpy!(3.0, x, y_sub);

# This allocates a ton of memory.
y = zeros(2 * n, 2 * n);
@time begin
  for i1 in 1:length(sub_ind), i2 in 1:length(sub_ind)
    j1 = sub_ind[i1]
    j2 = sub_ind[i2]
    z = 3 * x[i1, i2] + y[j1, j2]
    #y[j1, j2] += 3 * x[i1, i2]
    y[j1, j2] = z
  end
end
# n = 1000;   0.726820 seconds (7.47 M allocations: 129.318 MB, 12.70% gc time)
# n = 100;   0.005881 seconds (50.20 k allocations: 943.781 KB)

# This allocates a ton of memory.
y = zeros(2 * n, 2 * n);
@time begin
  for i in eachindex(x)
    i1, i2 = ind2sub(size(x), i)
    j1 = sub_ind[i1]
    j2 = sub_ind[i2]
    y[j1, j2] += 3 * x[i1, i2]
  end
end




n = 10000
y = ones(n);
x = rand(n);

@time begin
  for i1 = 1:n
    y[i1] += x[i1] * 3
  end
end

z = 0.0
@time begin
  for i1 = 1:n
    z = x[i1] * 3 + y[i1]
    y[i1] = z
  end
end

z = 0.0
@time begin
  for i1 = 1:n
    global z
    z = x[i1] * 3 + y[i1]
    y[i1] = z
  end
end


n = 100
y = rand(n, n);
@time fill!(y, 0.0);
@time y[:, :] = 0.0;
z = fill(0.0, 1, 1);
# @time BLAS.blascopy!(n * n, y, 1, z, 1); # segfault!



# eachindex doens't make loops faster.
n = collect(1:10) + 20
@time begin
  for i = 1:100000
    for j=1:length(n)
      x = 2 * n[j]
    end
  end
end

@time begin
  for i = 1:100000
    for j in eachindex(n)
      x = 2 * n[j]
    end
  end
end



#
