#!/usr/bin/env bash

BASH_DEBUG="${BASH_DEBUG:=}"
([ "${BASH_DEBUG}" == "true" ] || [ "${BASH_DEBUG}" == "1" ] ) && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
shopt -s dotglob
trap "exit" INT

# Install these for clang support:
# sudo apt-get install --verbose-versions llvm-10 clang{,-tools,-tidy,-format}-10 llvm-10 libclang-common-10-dev

# Directory where this script resides
THIS_DIR=$(cd $(dirname "${BASH_SOURCE[0]}"); pwd)

# Where the source code is
PROJECT_ROOT_DIR="$(realpath ${THIS_DIR}/..)"

source "${THIS_DIR}/lib/set_locales.sh"

source "${PROJECT_ROOT_DIR}/.env.example"
if [ -f "${PROJECT_ROOT_DIR}/.env" ]; then
  source "${PROJECT_ROOT_DIR}/.env"
fi

PROJECT_NAME="nextalign"
BUILD_PREFIX=""
MACOS_ARCH=${MACOS_ARCH:=x86_64}

SYSTEM_NAME="$(uname -s)"
PROCESSOR_NAME="$(uname -p || uname -m)"
if [ "${SYSTEM_NAME}" == "Darwin" ]; then
  SYSTEM_NAME="MacOS"
  PROCESSOR_NAME="${MACOS_ARCH}"
fi


IS_CI="0"
if false \
|| [ ! -z "${BUILD_ID:=}" ] \
|| [ ! -z "${CI:=}" ] \
|| [ ! -z "${CIRCLECI:=}" ] \
|| [ ! -z "${CIRRUS_CI:=}" ] \
|| [ ! -z "${CODEBUILD_BUILD_ID:=}" ] \
|| [ ! -z "${GITHUB_ACTIONS:=}" ] \
|| [ ! -z "${GITLAB_CI:=}" ] \
|| [ ! -z "${HEROKU_TEST_RUN_ID:=}" ] \
|| [ ! -z "${TEAMCITY_VERSION:=}" ] \
|| [ ! -z "${TF_BUILD:=}" ] \
|| [ ! -z "${TRAVIS:=}" ] \
; then
  IS_CI="1"
fi

# Build type (default: Release)
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:=Release}"

# Deduce conan build type from cmake build type
CONAN_BUILD_TYPE=${CMAKE_BUILD_TYPE}
case ${CMAKE_BUILD_TYPE} in
  Debug|Release|RelWithDebInfo|MinSizeRelease) CONAN_BUILD_TYPE=${CMAKE_BUILD_TYPE} ;;
  ASAN|MSAN|TSAN|UBSAN) CONAN_BUILD_TYPE=RelWithDebInfo ;;
  *) CONAN_BUILD_TYPE="Release" ;;
esac

ADDITIONAL_PATH="${PROJECT_ROOT_DIR}/3rdparty/binutils/bin:${PROJECT_ROOT_DIR}/3rdparty/gcc/bin:${PROJECT_ROOT_DIR}/3rdparty/llvm/bin"
export PATH="${ADDITIONAL_PATH}${PATH:+:$PATH}"

# Whether to use Clang Analyzer
USE_CLANG_ANALYZER="${USE_CLANG_ANALYZER:=0}"
CLANG_ANALYZER=""
if [ "${USE_CLANG_ANALYZER}" == "true" ] || [ "${USE_CLANG_ANALYZER}" == "1" ]; then
  CLANG_ANALYZER="scan-build -v --keep-going -o ${PROJECT_ROOT_DIR}/.reports/clang-analyzer"
  USE_CLANG=1
  mkdir -p "${PROJECT_ROOT_DIR}/.reports/clang-analyzer"
fi

# Whether to use Clang C++ compiler (default: use GCC)
USE_CLANG="${USE_CLANG:=0}"

CONAN_COMPILER_SETTINGS=""
if [ "${MACOS_ARCH}" == "arm64" ]; then
  CONAN_COMPILER_SETTINGS="\
    -s arch=armv8 \
  "
fi

BUILD_SUFFIX=""
if [ "${USE_CLANG}" == "true" ] || [ "${USE_CLANG}" == "1" ]; then
  export CC="${CC:-clang}"
  export CXX="${CXX:-clang++}"
  export CMAKE_C_COMPILER=${CC}
  export CMAKE_CXX_COMPILER=${CXX}

  CLANG_VERSION_DETECTED=$(${CC} --version | grep "clang version" | awk -F ' ' {'print $3'} | awk -F \. {'print $1'})
  CLANG_VERSION=${CLANG_VERSION:=${CLANG_VERSION_DETECTED}}

  CONAN_COMPILER_SETTINGS="\
    ${CONAN_COMPILER_SETTINGS}
    -s compiler=clang \
    -s compiler.version=${CLANG_VERSION} \
  "

  BUILD_SUFFIX="-Clang"
