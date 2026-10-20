#!/bin/bash
# NegPy Apple Silicon 优化 · 修复多核解码闪退：静态 libomp → 动态 libomp
#
# 原因：静态链接的 libomp（KMP_DYNAMIC_LIB=0）在最后一个用过它的线程退出时会关闭整个
# 运行库（kmp_runtime.cpp __kmp_internal_end_thread）；此时另一个线程进入 LibRaw 就会在
# __kmpc_critical_with_hint 里访问已释放的内存而闪退。动态库版不会在线程退出时关闭。
#
# 另：动态 libomp 默认的排队锁在 Apple 芯片上会让并发解码卡死（全部线程卡在
# __kmp_acquire_queuing_lock / LibRaw::copy_bayer）。negpy 启动时设 KMP_LOCK_KIND=tas 解决。
#
# 步骤：压力测试复现 → 编译动态 libomp → 重新编译 LibRaw 链接它 → 压力测试验证 →
#       解码像素与官方版逐位核对 → 自动接着运行 第三阶段-重新打包.command
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
B="${HOME}/.negpy-build"
SRC="${B}/negpy-0.65.0-zh_CN"
PY="${SRC}/.venv/bin/python"
W="${B}/apple-opt"
OMPS="${W}/omp-shared"
RES="${HERE}/results"
LOG="${HERE}/fix-omp.log"
LLVM_VER="19.1.7"
RAWS=("/path/to/reference.RW2" "/path/to/reference M11/L1009237.DNG" "/path/to/reference.ARW")
export MACOSX_DEPLOYMENT_TARGET=11.0
export PATH="${W}/tools/bin:${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
mkdir -p "${RES}"
exec > >(tee "${LOG}") 2>&1
T0=$(date +%s)
step() { echo; echo "▶ $*   （已用 $(( ($(date +%s) - T0) / 60 )) 分 $(( ($(date +%s) - T0) % 60 )) 秒）"; }
die() { echo "❌ $*"; echo "（日志：${LOG}）"; exit 1; }

