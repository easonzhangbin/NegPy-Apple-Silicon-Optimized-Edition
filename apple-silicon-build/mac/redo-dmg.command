#!/bin/bash
# NegPy Apple Silicon 优化 · 只重做 DMG：用已编好的 App，放入说明、改动清单与移植资料包（不重新测试、不重新编译）
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
B="${HOME}/.negpy-build"
SRC="${B}/negpy-0.65.0-zh_CN"
PY="${SRC}/.venv/bin/python"
RES="${HERE}/results"
LOG="${HERE}/redo-dmg.log"
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
APP="${SRC}/dist/NegPy.app"
[ -d "${APP}" ] || die "没有找到已编好的 App（${APP}），请先运行 第三阶段-重新打包.command"
LR="$(find "${APP}" -name 'libraw_r.25.dylib' | head -1)"
if nm -m "${LR}" 2>/dev/null | grep kmpc >/dev/null; then echo "App 内 LibRaw：多核版 ✅"; else die "App 内 LibRaw 不是多核版"; fi
OMPD="$(find "${APP}" -name 'libomp.dylib' | head -1)"
[ -n "${OMPD}" ] || die "App 里缺少 libomp.dylib（多核 LibRaw 必须链接动态 libomp）"
if nm -m "${LR}" 2>/dev/null | grep "__kmp_internal_end_thread" | grep -v undefined >/dev/null; then die "App 内 LibRaw 仍内置静态 libomp（会闪退），请先运行 修复多核解码闪退.command"; fi
echo "App 内 libomp：动态库 ✅（${OMPD#${APP}/}）"
step "1/1 生成 DMG 并安装到 ~/Applications"
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
echo "✅ DMG 已重做（含说明、改动清单与移植资料包）。"
echo "   DMG：${DMG}"
echo "   已安装：~/Applications/${NAME}.app"
echo "   告诉 Claude 一声即可。"
open -R "${DMG}"
