# NegPy Apple Silicon 优化移植资料包

这是一个“把 Apple 芯片优化移植到新版 NegPy”的资料包，不是一个可运行的项目。

先读 `PORTING.md`：里面有上游基线、提交结构、移植步骤、每项优化的设计和守护测试、已知坑。
要移植的代码在 `negpy-apple-silicon.bundle`（`git fetch` 它）或者 `patches/`（`git am`）里。
移植完成后运行 `python apple-silicon-build/verify_port.py`，必须全部 ✅。
与维护者用中文沟通，每个耗时步骤都要给出预计时间。
