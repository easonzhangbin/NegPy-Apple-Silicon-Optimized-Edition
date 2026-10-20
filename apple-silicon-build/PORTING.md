# NegPy Apple Silicon 优化版：移植说明（写给 AI / 开发者）

> 读者：Claude、Claude Code、Xcode 里的编码助手，或任何要把这套优化移植到新版 NegPy 的开发者。
> 目标：在**新的上游版本**上重新应用这套 Apple 芯片（M 系列）优化，保证**像素结果与官方版一致**，然后重新打包 Mac DMG。
> 维护者的偏好：用中文沟通；每个耗时步骤都要给出预计时间。

---

## 1. 基本信息

| 项目 | 值 |
|---|---|
| 上游仓库 | https://github.com/marcinz606/NegPy （GPL-3.0） |
| 优化所基于的上游提交 | `0dc536a8`（0.65.0 + 官方多语言支持，含官方 zh_CN.json） |
| 优化分支 | `apple-silicon-opt`（在本资料包的 `negpy-apple-silicon.bundle` 里） |
| 技术栈 | Python 3.13 · PyQt6 · WebGPU（wgpu，Mac 上是 Metal）· numba（CPU 内核）· rawpy/LibRaw · tifffile · PyInstaller |
| 优化生效范围 | 只在 macOS + arm64 生效；或在所有平台上与原版**逐位一致**（多核转换内核、TIFF 多线程压缩） |
| 测试规模 | 云端 Linux 完整套件 9221 项通过；Mac（M1 Max 64 GB）完整套件 9217 项通过 |

## 2. 资料包内容

```
negpy-apple-silicon.bundle   完整提交记录：git fetch 它即可得到 apple-silicon-opt 分支
patches/                     同样的提交，git format-patch 格式（可 git am，也可直接阅读）
PORTING.md                   本文件
CLAUDE.md                    给 Claude Code 的入口，指向本文件
改动与优化说明.md              给人看的改动清单（中文）
verify_port.py               移植核对脚本：逐项检查每个优化的关键代码是否还在
mac/                         Mac 端脚本：编译多核 LibRaw、测试 + 打包、测速
rawpy-0.27.0.tar.gz          rawpy 源码包（含 LibRaw 源码），用于编译多核 LibRaw
skill/SKILL.md               Claude 技能：移植流程（可直接导入为技能）
```

## 3. 提交结构（移植单位）

`git log 0dc536a8..apple-silicon-opt` 按顺序有 4 个提交：

1. `perf(apple-silicon): unified-memory policy, full-res prefetch, tiled HQ reuse, multi-core kernels and TIFF`：核心优化（代码 + 测试）
2. `perf(apple-silicon): prefetch RGB-scan triplet neighbours; warm the next frame first`：三色扫描预读（代码 + 测试）
3. `docs: Apple Silicon defaults in the user guide (all locales)`：用户手册，几乎每次升级都会冲突
4. `build: Apple Silicon port check and Mac build/bench scripts`：本目录 `apple-silicon-build/`

代码与文档刻意分开：翻译手册在上游变动频繁，混在一起会导致整个代码提交在冲突时被丢掉。

## 4. 移植步骤

```bash
git clone https://github.com/marcinz606/NegPy && cd NegPy
git fetch /path/to/negpy-apple-silicon.bundle apple-silicon-opt:apple-silicon-opt
git checkout -b apple-silicon-<新版本> <新版本 tag 或提交>
git cherry-pick <提交1> <提交2> <提交4>     # 先挑代码和工具
# 提交 3（文档）：对照 diff 手动改 docs/USER_GUIDE.md 与 negpy/translations/USER_GUIDE.{zh_CN,ja,ko}.md
make translations                             # 重新生成 USER_GUIDE.en.md（tests/test_i18n.py 会检查）
python apple-silicon-build/verify_port.py     # 必须全部 ✅
```

**冲突处理原则**：先弄清上游为什么改这段代码，再决定怎么合并；不要机械地保留旧代码。若上游已经自带了同类优化，就保留上游的实现，并在 `verify_port.py` 的 `MARKERS` 里删掉对应条目（在提交说明里写明原因）。

**测试**（云端约 11 分钟；内存小的机器不要同时跑两套）：

