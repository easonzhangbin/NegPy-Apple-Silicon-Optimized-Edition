"""Apple Silicon resource policy: memory-scaled defaults that change no rendering math."""

from dataclasses import replace
from unittest.mock import patch

import numpy as np

from negpy.kernel.system import apple_silicon as asi
from negpy.kernel.system.apple_silicon import GIB, cache_budget, hq_texture_cap, is_apple_silicon
from negpy.kernel.system.config import APP_CONFIG
from negpy.kernel.system.override import INTEGRATED_GPU_TEXTURE_CAP_DEFAULT, effective_max_texture_size


def test_detects_only_macos_arm64():
    assert is_apple_silicon("darwin", "arm64")
    assert not is_apple_silicon("darwin", "x86_64")
    assert not is_apple_silicon("win32", "arm64")
    assert not is_apple_silicon("linux", "arm64")


def test_hq_cap_scales_with_memory_and_respects_device_limit():
    assert hq_texture_cap(8 * GIB, 16384) is None  # generic integrated cap stays
    assert hq_texture_cap(16 * GIB, 16384) == 8192
    assert hq_texture_cap(64 * GIB, 16384) == 16384
    assert hq_texture_cap(64 * GIB, 8192) == 8192
    assert hq_texture_cap(None, 16384) is None


class _Gpu:
    is_integrated = True
    limits = {"max_texture_dimension_2d": 16384}


def test_effective_cap_on_apple_silicon():
    cfg = replace(APP_CONFIG, max_texture_size=None)
    with patch.object(asi, "is_apple_silicon", return_value=True), patch.object(asi, "unified_memory_bytes", return_value=64 * GIB):
        assert effective_max_texture_size(cfg, _Gpu()) == 16384
    with patch.object(asi, "is_apple_silicon", return_value=True), patch.object(asi, "unified_memory_bytes", return_value=8 * GIB):
        assert effective_max_texture_size(cfg, _Gpu()) == INTEGRATED_GPU_TEXTURE_CAP_DEFAULT
    with patch.object(asi, "is_apple_silicon", return_value=False):
        assert effective_max_texture_size(cfg, _Gpu()) == INTEGRATED_GPU_TEXTURE_CAP_DEFAULT


def test_explicit_texture_size_still_wins():
    cfg = replace(APP_CONFIG, max_texture_size=4096)
    with patch.object(asi, "is_apple_silicon", return_value=True), patch.object(asi, "unified_memory_bytes", return_value=64 * GIB):
        assert effective_max_texture_size(cfg, _Gpu()) == 4096


def test_cache_budget_tiers():
    assert cache_budget(8 * GIB) == {}
    assert cache_budget(16 * GIB)["preview_cache_max_bytes"] == 2 * GIB
    assert cache_budget(32 * GIB)["preview_cache_max_full_res_entries"] == 3
    assert cache_budget(64 * GIB)["preview_cache_max_full_res_entries"] == 4


def test_apply_cache_defaults_only_raises_and_only_on_apple():
    cfg = replace(APP_CONFIG)
    with patch.object(asi, "is_apple_silicon", return_value=False):
        assert asi.apply_cache_defaults(cfg, 64 * GIB) == {}
    with patch.object(asi, "is_apple_silicon", return_value=True):
        changed = asi.apply_cache_defaults(cfg, 64 * GIB)
    assert changed["preview_cache_max_bytes"] == 12 * GIB
    assert cfg.preview_cache_max_full_res_entries == 4
    big = replace(APP_CONFIG, preview_cache_max_bytes=20 * GIB)
    with patch.object(asi, "is_apple_silicon", return_value=True):
        asi.apply_cache_defaults(big, 64 * GIB)
    assert big.preview_cache_max_bytes == 20 * GIB  # never lowered


def _negative(h: int, w: int, seed: int = 5) -> np.ndarray:
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    ramp = (xx / w) * 0.5 + (yy / h) * 0.25
    blobs = 0.08 * np.sin(xx / 90.0) * np.cos(yy / 40.0) + 0.05 * np.sin((xx + yy) / 160.0)
    img = np.empty((h, w, 3), dtype=np.float32)
    img[..., 0] = 0.55 + ramp * 0.30 + blobs
    img[..., 1] = 0.35 + ramp * 0.25 + blobs * 0.7
    img[..., 2] = 0.15 + ramp * 0.20 + blobs * 0.4
    img += rng.normal(0, 0.01, img.shape).astype(np.float32)
    return np.clip(img, 1e-4, 1.0)


