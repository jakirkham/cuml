#!/bin/bash

# Copyright (c) 2019, NVIDIA CORPORATION.

# cuml build script

# This script is used to build the component(s) in this repo from
# source, and can be called with various options to customize the
# build as needed (see the help output for details)

# Abort script on first error
set -e

NUMARGS=$#
ARGS=$*

# NOTE: ensure all dir changes are relative to the location of this
# script, and that this script resides in the repo dir!
REPODIR=$(cd $(dirname $0); pwd)

VALIDARGS="clean deep-clean libcuml cuml prims bench -v -g -n --allgpuarch --multigpu -h --help"
HELP="$0 [<target> ...] [<flag> ...]
 where <target> is:
   clean         - remove all existing build artifacts and configuration (start over)
   deep-clean    - same as 'clean' option, but also cleans up the faiss build
   libcuml       - build the cuml C++ code only. Also builds the C-wrapper library
                   around the C++ code.
   cuml          - build the cuml Python package
   prims         - build the ML prims tests
   bench         - build the cuml C++ benchmark
 and <flag> is:
   -v            - verbose build mode
   -g            - build for debug
   -n            - no install step
   --allgpuarch  - build for all supported GPU architectures
   --multigpu    - Build cuml with multigpu support (requires libcumlMG and CUDA >=10.0)
   -h            - print this text

 default action (no args) is to build and install 'libcuml', 'cuml', and 'prims' targets only for the detected GPU arch
"
LIBCUML_BUILD_DIR=${REPODIR}/cpp/build
CUML_COMMS_BUILD_DIR=${REPODIR}/cpp/comms/std/build
CUML_BUILD_DIR=${REPODIR}/python/build
FAISS_DIR=${REPODIR}/thirdparty/faiss
BUILD_DIRS="${LIBCUML_BUILD_DIR} ${CUML_BUILD_DIR}"

# Set defaults for vars modified by flags to this script
VERBOSE=""
BUILD_TYPE=Release
INSTALL_TARGET=install
BUILD_ALL_GPU_ARCH=0
MULTIGPU=""
CLEAN=0

# Set defaults for vars that may not have been defined externally
#  FIXME: if INSTALL_PREFIX is not set, check PREFIX, then check
#         CONDA_PREFIX, but there is no fallback from there!
INSTALL_PREFIX=${INSTALL_PREFIX:=${PREFIX:=${CONDA_PREFIX}}}
PARALLEL_LEVEL=${PARALLEL_LEVEL:=""}
BUILD_ABI=${BUILD_ABI:=ON}

function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

if hasArg -h || hasArg --help; then
    echo "${HELP}"
    exit 0
fi

# Check for valid usage
if (( ${NUMARGS} != 0 )); then
    for a in ${ARGS}; do
  if ! (echo " ${VALIDARGS} " | grep -q " ${a} "); then
      echo "Invalid option: ${a}"
      exit 1
  fi
    done
fi

# Process flags
if hasArg -v; then
    VERBOSE=1
fi
if hasArg -g; then
    BUILD_TYPE=Debug
fi
if hasArg -n; then
    INSTALL_TARGET=""
fi
if hasArg --allgpuarch; then
    BUILD_ALL_GPU_ARCH=1
fi
if hasArg --multigpu; then
    MULTIGPU=--multigpu
fi
if hasArg deep-clean || hasArg clean; then
    CLEAN=1
fi

# If clean given, run it prior to any other steps
if (( ${CLEAN} == 1 )); then
    # If the dirs to clean are mounted dirs in a container, the
    # contents should be removed but the mounted dirs will remain.
    # The find removes all contents but leaves the dirs, the rmdir
    # attempts to remove the dirs but can fail safely.
    for bd in ${BUILD_DIRS}; do
  if [ -d ${bd} ]; then
      find ${bd} -mindepth 1 -delete
      rmdir ${bd} || true
  fi
    done
fi

# clean the faiss build also, if asked
if hasArg deep-clean; then
    cd ${FAISS_DIR}
    make clean
    cd gpu
    make clean
fi

################################################################################
# Configure for building all C++ targets
if (( ${NUMARGS} == 0 )) || hasArg libcuml || hasArg prims || hasArg bench; then
    if (( ${BUILD_ALL_GPU_ARCH} == 0 )); then
        GPU_ARCH=""
        echo "Building for the architecture of the GPU in the system..."
    else
        GPU_ARCH="-DGPU_ARCHS=ALL"
        echo "Building for *ALL* supported GPU architectures..."
    fi

    mkdir -p ${LIBCUML_BUILD_DIR}
    cd ${LIBCUML_BUILD_DIR}

    cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
          -DCMAKE_CXX11_ABI=${BUILD_ABI} \
          -DBLAS_LIBRARIES=${INSTALL_PREFIX}/lib/libopenblas.so.0 \
          ${GPU_ARCH} \
          -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
          -DPARALLEL_LEVEL=${PARALLEL_LEVEL} ..

fi

# Run all make targets at once
MAKE_TARGETS=
if (( ${NUMARGS} == 0 )) || hasArg libcuml; then
    MAKE_TARGETS="${MAKE_TARGETS}cuml++ cuml ml ml_mg"
fi
if (( ${NUMARGS} == 0 )) || hasArg prims; then
    MAKE_TARGETS="${MAKE_TARGETS} prims"
fi
if (( ${NUMARGS} == 0 )) || hasArg bench; then
    MAKE_TARGETS="${MAKE_TARGETS} sg_benchmark"
fi

# build cumlcomms library
if [ "${MAKE_TARGETS}" != "" ]; then
    cd ${LIBCUML_BUILD_DIR}
    make -j${PARALLEL_LEVEL} ${MAKE_TARGETS} VERBOSE=${VERBOSE} ${INSTALL_TARGET}

    mkdir -p ${CUML_COMMS_BUILD_DIR}
    cd ${CUML_COMMS_BUILD_DIR}

    cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
          -DWITH_UCX=OFF \
          -DCUML_INSTALL_DIR=${INSTALL_PREFIX}/lib .. \
          -DNCCL_PATH=${INSTALL_PREFIX} ..

    cd ${CUML_COMMS_BUILD_DIR}
    make -j${PARALLEL_LEVEL} VERBOSE=${VERBOSE} ${INSTALL_TARGET}
fi

# Build and (optionally) install the cuml Python package
if (( ${NUMARGS} == 0 )) || hasArg cuml; then

    cd ${REPODIR}/python
    if [[ ${INSTALL_TARGET} != "" ]]; then
  python setup.py build_ext --inplace ${MULTIGPU}
  python setup.py install --single-version-externally-managed --record=record.txt ${MULTIGPU}
    else
  python setup.py build_ext --inplace --library-dir=${LIBCUML_BUILD_DIR} ${MULTIGPU}
    fi
fi
