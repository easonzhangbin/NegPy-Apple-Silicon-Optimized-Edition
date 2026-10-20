#!/bin/bash
# NegPy Apple Silicon 优化 · 第一阶段：基线测量 → 编译多核 LibRaw → 复测对比
# 只改动打包环境 ~/.negpy-build 里的 rawpy，不影响已安装的任何 App。原文件自动备份。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
B="${HOME}/.negpy-build"
SRC="${B}/negpy-0.65.0-zh_CN"
PY="${SRC}/.venv/bin/python"
W="${B}/apple-opt"
OMP="${W}/omp"
RES="${HERE}/results"
LOG="${HERE}/stage1.log"
LLVM_VER="19.1.7"
export MACOSX_DEPLOYMENT_TARGET=11.0
mkdir -p "${W}" "${RES}"
exec > >(tee "${LOG}") 2>&1

step() { echo; echo "▶ $*"; }
die() { echo "❌ $*"; echo "（日志：${LOG}）"; exit 1; }

[ -x "${PY}" ] || die "找不到打包环境 ${PY}，请先运行之前的 打包NegPy中文版.command"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
command -v uv >/dev/null || die "找不到 uv"
command -v brew >/dev/null || die "找不到 Homebrew"
xcrun --find clang >/dev/null || die "找不到 Xcode 编译器"

RAWPY_DIR="$("${PY}" -c 'import os,rawpy;print(os.path.dirname(rawpy.__file__))')"
echo "rawpy 位置：${RAWPY_DIR}"
cp "${HERE}/bench_mac.py" "${SRC}/bench_mac.py"

# ---------------------------------------------------------------------------
step "1/5 基线测量（现有 rawpy，单核 LibRaw）"
if [ ! -d "${W}/rawpy-stock" ]; then
  mkdir -p "${W}/rawpy-stock"
  cp -a "${RAWPY_DIR}/." "${W}/rawpy-stock/"
fi
( cd "${SRC}" && "${PY}" bench_mac.py --label stock --out "${RES}/stock.json" ) || echo "（基线测量有部分失败，继续）"

# ---------------------------------------------------------------------------
step "2/5 准备编译工具（cmake、ninja、头文件）"
uv venv -q "${W}/tools" --python 3.13 || die "创建工具环境失败"
uv pip install -q --python "${W}/tools/bin/python" cmake ninja || die "安装 cmake/ninja 失败"
export PATH="${W}/tools/bin:${PATH}"
brew list little-cms2 >/dev/null 2>&1 || brew install little-cms2 || echo "（little-cms2 安装失败，将不带 LCMS 编译）"
brew list jasper >/dev/null 2>&1 || brew install jasper || echo "（jasper 安装失败，将不带 RedCine 编译）"
brew list jpeg-turbo >/dev/null 2>&1 || brew install jpeg-turbo || true

# ---------------------------------------------------------------------------
step "3/5 编译 OpenMP 运行库（LLVM ${LLVM_VER}，静态库，最低 macOS 11）"
if [ ! -f "${OMP}/lib/libomp.a" ]; then
  cd "${W}"
  for p in openmp cmake; do
    f="${p}-${LLVM_VER}.src.tar.xz"
    [ -f "${f}" ] || curl -fL --retry 3 -o "${f}" "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VER}/${f}" || true
  done
  if [ -f "openmp-${LLVM_VER}.src.tar.xz" ] && [ -f "cmake-${LLVM_VER}.src.tar.xz" ]; then
    rm -rf llvm-src && mkdir llvm-src && cd llvm-src
    tar xf "../openmp-${LLVM_VER}.src.tar.xz" && mv "openmp-${LLVM_VER}.src" openmp
    tar xf "../cmake-${LLVM_VER}.src.tar.xz" && mv "cmake-${LLVM_VER}.src" cmake
    cmake -S openmp -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
      -DLIBOMP_ENABLE_SHARED=OFF -DOPENMP_ENABLE_LIBOMPTARGET=OFF -DLIBOMP_OMPD_SUPPORT=OFF \
      -DOPENMP_ENABLE_OMPT_TOOLS=OFF -DLIBOMP_OMPT_SUPPORT=OFF -DOPENMP_STANDALONE_BUILD=ON \
      -DCMAKE_INSTALL_PREFIX="${OMP}" && cmake --build build && cmake --install build \
      || echo "（从源码编译 libomp 失败，改用 Homebrew 的 libomp）"
  fi
  if [ ! -f "${OMP}/lib/libomp.a" ]; then
    brew list libomp >/dev/null 2>&1 || brew install libomp || die "无法获得 libomp"
    LP="$(brew --prefix libomp)"
    [ -f "${LP}/lib/libomp.a" ] || die "Homebrew libomp 没有静态库"
    mkdir -p "${OMP}/lib" "${OMP}/include"
    cp "${LP}/lib/libomp.a" "${OMP}/lib/" && cp "${LP}/include/"*.h "${OMP}/include/"
    echo "（注意：使用的是 Homebrew 的 libomp）"
  fi