fi

# Create build directory
BUILD_DIR_DEFAULT="${PROJECT_ROOT_DIR}/.build/${BUILD_PREFIX}${CMAKE_BUILD_TYPE}${BUILD_SUFFIX}"
BUILD_DIR="${BUILD_DIR:=${BUILD_DIR_DEFAULT}}"

mkdir -p "${BUILD_DIR}"

INSTALL_DIR="${PROJECT_ROOT_DIR}/.out"

CLI_DIR="${BUILD_DIR}/packages/${PROJECT_NAME}_cli"
CLI_EXE="nextalign-${SYSTEM_NAME}-${PROCESSOR_NAME}"
CLI=${INSTALL_DIR}/bin/${CLI_EXE}

USE_COLOR="${USE_COLOR:=1}"
DEV_CLI_OPTIONS="${DEV_CLI_OPTIONS:=}"

# Whether to build a standalone static executable
NEXTALIGN_STATIC_BUILD_DEFAULT=0
if [ "${CMAKE_BUILD_TYPE}" == "Release" ]; then
  NEXTALIGN_STATIC_BUILD_DEFAULT=1
fi
NEXTALIGN_STATIC_BUILD=${NEXTALIGN_STATIC_BUILD:=${NEXTALIGN_STATIC_BUILD_DEFAULT}}

# Add flags necessary for static build
CONAN_STATIC_BUILD_FLAGS="-o boost:header_only=True"
CONAN_TBB_STATIC_BUILD_FLAGS=""
if [ "${NEXTALIGN_STATIC_BUILD}" == "true" ] || [ "${NEXTALIGN_STATIC_BUILD}" == "1" ]; then
  CONAN_STATIC_BUILD_FLAGS="\
    ${CONAN_STATIC_BUILD_FLAGS} \
    -o tbb:shared=False \
    -o gtest:shared=True \
  "

  CONAN_TBB_STATIC_BUILD_FLAGS="-o shared=False"
fi

# AddressSanitizer and MemorySanitizer don't work with gdb
case ${CMAKE_BUILD_TYPE} in
  ASAN|MSAN) GDB_DEFAULT="" ;;
  *) ;;
esac

# gdb (or lldb) command with arguments
GDB_DEFAULT="gdb --quiet -ix ${THIS_DIR}/lib/.gdbinit -x ${THIS_DIR}/lib/.gdbexec --args"
if [ "${IS_CI}" == "1" ]; then
  GDB_DEFAULT=""
fi
GDB="${GDB:=${GDB_DEFAULT}}"

# gttp (Google Test Pretty Printer) command
GTTP_DEFAULT="${THIS_DIR}/lib/gtpp.py"
if [ "${IS_CI}" == "1" ]; then
  GTTP_DEFAULT=""
fi
GTPP="${GTPP:=${GTTP_DEFAULT}}"

# Generate a semicolon-delimited list of arguments for cppcheck
# (to run during cmake build). The arguments are taken from the file
# `.cppcheck` in the source root
CMAKE_CXX_CPPCHECK="cppcheck;--template=gcc"
while IFS='' read -r flag; do
  CMAKE_CXX_CPPCHECK="${CMAKE_CXX_CPPCHECK};${flag}"
done<"${THIS_DIR}/../.cppcheck"

# Print coloured message
function print() {
  if [[ ! -z "${USE_COLOR}" ]] && [[ "${USE_COLOR}" != "false" ]]; then
    echo -en "\n\e[48;5;${1}m - ${2} \t\e[0m\n";
  else
    printf "\n${2}\n";
  fi
}

