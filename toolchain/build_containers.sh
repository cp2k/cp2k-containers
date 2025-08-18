#!/bin/bash
if [[ "${0}" == "${BASH_SOURCE}" ]]; then
   echo "ERROR: Script ${0##*/} must be sourced"
   echo "Usage: source ${0##*/} <cp2k release>"
   exit 1
fi
if [[ -n $1 ]]; then
   releases=$1
else
   echo "No release(s) found as argument"
   echo "Usage: source ${BASH_SOURCE##*/} 2025.1"
   return 1
fi
docker system prune --all --force
echo '#!/bin/bash' >push_containers.sh
echo '#!/bin/bash' >run_containers.sh
for release in ${releases}; do
   for target in generic haswell skylake-avx512 generic_cuda_P100; do
      for mpi in mpich openmpi; do
         dfname=${release}_${mpi}_${target}_psmp
         DOCKER_BUILDKIT=0 docker build --shm-size=1g -f ./${dfname}.Dockerfile -t cp2k/cp2k:${dfname} . 2>&1 | tee ${dfname}.log
         echo 'docker run -it --shm-size=1g -u `id -u $USER`:`id -g $USER` -v $PWD:/mnt' "cp2k/cp2k:${dfname} run_tests" >>run_containers.sh
         echo "docker push cp2k/cp2k:${dfname}" >>push_containers.sh
      done
   done
done
echo '#!/bin/bash' >push_containers_reverse.sh
tail -n +2 push_containers.sh | tac >>push_containers_reverse.sh
