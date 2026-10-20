#!/bin/bash
# NegPy Apple Silicon 优化 · 重新打包：部署最新源码 → Mac 实机完整测试 → 打包 App 与 DMG
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
B="${HOME}/.negpy-build"
SRC="${B}/negpy-0.65.0-zh_CN"
PY="${SRC}/.venv/bin/python"
RES="${HERE}/results"
LOG="${HERE}/repack.log"
NAME="NegPy 0.65.0 简体中文 · Apple Silicon 优化版"
DMG="${HERE}/NegPy-0.65.0-zh_CN-AppleSilicon优化版-arm64.dmg"
SRCPKG="negpy-0.65.0-zh_CN-apple-silicon-src.tar.gz"
export MACOSX_DEPLOYMENT_TARGET=11.0
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"
mkdir -p "${RES}"
exec > >(tee "${LOG}") 2>&1
step() { echo; echo "▶ $*"; }
die() { echo "❌ $*"; echo "（日志：${LOG}）"; exit 1; }

[ -x "${PY}" ] || die "找不到打包环境，请先运行第一阶段"
"${PY}" - <<'PYEOF' || die "打包环境里的 rawpy 不是多核版，请先运行第一阶段"
import os, rawpy, subprocess
lib = os.path.join(os.path.dirname(rawpy.__file__), "libraw_r.25.dylib")
out = subprocess.run(["nm", "-gU", lib], capture_output=True, text=True).stdout + subprocess.run(["nm", "-m", lib], capture_output=True, text=True).stdout
assert "kmpc" in out, "no OpenMP runtime in libraw"
print("多核 LibRaw：已确认")
PYEOF

# ---------------------------------------------------------------------------
step "1/4 部署优化后的源码（保留打包环境 .venv）"
rm -rf "${B}/opt-src" && mkdir -p "${B}/opt-src"
tar xzf "${HERE}/${SRCPKG}" -C "${B}/opt-src" || die "解压源码失败"
rsync -a --delete --exclude .venv --exclude build --exclude dist --exclude '*.pyc' --exclude __pycache__ \
  "${B}/opt-src/negpy-0.65.0-zh_CN/" "${SRC}/" || die "同步源码失败"
( cd "${SRC}" && git log --oneline -1 2>/dev/null || true )
( cd "${SRC}" && "${PY}" apple-silicon-build/verify_port.py ) | tee "${RES}/verify_port.txt" \
  || die "有优化在移植中丢失（见上方 ❌）"

# ---------------------------------------------------------------------------
step "2/4 Mac 实机测试（Metal GPU）"
( cd "${SRC}" && "${PY}" -m pytest -q -p no:cacheprovider \
    tests/test_apple_silicon.py tests/test_parallel_conversions.py tests/test_parallel_gate.py tests/test_parallel_dispatch.py \
    tests/test_preview_cache.py tests/test_rgbscan.py tests/test_i18n.py \
    tests/test_pipeline_parity.py tests/test_gpu_tiled_low_vram.py tests/test_gpu_layout_parity.py \
    tests/test_gpu_stage_skip.py tests/test_gpu_analysis_cache.py 2>&1 | tail -15 ) | tee "${RES}/mac_tests_focused.txt"
echo "（完整测试套件，约 5～10 分钟）"
( cd "${SRC}" && "${PY}" -m pytest -q -p no:cacheprovider 2>&1 | tail -12 ) | tee "${RES}/mac_tests_full.txt"

# ---------------------------------------------------------------------------
step "3/4 打包 App（官方 build.py，不让 uv 重装依赖）"
cd "${SRC}"
rm -rf build dist
"${PY}" build.py || {
  echo "（build.py 的签名/DMG 步骤失败，手动补签名）"
  [ -d dist/NegPy.app ] || die "没有生成 NegPy.app"
  xattr -cr dist/NegPy.app && codesign --force --deep -s - dist/NegPy.app || die "签名失败"
}
APP="${SRC}/dist/NegPy.app"
LR="$(find "${APP}" -name 'libraw_r.25.dylib' | head -1)"
[ -n "${LR}" ] || die "App 里找不到 libraw"
if nm -m "${LR}" 2>/dev/null | grep kmpc >/dev/null; then echo "App 内 LibRaw：多核版 ✅"; else die "App 内 LibRaw 不是多核版"; fi
OMPD="$(find "${APP}" -name 'libomp.dylib' | head -1)"
[ -n "${OMPD}" ] || die "App 里缺少 libomp.dylib（多核 LibRaw 必须链接动态 libomp）"
if nm -m "${LR}" 2>/dev/null | grep "__kmp_internal_end_thread" | grep -v undefined >/dev/null; then die "App 内 LibRaw 仍内置静态 libomp（会闪退），请先运行 修复多核解码闪退.command"; fi
echo "App 内 libomp：动态库 ✅（${OMPD#${APP}/}）"
if find "${APP}" -name '*.dylib' -o -name '*.so' | xargs otool -L 2>/dev/null | grep -q "/opt/homebrew"; then
  echo "⚠️ App 内有依赖 Homebrew 路径的库："; find "${APP}" -name '*.dylib' -o -name '*.so' | xargs otool -L 2>/dev/null | grep -B1 "/opt/homebrew" | head -20
fi

# ---------------------------------------------------------------------------
step "4/4 生成 DMG 并安装到 ~/Applications"
STAGE="${B}/dmg-stage-opt"
rm -rf "${STAGE}" && mkdir -p "${STAGE}"
ditto "${APP}" "${STAGE}/${NAME}.app"
ln -s /Applications "${STAGE}/Applications"
cp "${HERE}/${SRCPKG}" "${STAGE}/源码-${SRCPKG}"
cp "${HERE}/说明-AppleSilicon优化版.txt" "${STAGE}/说明.txt"
[ -f "${HERE}/移植资料包.tar.gz" ] || die "缺少 移植资料包.tar.gz（由 Claude 生成并放进本文件夹）"
tar xzf "${HERE}/移植资料包.tar.gz" -C "${STAGE}" || die "解压移植资料包失败"
cp "${STAGE}/移植资料包/改动与优化说明.md" "${STAGE}/改动与优化说明.txt"
xattr -cr "${STAGE}"
codesign --force --deep -s - "${STAGE}/${NAME}.app"
rm -f "${DMG}"
hdiutil create -volname "${NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" || die "生成 DMG 失败"
mkdir -p "${HOME}/Applications"
rm -rf "${HOME}/Applications/${NAME}.app"
ditto "${STAGE}/${NAME}.app" "${HOME}/Applications/${NAME}.app"
rm -rf "${STAGE}"
ls -la "${DMG}"

echo
echo "✅ 重新打包完成。"
echo "   DMG：${DMG}"
echo "   已安装：~/Applications/${NAME}.app"
echo "   告诉 Claude 一声即可。"
open -R "${DMG}"
