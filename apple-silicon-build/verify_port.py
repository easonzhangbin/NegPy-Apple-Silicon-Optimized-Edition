"""Check that every Apple Silicon optimization survived a port onto a new upstream release.

Run from the repository root:  python apple-silicon-build/verify_port.py
Exit code 0 when every marker is present. A missing marker means an optimization was
dropped (a skipped commit, a conflict resolved the wrong way, or upstream rewrote the code)
and must be re-applied or deliberately retired here.

Markers are literal code that the optimization cannot work without; each names the guard
test that proves it still behaves.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (optimization, file, literal that must appear, guard test)
MARKERS = [
    ("Apple Silicon 检测与内存策略模块", "negpy/kernel/system/apple_silicon.py", "def ample_unified_memory(", "tests/test_apple_silicon.py"),
    ("16 GB 机器 HQ 上限 8192 px", "negpy/kernel/system/apple_silicon.py", "cap = 8192", "test_hq_cap_scales_with_memory_and_respects_device_limit"),
    ("按内存放大预览缓存（启动时应用）", "negpy/desktop/main.py", "apply_apple_cache_defaults(APP_CONFIG)", "test_apply_cache_defaults_only_raises_and_only_on_apple"),
    ("64 GB 缓存 12 GB（全尺寸预读所需）", "negpy/kernel/system/apple_silicon.py", '"preview_cache_max_bytes": 12 * GIB', "test_apply_cache_defaults_only_raises_and_only_on_apple"),
    ("HQ 上限按统一内存", "negpy/kernel/system/override.py", "hq_texture_cap(unified_memory_bytes()", "test_effective_cap_on_apple_silicon"),
    ("全尺寸邻居预读：控制器", "negpy/desktop/controller.py", "full_resolution=full_resolution_prefetch(", "test_full_resolution_prefetch_gate"),
    ("全尺寸邻居预读：工作线程", "negpy/desktop/workers/render.py", "full_resolution=task.full_resolution,", "test_full_resolution_prefetch_gate"),
    ("全尺寸邻居预读：缓存键", "negpy/services/rendering/preview_manager.py", "full_resolution=full_resolution,", "test_full_resolution_prefetch_gate"),
    ("全尺寸裁剪不淘汰当前画面", "negpy/services/rendering/preview_cache.py", "full = [k for k in full if not self._is_protected(k, protected, False)]", "test_full_res_trim_keeps_the_protected_frame"),
    ("三色扫描三张同时解码", "negpy/services/rendering/preview_manager.py", 'thread_name_prefix="rgb-decode"', "test_parallel_triplet_decode_matches_serial"),
    ("RAW 尺寸探测（内存估算）", "negpy/infrastructure/loaders/memory.py", "def _raw_dimensions(", "test_raw_dimension_probe_sizes_an_unparseable_raw"),
    ("HQ 预览用导出分块（不强制低显存）", "negpy/services/rendering/image_processor.py", "memory_bounded=not ample_unified_memory()", "test_large_preview_uses_memory_bounded_gpu_tiling"),
    ("分块原图常驻 GPU", "negpy/services/rendering/image_processor.py", "reuse_source_tiles=ample_unified_memory()", "test_resident_source_tiles_render_identical_pixels"),
    ("分块原图常驻 GPU：引擎", "negpy/services/rendering/gpu_engine.py", "source_texture=tile_src,", "test_resident_source_tiles_render_identical_pixels"),
    ("分块参考渲染独立分析缓存", "negpy/services/rendering/gpu_engine.py", "self._tiled_ref_caches = (self._analysis_cache", "test_tiled_meter_caching_renders_identical_pixels"),
    ("分块整帧分析缓存", "negpy/services/rendering/gpu_engine.py", "self._tiled_meter_cache = (", "test_tiled_meter_caching_renders_identical_pixels"),
    ("分块路径传入原图身份", "negpy/services/rendering/gpu_engine.py", "analysis_source_hash=analysis_source_hash,\n                reuse_source_tiles=", "test_tiled_meter_caching_renders_identical_pixels"),
    ("Apple 芯片默认多核 CPU", "negpy/kernel/system/parallel.py", 'return machine == "arm64"', "tests/test_parallel_gate.py"),
    ("多核转换内核：8 位量化", "negpy/kernel/image/logic.py", "@parallel_njit(cache=True, fastmath=True)\ndef _to_uint8_jit(", "tests/test_parallel_conversions.py"),
    ("多核转换内核：16 位量化", "negpy/kernel/image/logic.py", "@parallel_njit(cache=True, fastmath=True)\ndef _to_uint16_jit(", "tests/test_parallel_conversions.py"),
    ("多核转换内核：uint16→float", "negpy/kernel/image/logic.py", "@parallel_njit(cache=True, fastmath=True)\ndef uint16_to_float32(", "tests/test_parallel_conversions.py"),
    ("多核转换内核：RGB→RGBA", "negpy/kernel/image/logic.py", "@parallel_njit(cache=True)\ndef rgb_to_rgba_into(", "tests/test_parallel_conversions.py"),
    ("多核转换内核：RGBA→RGB", "negpy/kernel/image/logic.py", "@parallel_njit(cache=True)\ndef rgba_to_rgb_into(", "tests/test_parallel_conversions.py"),
    ("TIFF 多核压缩", "negpy/services/export/encoders.py", 'kwargs["maxworkers"] = max(1, os.cpu_count() or 1)', "test_threaded_tiff_encode_writes_identical_bytes"),
    ("TIFF 64 行条带", "negpy/services/export/encoders.py", 'kwargs["rowsperstrip"] = 64', "test_tiff_strip_layout_keeps_every_pixel"),
    ("三色扫描邻居预读：控制器", "negpy/desktop/controller.py", "return self._rgb_prefetch_task(asset, generation, protected_file_hashes)", "test_rgb_prefetch_task_matches_the_foreground_load_and_is_gated"),
    ("三色扫描邻居预读：工作线程", "negpy/desktop/workers/render.py", "self._preview_service.prefetch_linear_preview_rgb(", "test_prefetch_worker_routes_triplets_to_the_rgb_warm"),
    ("三色扫描邻居预读：缓存", "negpy/services/rendering/preview_manager.py", "def prefetch_linear_preview_rgb(", "test_rgb_triplet_prefetch_hits_the_real_load"),
    ("多核 LibRaw 必须链接动态 libomp（守护测试）", "tests/test_apple_silicon.py", "def test_openmp_libraw_uses_the_shared_runtime(", "test_openmp_libraw_uses_the_shared_runtime"),
    ("OpenMP 用简单锁（防止并发解码卡死）", "negpy/__init__.py", "_configure_openmp_runtime()", "test_openmp_lock_kind_is_set_on_apple_silicon_only"),
    ("OpenMP 锁类型：策略", "negpy/kernel/system/apple_silicon.py", 'env["KMP_LOCK_KIND"] = "tas"', "test_package_import_sets_the_lock_before_rawpy_is_used"),
    ("全尺寸预读先读下一张", "negpy/desktop/controller.py", "neighbours.reverse()", "test_full_resolution_prefetch_warms_the_next_frame_first"),
]


def main() -> int:
    missing = []
    for name, rel, needle, guard in MARKERS:
        path = ROOT / rel
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        ok = needle in text
        print(f"{'✅' if ok else '❌'} {name:28}  {rel}")
        if not ok:
            missing.append((name, rel, guard))
    print()
    if missing:
        print(f"❌ {len(missing)} 项优化缺失：")
        for name, rel, guard in missing:
            print(f"   - {name}（{rel}；守护测试 {guard}）")
        return 1
    print(f"✅ 全部 {len(MARKERS)} 项优化都在。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
