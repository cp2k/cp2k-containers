FROM rockylinux:9

RUN ( \
  echo "[oneAPI]" && \
  echo "name=Intel oneAPI repository" && \
  echo "baseurl=https://yum.repos.intel.com/oneapi" && \
  echo "enabled=1" && \
  echo "gpgcheck=1" && \
  echo "repo_gpgcheck=1" && \
  echo "gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB" \
) >/etc/yum.repos.d/oneAPI.repo

RUN dnf upgrade -y
RUN dnf install -y \
  gcc-gfortran gcc-c++ git procps which bzip2 \
  intel-oneapi-mpi intel-oneapi-mpi-devel \
  intel-oneapi-mkl intel-oneapi-mkl-devel \
  cmake automake libtool wget diffutils \
  gmp-devel boost-devel

ARG MYENV=/root/my.env
RUN ( \
  echo "source /opt/intel/oneapi/mpi/latest/env/vars.sh" && \
  echo "source /opt/intel/oneapi/mkl/latest/env/vars.sh" \
) >$MYENV

WORKDIR /root

# XCONFIGURE
RUN wget https://github.com/hfp/xconfigure/raw/master/configure-get.sh
RUN chmod +x configure-get.sh

# LIBINT
RUN wget https://github.com/evaleev/libint/archive/refs/tags/v2.9.0.tar.gz
RUN tar xvf v2.9.0.tar.gz && rm v2.9.0.tar.gz
RUN cd libint-2.9.0 && source $MYENV && ./autogen.sh && ./configure \
  --enable-eri=1 --enable-eri2=1 --enable-eri3=1 --with-max-am=6 \
  --with-eri-max-am=6,5 --with-eri2-max-am=8,7 --with-eri3-max-am=8,7 --with-opt-am=3 \
  --with-libint-exportdir=libint-cp2k --disable-unrolling --enable-fma \
  --with-real-type=libint2::simd::VectorAVXDouble \
  --with-cxxgen-optflags="-march=native -mtune=native"
RUN cd libint-2.9.0 && source $MYENV && make -j $(nproc) export
RUN cd libint-2.9.0 && make clean

# LIBINT-CP2K
RUN tar xvf libint-2.9.0/libint-cp2k.tgz
RUN cd libint-cp2k && ../configure-get.sh libint
RUN cd libint-cp2k && source $MYENV && ./configure-libint-gnu.sh
RUN cd libint-cp2k && source $MYENV && make -j $(nproc) install
RUN cd libint-cp2k && make clean

# LIBXC
RUN wget https://gitlab.com/libxc/libxc/-/archive/6.2.2/libxc-6.2.2.tar.bz2
RUN tar xvf libxc-6.2.2.tar.bz2 && rm libxc-6.2.2.tar.bz2
RUN cd libxc-6.2.2 && ../configure-get.sh libxc
RUN cd libxc-6.2.2 && source $MYENV && ./configure-libxc-gnu.sh
RUN cd libxc-6.2.2 && source $MYENV && make -j $(nproc) install
RUN cd libxc-6.2.2 && make distclean

# LIBXSMM
RUN git clone https://github.com/libxsmm/libxsmm.git
RUN cd libxsmm && git fetch && git checkout 379d90b6e55c4dd9263574d2066e9b038cb628ea
#RUN cd libxsmm && source $MYENV && make GNU=1 -j $(nproc)

# CP2K
RUN git clone https://github.com/cp2k/cp2k.git
RUN cd cp2k && git pull && git submodule update --init --recursive
RUN cd cp2k/exts/dbcsr && git submodule update --init --recursive
RUN cd cp2k/exts/dbcsr && git checkout develop && git pull
RUN cd cp2k && ../configure-get.sh cp2k
RUN cd cp2k && source $MYENV && make -j $(nproc) \
  ARCH=Linux-x86-64-intelx VERSION=psmp cp2k \
  GNU=1
