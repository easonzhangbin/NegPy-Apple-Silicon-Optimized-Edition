# r8 验证报告 / r8 validation report

日期 / Date: 2026-10-20. 基线 / Base: NegPy 0.65.0 custom r8.

## 本地验证 / Local validation

环境为 M1 Max / 64 GB / macOS arm64，不代表所有 M 系列设备，也不是 GitHub CI 已通过的声明。

Tested on an M1 Max / 64 GB / macOS arm64 system, not every M-series device. This is not a claim that GitHub CI has passed.

- 回归：9,283 passed、51 skipped、14 deselected，99 个子测试通过。
- Regression: 9,283 passed, 51 skipped, 14 deselected, 99 passing subtests.
- 后续功能、翻译、界面专项：111 passed，与前述测试有重叠，不可相加。
- Subsequent feature, localization and UI checks: 111 passed; these overlap with the regression run and are not additive.
- Ruff、翻译覆盖与格式检查通过；新增模块定向类型检查沿用项目忽略项。
- Ruff and translation coverage/format checks passed. Targeted new-module type checks used the project's ignore settings.
- 验证了 EXIF 旋转、取消、无纹理拒绝、无效配置拒绝、系数持久化，以及平场和色差共同启用时预览与导出源像素一致。
- Checked EXIF rotations, cancellation, texture and invalid-profile rejection, coefficient persistence, and identical preview/export source pixels with flat-field and measured CA enabled.

## 合成参考 / Synthetic references

| 指标 / Metric | 前 / Before | 后 / After |
|---|---:|---:|
| 红/绿独立区域 RMS 偏移 / R-G held-out RMS | 1.079 px | 0.034 px |
| 蓝/绿独立区域 RMS 偏移 / B-G held-out RMS | 0.757 px | 0.039 px |
| 平场亮度偏差 P95 / Brightness deviation P95 | 0.393 EV | 0.031 EV |
| 平场色彩偏差 P95 / Color deviation P95 | 0.133 EV | 0.005 EV |

上表色差测试使用已知径向变形的合成中性纹理，绿色保持不变；平场测试使用已知渐变与色偏的合成参考，不是实际 LAOWA 镜头的标定。README 的平场图片另采用用户提供的实际使用截图，包含照片背景；截图不替代上述合成测试，也不代表真实镜头色差校准已经验证。

The table uses synthetic neutral texture with known radial deformation for CA, with green unchanged, and synthetic brightness/color gradients for flat-field. These are not real LAOWA lens measurements. The README separately shows a user-provided actual flat-field usage screenshot with a photograph in the background; it does not replace these synthetic tests or establish real-lens CA validation.

## 安装包 / Local package

冻结 App 通过启动测试，Metal 在 M1 Max 上初始化。检查了临时签名、DMG 校验、只读挂载及依赖诊断；源码归档通过 CRC 并与打包暂存源码一致。启动检查不是长时间实拍稳定性保证。

The frozen app passed startup checks and initialized Metal on M1 Max. Ad-hoc signatures, DMG verification, read-only mounting and dependency diagnostics were checked. The source archive passed CRC and matched staged sources. Startup checks are not a long-duration capture stability guarantee.

公开源码清理了历史脚本中的私人参考路径，并增加双语说明。原始机器日志不直接公开。公开树的后续测试另行记录。

Public sources remove private reference paths from historical scripts and add bilingual documentation. Original machine logs are not published. Subsequent tests of the public tree are recorded separately.

## 公开源码复验 / Public-tree revalidation

公开上传目录完整回归：**9,290 passed、51 skipped、14 deselected、99 subtests passed**。测试确认导入的是公开目录中的代码；使用与本地 r8 匹配的运行环境及独立临时用户目录，没有读取真实照片数据库。Ruff 与三种语言各 2,922 条消息的翻译检查通过。

Full regression of the public upload tree: **9,290 passed, 51 skipped, 14 deselected, 99 subtests passed**. Imports were confirmed to use the public-tree code, with the matching r8 runtime and an isolated temporary user directory, not the real photo database. Ruff and translation checks passed for 2,922 messages in each of the three catalogs.
