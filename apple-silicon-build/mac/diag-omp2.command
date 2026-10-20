#!/bin/bash
# 诊断第二轮：OpenMP 锁类型与并发数（约 4 分钟，只读，不改动打包环境）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="${HOME}/.negpy-build"; SRC="${B}/negpy-0.65.0-zh_CN"; PY="${SRC}/.venv/bin/python"; W="${B}/apple-opt"
RES="${HERE}/results/omp-diag"; LOG="${HERE}/diag-omp2.log"
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
: > "${RES}/summary2.txt"
run2() { run "$@"; tail -1 "${RES}/summary.txt" >> "${RES}/summary2.txt"; }
run2 F_shared_mixed8_tas      shared 0.15 KMP_LOCK_KIND=tas
run2 G_shared_mixed3          shared 0.15 STRESS_CONC=3
run2 H_shared_mixed3_tas      shared 0.15 STRESS_CONC=3 KMP_LOCK_KIND=tas
run2 J_shared_full3_tas       shared 1.0  STRESS_CONC=3 KMP_LOCK_KIND=tas
run2 K_shared_full8_tas       shared 1.0  STRESS_CONC=8 KMP_LOCK_KIND=tas
echo; echo "✅ 诊断（第二轮）完成 $(el)。告诉 Claude 一声即可。"
