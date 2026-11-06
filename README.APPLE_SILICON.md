# NegPy 0.67.0 — Apple Silicon Metal

Based on the upstream `0.67.0` tag (`1d360ec2104f7f89ec35a640a8f13984623a62c1`).

## 中文更新说明

- 以 NegPy 0.67.0 为基础，保留官方三色合成、Rust 多核引擎与导出流程。
- 高分辨率分块预览可复用参考缩图、整幅测光结果及 Metal 源图纹理，减少重复计算和上传。
- 纹理复用需要 Apple Silicon、Metal、至少 32 GiB 统一内存及足够的可用内存。切回非分块预览时释放分块缓存。
- 安装包仅支持 Apple Silicon（arm64），采用临时签名，未经 Apple 公证。应用使用独立数据目录，不自动迁移正式版设置；不包含 Capture Lab 六帧校准。

## English update notes

- Ports the local 0.66 Apple Silicon preview/cache defaults and tiled-render reuse.
- On Apple Silicon with the Metal backend, at least 32 GiB installed and sufficient
  available memory, tiled previews can reuse uploaded source tiles. Low-memory
  rendering retains upstream's bounded path.
- Reuses the resized reference image and whole-frame measurements across compatible
  tiled renders. Source and geometry changes invalidate the corresponding caches.
- Releases tiled resources when the preview switches to the non-tiled path.
- Keeps the upstream Rust/Rayon engine, shaders, and export pipeline. This port
  does not include the custom six-frame calibration or other Capture Lab changes.
- The arm64 DMG uses an ad-hoc signature and is not notarized. The app uses a
  separate data directory and does not automatically migrate upstream settings.

Build the arm64 DMG on macOS:

```sh
NEGPY_APP_NAME='NegPy Apple Silicon' NEGPY_ENTRY_POINT=desktop_apple_silicon.py \
NEGPY_MACOS_BUNDLE_ID=org.negpy.apple-silicon-067 NEGPY_MACOS_ARCH=arm64 \
uv run --locked --group camera --group plustek --group pieusb --group nkscan python build.py
```

Run focused verification on an Apple Silicon Mac:

```sh
QT_QPA_PLATFORM=offscreen uv run --locked pytest -q tests/test_apple_silicon.py tests/test_gpu_tiled_parity.py tests/test_gpu_tiled_pool_reuse.py tests/test_image_processor.py
```

## Flameeye research companion

Use the [Flameeye P32 companion](research/flameeye-mac/README.md) to check camera exposure on clear film base and save a measured lighting reference.
