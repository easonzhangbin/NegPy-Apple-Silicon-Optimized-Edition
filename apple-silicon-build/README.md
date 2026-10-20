# Apple Silicon build tooling

Everything here is outside the `negpy` package and ships nothing into the app.

| File | Where it runs | What it does |
|---|---|---|
| `verify_port.py` | anywhere | After rebasing onto a new upstream release: checks that every Apple Silicon optimization is still in the code, names the guard test for each. Exit 1 if any is missing. |
| `mac/stage1.command` | Mac | Builds static LLVM OpenMP and an OpenMP LibRaw from the rawpy sdist (`rawpy-<ver>.tar.gz` next to it), swaps it into the build venv's rawpy, benchmarks before/after. Re-run only when upstream bumps rawpy. The version is hard-coded (`rawpy-0.27.0`). |
| `mac/fix-omp.command` | Mac | Required after stage1: rebuilds libomp as a **shared** library, relinks LibRaw against it, stress-tests (`omp_stress.py`), checks pixels, then runs repack. A static libomp crashes (runtime shutdown when the last root thread exits). |
| `mac/omp_stress.py` | Mac | Many short-lived threads opening/decoding RAWs; reproduces the static-libomp crash and the queuing-lock deadlock. `NEGPY_SRC=<src>` imports negpy first, like the app. |
| `mac/diag-omp.command`, `mac/diag-omp2.command` | Mac | Compare stock / static / shared LibRaw, lock kinds and concurrency; `sample` stacks on a hang. |
| `mac/repack.command` | Mac | Deploys the source tarball, runs `verify_port.py`, the focused and full test suites on Metal, `build.py`, checks LibRaw in the app is the OpenMP one, builds the DMG. |
| `mac/bench_mac.py`, `mac/tiff_bench.py` | Mac | Real-file timings with pixel hashes, to compare two builds exactly. |
| `mac/redo-dmg.command` | Mac | Rebuild only the DMG from the already-built app (no tests, no build). |
| `make_kit.sh` | anywhere with git | Builds `移植资料包.tar.gz`: git bundle, format-patch series, PORTING.md, CLAUDE.md, change list, verify_port.py, Mac scripts, skill, rawpy sdist. The Mac scripts put it into the DMG. |
| `PORTING.md` | — | Porting guide for AI assistants / developers: baseline, commit layout, steps, design of every optimization, pitfalls. |
| `改动与优化说明.md` | — | Human change list (Chinese); copied into the DMG as `改动与优化说明.txt`. |
| `kit-CLAUDE.md`, `skill/SKILL.md` | — | Entry file and Claude skill shipped in the kit. |
| `mac/说明-AppleSilicon优化版.txt` | — | Readme copied into the DMG. |

Commit layout on `apple-silicon-opt` (keeps cherry-picks onto a new release small):
code + tests commits first, then one docs/translations commit, then this tooling.
Translation guides conflict on almost every upstream release; re-apply the docs commit
by hand, then `make translations`.

