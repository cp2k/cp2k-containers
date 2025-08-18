#
# This file was created by generate_docker_files.py
#
# Usage: podman build --shm-size=1g -f ./master_openmpi_x86_64_psmp.Dockerfile -t cp2k/cp2k:master$(date +%Y%m%d)_openmpi_x86_64_psmp .

# Stage 1: Build CP2K
ARG BASE_IMAGE="ubuntu:24.04"
FROM ${BASE_IMAGE} AS build_cp2k

# Install packages required to build the CP2K dependencies with Spack
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    g++ gcc gfortran python3 \
    automake \
    bzip2 \
    ca-certificates \
    cmake \
    git \
    libncurses-dev \
    libssh-dev \
    libssl-dev \
    libtool-bin \
    lsb-release \
    make \
    ninja-build \
    openssh-client \
    patch \
    pkgconf \
    python3-dev \
    python3-pip \
    python3-venv \
    unzip \
    wget \
    xxd \
    xz-utils \
    zstd && rm -rf /var/lib/apt/lists/*

# Download CP2K
RUN git clone --recursive https://github.com/cp2k/cp2k.git /opt/cp2k

# Retrieve the number of available CPU cores
ARG NUM_PROCS
ENV NUM_PROCS=${NUM_PROCS:-16}

# Install Spack and Spack packages
WORKDIR /root/spack
ARG SPACK_VERSION
ENV SPACK_VERSION=${SPACK_VERSION:-1.0.0}
ARG SPACK_PACKAGES_VERSION
ENV SPACK_PACKAGES_VERSION=${SPACK_PACKAGES_VERSION:-2025.07.0}
ARG SPACK_REPO=https://github.com/spack/spack
ENV SPACK_ROOT=/opt/spack-${SPACK_VERSION}
ARG SPACK_PACKAGES_REPO=https://github.com/spack/spack-packages
ENV SPACK_PACKAGES_ROOT=/opt/spack-packages-${SPACK_PACKAGES_VERSION}
RUN mkdir -p ${SPACK_ROOT} && \
    wget -q ${SPACK_REPO}/archive/v${SPACK_VERSION}.tar.gz && \
    tar -xzf v${SPACK_VERSION}.tar.gz -C /opt && rm -f v${SPACK_VERSION}.tar.gz && \
    mkdir -p ${SPACK_PACKAGES_ROOT} && \
    wget -q ${SPACK_PACKAGES_REPO}/archive/v${SPACK_PACKAGES_VERSION}.tar.gz && \
    tar -xzf v${SPACK_PACKAGES_VERSION}.tar.gz -C /opt && rm -f v${SPACK_PACKAGES_VERSION}.tar.gz

ENV PATH="${SPACK_ROOT}/bin:${PATH}"

# Add Spack packages builtin repository
RUN spack repo add --scope site ${SPACK_PACKAGES_ROOT}/repos/spack_repo/builtin

# Find all compilers
RUN spack compiler find

# Find all external packages
RUN spack external find --all --not-buildable

# Copy Spack configuration and build recipes
ARG CP2K_VERSION
ENV CP2K_VERSION=${CP2K_VERSION:-psmp}
RUN cp -a /opt/cp2k/tools/spack/cp2k_dev_repo ${SPACK_PACKAGES_ROOT}/repos/spack_repo && \
    spack repo add --scope site ${SPACK_PACKAGES_ROOT}/repos/spack_repo/cp2k_dev_repo
RUN sed -e 's/require: target="\w*"/require: target="x86_64"/' -e 's/- mpich/- openmpi/' -e '/^\s*- "mpich@/ s/^ /#/' -e '/^#\s*- "openmpi@/ s/^#/ /' -i /opt/cp2k/tools/spack/cp2k_deps_${CP2K_VERSION}.yaml && \
    cat /opt/cp2k/tools/spack/cp2k_deps_${CP2K_VERSION}.yaml && \
    spack env create myenv /opt/cp2k/tools/spack/cp2k_deps_${CP2K_VERSION}.yaml && \
    spack -e myenv repo list

# Install CP2K dependencies via Spack
RUN spack -e myenv concretize -f
ENV SPACK_ENV_VIEW="${SPACK_ROOT}/var/spack/environments/myenv/spack-env/view"
RUN spack -e myenv env depfile -o spack_makefile && \
    make -j${NUM_PROCS} --file=spack_makefile SPACK_COLOR=never --output-sync=recurse && \
    cp -ar ${SPACK_ENV_VIEW}/bin ${SPACK_ENV_VIEW}/include ${SPACK_ENV_VIEW}/lib /opt/spack

# Run CMake
WORKDIR /opt/cp2k
RUN /bin/bash -c -o pipefail "source ./cmake/cmake_cp2k.sh spack ${CP2K_VERSION}"

# Compile CP2K for target CPU x86_64
ARG LOG_LINES
ENV LOG_LINES=${LOG_LINES:-200}
WORKDIR /opt/cp2k/build
RUN /bin/bash -c -o pipefail " \
    echo -e '\nCompiling CP2K ... \c'; \
    if ninja --verbose &>ninja.log; then \
      echo -e 'done\n'; \
      echo -e 'Installing CP2K ... \c'; \
      if ninja --verbose install &>install.log; then \
        echo -e 'done\n'; \
      else \
        echo -e 'failed\n'; \
        tail -n ${LOG_LINES} install.log; \
      fi; \
      cat cmake.log ninja.log install.log | gzip >build_cp2k.log.gz; \
    else \
      echo -e 'failed\n'; \
      tail -n ${LOG_LINES} ninja.log; \
      cat cmake.log ninja.log | gzip >build_cp2k.log.gz; \
    fi"

# Store build arguments from base image needed in next stage
RUN echo "${CP2K_VERSION}" >/CP2K_VERSION

# Stage 2: Install CP2K
FROM ${BASE_IMAGE} AS install_cp2k

# Install required packages
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    g++ gcc gfortran python3 && rm -rf /var/lib/apt/lists/*

# Import build arguments from base image
COPY --from=build_cp2k /CP2K_VERSION /

# Install CP2K dependencies built with Spack
WORKDIR /opt
COPY --from=build_cp2k /opt/spack ./spack

# Install CP2K binaries
WORKDIR /opt/cp2k
COPY --from=build_cp2k /opt/cp2k/bin ./bin

# Install CP2K libraries
COPY --from=build_cp2k /opt/cp2k/lib ./lib

# Install CP2K database files
COPY --from=build_cp2k /opt/cp2k/share ./share

# Install CP2K regression tests
COPY --from=build_cp2k /opt/cp2k/tests ./tests
COPY --from=build_cp2k /opt/cp2k/src/grid/sample_tasks ./src/grid/sample_tasks

# Install CP2K/Quickstep CI benchmarks
COPY --from=build_cp2k /opt/cp2k/benchmarks/CI ./benchmarks/CI

# Import compressed build log file
COPY --from=build_cp2k /opt/cp2k/build/build_cp2k.log.gz /opt/cp2k/build/build_cp2k.log.gz

# Create links to CP2K binaries
WORKDIR /opt/cp2k/bin
RUN CP2K_VERSION=$(cat /CP2K_VERSION) && \
    ln -sf cp2k.${CP2K_VERSION} cp2k && \
    ln -sf cp2k.${CP2K_VERSION} cp2k.$(echo ${CP2K_VERSION} | sed "s/smp/opt/") && \
    ln -sf cp2k.${CP2K_VERSION} cp2k_shell

# Update library search path
RUN echo "/opt/cp2k/lib\n/opt/spack/lib\n$(dirname $(find /opt/spack/lib -name libtorch.so 2>/dev/null || true) 2>/dev/null || true)" >/etc/ld.so.conf.d/cp2k.conf && ldconfig

# Create entrypoint script file
RUN printf "#!/bin/bash\n\
ulimit -c 0 -s unlimited\n\
\
export OMPI_ALLOW_RUN_AS_ROOT=1\n\
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1\n\
export OMPI_MCA_btl_vader_single_copy_mechanism=none\n\
export OMP_STACKSIZE=64M\n\
export PATH=/opt/cp2k/bin:/opt/spack/bin:\${PATH}\n\
\"\$@\"" \
>/opt/cp2k/bin/entrypoint.sh && chmod 755 /opt/cp2k/bin/entrypoint.sh

# Create shortcut for regression test
RUN printf "/opt/cp2k/tests/do_regtest.py \$* /opt/cp2k/bin $(cat /CP2K_VERSION)" \
>/opt/cp2k/bin/run_tests && chmod 755 /opt/cp2k/bin/run_tests

# Define entrypoint
WORKDIR /mnt
ENTRYPOINT ["/opt/cp2k/bin/entrypoint.sh"]
CMD ["cp2k", "--help"]

# EOF