```bash
python -m pytest -q tests/test_apple_silicon.py tests/test_parallel_conversions.py tests/test_parallel_gate.py \
  tests/test_parallel_dispatch.py tests/test_preview_cache.py tests/test_preview_manager.py tests/test_controller.py \
  tests/test_override_config.py tests/test_image_processor.py tests/test_i18n.py
python -m pytest -q          # 完整套件
```

在 Linux/Windows 上测“通用策略”的测试，必须把 `is_apple_silicon` / `ample_unified_memory` patch 为 False，否则在 Mac 上跑会失败（已有测试就是这样写的，新测试照做）。

**rawpy 版本变化**：查看上游依赖里 rawpy 的版本。如果不是 0.27.0，需要新版 rawpy 源码包，并修改 `mac/stage1.command` 里写死的 `rawpy-0.27.0`，然后在 Mac 上先跑一遍 stage1（编译多核 LibRaw）。版本没变则跳过。

**Mac 端打包**：把 `git archive --prefix=negpy-<ver>-zh_CN/` 生成的源码包放到 Mac 的工作文件夹，运行 `mac/repack.command`（约 15～20 分钟：移植核对 10 秒 → 重点测试 2 分钟 → 完整测试 5～10 分钟 → build.py 5 分钟 → DMG 2 分钟）。改版本号时同时修改脚本里的 `NAME`、`DMG`、`SRCPKG`。

## 5. 每项优化：做了什么、在哪、怎么验证

`verify_port.py` 中的 `MARKERS` 是权威清单（中文名、文件、必须存在的代码字面量、守护测试）。下面是设计说明。

### 5.1 统一内存策略：`negpy/kernel/system/apple_silicon.py`（新文件）
- `is_apple_silicon()`、`unified_memory_bytes()`（sysconf，失败时用 `sysctl hw.memsize`）。
- `hq_texture_cap(mem, device_limit)`：HQ 预览的长边上限。≥32 GB 为 16384，≥16 GB 为 8192，否则为 None（保持上游的集成显卡默认值 6144）。不超过 Metal 设备的 `max_texture_dimension_2d`。由 `override.effective_max_texture_size` 的集成显卡分支调用（延迟导入）。
- `cache_budget(mem)` / `apply_cache_defaults(APP_CONFIG)`：按内存放大预览缓存。64 GB 为 12 GiB / 16 项 / 全尺寸 4 项 / render memo 16；32 GB 为 6 GiB / 12 / 3 / 12；16 GB 为 2 GiB / 10 / 2 / 10。在 `desktop/main.py` 中、`apply_override` **之前**调用，并且**只调高不调低**，所以 override.toml 和偏好设置仍然优先。
- `ample_unified_memory()`：Apple 芯片且内存 ≥32 GB。是后面几项优化的总开关。
- `full_resolution_prefetch(hq)`：开启 HQ 且内存充足时，邻居预读改为全尺寸。

### 5.2 全尺寸邻居预读
- 问题：上游预读的是预览尺寸，HQ 会话读的是全尺寸缓存键，所以预读永远不命中。
- `controller._neighbor_prefetch_task` 传 `full_resolution=full_resolution_prefetch(...)`；`workers/render.py::_process_prefetch` 和 `preview_manager.prefetch_linear_preview(full_resolution=...)` 把它用于缓存键、内存估算（`_FULL_RES_ESTIMATE_EDGE = 16384`）和加载。
- `preview_cache.put`：裁剪全尺寸条目时，超出量按**全部**全尺寸条目计算，然后跳过受保护的（当前画面），不会把正在看的那张淘汰掉。
- `infrastructure/loaders/memory.py::_raw_dimensions`：Pillow 读不出尺寸的 RAW（如 RW2）改用 LibRaw 读文件头。否则会按 16384² 估算（约 11 GB），预读被内存检查拒绝。
- 预读仍然经过上游的 `decide_prefetch`（系统可用内存安全检查）。

