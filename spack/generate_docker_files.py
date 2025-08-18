#!/usr/bin/env python3

# Author: Matthias Krack

from pathlib import Path
from typing import Any
import argparse
import io
import os

# ------------------------------------------------------------------------------

release_list = ["2025.2", "master"]
mpi_implementation_list = ["mpich", "openmpi"]
target_cpu_list = ["x86_64", "cascadelake"]
target_gpu_list = ["no GPU", "P100"]
version_list = ["psmp", "pdbg"]

# ------------------------------------------------------------------------------


def main() -> None:

    mpi_implementation_choices = ["all"] + mpi_implementation_list
    release_choices = ["all"] + release_list
    target_cpu_choices = ["all"] + target_cpu_list
    target_gpu_choices = target_gpu_list + ["all"]
    version_choices = version_list + ["all"]

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        dest="check",
        help="Check consistency with generator script",
    )
    parser.add_argument(
        "--mpi",
        choices=mpi_implementation_choices,
        default=mpi_implementation_choices[0],
        dest="mpi_implementation",
        help=(
            "Select a MPI implementation (default is to generate docker "
            f"containers for {mpi_implementation_choices[0]})"
        ),
        type=str,
    )
    parser.add_argument(
        "-j",
        "--ncores",
        default=16,
        dest="ncores",
        help=(
            "Select the number of CPU cores used for building the container "
            "and running the regression tests (default is 16)"
        ),
        type=check_ncores,
    )
    parser.add_argument(
        "--release",
        choices=release_choices,
        default=release_choices[0],
        dest="release",
        help=(
            "Specify the CP2K release for which the docker files are generated "
            f"(default is {release_choices[0]})"
        ),
        type=str,
    )
    parser.add_argument(
        "--target-cpu",
        choices=target_cpu_choices,
        default=target_cpu_choices[0],
        dest="target_cpu",
        help=(
            "Specify the target CPU for which the docker files are generated "
            f"(default is {target_cpu_choices[0]})"
        ),
        type=str,
    )
    parser.add_argument(
        "--target-gpu",
        choices=target_gpu_choices,
        default=target_gpu_choices[0],
        dest="target_gpu",
        help=(
            "Specify the target GPU for which the docker files are generated "
            f"(default is {target_gpu_choices[0]})"
        ),
        type=str,
    )
    parser.add_argument(
        "--user",
        "--user-name",
        default="cp2k",
        dest="user_name",
        help="Specify the username for GitHub and DockerHub (default is cp2k)",
        type=str,
    )
    parser.add_argument(
        "--version",
        choices=version_choices,
        default=version_choices[0],
        dest="version",
        help=(
            "Specify the version type of the CP2K binary "
            f"(default is {version_choices[0]})"
        ),
        type=str,
    )
    args = parser.parse_args()

    ncores = args.ncores
    omp_stacksize = "64M"
    user_name = args.user_name

    if ncores > os.cpu_count():
        print(
            "WARNING: More CPU cores requested for build than available "
            f"({ncores} > {os.cpu_count()})"
        )

    base_system = "ubuntu:24.04"
    for release in release_list:
        if args.release not in ("all", release):
            continue
        for mpi_implementation in mpi_implementation_list:
            if args.mpi_implementation not in ("all", mpi_implementation):
                continue
            for target_cpu in target_cpu_list:
                if args.target_cpu not in ("all", target_cpu):
                    continue
                for version in version_list:
                    if args.version not in ("all", version):
                        continue
                    name = f"{release}_{mpi_implementation}_{target_cpu}_{version}"
                    with OutputFile(f"{name}.Dockerfile", args.check) as output_file:
                        output_file.write(
                            write_docker_file(
                                base_system=base_system,
                                mpi_implementation=mpi_implementation,
                                name=name,
                                ncores=ncores,
                                omp_stacksize=omp_stacksize,
                                release=release,
                                target_cpu=target_cpu,
                                target_gpu="",
                                user_name=user_name,
                                version=version,
                            )
                        )

    # Generate docker files for CUDA
    base_system = "nvidia/cuda:12.8.1-devel-ubuntu24.04"
    for release in release_list:
        if args.release not in ("all", release):
            continue
        for mpi_implementation in mpi_implementation_list:
            if args.mpi_implementation not in ("all", mpi_implementation):
                continue
            for target_cpu in target_cpu_list:
                if args.target_cpu not in ("all", target_cpu):
                    continue
                for target_gpu in target_gpu_list:
                    if args.target_gpu == "no GPU" or args.target_gpu not in (
                        "all",
                        target_gpu,
                    ):
                        continue
                    print(f"Container build for GPU {target_gpu} is not yet supported.")
                    continue
                    for version in version_list:
                        if args.version not in ("all", version):
                            continue
                        name = (
                            f"{release}_{mpi_implementation}_{target_cpu}"
                            f"_cuda_{target_gpu}_{version}"
                        )
                        with OutputFile(
                            f"{name}.Dockerfile", args.check
                        ) as output_file:
                            output_file.write(
                                write_docker_file(
                                    base_system=base_system,
                                    name=name,
                                    mpi_implementation=mpi_implementation,
                                    ncores=ncores,
                                    omp_stacksize=omp_stacksize,
                                    release=release,
                                    target_cpu=target_cpu,
                                    target_gpu=target_gpu,
                                    user_name=user_name,
                                    version=version,
                                )
                            )