echo "-------------------------------------------------------------------------"
echo "PROJECT_NAME=${PROJECT_NAME:=}"
echo ""
echo "SYSTEM_NAME=${SYSTEM_NAME:=}"
echo "PROCESSOR_NAME=${PROCESSOR_NAME:=}"
echo "MACOS_ARCH=${MACOS_ARCH:=}"
echo ""
echo "IS_CI=${IS_CI:=}"
echo "CI=${CI:=}"
echo "TRAVIS=${TRAVIS:=}"
echo "CIRCLECI=${CIRCLECI:=}"
echo "GITHUB_ACTIONS=${GITHUB_ACTIONS:=}"
echo ""
echo "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:=}"
echo "CONAN_BUILD_TYPE=${CONAN_BUILD_TYPE:=}"
echo "NEXTALIGN_STATIC_BUILD=${NEXTALIGN_STATIC_BUILD:=}"
echo ""
echo "USE_COLOR=${USE_COLOR:=}"
echo "USE_CLANG=${USE_CLANG:=}"
echo "CLANG_VERSION=${CLANG_VERSION:=}"
echo "CC=${CC:=}"
echo "CXX=${CXX:=}"
echo "CMAKE_C_COMPILER=${CMAKE_C_COMPILER:=}"
echo "CMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER:=}"
echo "USE_CLANG_ANALYZER=${USE_CLANG_ANALYZER:=}"
echo "CONAN_COMPILER_SETTINGS=${CONAN_COMPILER_SETTINGS:=}"
echo "CONAN_COMPILER_SETTINGS=${CONAN_STATIC_BUILD_FLAGS:=}"
echo "CONAN_COMPILER_SETTINGS=${CONAN_TBB_STATIC_BUILD_FLAGS:=}"
echo ""
echo "BUILD_PREFIX=${BUILD_PREFIX:=}"
echo "BUILD_SUFFIX=${BUILD_SUFFIX:=}"
echo "BUILD_DIR=${BUILD_DIR:=}"
echo "INSTALL_DIR=${INSTALL_DIR:=}"
echo "CLI=${CLI:=}"
echo "-------------------------------------------------------------------------"

# If `tbb/2020.3@local/stable` is not in conan cache
if [ -z "$(conan search | grep 'tbb/2021.2.0-rc@local/stable')" ]; then
  # Create Intel TBB package patched for Apple Silicon and put it under `@local/stable` reference
  print 56 "Build Intel TBB";
  pushd "3rdparty/tbb" > /dev/null
      conan create . local/stable \
      -s build_type="${CONAN_BUILD_TYPE}" \
      ${CONAN_COMPILER_SETTINGS} \
      ${CONAN_STATIC_BUILD_FLAGS} \
      ${CONAN_TBB_STATIC_BUILD_FLAGS} \

  popd > /dev/null
fi

pushd "${BUILD_DIR}" > /dev/null

  print 56 "Install dependencies";
  conan install "${PROJECT_ROOT_DIR}" \
    -s build_type="${CONAN_BUILD_TYPE}" \
    ${CONAN_COMPILER_SETTINGS} \
    ${CONAN_STATIC_BUILD_FLAGS} \
    --build missing \

  print 92 "Generate build files";
  ${CLANG_ANALYZER} cmake "${PROJECT_ROOT_DIR}" \
    -DCMAKE_MODULE_PATH="${BUILD_DIR}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DCMAKE_CXX_CPPCHECK="${CMAKE_CXX_CPPCHECK}" \
    -DCMAKE_VERBOSE_MAKEFILE=${CMAKE_VERBOSE_MAKEFILE:=0} \
    -DNEXTALIGN_STATIC_BUILD=${NEXTALIGN_STATIC_BUILD} \
    -DNEXTALIGN_BUILD_BENCHMARKS=1 \
    -DNEXTALIGN_BUILD_TESTS=1 \
    -DNEXTALIGN_MACOS_ARCH="${MACOS_ARCH}" \
    -DCMAKE_OSX_ARCHITECTURES="${MACOS_ARCH}" \

  print 12 "Build";
  ${CLANG_ANALYZER} cmake --build "${BUILD_DIR}" --config "${CMAKE_BUILD_TYPE}" -- -j$(($(nproc) - 1))

  if [ "${CMAKE_BUILD_TYPE}" == "Release" ]; then
    print 14 "Install executable";
    cmake --install "${BUILD_DIR}" --config "${CMAKE_BUILD_TYPE}" --strip

    print 14 "Strip executable";
    if [ "${SYSTEM_NAME}" == "MacOS" ]; then
      strip ${CLI}

      ls -l ${CLI}
    elif [ "${SYSTEM_NAME}" == "Linux" ]; then
      strip -s \
        --strip-unneeded \
        --remove-section=.note.gnu.gold-version \
        --remove-section=.comment \
        --remove-section=.note \
        --remove-section=.note.gnu.build-id \
        --remove-section=.note.ABI-tag \
        ${CLI}

        ls --human-readable --kibibytes -Sl ${CLI}
    fi

    print 14 "Print executable info";
    file ${CLI}
  fi

popd > /dev/null

print 25 "Run cppcheck";
. "${THIS_DIR}/cppcheck.sh"

pushd "${PROJECT_ROOT_DIR}" > /dev/null
  print 23 "Run tests";
  pushd "${BUILD_DIR}/packages/${PROJECT_NAME}/tests" > /dev/null
      eval ${GTPP} ${GDB} ./nextalign_tests --gtest_output=xml:${PROJECT_ROOT_DIR}/.reports/tests.xml || cd .
  popd > /dev/null

  print 27 "Run CLI";

  eval "${GDB}" ${CLI} ${DEV_CLI_OPTIONS} || cd .

  print 22 "Done";

popd > /dev/null