### 5.3 三色扫描（RGB triplet）
- `preview_manager.load_linear_preview_rgb`：在 Apple 芯片上用 `ThreadPoolExecutor(max_workers=3, thread_name_prefix="rgb-decode")` 同时解码三张曝光（LibRaw 会释放 GIL）。合成结果与串行一致。
- 邻居预读（提交 2）：上游 `_neighbor_prefetch_task` 遇到组合（`is_composite`）就返回 None。现在改为 `return self._rgb_prefetch_task(...)`：只处理有 `green_path`、已保存设置为三色、未启用拼接/HDR 的条目，且要求 `ample_unified_memory()`。参数与前台加载完全相同（色彩空间、`use_camera_wb=not effective_linear_raw`、HQ、`demosaic_preview`、rgbscan）。
- `preview_manager.prefetch_linear_preview_rgb`：先检查合成缓存键是否已存在；内存估算按单张 ×2 计缓存、×3 计临时；经过 `decide_prefetch` 检查；然后调用真正的 `load_linear_preview_rgb`，并带上 `cache_protected_file_hashes` 与 `cache_preserve_full_resolution`。
- 全尺寸预读时，邻居顺序反转为“下一张优先”（`neighbours.reverse()`），因为内存可能只够放一张。

### 5.4 大图 HQ 预览走分块渲染：`gpu_engine.py`、`image_processor.py`
- 超过 `TILING_THRESHOLD_PX`（12 MP）的 HQ 预览：内存充足时 `memory_bounded=not ample_unified_memory()`，用与导出相同的 2048 分块，而不是 1024 低显存分块。
- 整帧分析缓存：`self._tiled_meter_cache` 的键包含源 hash、形状、process/geometry 设置、自动曝光/对比度标志、`TARGETS_REVISION`、测光 ROI 等。松手后不再重新分析整帧。参考帧渲染使用独立的分析缓存（`self._tiled_ref_caches`，`ref_hash=f"{hash}\x00tiled-ref"`），不会污染主缓存。
- 原图分块常驻 GPU：`self._resident_tiles = (layout_key, {rect: GPUTexture})`，每块只上传一次。`process_to_texture(source_texture=...)` 跳过上传；`cleanup()` 中调用 `_drop_resident_tiles()`。只在 `reuse_source_tiles` 为真时启用（内存充足、有源 hash、非 memory_bounded）。
- 守护测试：分块渲染结果与“每次重新分析/重新上传”的上游行为**逐像素一致**。

### 5.5 CPU 多核
- `kernel/system/parallel.py::default_cpu_parallel`：darwin 上仅 arm64 默认开启多核（上游在 Mac 上全部关闭）。异常退出后仍沿用上游的“提示关闭”机制。
- `kernel/image/logic.py`：`_to_uint8_jit`、`_to_uint16_jit`、`uint8_to_float32`、`uint16_to_float32` 改为 `@parallel_njit(cache=True, fastmath=True)` + `prange`；`rgb_to_rgba_into`、`rgba_to_rgb_into` 改为 `@parallel_njit(cache=True)`，按行并行。`parallel_njit` 同时保留串行和并行两份，小数组（`SERIAL_MAX_ELEMENTS`）走串行。`tests/test_parallel_conversions.py` 用舍入边界值、NaN、Inf 验证两者逐位相同。

### 5.6 导出 TIFF：`services/export/encoders.py::encode_tiff`
- `maxworkers = os.cpu_count()`；有压缩时 `rowsperstrip = 64`，让 tifffile 分条并行压缩。解码出的像素完全相同（文件字节因条带布局不同而不同，这是预期的）。