fi
ls -la "${OMP}/lib/libomp.a" || die "libomp.a 不存在"

# ---------------------------------------------------------------------------
step "4/5 编译多核 LibRaw（与官方 rawpy 0.27.0 同一份 LibRaw 源码）"
cd "${W}"
rm -rf rawpy-src && mkdir rawpy-src && tar xzf "${HERE}/rawpy-0.27.0.tar.gz" -C rawpy-src
LR="${W}/rawpy-src/rawpy-0.27.0/external"
DL="${W}/rawpy-stock/.dylibs"
BP="$(brew --prefix)"
OMPFLAGS="-Xpreprocessor -fopenmp -I${OMP}/include"
cmake -S "${LR}/LibRaw-cmake" -B "${W}/libraw-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DLIBRAW_PATH="${LR}/LibRaw" -DENABLE_X3FTOOLS=ON -DENABLE_6BY9RPI=ON -DENABLE_EXAMPLES=OFF \
  -DENABLE_RAWSPEED=OFF -DENABLE_OPENMP=ON \
  -DOpenMP_C_FLAGS="${OMPFLAGS}" -DOpenMP_CXX_FLAGS="${OMPFLAGS}" \
  -DOpenMP_C_LIB_NAMES=omp -DOpenMP_CXX_LIB_NAMES=omp -DOpenMP_omp_LIBRARY="${OMP}/lib/libomp.a" \
  -DLCMS2_INCLUDE_DIR="${BP}/opt/little-cms2/include" -DLCMS2_LIBRARIES="${DL}/liblcms2.2.dylib" \
  -DJPEG_INCLUDE_DIR="${BP}/opt/jpeg-turbo/include" -DJPEG_LIBRARY="${DL}/libjpeg.8.3.2.dylib" -DJPEG_LIBRARY_RELEASE="${DL}/libjpeg.8.3.2.dylib" \
  -DJASPER_INCLUDE_DIR="${BP}/opt/jasper/include" -DJASPER_LIBRARY="${DL}/libjasper.7.0.0.dylib" -DJASPER_LIBRARY_RELEASE="${DL}/libjasper.7.0.0.dylib" \
  -DCMAKE_INSTALL_PREFIX="${W}/libraw-install" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_NAME_DIR=@rpath \
  || die "LibRaw cmake 配置失败"
cmake --build "${W}/libraw-build" --target raw_r || die "LibRaw 编译失败"
NEW="$(ls "${W}"/libraw-build/libraw_r*.dylib 2>/dev/null | grep -E 'libraw_r\.[0-9]+\.[0-9]+\.[0-9]+\.dylib$' | head -1)"
[ -n "${NEW}" ] || NEW="$(find "${W}/libraw-build" -name 'libraw_r*.dylib' -type f | head -1)"
[ -f "${NEW}" ] || die "找不到编译出的 libraw_r dylib"
echo "新库：${NEW}"
otool -L "${NEW}"

# Point the three codec dylibs at the copies rawpy ships next to libraw.
for lib in liblcms2.2.dylib libjpeg.8.3.2.dylib libjasper.7.0.0.dylib; do
  old="$(otool -L "${NEW}" | awk '{print $1}' | grep "${lib}" | head -1)"
  [ -n "${old}" ] && [ "${old}" != "@loader_path/.dylibs/${lib}" ] && install_name_tool -change "${old}" "@loader_path/.dylibs/${lib}" "${NEW}"
done
install_name_tool -id "@rpath/libraw_r.25.dylib" "${NEW}"
codesign -f -s - "${NEW}"
echo "修正后的依赖："; otool -L "${NEW}"
if otool -L "${NEW}" | grep -q "/opt/homebrew"; then die "新库仍依赖 Homebrew 路径，不能分发"; fi
otool -l "${NEW}" | grep -A3 LC_BUILD_VERSION | grep minos

# The wheel stores libraw_r.dylib / .25.dylib / .25.0.0.dylib as separate copies
# (zip has no symlinks); _rawpy loads @rpath/libraw_r.25.dylib. Replace every real copy.
for f in "${RAWPY_DIR}"/libraw_r*.dylib; do
  if [ -L "${f}" ]; then echo "  保留链接 $(basename "${f}")"; continue; fi
  cp "${NEW}" "${f}" && codesign -f -s - "${f}" && echo "  已替换 $(basename "${f}")"
done
"${PY}" -c "import rawpy;print('rawpy flags:', rawpy.flags)" || { cp -a "${W}/rawpy-stock/." "${RAWPY_DIR}/"; die "新库加载失败，已恢复原版"; }

# ---------------------------------------------------------------------------
step "5/5 复测（多核 LibRaw）"
( cd "${SRC}" && "${PY}" bench_mac.py --label openmp --out "${RES}/openmp.json" ) || echo "（复测有部分失败）"

echo
echo "✅ 第一阶段完成。结果在 ${RES}，告诉 Claude 一声即可。"
echo "   如需恢复原版 rawpy：cp -a \"${W}/rawpy-stock/.\" \"${RAWPY_DIR}/\""
