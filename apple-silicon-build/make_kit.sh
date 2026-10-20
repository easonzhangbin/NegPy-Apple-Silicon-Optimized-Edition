#!/bin/bash
# Build the porting kit (git bundle + patches + AI docs + scripts) from a git checkout.
# Usage: apple-silicon-build/make_kit.sh <base-commit> <branch> <out.tar.gz> [rawpy-sdist]
set -euo pipefail
BASE="$1"; BRANCH="$2"; OUT="$3"; RAWPY="${4:-}"
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; KIT="${TMP}/移植资料包"
mkdir -p "${KIT}/patches" "${KIT}/mac" "${KIT}/skill"
git -C "${ROOT}" bundle create -q "${KIT}/negpy-apple-silicon.bundle" "${BASE}..${BRANCH}"
git -C "${ROOT}" format-patch -q -o "${KIT}/patches" "${BASE}..${BRANCH}"
git -C "${ROOT}" log --format='%h %s' "${BASE}..${BRANCH}" > "${KIT}/patches/提交列表.txt"
echo "base ${BASE}  branch ${BRANCH}  head $(git -C "${ROOT}" rev-parse --short "${BRANCH}")" >> "${KIT}/patches/提交列表.txt"
A="${ROOT}/apple-silicon-build"
cp "${A}/PORTING.md" "${A}/改动与优化说明.md" "${A}/verify_port.py" "${A}/README.md" "${KIT}/"
cp "${A}/kit-CLAUDE.md" "${KIT}/CLAUDE.md"
cp "${A}/skill/SKILL.md" "${KIT}/skill/"
cp "${A}"/mac/*.command "${A}"/mac/*.py "${KIT}/mac/"
[ -n "${RAWPY}" ] && cp "${RAWPY}" "${KIT}/"
tar czf "${OUT}" -C "${TMP}" "移植资料包"
rm -rf "${TMP}"
echo "kit: ${OUT}"
