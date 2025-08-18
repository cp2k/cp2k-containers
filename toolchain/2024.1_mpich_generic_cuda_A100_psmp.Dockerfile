#
# This file was created by generate_docker_files.py
#
# Usage: docker build -f ./2024.1_mpich_generic_cuda_A100_psmp.Dockerfile -t cp2k/cp2k:2024.1_mpich_generic_cuda_A100_psmp .

# Stage 1: build step
FROM nvidia/cuda:12.2.0-devel-ubuntu22.04 AS build

# Setup CUDA environment
ENV CUDA_PATH /usr/local/cuda
ENV LD_LIBRARY_PATH /usr/local/cuda/lib64

# Disable JIT cache as there seems to be an issue with file locking on overlayfs
# See also https://github.com/cp2k/cp2k/pull/2337
ENV CUDA_CACHE_DISABLE 1

# Install packages required for the CP2K toolchain build
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    g++ gcc gfortran libmpich-dev mpich openssh-client python3 libtool libtool-bin \
    bzip2 ca-certificates git make patch pkg-config unzip wget zlib1g-dev

# Download CP2K
RUN git clone --recursive -b support/v2024.1 https://github.com/cp2k/cp2k.git /opt/cp2k

# Build CP2K toolchain for target CPU generic
WORKDIR /opt/cp2k/tools/toolchain
RUN /bin/bash -c -o pipefail \
    "./install_cp2k_toolchain.sh -j 8 \
     --install-all \
     --enable-cuda=yes --gpu-ver=A100 --with-deepmd=no --with-libtorch=no \
     --target-cpu=generic \
     --with-cusolvermp=no \
     --with-gcc=system \
     --with-mpich=system"

# Build CP2K for target CPU generic
WORKDIR /opt/cp2k
RUN /bin/bash -c -o pipefail \
    "cp ./tools/toolchain/install/arch/local_cuda.psmp ./arch/; \
     source ./tools/toolchain/install/setup; \
     make -j 8 ARCH=local_cuda VERSION=psmp"

# Collect components for installation and remove symbolic links
RUN /bin/bash -c -o pipefail \
    "mkdir -p /toolchain/install /toolchain/scripts; \
     for libdir in \$(ldd ./exe/local_cuda/cp2k.psmp | \
                      grep /opt/cp2k/tools/toolchain/install | \
                      awk '{print \$3}' | cut -d/ -f7 | \
                      sort | uniq) setup; do \
        cp -ar /opt/cp2k/tools/toolchain/install/\${libdir} /toolchain/install; \
     done; \
     cp /opt/cp2k/tools/toolchain/scripts/tool_kit.sh /toolchain/scripts; \
     unlink ./exe/local_cuda/cp2k.popt; \
     unlink ./exe/local_cuda/cp2k_shell.psmp"

# Stage 2: install step
FROM nvidia/cuda:12.2.0-devel-ubuntu22.04 AS install

# Install required packages
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    g++ gcc gfortran libmpich-dev mpich openssh-client python3 && rm -rf /var/lib/apt/lists/*

# Install CP2K binaries
COPY --from=build /opt/cp2k/exe/local_cuda/ /opt/cp2k/exe/local_cuda/

# Install CP2K regression tests
COPY --from=build /opt/cp2k/tests/ /opt/cp2k/tests/
COPY --from=build /opt/cp2k/tools/regtesting/ /opt/cp2k/tools/regtesting/
COPY --from=build /opt/cp2k/src/grid/sample_tasks/ /opt/cp2k/src/grid/sample_tasks/

# Install CP2K database files
COPY --from=build /opt/cp2k/data/ /opt/cp2k/data/

# Install shared libraries required by the CP2K binaries
COPY --from=build /toolchain/ /opt/cp2k/tools/toolchain/

# Create links to CP2K binaries
RUN /bin/bash -c -o pipefail \
    "for binary in cp2k dumpdcd graph xyz2dcd; do \
        ln -sf /opt/cp2k/exe/local_cuda/\${binary}.psmp \
               /usr/local/bin/\${binary}; \
     done; \
     ln -sf /opt/cp2k/exe/local_cuda/cp2k.psmp \
            /usr/local/bin/cp2k_shell; \
     ln -sf /opt/cp2k/exe/local_cuda/cp2k.psmp \
            /usr/local/bin/cp2k.popt"

# Create entrypoint script file
RUN printf "#!/bin/bash\n\
ulimit -c 0 -s unlimited\n\
export CUDA_CACHE_DISABLE=1\n\
export CUDA_PATH=/usr/local/cuda\n\
export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH}:\${CUDA_PATH}/lib64\n\
export OMP_STACKSIZE=16M\n\
export PATH=/opt/cp2k/exe/local_cuda:\${PATH}\n\
source /opt/cp2k/tools/toolchain/install/setup\n\
\"\$@\"" \
>/usr/local/bin/entrypoint.sh && chmod 755 /usr/local/bin/entrypoint.sh

# Create shortcut for regression test
RUN printf "/opt/cp2k/tests/do_regtest.py --maxtasks 8 --workbasedir /mnt \$* local_cuda psmp" \
>/usr/local/bin/run_tests && chmod 755 /usr/local/bin/run_tests

# Define entrypoint
WORKDIR /mnt
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cp2k", "--help"]

# Label docker image
LABEL author="CP2K Developers" \
      cp2k_version="2024.1" \
      dockerfile_generator_version="0.2"

# EOF