# ------------------------------------------------------------------------------


def check_ncores(value: str) -> int:
    ivalue = int(value)
    if ivalue < 1:
        raise argparse.ArgumentTypeError(f"{value} is an invalid number of CPU cores")
    return ivalue


# ------------------------------------------------------------------------------


def write_docker_file(
    base_system: str,
    name: str,
    mpi_implementation: str,
    ncores: int,
    omp_stacksize: str,
    release: str,
    target_cpu: str,
    target_gpu: str,
    user_name: str,
    version: str,
) -> str:
    do_regtest = "/opt/cp2k/tests/do_regtest.py"

    if release == "master":
        branch = ""
        tagname = name.replace("master", r"master$(date +%Y%m%d)")
    else:
        branch = f" -b support/v{release}"
        tagname = name

    if release == "2025.2":
        build_type = "_all"
        sed_line = rf"""sed -e '/^\s*mpi:/i\      require: target="{target_cpu}"'"""
        if mpi_implementation == "openmpi":
            sed_line = rf"""{sed_line} -e 's/- mpich/- openmpi/'"""
            sed_line = rf"""{sed_line} -e '/^\s*xpmem:/i\    openmpi:\n      require:\n        - +internal-hwloc'"""
            sed_line = rf"""{sed_line} -e '/^\s*- "mpich@/ s/^ /#/'"""
            sed_line = rf"""{sed_line} -e '/^#\s*- "openmpi@/ s/^#/ /'"""
    elif release == "master":
        build_type = ""
        sed_line = (
            rf"""sed -e 's/require: target="\w*"/require: target="{target_cpu}"/'"""
        )
        if mpi_implementation == "openmpi":
            sed_line = rf"""{sed_line} -e 's/- mpich/- openmpi/'"""
            sed_line = rf"""{sed_line} -e '/^\s*- "mpich@/ s/^ /#/'"""
            sed_line = rf"""{sed_line} -e '/^#\s*- "openmpi@/ s/^#/ /'"""
    sed_line = rf"""{sed_line} -i /opt/cp2k/tools/spack/cp2k_deps{build_type}_${{CP2K_VERSION}}.yaml"""

    # Required packages for the final container
    required_packages = "g++ gcc gfortran python3"
    if target_gpu:
        cuda_path = "/usr/local/cuda"
        additional_exports = rf"""\
export CUDA_CACHE_DISABLE=1\\n\\
export CUDA_PATH={cuda_path}\\n\\
export LD_LIBRARY_PATH=\${{LD_LIBRARY_PATH}}:\${{CUDA_PATH}}/lib64\\n\\\
"""
        cuda_environment = rf"""\\
# Setup CUDA environment
ENV CUDA_PATH {cuda_path}
ENV LD_LIBRARY_PATH {cuda_path}/lib64

# Disable JIT cache as there seems to be an issue with file locking on overlayfs
# See also https://github.com/cp2k/cp2k/pull/2337
ENV CUDA_CACHE_DISABLE 1
"""
    else:
        additional_exports = "\\"
        cuda_environment = ""

    # Default options for the regression tests
    testopts = f"--maxtasks {ncores}" " --workbasedir /mnt"

    if mpi_implementation == "openmpi":
        additional_exports += """
export OMPI_ALLOW_RUN_AS_ROOT=1\\n\\
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1\\n\\
export OMPI_MCA_btl_vader_single_copy_mechanism=none\\n\\\
"""
        testopts = '--mpiexec \\"mpiexec --bind-to none\\" ' + testopts

    return rf"""
# Usage: podman build --shm-size=1g -f ./{name}.Dockerfile -t {user_name}/cp2k:{tagname} .

# Stage 1: Build CP2K
ARG BASE_IMAGE="{base_system}"
FROM ${{BASE_IMAGE}} AS build_cp2k

# Install packages required to build the CP2K dependencies with Spack
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    {required_packages} \
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
RUN git clone --recursive{branch} https://github.com/{user_name}/cp2k.git /opt/cp2k

# Retrieve the number of available CPU cores
ARG NUM_PROCS
ENV NUM_PROCS=${{NUM_PROCS:-{ncores}}}

# Install Spack and Spack packages
WORKDIR /root/spack
ARG SPACK_VERSION
ENV SPACK_VERSION=${{SPACK_VERSION:-1.0.0}}
ARG SPACK_PACKAGES_VERSION
ENV SPACK_PACKAGES_VERSION=${{SPACK_PACKAGES_VERSION:-2025.07.0}}
ARG SPACK_REPO=https://github.com/spack/spack
ENV SPACK_ROOT=/opt/spack-${{SPACK_VERSION}}
ARG SPACK_PACKAGES_REPO=https://github.com/spack/spack-packages
ENV SPACK_PACKAGES_ROOT=/opt/spack-packages-${{SPACK_PACKAGES_VERSION}}
RUN mkdir -p ${{SPACK_ROOT}} && \
    wget -q ${{SPACK_REPO}}/archive/v${{SPACK_VERSION}}.tar.gz && \
    tar -xzf v${{SPACK_VERSION}}.tar.gz -C /opt && rm -f v${{SPACK_VERSION}}.tar.gz && \
    mkdir -p ${{SPACK_PACKAGES_ROOT}} && \
    wget -q ${{SPACK_PACKAGES_REPO}}/archive/v${{SPACK_PACKAGES_VERSION}}.tar.gz && \
    tar -xzf v${{SPACK_PACKAGES_VERSION}}.tar.gz -C /opt && rm -f v${{SPACK_PACKAGES_VERSION}}.tar.gz

ENV PATH="${{SPACK_ROOT}}/bin:${{PATH}}"

# Add Spack packages builtin repository
RUN spack repo add --scope site ${{SPACK_PACKAGES_ROOT}}/repos/spack_repo/builtin

# Find all compilers
RUN spack compiler find

# Find all external packages
RUN spack external find --all --not-buildable

# Copy Spack configuration and build recipes
ARG CP2K_VERSION
ENV CP2K_VERSION=${{CP2K_VERSION:-{version}}}
RUN cp -a /opt/cp2k/tools/spack/cp2k_dev_repo ${{SPACK_PACKAGES_ROOT}}/repos/spack_repo && \
    spack repo add --scope site ${{SPACK_PACKAGES_ROOT}}/repos/spack_repo/cp2k_dev_repo
RUN {sed_line} && \
    cat /opt/cp2k/tools/spack/cp2k_deps{build_type}_${{CP2K_VERSION}}.yaml && \
    spack env create myenv /opt/cp2k/tools/spack/cp2k_deps{build_type}_${{CP2K_VERSION}}.yaml && \
    spack -e myenv repo list

# Install CP2K dependencies via Spack
RUN spack -e myenv concretize -f
ENV SPACK_ENV_VIEW="${{SPACK_ROOT}}/var/spack/environments/myenv/spack-env/view"
RUN spack -e myenv env depfile -o spack_makefile && \
    make -j${{NUM_PROCS}} --file=spack_makefile SPACK_COLOR=never --output-sync=recurse && \
    cp -ar ${{SPACK_ENV_VIEW}}/bin ${{SPACK_ENV_VIEW}}/include ${{SPACK_ENV_VIEW}}/lib /opt/spack

# Run CMake
WORKDIR /opt/cp2k
RUN /bin/bash -c -o pipefail "source ./cmake/cmake_cp2k.sh spack{build_type} ${{CP2K_VERSION}}"

# Compile CP2K for target CPU {target_cpu}
ARG LOG_LINES
ENV LOG_LINES=${{LOG_LINES:-200}}
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
        tail -n ${{LOG_LINES}} install.log; \
      fi; \
      cat cmake.log ninja.log install.log | gzip >build_cp2k.log.gz; \
    else \
      echo -e 'failed\n'; \
      tail -n ${{LOG_LINES}} ninja.log; \
      cat cmake.log ninja.log | gzip >build_cp2k.log.gz; \
    fi"

# Store build arguments from base image needed in next stage
RUN echo "${{CP2K_VERSION}}" >/CP2K_VERSION

# Stage 2: Install CP2K
FROM ${{BASE_IMAGE}} AS install_cp2k

# Install required packages
RUN apt-get update -qq && apt-get install -qq --no-install-recommends \
    {required_packages} && rm -rf /var/lib/apt/lists/*

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
    ln -sf cp2k.${{CP2K_VERSION}} cp2k && \
    ln -sf cp2k.${{CP2K_VERSION}} cp2k.$(echo ${{CP2K_VERSION}} | sed "s/smp/opt/") && \
    ln -sf cp2k.${{CP2K_VERSION}} cp2k_shell

# Update library search path
RUN echo "/opt/cp2k/lib\n/opt/spack/lib\n$(dirname $(find /opt/spack/lib -name libtorch.so 2>/dev/null || true) 2>/dev/null || true)" >/etc/ld.so.conf.d/cp2k.conf && ldconfig

# Create entrypoint script file
RUN printf "#!/bin/bash\n\
ulimit -c 0 -s unlimited\n\
{additional_exports}
export OMP_STACKSIZE={omp_stacksize}\n\
export PATH=/opt/cp2k/bin:/opt/spack/bin:\${{PATH}}\n\
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
"""


# ------------------------------------------------------------------------------


class OutputFile:
    def __init__(self, filename: str, check: bool) -> None:
        self.filename = filename
        self.check = check
        self.content = io.StringIO()
        self.content.write("#\n")
        self.content.write("# This file was created by generate_docker_files.py\n")
        self.content.write("#")

    def __enter__(self) -> io.StringIO:
        return self.content

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        output_path = Path(__file__).parent / self.filename
        if self.check:
            assert output_path.read_text(encoding="utf8") == self.content.getvalue()
            print(f"File {output_path} is consistent with generator script")
        else:
            output_path.write_text(self.content.getvalue(), encoding="utf8")
            print(f"Wrote {output_path}")


# ------------------------------------------------------------------------------

main()

# EOF