### 5.7 多核 LibRaw（不在 Python 代码里，属于构建步骤）
- 官方 Mac 版 rawpy wheel 的 LibRaw 没有开启 OpenMP。做法：用 LLVM 19.1.7 编译 libomp（minos 11.0），再用 rawpy 源码包里的同一份 LibRaw、`-DENABLE_OPENMP=ON` 重新编译 `libraw_r`。链接 wheel 自带的 lcms2/jpeg/jasper，以及放在 `rawpy/.dylibs/` 下的 `libomp.dylib`（都用 `@loader_path/.dylibs/` 引用），替换 rawpy 目录下 3 份 `libraw_r*.dylib`。
- **libomp 必须是动态库。** 最初版本用的是静态 libomp，实际使用中闪退了（`EXC_BAD_ACCESS` in `__kmpc_critical_with_hint` ← `libraw_memmgr::mem_ptr` ← `LibRaw::open_file`）。原因：静态构建时 `KMP_DYNAMIC_LIB=0`，`kmp_runtime.cpp::__kmp_internal_end_thread` 会在**最后一个 root 线程退出时关闭整个运行库**，而 NegPy 有很多短命线程（预读、缩略图、三色解码池）在调用 LibRaw，另一个线程恰好在此时进入就会访问已释放的状态。动态库会等到库卸载时才关闭。
- **还必须设 `KMP_LOCK_KIND=tas`。** 动态 libomp 默认用排队锁实现 `#pragma omp critical`。在 Apple 芯片上，只要有 3 个以上解码同时进行，几十秒内就会死锁：所有线程都卡在 `__kmp_acquire_queuing_lock`（位于 `LibRaw::copy_bayer` 的 omp outlined 区域），负责释放的线程在等一个永远不会接上的后继线程。实测对比（M1 Max）：默认锁 3 并发卡死、8 并发卡死；`tas` 锁下 8 并发混合、3/8 并发完整解码全部通过，吞吐量不变；`OMP_NUM_THREADS=1` 也不卡，但会失去多核。解决方法：`negpy/__init__.py` 在导入时调用 `apple_silicon.configure_openmp_runtime()`（只在 Apple 芯片上设置，用户自己设置的值优先）。守护测试：`test_openmp_lock_kind_is_set_on_apple_silicon_only`、`test_package_import_sets_the_lock_before_rawpy_is_used`。
- 构建脚本：`mac/stage1.command`（第一次：静态版 + 测速），然后**必须**运行 `mac/fix-omp.command`：编译动态 libomp、重新链接 LibRaw、用 `mac/omp_stress.py` 做多线程压力测试（修复前复现、修复后 90 秒不崩），核对像素，然后自动打包。rawpy 升级时两步都要重跑；最好把 stage1 改成直接构建动态版。
- 验证方法：`otool -L libraw_r.25.dylib` 中包含 `@loader_path/.dylibs/libomp.dylib`；`nm -m` 里没有已定义的 `__kmp_internal_end_thread`（守护测试 `test_openmp_libraw_uses_the_shared_runtime`，打包脚本也会检查 App 内的库）。`rawpy.flags["OPENMP"]` 仍显示 False，因为它只是编译期标记，这是正常的。解码像素与官方版逐位一致。

## 6. 不做的事（以及原因）
- **GPU 去马赛克**：无法保证与 LibRaw AHD 逐位一致。
- **用内嵌 JPEG 做快速预览**：负片的内嵌 JPEG 是橙色底片，闪一下反而干扰。
- **改动任何调色/渲染数学**：所有优化只改调度、缓存和并行方式。

## 7. 已知坑
- **静态 libomp 会闪退，默认锁会卡死**（见 5.7）。只能用动态 libomp，并且设 `KMP_LOCK_KIND=tas`。这两类线程问题在单元测试和测速中都碰不到，必须做压力测试（`mac/omp_stress.py`；用 `NEGPY_SRC=<源码>` 让它像 App 一样先导入 negpy）。诊断脚本 `mac/diag-omp*.command` 会对比各种配置，卡死时用 `sample` 抓下所有线程的调用栈。
- bash 3.2（macOS 自带）：`$VAR` 后面紧跟全角字符时会报 unbound variable，要写成 `${VAR}`。在 `set -o pipefail` 下用 `grep -q` 会触发 SIGPIPE 误报，改用 `grep ... >/dev/null`。
- 在 iCloud 文件夹里 codesign 会报 “resource fork, Finder information, or similar detritus”，所以构建放在 `~/.negpy-build`。
- 三色扫描对齐用的 OpenCV `phaseCorrelate` 在多线程下有极小的不确定性，属于上游行为，与本优化无关。比较三色输出时要在同一进程内比较，或者多跑几次。
- 改了 `docs/USER_GUIDE.md` 之后，一定要 `make translations`，否则 `tests/test_i18n.py` 会报 stale。

## 8. 后续可做（按收益排序，尚未实现）
1. HQ 两段式显示：先显示半尺寸正片（约 0.2 秒），再换成全尺寸。
2. 导入时并行生成缩略图（目前由 QTimer 串行生成，尚未测量）。
3. 批量导出流水线化（解码、渲染、编码重叠进行）。
4. 测量画布上传/显示的耗时。
5. 编译 LibRaw 时加 `-mcpu=apple-m1` 等调优，预计快 5～10%。