[ -x "${PY}" ] || die "找不到打包环境 ${PY}"
command -v cmake >/dev/null || die "找不到 cmake（第一阶段的工具环境 ${W}/tools）"
RAWPY_DIR="$("${PY}" -c 'import os,rawpy;print(os.path.dirname(rawpy.__file__))')"
FILES=(); for f in "${RAWS[@]}"; do [ -f "${f}" ] && FILES+=("${f}"); done
[ ${#FILES[@]} -gt 0 ] || die "找不到用于测试的 RAW 文件"
cp "${HERE}/omp_stress.py" "${W}/omp_stress.py"
echo "预计总耗时：修复约 7 分钟，随后自动重新打包约 15～20 分钟。"

# ---------------------------------------------------------------------------
step "1/6 压力测试：现在的版本（预计 1 分钟；已复现过则跳过）"
if [ -s "${RES}/omp_stress_before.txt" ] && [ "$(cat "${RES}/omp_stress_before.txt")" != "0" ]; then
  echo "   之前已复现过（退出码 $(cat "${RES}/omp_stress_before.txt")），跳过"
elif nm -m "$(ls "${RAWPY_DIR}"/libraw_r.25.dylib)" 2>/dev/null | grep "__kmp_internal_end_thread" | grep -v undefined >/dev/null; then
  "${PY}" "${W}/omp_stress.py" 45 "${FILES[@]}"
  rc=$?
  if [ ${rc} -eq 0 ]; then echo "   （45 秒内没有复现，这类竞争很偶然；照样修复）"
  elif [ ${rc} -eq 3 ]; then echo "   ✅ 已复现：卡死（静态 libomp 的另一种表现）"
  else echo "   ✅ 已复现崩溃（退出码 ${rc}），与你的崩溃报告一致"; fi
  echo "${rc}" > "${RES}/omp_stress_before.txt"
else
  echo "   打包环境里已经是动态 libomp，跳过"
fi

# ---------------------------------------------------------------------------
step "2/6 编译动态版 libomp（LLVM ${LLVM_VER}，最低 macOS 11；约 2 分钟）"
if [ ! -f "${OMPS}/lib/libomp.dylib" ]; then
  cd "${W}"
  if [ ! -d llvm-src/openmp ]; then
    for p in openmp cmake; do
      f="${p}-${LLVM_VER}.src.tar.xz"
      [ -f "${f}" ] || curl -fL --retry 3 -o "${f}" "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VER}/${f}" || die "下载 ${f} 失败"
    done
    rm -rf llvm-src && mkdir llvm-src && cd llvm-src
    tar xf "../openmp-${LLVM_VER}.src.tar.xz" && mv "openmp-${LLVM_VER}.src" openmp
    tar xf "../cmake-${LLVM_VER}.src.tar.xz" && mv "cmake-${LLVM_VER}.src" cmake
    cd "${W}"
  fi
  rm -rf "${W}/llvm-src/build-shared"
  cmake -S "${W}/llvm-src/openmp" -B "${W}/llvm-src/build-shared" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DLIBOMP_ENABLE_SHARED=ON -DOPENMP_ENABLE_LIBOMPTARGET=OFF -DLIBOMP_OMPD_SUPPORT=OFF \
    -DOPENMP_ENABLE_OMPT_TOOLS=OFF -DLIBOMP_OMPT_SUPPORT=OFF -DOPENMP_STANDALONE_BUILD=ON \
    -DLIBOMP_INSTALL_ALIASES=OFF -DCMAKE_INSTALL_PREFIX="${OMPS}" \
    && cmake --build "${W}/llvm-src/build-shared" && cmake --install "${W}/llvm-src/build-shared" \
    || die "编译动态 libomp 失败"
fi
OMPLIB="${OMPS}/lib/libomp.dylib"
[ -f "${OMPLIB}" ] || die "没有生成 libomp.dylib"
otool -l "${OMPLIB}" | grep -A3 LC_BUILD_VERSION | grep minos

# ---------------------------------------------------------------------------
step "3/6 重新编译 LibRaw，链接动态 libomp（约 2 分钟）"
LR="${W}/rawpy-src/rawpy-0.27.0/external"
[ -d "${LR}/LibRaw" ] || { rm -rf "${W}/rawpy-src" && mkdir -p "${W}/rawpy-src" && tar xzf "${HERE}/rawpy-0.27.0.tar.gz" -C "${W}/rawpy-src"; }
DL="${W}/rawpy-stock/.dylibs"
BP="$(brew --prefix)"
OMPFLAGS="-Xpreprocessor -fopenmp -I${OMPS}/include"
BLD="${W}/libraw-build-shared"
rm -rf "${BLD}"
cmake -S "${LR}/LibRaw-cmake" -B "${BLD}" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DLIBRAW_PATH="${LR}/LibRaw" -DENABLE_X3FTOOLS=ON -DENABLE_6BY9RPI=ON -DENABLE_EXAMPLES=OFF \
  -DENABLE_RAWSPEED=OFF -DENABLE_OPENMP=ON \
  -DOpenMP_C_FLAGS="${OMPFLAGS}" -DOpenMP_CXX_FLAGS="${OMPFLAGS}" \
  -DOpenMP_C_LIB_NAMES=omp -DOpenMP_CXX_LIB_NAMES=omp -DOpenMP_omp_LIBRARY="${OMPLIB}" \
  -DLCMS2_INCLUDE_DIR="${BP}/opt/little-cms2/include" -DLCMS2_LIBRARIES="${DL}/liblcms2.2.dylib" \
  -DJPEG_INCLUDE_DIR="${BP}/opt/jpeg-turbo/include" -DJPEG_LIBRARY="${DL}/libjpeg.8.3.2.dylib" -DJPEG_LIBRARY_RELEASE="${DL}/libjpeg.8.3.2.dylib" \
  -DJASPER_INCLUDE_DIR="${BP}/opt/jasper/include" -DJASPER_LIBRARY="${DL}/libjasper.7.0.0.dylib" -DJASPER_LIBRARY_RELEASE="${DL}/libjasper.7.0.0.dylib" \
  -DCMAKE_INSTALL_NAME_DIR=@rpath \
  || die "LibRaw cmake 配置失败"
cmake --build "${BLD}" --target raw_r || die "LibRaw 编译失败"
NEW="$(find "${BLD}" -name 'libraw_r*.dylib' -type f | head -1)"
[ -f "${NEW}" ] || die "找不到编译出的 libraw_r"

for lib in liblcms2.2.dylib libjpeg.8.3.2.dylib libjasper.7.0.0.dylib libomp.dylib; do
  old="$(otool -L "${NEW}" | awk '{print $1}' | grep "${lib}" | head -1)"
  [ -n "${old}" ] && [ "${old}" != "@loader_path/.dylibs/${lib}" ] && install_name_tool -change "${old}" "@loader_path/.dylibs/${lib}" "${NEW}"
done
install_name_tool -id "@rpath/libraw_r.25.dylib" "${NEW}"
codesign -f -s - "${NEW}"
otool -L "${NEW}"
otool -L "${NEW}" | grep "@loader_path/.dylibs/libomp.dylib" >/dev/null || die "新 LibRaw 没有链接动态 libomp"
if otool -L "${NEW}" | tail -n +2 | grep -E "/opt/homebrew|/Users/" >/dev/null; then die "新库仍依赖本机绝对路径，不能分发"; fi
if nm -m "${NEW}" | grep "__kmp_internal_end_thread" | grep -v undefined >/dev/null; then die "新 LibRaw 里仍然内置了 libomp"; fi

# ---------------------------------------------------------------------------
step "4/6 替换打包环境里的 LibRaw（原版和静态版都已备份）"
[ -d "${W}/rawpy-omp-static" ] || { mkdir -p "${W}/rawpy-omp-static" && cp -a "${RAWPY_DIR}/." "${W}/rawpy-omp-static/"; }
cp "${OMPLIB}" "${RAWPY_DIR}/.dylibs/libomp.dylib"
install_name_tool -id "@rpath/libomp.dylib" "${RAWPY_DIR}/.dylibs/libomp.dylib"
codesign -f -s - "${RAWPY_DIR}/.dylibs/libomp.dylib"
for f in "${RAWPY_DIR}"/libraw_r*.dylib; do
  [ -L "${f}" ] && continue
  cp "${NEW}" "${f}" && codesign -f -s - "${f}" && echo "  已替换 $(basename "${f}")"
done
"${PY}" -c "import rawpy;print('rawpy 加载正常', rawpy.__version__)" || { cp -a "${W}/rawpy-omp-static/." "${RAWPY_DIR}/"; die "新库加载失败，已恢复"; }

# ---------------------------------------------------------------------------
step "5/6 部署新源码，压力测试：修复后（预计 3 分钟，必须不崩溃、不卡死）"
SRCPKG="negpy-0.65.0-zh_CN-apple-silicon-src.tar.gz"
rm -rf "${B}/opt-src" && mkdir -p "${B}/opt-src" && tar xzf "${HERE}/${SRCPKG}" -C "${B}/opt-src" || die "解压源码失败"
rsync -a --delete --exclude .venv --exclude build --exclude dist --exclude '*.pyc' --exclude __pycache__ \
  "${B}/opt-src/negpy-0.65.0-zh_CN/" "${SRC}/" || die "同步源码失败"
grep -q "_configure_openmp_runtime()" "${SRC}/negpy/__init__.py" || die "源码里没有 OpenMP 锁设置，请让 Claude 检查源码包"
fail() { cp -a "${W}/rawpy-omp-static/." "${RAWPY_DIR}/"; die "修复后仍然$1，已恢复原状，请把日志发给 Claude"; }
echo "   ① 8 个线程混合打开/解码（60 秒）"
env -u KMP_LOCK_KIND NEGPY_SRC="${SRC}" STRESS_SAMPLE="${RES}/sample_after_mixed.txt" "${PY}" "${W}/omp_stress.py" 60 "${FILES[@]}" || fail "崩溃或卡死（混合）"
echo "   ② 3 个线程同时完整解码，像三色扫描（45 秒）"
env -u KMP_LOCK_KIND NEGPY_SRC="${SRC}" STRESS_CONC=3 STRESS_FULL_RATIO=1 STRESS_SAMPLE="${RES}/sample_after_full.txt" "${PY}" "${W}/omp_stress.py" 45 "${FILES[@]}" || fail "崩溃或卡死（完整解码）"
echo "0" > "${RES}/omp_stress_after.txt"

# ---------------------------------------------------------------------------
step "6/6 核对：解码像素与官方版逐位一致，速度仍是多核（约 1 分钟）"
cp "${HERE}/bench_mac.py" "${SRC}/bench_mac.py"
( cd "${SRC}" && BENCH_RUNS=2 "${PY}" bench_mac.py --label omp-shared --out "${RES}/omp_shared.json" --sections decode_rawpy ) || die "测速失败"
"${PY}" - "${RES}/stock.json" "${RES}/omp_shared.json" "${RES}/openmp.json" <<'PYEOF' || die "解码像素与官方版不一致"
import json, sys
stock, new = json.load(open(sys.argv[1]))["decode_rawpy"], json.load(open(sys.argv[2]))["decode_rawpy"]
try:
    static = json.load(open(sys.argv[3]))["decode_rawpy"]
except Exception:
    static = {}
bad = 0
for k, v in new.items():
    s = stock.get(k, {})
    same = s.get("sha") == v["sha"]
    bad += not same
    print(f"   {k}: 官方 {s.get('median_ms')} ms → 静态多核 {static.get(k, {}).get('median_ms')} ms → 动态多核 {v['median_ms']} ms，像素{'一致 ✅' if same else '不一致 ❌'}")
sys.exit(1 if bad else 0)
PYEOF

echo
echo "✅ 修复完成（用时 $(( ($(date +%s) - T0) / 60 )) 分钟）。接着自动重新打包（约 15～20 分钟）……"
bash "${HERE}/第三阶段-重新打包.command"
