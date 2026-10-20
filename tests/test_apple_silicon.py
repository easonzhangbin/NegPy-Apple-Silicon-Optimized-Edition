"""Apple Silicon resource policy: memory-scaled defaults that change no rendering math."""

from dataclasses import replace
from unittest.mock import patch

import numpy as np

from negpy.kernel.system import apple_silicon as asi
from negpy.kernel.system.apple_silicon import GIB, cache_budget, full_resolution_prefetch, hq_texture_cap, is_apple_silicon
from negpy.kernel.system.config import APP_CONFIG
from negpy.kernel.system.override import INTEGRATED_GPU_TEXTURE_CAP_DEFAULT, effective_max_texture_size
from negpy.services.rendering.preview_cache import PreviewBufferCache, PreviewCacheKey


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


def test_full_resolution_prefetch_gate():
    with patch.object(asi, "is_apple_silicon", return_value=True):
        assert full_resolution_prefetch(True, 64 * GIB)
        assert full_resolution_prefetch(True, 32 * GIB)
        assert not full_resolution_prefetch(True, 16 * GIB)
        assert not full_resolution_prefetch(False, 64 * GIB)
    with patch.object(asi, "is_apple_silicon", return_value=False):
        assert not full_resolution_prefetch(True, 64 * GIB)


def _key(h: str) -> PreviewCacheKey:
    return PreviewCacheKey(file_hash=h, use_camera_wb=False, workspace_color_space="Adobe RGB", full_resolution=True)


def test_full_res_trim_keeps_the_protected_frame():
    cfg = replace(APP_CONFIG, preview_cache_max_full_res_entries=2, preview_cache_max_bytes=10**9, preview_cache_max_entries=8)
    cache = PreviewBufferCache(cfg)
    buf = np.zeros((4, 4, 3), np.float32)
    cache.put(_key("current"), buf, (4, 4), {})
    cache.put(_key("neighbour-a"), buf, (4, 4), {}, protected_file_hashes=("current",), preserve_full_resolution=True)
    cache.put(_key("neighbour-b"), buf, (4, 4), {}, protected_file_hashes=("current",), preserve_full_resolution=True)
    assert cache.contains(_key("current"))
    assert cache.contains(_key("neighbour-b"))
    assert not cache.contains(_key("neighbour-a"))


def test_full_res_trim_unprotected_is_unchanged():
    cfg = replace(APP_CONFIG, preview_cache_max_full_res_entries=2, preview_cache_max_bytes=10**9, preview_cache_max_entries=8)
    cache = PreviewBufferCache(cfg)
    buf = np.zeros((4, 4, 3), np.float32)
    for h in ("a", "b", "c"):
        cache.put(_key(h), buf, (4, 4), {})
    assert not cache.contains(_key("a"))
    assert cache.contains(_key("b")) and cache.contains(_key("c"))


def test_parallel_triplet_decode_matches_serial(tmp_path):
    """The Apple Silicon side-by-side triplet decode must assemble the same pixels."""
    import tifffile

    from negpy.features.rgbscan.models import RgbScanConfig
    from negpy.services.rendering import preview_manager as pmod

    rng = np.random.default_rng(3)
    paths = []
    for ch in range(3):
        img = np.full((120, 160, 3), 800, np.uint16)
        img[..., ch] = (rng.random((120, 160)) * 30000 + 5000).astype(np.uint16)
        p = tmp_path / f"shot{ch}.tif"
        tifffile.imwrite(p, img)
        paths.append(str(p))
    cfg = RgbScanConfig(enabled=True, green_path=paths[1], blue_path=paths[2], align=True)
    results = {}
    for apple in (False, True):
        with patch.object(pmod, "is_apple_silicon", return_value=apple):
            out, dims, meta = pmod.PreviewManager().load_linear_preview_rgb(paths[0], cfg, "Adobe RGB", False, True)
        results[apple] = (np.asarray(out).copy(), dims)
    assert results[True][1] == results[False][1]
    np.testing.assert_array_equal(results[True][0], results[False][0])


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