def test_tiled_meter_caching_renders_identical_pixels():
    """A tiled render that reuses its whole-frame meters (source identity given) paints exactly
    what a render that re-meters every time (no identity: the upstream behaviour) paints,
    across slider moves, a process change and interleaved direct proxy frames."""
    import pytest

    from negpy.domain.models import WorkspaceConfig
    from negpy.features.process.models import ProcessMode
    from negpy.infrastructure.gpu.device import GPUDevice
    from negpy.services.rendering import gpu_engine as ge

    if not GPUDevice.get().is_available:
        pytest.skip("GPU not available")
    img = _negative(1100, 1500)
    proxy = _negative(220, 300, seed=6)
    base = WorkspaceConfig()
    base = replace(base, process=replace(base.process, process_mode=ProcessMode.C41), lab=replace(base.lab, clahe_strength=0.3))
    seq = [
        base,
        replace(base, exposure=replace(base.exposure, density=1.08)),
        replace(base, exposure=replace(base.exposure, density=0.93, grade=125.0)),
        replace(base, process=replace(base.process, luma_range_clip=base.process.luma_range_clip + 0.01)),
        replace(base, exposure=replace(base.exposure, density=1.08)),
    ]
    with patch.object(ge, "TILING_THRESHOLD_PX", 100_000):
        fresh, cached = ge.GPUEngine(), ge.GPUEngine()
        try:
            for n, cfg in enumerate(seq):
                assert fresh.requires_tiling(img, cfg)
                a, _ = fresh.process(img, cfg, memory_bounded=True)
                # A drag paints the proxy directly under the same identity between releases.
                cached.process_to_texture(proxy, cfg, source_hash="src", analysis_source_hash="src")
                b, _ = cached.process(img, cfg, memory_bounded=True, source_hash="src", analysis_source_hash="src")
                np.testing.assert_array_equal(np.asarray(b), np.asarray(a), err_msg=f"frame {n}")
            assert cached._tiled_meter_cache is not None
        finally:
            fresh.destroy_all()
            cached.destroy_all()


def test_resident_source_tiles_render_identical_pixels():
    """Tiles bound from the GPU-resident cache paint exactly what freshly uploaded tiles paint,
    and a geometry change re-uploads instead of binding stale tiles."""
    import pytest

    from negpy.domain.models import WorkspaceConfig
    from negpy.infrastructure.gpu.device import GPUDevice
    from negpy.services.rendering import gpu_engine as ge

    if not GPUDevice.get().is_available:
        pytest.skip("GPU not available")
    img = _negative(1100, 1500, seed=9)
    base = WorkspaceConfig()
    seq = [
        base,
        replace(base, exposure=replace(base.exposure, density=1.1)),
        replace(base, geometry=replace(base.geometry, flip_horizontal=True)),
        replace(base, geometry=replace(base.geometry, flip_horizontal=True), exposure=replace(base.exposure, density=0.9)),
        replace(base, exposure=replace(base.exposure, density=1.1)),
    ]
    with patch.object(ge, "TILING_THRESHOLD_PX", 100_000), patch.object(ge, "TILE_SIZE", 512):
        fresh, resident = ge.GPUEngine(), ge.GPUEngine()
        try:
            for n, cfg in enumerate(seq):
                a, _ = fresh.process(img, cfg, source_hash="s", analysis_source_hash="s")
                b, _ = resident.process(img, cfg, source_hash="s", analysis_source_hash="s", reuse_source_tiles=True)
                np.testing.assert_array_equal(np.asarray(b), np.asarray(a), err_msg=f"frame {n}")
                assert resident._resident_tiles is not None and len(resident._resident_tiles[1]) > 1
            assert fresh._resident_tiles is None
        finally:
            fresh.destroy_all()
            resident.destroy_all()
        assert resident._resident_tiles is None
