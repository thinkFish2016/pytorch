#include <ATen/Dispatch.h>
#include <ATen/ExpandUtils.h>
#include <ATen/NativeFunctions.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>
#include <ATen/AccumulateType.h>
#include <ATen/CUDAGenerator.h>
#include <ATen/native/UnaryOps.h>
#include <ATen/native/cuda/DistributionTemplates.h>

#include <curand.h>
#include <curand_kernel.h>
#include <curand_philox4x32_x.h>
#include <utility>
#include <functional>

#include <ATen/native/Distributions.h>
#include <ATen/native/cuda/Loops.cuh>
#include <ATen/native/TensorIterator.h>
#include <ATen/LegacyTHFunctionsCUDA.h>

#include <THC/THCGeneral.h>
#include <THC/THCApply.cuh>
#include <THC/THCDeviceUtils.cuh>

#include <cstdint>
#include <cmath>
#include <limits>
#include <utility>
#include <type_traits>


namespace {

template <typename scalar_t>
void poisson_cuda_kernel(
    at::Tensor& ret,
    const at::Tensor& lambda,
    std::pair<uint64_t, uint64_t> seeds) {
  at::TensorIterator iter;
  iter.add_output(ret);
  iter.add_input(lambda);
  iter.build();
  bool initialized = false;
  curandStatePhilox4_32_10_t state;
  at::native::gpu_kernel(iter,
    [seeds, state, initialized] GPU_LAMBDA (scalar_t lambda) mutable -> scalar_t {
      #if defined(__CUDA_ARCH__) || defined(__HIP_PLATFORM_HCC__)
      if (!initialized) {
        curand_init(
            seeds.first,
            blockIdx.x * blockDim.x + threadIdx.x,
            seeds.second,
            &state);
        initialized = true;
      }
      return static_cast<scalar_t>(curand_poisson(&state, lambda));
      #else
      return static_cast<scalar_t>(std::nan(""));  // just to avoid compiler warning
      #endif
    });
}

struct curand_uniform_wrapper {
  curandStatePhilox4_32_10_t &state;
  __device__ curand_uniform_wrapper(curandStatePhilox4_32_10_t &state): state(state) {}
  __device__ float operator()() {
    return curand_uniform(&state);
  }
};

struct curand_normal_wrapper {
  curandStatePhilox4_32_10_t &state;
  __device__ curand_normal_wrapper(curandStatePhilox4_32_10_t &state): state(state) {}
  __device__ float operator()() {
    return curand_normal(&state);
  }
};

template <typename scalar_t>
void gamma_cuda_kernel(
    at::Tensor& ret,
    const at::Tensor& alpha,
    std::pair<uint64_t, uint64_t> seeds) {
  using accscalar_t = at::acc_type<scalar_t, true>;
  at::TensorIterator iter;
  iter.add_output(ret);
  iter.add_input(alpha);
  iter.build();

  at::native::gpu_kernel(iter,
    [seeds] GPU_LAMBDA (scalar_t alpha) {
      #if defined(__CUDA_ARCH__) || defined(__HIP_PLATFORM_HCC__)
      curandStatePhilox4_32_10_t state;
      curand_init(
          seeds.first,
          blockIdx.x * blockDim.x + threadIdx.x,
          seeds.second,
          &state);

      auto uniform_lambda = curand_uniform_wrapper(state);
      BaseSampler<accscalar_t, decltype(uniform_lambda)> standard_uniform(uniform_lambda);

      auto normal_lambda = curand_normal_wrapper(state);
      BaseSampler<accscalar_t, decltype(normal_lambda)> standard_normal(normal_lambda);
      auto sample = sample_gamma<scalar_t, accscalar_t, decltype(uniform_lambda), decltype(normal_lambda)>(alpha, standard_uniform, standard_normal);
      auto min_value = std::numeric_limits<scalar_t>::min();
      return (min_value > sample) ? min_value : sample;
      #else
      return alpha;  //useless
      #endif
    });
}

template<typename scalar_t>
void dirichlet_scalar_cuda_kernel(
    at::Tensor& ret,
    const at::Tensor& gamma) {
  auto gamma_sum = gamma.sum(-1, true);
  at::TensorIterator iter;
  iter.add_output(ret);
  iter.add_input(gamma);
  iter.add_input(gamma_sum);
  iter.build();
  at::native::gpu_kernel(iter,
    [] GPU_LAMBDA (scalar_t gamma, scalar_t gamma_sum) {
      auto ret_val = gamma / gamma_sum;
      auto min_value = std::numeric_limits<scalar_t>::min();
      auto max_value = 1 - std::numeric_limits<scalar_t>::epsilon();
      ret_val = (min_value > ret_val) ? min_value : ret_val;
      ret_val = (max_value < ret_val) ? max_value : ret_val;
      return ret_val;
    });
}

} // namespace

