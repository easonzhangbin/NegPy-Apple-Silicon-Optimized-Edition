---
name: negpy-apple-silicon-port
description: Port the user's NegPy Apple Silicon optimizations and zh_CN build onto a new upstream NegPy release, verify, and rebuild the Mac DMG.
---

# NegPy Apple Silicon 优化移植

用户维护一个基于 github.com/marcinz606/NegPy 的 Apple 芯片（M 系列）优化版，分享给朋友使用。每次上游发布新版本，都要把优化移植过去并重新打包 DMG。全程用中文回复，并给出每一步的预计耗时（用户希望看到“计时器”）。不要用 sleep 轮询等待 Mac 脚本，请用户在脚本结束时说一声。

详细设计见同一资料包中的 `PORTING.md`。

## 资料在哪
- DMG 里的“移植资料包”，或用户 Mac 的 `~/Documents/Codex/2026-10-06/negpy-apple-silicon/`：
  - `negpy-apple-silicon.bundle` / `patches/`：优化分支 `apple-silicon-opt` 的全部提交（基于上游 0dc536a8）。
  - `rawpy-<ver>.tar.gz`：rawpy 源码包。`mac/stage1.command` 编译多核 LibRaw；`mac/repack.command` 负责测试和打包。
- Mac 打包环境：`~/.negpy-build/negpy-0.65.0-zh_CN`（含 `.venv`；放在 iCloud 外面，避免 codesign 报 detritus 错误）。

## 提交结构
1. 核心优化：代码 + 测试
2. 三色扫描预读、全尺寸预读优先读下一张：代码 + 测试
3. docs：用户手册（几乎每次都冲突，手动重做，然后 `make translations`）
4. build：`apple-silicon-build/`（verify_port.py、PORTING.md、Mac 脚本、make_kit.sh）

新增优化也要遵守“代码与文档分开提交”，并在 `verify_port.py` 的 `MARKERS` 中加一行。

## 步骤
1. clone 上游；`git fetch <bundle> apple-silicon-opt`；用中文简述新版本有哪些新功能。
2. 在新 tag 上建分支，cherry-pick 提交 1、2、4；提交 3 手动合并。冲突时先理解上游改了什么，再决定怎么合并。
3. 运行 `python apple-silicon-build/verify_port.py`，必须全部 ✅。上游已自带同类优化时，在 MARKERS 中注明退役。
4. 云端测试：先跑重点套件（见 PORTING.md），再在后台跑完整套件（约 11 分钟，内存小，不要同时跑两套）。通用策略的测试要 patch `is_apple_silicon` / `ample_unified_memory` 为 False。
5. rawpy 版本变了：准备新的 sdist，修改 stage1 和 fix-omp 中写死的版本号，让用户先跑 `mac/stage1.command`，再跑 `mac/fix-omp.command`（编译动态 libomp、压力测试、像素核对，然后自动打包）。版本没变则跳过这一步。
   - libomp 必须是**动态库**：静态库会在最后一个线程退出时关闭运行库，导致闪退。
   - 必须使用 `KMP_LOCK_KIND=tas`（`negpy/__init__.py` 在导入时设置）：默认的排队锁在 Apple 芯片上，3 个以上解码同时进行时会卡死。
   - 这两个问题只有压力测试 `mac/omp_stress.py`（`NEGPY_SRC=<源码>`）才能发现；`mac/diag-omp*.command` 可以对比各种配置，并在卡死时用 `sample` 抓下调用栈。
6. 交付到 Mac：
   - `git archive --prefix=negpy-<ver>-zh_CN/` 生成源码包。
   - `apple-silicon-build/make_kit.sh <base> apple-silicon-opt 移植资料包.tar.gz rawpy-<ver>.tar.gz` 生成移植资料包。
   - 更新打包脚本里的版本号和 DMG 名。
   - 更新 `改动与优化说明.md`。
   - 用 device_commit_files 写入 Mac 文件夹，并 chmod +x。
7. 用户在 Mac 上运行 `第三阶段-重新打包.command`（约 15～20 分钟）。它会检查 App 内的 libomp 是否为动态库。DMG 内容包括：App、说明.txt、改动与优化说明.txt、移植资料包/、源码包。只改了文档时，运行 `只重做DMG.command` 即可（约 2 分钟）。结束后读取 `results/` 中的 verify_port.txt、mac_tests_*.txt 和 repack.log 进行检查。
8. 可选：运行 bench_mac.py 测速（各项都附带像素哈希，前后两版必须逐位一致）。

## 原则
- 优化只在 macOS/arm64 生效，或在所有平台逐位一致；不改调色算法；不做 GPU 去马赛克。
- override.toml 和偏好设置优先于 Apple 默认值。
- GPL-3：DMG 中必须附带完整源码。
- bash 3.2：变量后紧跟全角字符时要写 `${VAR}`；在 pipefail 下用 `grep >/dev/null`，不要用 `grep -q`。