def test_raw_dimension_probe_sizes_an_unparseable_raw(tmp_path):
    """A RAW that neither the TIFF reader nor Pillow parses (Panasonic RW2's TIFF variant) is
    sized from LibRaw's header, not as the worst-case max_edge square."""
    from types import SimpleNamespace

    from negpy.infrastructure.loaders import memory

    p = tmp_path / "frame.RW2"
    p.write_bytes(b"IIU\x00" + b"\x00" * 64)

    class _Raw:
        sizes = SimpleNamespace(width=12032, height=8018)

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    with patch("rawpy.imread", return_value=_Raw()):
        assert memory._image_dimensions(str(p)) == (12032, 8018)
        est = memory.estimate_preview_memory(str(p), 16384, "raw")
    assert est.cached_bytes < 16384 * 16384 * 3 * 4  # not the dimensionless worst case
    assert memory._raw_dimensions(str(tmp_path / "x.tif")) is None  # only camera RAW suffixes


def test_threaded_tiff_encode_writes_identical_bytes():
    """Multi-threaded strip compression must write the very same file as one thread."""
    from negpy.services.export.encoders import encode_tiff

    a = (np.random.default_rng(4).random((700, 900, 3)) * 65535).astype(np.uint16)
    assert encode_tiff(a) == encode_tiff(a, maxworkers=1)


def test_tiff_strip_layout_keeps_every_pixel():
    """64-row strips change the file layout, never the pixels: decode equals the source,
    and equals what tifffile's own default layout decodes to."""
    import io

    import tifffile

    from negpy.services.export.encoders import encode_tiff

    for dtype, top in ((np.uint16, 65535), (np.uint8, 255)):
        a = (np.random.default_rng(5).random((333, 517, 3)) * top).astype(dtype)
        ours = tifffile.imread(io.BytesIO(encode_tiff(a)))
        stock = tifffile.imread(io.BytesIO(encode_tiff(a, rowsperstrip=None, maxworkers=1)))
        np.testing.assert_array_equal(ours, a)
        np.testing.assert_array_equal(stock, a)
        with tifffile.TiffFile(io.BytesIO(encode_tiff(a))) as tif:
            assert tif.pages[0].rowsperstrip == 64


def _triplet(tmp_path):
    import tifffile

    from negpy.features.rgbscan.models import RgbScanConfig

    rng = np.random.default_rng(7)
    paths = []
    for ch in range(3):
        img = np.full((120, 160, 3), 800, np.uint16)
        img[..., ch] = (rng.random((120, 160)) * 30000 + 5000).astype(np.uint16)
        p = tmp_path / f"rgb{ch}.tif"
        tifffile.imwrite(p, img)
        paths.append(str(p))
    return paths, RgbScanConfig(enabled=True, green_path=paths[1], blue_path=paths[2], align=True)


def test_rgb_triplet_prefetch_hits_the_real_load(tmp_path):
    """The background trichrome warm fills exactly the entry the foreground open reads:
    stepping onto the triplet decodes nothing and shows the same pixels as a cold open."""
    from negpy.services.rendering import preview_manager as pmod

    paths, cfg = _triplet(tmp_path)
    cold, cold_dims, _ = pmod.PreviewManager().load_linear_preview_rgb(
        paths[0], cfg, "Adobe RGB", use_camera_wb=True, full_resolution=True, file_hash="red", demosaic="auto"
    )
    pm = pmod.PreviewManager()
    with patch.object(pmod, "available_system_memory_bytes", return_value=256 * GIB):
        assert pm.prefetch_linear_preview_rgb(
            paths[0], cfg, "Adobe RGB", use_camera_wb=True, file_hash="red", full_resolution=True, demosaic="auto",
            protected_file_hashes=("selected",),
        )
    with patch.object(pm, "load_linear_preview", side_effect=AssertionError("decoded on a warmed step")):
        hit, dims, _ = pm.load_linear_preview_rgb(
            paths[0], cfg, "Adobe RGB", use_camera_wb=True, full_resolution=True, file_hash="red", demosaic="auto"
        )
    assert dims == cold_dims
    np.testing.assert_array_equal(np.asarray(hit), np.asarray(cold))
    # Already warm: a second warm is a no-op that still reports the entry as present.
    with patch.object(pm, "load_linear_preview_rgb", side_effect=AssertionError("re-warmed")):
        assert pm.prefetch_linear_preview_rgb(
            paths[0], cfg, "Adobe RGB", use_camera_wb=True, file_hash="red", full_resolution=True, demosaic="auto"
        )


