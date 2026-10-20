#!/bin/bash
# 诊断：修复后的 LibRaw 在压力测试下卡死，找出卡在哪里（约 4 分钟，只读，不改动打包环境）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="${HOME}/.negpy-build"; SRC="${B}/negpy-0.65.0-zh_CN"; PY="${SRC}/.venv/bin/python"; W="${B}/apple-opt"
RES="${HERE}/results/omp-diag"; LOG="${HERE}/diag-omp.log"
mkdir -p "${RES}"; exec > >(tee "${LOG}") 2>&1
RAWS=("/path/to/reference.RW2" "/path/to/reference M11/L1009237.DNG" "/path/to/reference.ARW")
FILES=(); for f in "${RAWS[@]}"; do [ -f "${f}" ] && FILES+=("${f}"); done
cp "${HERE}/omp_stress.py" "${W}/omp_stress.py"
T0=$(date +%s)
el() { echo "（已用 $(( ($(date +%s) - T0) / 60 )) 分 $(( ($(date +%s) - T0) % 60 )) 秒）"; }

# Three rawpy builds side by side, selected with PYTHONPATH (nothing installed is touched).
V="${W}/diag-variants"; rm -rf "${V}"; mkdir -p "${V}/stock" "${V}/static" "${V}/shared"
cp -a "${W}/rawpy-stock" "${V}/stock/rawpy"
cp -a "${W}/rawpy-omp-static" "${V}/static/rawpy"
cp -a "${W}/rawpy-omp-static" "${V}/shared/rawpy"
NEW="$(find "${W}/libraw-build-shared" -name 'libraw_r*.dylib' -type f | head -1)"
for f in "${V}/shared/rawpy"/libraw_r*.dylib; do [ -L "${f}" ] || cp "${NEW}" "${f}"; done
cp "${W}/omp-shared/lib/libomp.dylib" "${V}/shared/rawpy/.dylibs/libomp.dylib"
install_name_tool -id "@rpath/libomp.dylib" "${V}/shared/rawpy/.dylibs/libomp.dylib" 2>/dev/null
codesign -f -s - "${V}/shared/rawpy/.dylibs/libomp.dylib" >/dev/null 2>&1

run() {  # name variant full_ratio [env...]
  local name="$1" var="$2" ratio="$3"; shift 3
  echo; echo "▶ ${name}  $(el)"
  env PYTHONPATH="${V}/${var}" STRESS_FULL_RATIO="${ratio}" STRESS_SAMPLE="${RES}/sample_${name}.txt" "$@" \
    "${PY}" -c "import rawpy,os;print('   rawpy 来自', os.path.dirname(rawpy.__file__))"
  env PYTHONPATH="${V}/${var}" STRESS_FULL_RATIO="${ratio}" STRESS_SAMPLE="${RES}/sample_${name}.txt" "$@" \
    "${PY}" "${W}/omp_stress.py" 35 "${FILES[@]}"
  echo "   ${name} 结果：退出码 $?（0=通过 3=卡死 139=崩溃）" | tee -a "${RES}/summary.txt"
}
: > "${RES}/summary.txt"
run A_stock_mixed       stock  0.15
run B_shared_openonly   shared 0
run C_shared_mixed      shared 0.15
run D_shared_mixed_1thr shared 0.15 OMP_NUM_THREADS=1
run E_shared_mixed_passive shared 0.15 OMP_WAIT_POLICY=passive KMP_BLOCKTIME=0
echo; echo "✅ 诊断完成 $(el)。告诉 Claude 一声即可。"