namespace at { namespace native {

Tensor _s_poisson_cuda(const Tensor& lambda, Generator gen_) {
  auto gen = get_generator_or_default<CUDAGenerator>(gen_, cuda::detail::getDefaultCUDAGenerator());
  std::pair<uint64_t, uint64_t> rng_engine_inputs;
  {
    // See Note [Acquire lock when using random generators]
    std::lock_guard<std::mutex> lock(gen->mutex_);
    rng_engine_inputs = gen->philox_engine_inputs(20);
  }
  Tensor ret = at::empty(lambda.sizes(), lambda.options());
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, ret.scalar_type(), "poisson_cuda", [&] {
    poisson_cuda_kernel<scalar_t>(ret, lambda, rng_engine_inputs);
  });
  return ret;
}

Tensor _s_gamma_cuda(const Tensor& alpha, Generator gen_) {
  auto gen = get_generator_or_default<CUDAGenerator>(gen_, cuda::detail::getDefaultCUDAGenerator());
  std::pair<uint64_t, uint64_t> rng_engine_inputs;
  {
    // See Note [Acquire lock when using random generators]
    std::lock_guard<std::mutex> lock(gen->mutex_);
    rng_engine_inputs = gen->philox_engine_inputs(10);
  }
  Tensor ret = at::empty(alpha.sizes(), alpha.options());
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, ret.scalar_type(), "gamma_cuda", [&] {
     gamma_cuda_kernel<scalar_t>(ret, alpha, rng_engine_inputs);
   });
  return ret;
}

Tensor _s_dirichlet_cuda(const Tensor& alpha, Generator gen_) {
  auto gen = get_generator_or_default<CUDAGenerator>(gen_, cuda::detail::getDefaultCUDAGenerator());
  std::pair<uint64_t, uint64_t> rng_engine_inputs;
  {
    // See Note [Acquire lock when using random generators]
    std::lock_guard<std::mutex> lock(gen->mutex_);
    rng_engine_inputs = gen->philox_engine_inputs(10);
  }
  Tensor ret = at::empty(alpha.sizes(), alpha.options());
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, ret.scalar_type(), "dirichlet", [&] {
    Tensor gamma = at::empty(alpha.sizes(), alpha.options());
    gamma_cuda_kernel<scalar_t>(gamma, alpha, rng_engine_inputs);
    dirichlet_scalar_cuda_kernel<scalar_t>(ret, gamma);
  });
  return ret;
}

Tensor _standard_gamma_grad_cuda(const Tensor& self, const Tensor& output) {
  Tensor ret = at::empty(self.sizes(), self.options());
  TensorIterator iter;
  iter.add_output(ret);
  iter.add_input(self);
  iter.add_input(output);
  iter.build();
  AT_DISPATCH_FLOATING_TYPES_AND2(at::ScalarType::Half, at::ScalarType::BFloat16, iter.common_dtype(), "_standard_gamma_grad_cuda", [&] {
    using accscalar_t = at::acc_type<scalar_t, true>;
    gpu_kernel(iter,
      [] GPU_LAMBDA (scalar_t self_val, scalar_t output_val) {
        return standard_gamma_grad_one<scalar_t, accscalar_t>(self_val, output_val);
      });
  });
  return ret;
}

Tensor _dirichlet_grad_cuda(const Tensor& x, const Tensor& alpha, const Tensor& total) {
  Tensor ret = at::empty(x.sizes(), x.options());
  TensorIterator iter;
  iter.add_output(ret);
  iter.add_input(x);
  iter.add_input(alpha);
  iter.add_input(total);
  iter.build();
  AT_DISPATCH_FLOATING_TYPES(x.scalar_type(), "_dirichlet_grad_cuda", [&] {
    using accscalar_t = at::acc_type<scalar_t, true>;
    gpu_kernel(iter,
      [] GPU_LAMBDA (scalar_t x_val, scalar_t alpha_val, scalar_t total_val) -> scalar_t {
        return dirichlet_grad_one<scalar_t, accscalar_t>(x_val, alpha_val, total_val);
      });
  });
  return ret;
}

}} // namespace at::native