def test_rgb_triplet_prefetch_respects_the_ram_check(tmp_path):
    from negpy.services.rendering import preview_manager as pmod

    paths, cfg = _triplet(tmp_path)
    pm = pmod.PreviewManager()
    with patch.object(pmod, "available_system_memory_bytes", return_value=1024), patch.object(
        pm, "load_linear_preview_rgb", side_effect=AssertionError("warmed without RAM")
    ):
        assert not pm.prefetch_linear_preview_rgb(
            paths[0], cfg, "Adobe RGB", use_camera_wb=True, file_hash="red", full_resolution=True
        )


def _controller_stub(saved, hq=True):
    from types import SimpleNamespace
    from unittest.mock import MagicMock

    repo = MagicMock()
    repo.load_file_settings.return_value = saved
    return SimpleNamespace(
        session=SimpleNamespace(repo=repo),
        state=SimpleNamespace(gpu_enabled=False, workspace_color_space="Adobe RGB", hq_preview=hq),
    )


def test_rgb_prefetch_task_matches_the_foreground_load_and_is_gated(tmp_path):
    from negpy.desktop import controller as cmod
    from negpy.desktop.controller import AppController
    from negpy.domain.models import WorkspaceConfig
    from negpy.features.rgbscan.models import RgbScanConfig

    _, cfg = _triplet(tmp_path)
    base = WorkspaceConfig()
    saved = replace(base, rgbscan=cfg)
    asset = {"path": "/r.tif", "hash": "red", "green_path": cfg.green_path}
    stub = _controller_stub(saved)
    with patch.object(cmod, "ample_unified_memory", return_value=True):
        task = AppController._rgb_prefetch_task(stub, asset, 3, ("selected",))
        assert task.rgbscan == cfg and task.file_hash == "red" and task.full_resolution and task.for_cache_warm
        assert task.protected_file_hashes == ("selected",)
        assert task.use_camera_wb == (not cmod.effective_linear_raw(saved.process))
        assert task.demosaic == saved.process.demosaic_preview
        # Not a triplet (settings never saved, or trichrome off): nothing to warm.
        assert AppController._rgb_prefetch_task(_controller_stub(None), asset, 3, ()) is None
        off = replace(base, rgbscan=RgbScanConfig())
        assert AppController._rgb_prefetch_task(_controller_stub(off), asset, 3, ()) is None
        # A stitch/bracket asset (no green_path) stays skipped.
        assert AppController._rgb_prefetch_task(stub, {"path": "/s", "hash": "s", "stitch_paths": ["x"]}, 3, ()) is None
    with patch.object(cmod, "ample_unified_memory", return_value=False):
        assert AppController._rgb_prefetch_task(stub, asset, 3, ()) is None


def test_prefetch_worker_routes_triplets_to_the_rgb_warm(tmp_path):
    from types import SimpleNamespace
    from unittest.mock import MagicMock

    from negpy.desktop.workers.render import PreviewLoadTask, PreviewLoadWorker

    _, cfg = _triplet(tmp_path)
    service = MagicMock()
    stub = SimpleNamespace(_prefetch_is_current=lambda t: True, _preview_service=service, prefetch_finished=MagicMock())
    task = PreviewLoadTask(file_path="/r.tif", workspace_color_space="Adobe RGB", use_camera_wb=True, file_hash="red",
                           full_resolution=True, for_cache_warm=True, rgbscan=cfg, protected_file_hashes=("selected",))
    PreviewLoadWorker._process_prefetch(stub, task)
    service.prefetch_linear_preview.assert_not_called()
    args, kwargs = service.prefetch_linear_preview_rgb.call_args
    assert args == ("/r.tif", cfg, "Adobe RGB")
    assert kwargs["full_resolution"] and kwargs["file_hash"] == "red" and kwargs["protected_file_hashes"] == ("selected",)
    stub.prefetch_finished.emit.assert_called_once()


