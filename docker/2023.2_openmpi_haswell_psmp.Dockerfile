#
# This file was created by generate_docker_files.py
#
# Usage: docker build -f ./2023.2_openmpi_haswell_psmp.Dockerfile -t cp2k/cp2k:2023.2_openmpi_haswell_psmp .

# Stage 1: build step
FROM ubuntu:22.04 AS build


# Install packages required for the CP2K toolchain build
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    g++ gcc gfortran openssh-client python3 \
    bzip2 ca-certificates git make patch pkg-config unzip wget zlib1g-dev

# Download CP2K
RUN git clone --recursive -b support/v2023.2 https://github.com/cp2k/cp2k.git /opt/cp2k

# Build CP2K toolchain for target CPU haswell
WORKDIR /opt/cp2k/tools/toolchain
RUN /bin/bash -c -o pipefail \
    "./install_cp2k_toolchain.sh -j 8 \
     --install-all \
     --enable-cuda=no \
     --target-cpu=haswell \
     --with-cusolvermp=no \
     --with-gcc=system \
     --with-openmpi=install"

# Build CP2K for target CPU haswell
WORKDIR /opt/cp2k
RUN /bin/bash -c -o pipefail \
    "cp ./tools/toolchain/install/arch/local.psmp ./arch/; \
     source ./tools/toolchain/install/setup; \
     make -j 8 ARCH=local VERSION=psmp"

# Collect components for installation and remove symbolic links
RUN /bin/bash -c -o pipefail \
    "mkdir -p /toolchain/install /toolchain/scripts; \
     for libdir in \$(ldd ./exe/local/cp2k.psmp | \
                      grep /opt/cp2k/tools/toolchain/install | \
                      awk '{print \$3}' | cut -d/ -f7 | \
                      sort | uniq) setup; do \
        cp -ar /opt/cp2k/tools/toolchain/install/\${libdir} /toolchain/install; \
     done; \
     cp /opt/cp2k/tools/toolchain/scripts/tool_kit.sh /toolchain/scripts; \
     unlink ./exe/local/cp2k.popt; \
     unlink ./exe/local/cp2k_shell.psmp"

# Stage 2: install step
FROM ubuntu:22.04 AS install

# Install required packages
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    g++ gcc gfortran openssh-client python3 && rm -rf /var/lib/apt/lists/*

# Install CP2K binaries
COPY --from=build /opt/cp2k/exe/local/ /opt/cp2k/exe/local/

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
        ln -sf /opt/cp2k/exe/local/\${binary}.psmp \
               /usr/local/bin/\${binary}; \
     done; \
     ln -sf /opt/cp2k/exe/local/cp2k.psmp \
            /usr/local/bin/cp2k_shell; \
     ln -sf /opt/cp2k/exe/local/cp2k.psmp \
            /usr/local/bin/cp2k.popt"

# Create entrypoint script file
RUN printf "#!/bin/bash\n\
ulimit -c 0 -s unlimited\n\
\
export OMPI_ALLOW_RUN_AS_ROOT=1\n\
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1\n\
export OMPI_MCA_btl_vader_single_copy_mechanism=none\n\
export OMP_STACKSIZE=16M\n\
export PATH=/opt/cp2k/exe/local:\${PATH}\n\
source /opt/cp2k/tools/toolchain/install/setup\n\
\"\$@\"" \
>/usr/local/bin/entrypoint.sh && chmod 755 /usr/local/bin/entrypoint.sh

# Create shortcut for regression test
RUN printf "/opt/cp2k/tools/regtesting/do_regtest.py --mpiexec \"mpiexec --bind-to none\" --maxtasks 8 --workbasedir /mnt \$* local psmp" \
>/usr/local/bin/run_tests && chmod 755 /usr/local/bin/run_tests

# Define entrypoint
WORKDIR /mnt
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cp2k", "--help"]

# Label docker image
LABEL author="CP2K Developers" \
      cp2k_version="2023.2" \
      dockerfile_generator_version="0.2"

# EOF