def test_full_resolution_prefetch_warms_the_next_frame_first():
    from types import SimpleNamespace
    from unittest.mock import MagicMock

    from negpy.desktop import controller as cmod
    from negpy.desktop.controller import AppController

    files = [{"path": f"/{n}", "hash": n} for n in ("previous", "selected", "next")]

    def run(gate):
        stub = SimpleNamespace(
            _prefetch_gen=1,
            _foreground_work_active=lambda: False,
            state=SimpleNamespace(selected_file_idx=1, uploaded_files=files, hq_preview=True),
            session=SimpleNamespace(asset_model=MagicMock(visible_actual_indices_ordered=MagicMock(return_value=[0, 1, 2]))),
            _neighbor_prefetch_task=lambda a, g, p: SimpleNamespace(file_hash=a["hash"], protected=p),
            _start_next_neighbor_prefetch=MagicMock(),
        )
        with patch.object(cmod, "full_resolution_prefetch", return_value=gate):
            AppController._prepare_neighbor_prefetch(stub, 1)
        return [(t.file_hash, t.protected) for t in stub._neighbor_prefetch_queue]

    assert run(False) == [("previous", ("selected",)), ("next", ("selected", "previous"))]  # upstream order
    assert run(True) == [("next", ("selected",)), ("previous", ("selected", "next"))]


def test_openmp_libraw_uses_the_shared_runtime():
    """An OpenMP LibRaw must link libomp dynamically. A statically linked libomp shuts its
    runtime down when the last thread that used it exits, so a thread entering LibRaw at
    that moment segfaults (__kmpc_critical_with_hint in libraw_memmgr). Mac build env only."""
    import glob
    import os
    import shutil
    import subprocess

    import pytest
    import rawpy

    if not is_apple_silicon() or not shutil.which("nm"):
        pytest.skip("Apple Silicon build environment only")
    libs = [p for p in glob.glob(os.path.join(os.path.dirname(rawpy.__file__), "libraw_r*.dylib")) if not os.path.islink(p)]
    if not libs:
        pytest.skip("no libraw dylib next to rawpy")
    for lib in libs:
        symbols = subprocess.run(["nm", "-m", lib], capture_output=True, text=True).stdout
        if "kmpc" not in symbols:
            continue  # stock single-threaded LibRaw: nothing to check
        defined = [line for line in symbols.splitlines() if "__kmp_internal_end_thread" in line and "undefined" not in line]
        assert not defined, f"{os.path.basename(lib)} embeds a static libomp"
        deps = subprocess.run(["otool", "-L", lib], capture_output=True, text=True).stdout
        assert "libomp.dylib" in deps, f"{os.path.basename(lib)} does not link the shared libomp"


def test_openmp_lock_kind_is_set_on_apple_silicon_only():
    """libomp's default queuing lock deadlocks concurrent LibRaw decodes on Apple Silicon;
    the package selects the test-and-set lock before LibRaw starts, unless the user chose."""
    with patch.object(asi, "is_apple_silicon", return_value=True):
        env = {}
        assert asi.configure_openmp_runtime(env) == {"KMP_LOCK_KIND": "tas"}
        assert env == {"KMP_LOCK_KIND": "tas"}
        env = {"KMP_LOCK_KIND": "queuing"}
        assert asi.configure_openmp_runtime(env) == {} and env["KMP_LOCK_KIND"] == "queuing"
    with patch.object(asi, "is_apple_silicon", return_value=False):
        env = {}
        assert asi.configure_openmp_runtime(env) == {} and env == {}


def test_package_import_sets_the_lock_before_rawpy_is_used():
    import subprocess
    import sys

    code = (
        "import os; os.environ.pop('KMP_LOCK_KIND', None)\n"
        "from unittest.mock import patch\n"
        "import negpy.kernel.system.apple_silicon as a\n"
        "print(os.environ.get('KMP_LOCK_KIND'))\n"
    )
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env={k: v for k, v in __import__('os').environ.items() if k != 'KMP_LOCK_KIND'})
    expected = "tas" if is_apple_silicon() else "None"
    assert out.stdout.strip() == expected, out.stderr
