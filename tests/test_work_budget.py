from concurrent.futures import ThreadPoolExecutor
import threading
import time

import pytest

from negpy.kernel.system import work_budget as budget


def wait_until(predicate):
    deadline = time.monotonic() + 5
    while not predicate():
        assert time.monotonic() < deadline
        time.sleep(0.005)


def test_identical_requests_share_one_result():
    flights = budget.DecodeFlights()
    started, release = threading.Event(), threading.Event()
    result = object()
    calls = []

    def decode():
        calls.append(1)
        started.set()
        assert release.wait(5)
        return result

    with ThreadPoolExecutor(2) as pool:
        first = pool.submit(flights.run, ("frame",), decode)
        assert started.wait(5)
        second = pool.submit(flights.run, ("frame",), decode)
        wait_until(lambda: flights.snapshot()["shared_requests"] == 1)
        release.set()
        assert first.result(5) is result
        assert second.result(5) is result
    assert calls == [1]
    assert flights.snapshot()["in_flight"] == 0


def test_cancelled_waiter_does_not_cancel_owner():
    flights = budget.DecodeFlights()
    started, release, cancelled = threading.Event(), threading.Event(), threading.Event()

    def decode():
        started.set()
        assert release.wait(5)
        return 42

    with ThreadPoolExecutor(2) as pool:
        owner = pool.submit(flights.run, ("frame",), decode)
        assert started.wait(5)
        waiter = pool.submit(flights.run, ("frame",), decode, should_cancel=cancelled.is_set)
        wait_until(lambda: flights.snapshot()["shared_requests"] == 1)
        cancelled.set()
        with pytest.raises(InterruptedError):
            waiter.result(5)
        release.set()
        assert owner.result(5) == 42


def test_cancelled_owner_allows_a_live_waiter_to_retry():
    flights = budget.DecodeFlights()
    started, release = threading.Event(), threading.Event()

    def cancelled_decode():
        started.set()
        assert release.wait(5)
        raise InterruptedError("obsolete frame")

    with ThreadPoolExecutor(2) as pool:
        owner = pool.submit(flights.run, ("frame",), cancelled_decode)
        assert started.wait(5)
        waiter = pool.submit(flights.run, ("frame",), lambda: 42)
        wait_until(lambda: flights.snapshot()["shared_requests"] == 1)
        release.set()
        with pytest.raises(InterruptedError):
            owner.result(5)
        assert waiter.result(5) == 42
    assert flights.snapshot()["in_flight"] == 0


def test_failed_flight_is_not_cached():
    flights = budget.DecodeFlights()
    with pytest.raises(ValueError):
        flights.run(("bad",), lambda: int("bad"))
    assert flights.run(("bad",), lambda: 7) == 7
    assert flights.snapshot()["failed"] == 1


def test_foreground_waiter_has_priority_over_background():
    gate = budget.DecodeBudget(1)
    started, release = threading.Event(), threading.Event()
    order = []

    def holder():
        with gate.acquire():
            started.set()
            assert release.wait(5)

    def worker(name, background):
        with gate.acquire(background=background):
            order.append(name)

    with ThreadPoolExecutor(3) as pool:
        active = pool.submit(holder)
        assert started.wait(5)
        background = pool.submit(worker, "background", True)
        foreground = pool.submit(worker, "foreground", False)
        wait_until(lambda: gate._foreground_waiters == 1)
        release.set()
        active.result(5)
        foreground.result(5)
        background.result(5)
    assert order == ["foreground", "background"]


def test_slot_is_released_after_failure():
    gate = budget.DecodeBudget(1)
    with pytest.raises(ValueError), gate.acquire():
        raise ValueError("bad decode")
    with gate.acquire():
        assert gate._active == 1
    assert gate._active == 0


def test_waiting_decode_can_be_cancelled():
    gate = budget.DecodeBudget(1)
    with gate.acquire(), ThreadPoolExecutor(1) as pool:

        def cancelled():
            with gate.acquire(should_cancel=lambda: True):
                pytest.fail("cancelled job acquired a slot")

        with pytest.raises(InterruptedError):
            pool.submit(cancelled).result(5)
    assert gate._foreground_waiters == 0


def test_background_context_propagates_and_restores():
    @budget.background_decode
    def background():
        with ThreadPoolExecutor(1) as pool:
            return budget.submit_decode(pool, budget._BACKGROUND.get).result(5)

    assert background() is True
    assert budget._BACKGROUND.get() is False


def test_decode_threads_preserve_explicit_environment(monkeypatch):
    monkeypatch.setattr(budget, "is_apple_silicon", lambda: True)
    monkeypatch.setattr(budget.os, "cpu_count", lambda: 10)
    environ = {"OMP_NUM_THREADS": "3"}
    assert budget.configure_decode_threads(environ) == {"OMP_MAX_ACTIVE_LEVELS": "1"}
    assert environ["OMP_NUM_THREADS"] == "3"
    defaults = {}
    budget.configure_decode_threads(defaults)
    assert defaults["OMP_NUM_THREADS"] == "4"
    monkeypatch.setattr(budget, "is_apple_silicon", lambda: False)
    assert budget.configure_decode_threads({}) == {}


def test_low_memory_trims_only_inactive_frames():
    from types import SimpleNamespace
    import numpy as np
    from negpy.services.rendering.preview_cache import PreviewBufferCache, PreviewCacheKey

    cache = PreviewBufferCache(
        SimpleNamespace(
            preview_cache_max_entries=8,
            preview_cache_max_bytes=1024**3,
            preview_cache_max_full_res_entries=4,
        )
    )
    active = PreviewCacheKey("active", False, "Adobe RGB", True)
    inactive = PreviewCacheKey("inactive", False, "Adobe RGB", True)
    image = np.zeros((8, 8, 3), np.float32)
    cache.put(active, image, (8, 8), {})
    cache.put(inactive, image.copy(), (8, 8), {})
    cache.trim_for_memory(512 * 1024**2, {"active"})
    assert cache.peek(active) is not None
    assert cache.peek(inactive) is None


def test_gpu_resident_tiles_follow_memory_headroom(monkeypatch):
    from negpy.kernel.system import apple_silicon as apple

    monkeypatch.setattr(apple, "ample_unified_memory", lambda: True)
    monkeypatch.setattr(apple, "_headroom_time", time.monotonic())
    monkeypatch.setattr(apple, "_headroom_bytes", 1024**3)
    assert not apple.retain_source_tiles(512 * 1024**2)
    monkeypatch.setattr(apple, "_headroom_bytes", 8 * 1024**3)
    assert apple.retain_source_tiles(512 * 1024**2)


def test_tiff_destination_preserves_pixels_and_metadata(tmp_path):
    import io
    import numpy as np
    import tifffile
    from negpy.services.export.encoders import encode_tiff

    image = np.arange(96 * 128 * 3, dtype=np.uint16).reshape(96, 128, 3)
    path = tmp_path / "frame.part"
    reference = encode_tiff(image, description="metadata", icc=b"test-profile")
    with path.open("w+b") as destination:
        assert encode_tiff(image, destination=destination, description="metadata", icc=b"test-profile") == b""
    np.testing.assert_array_equal(tifffile.imread(path), tifffile.imread(io.BytesIO(reference)))
    with tifffile.TiffFile(path) as tiff:
        assert tiff.pages[0].description == "metadata"
        assert tiff.pages[0].tags[34675].value == b"test-profile"


def test_streamed_export_failure_preserves_existing_output(tmp_path, monkeypatch):
    import numpy as np
    from test_export_pipelining import _preset, _task
    from negpy.desktop.workers.export import ExportWorker
    from negpy.domain.models import ExportFormat

    task = _task(tmp_path, "frame.tif", preset=_preset(tmp_path, export_fmt=ExportFormat.TIFF, overwrite=True))
    worker = ExportWorker()
    monkeypatch.setattr(worker._processor, "encode_export", lambda *args, **kwargs: (None, "encode failed"))
    assert worker._finish_task(task, np.zeros((16, 16, 3), np.float32), "Adobe RGB", None) == "encode failed"
    assert not list(tmp_path.glob("*.part"))
    assert not list(tmp_path.glob("*.tiff"))


def test_real_streamed_batch_tiff_is_readable(tmp_path):
    import numpy as np
    import tifffile
    from test_export_pipelining import _preset, _task
    from negpy.desktop.workers.export import ExportWorker
    from negpy.domain.models import ExportFormat

    task = _task(tmp_path, "frame.raw", preset=_preset(tmp_path, export_fmt=ExportFormat.TIFF))
    worker = ExportWorker()
    image = np.full((24, 32, 3), 0.18, np.float32)
    assert worker._finish_task(task, image, "Adobe RGB", None) is None
    assert tifffile.imread(next(tmp_path.glob("*.tiff"))).shape == (24, 32, 3)
    assert not list(tmp_path.glob("*.part"))


def test_custom_frozen_build_cannot_be_overwritten_by_upstream(tmp_path, monkeypatch):
    from negpy.kernel.system import updater

    (tmp_path / "BUILD_VARIANT.json").write_text("{}")
    monkeypatch.setattr(updater.sys, "_MEIPASS", str(tmp_path), raising=False)
    monkeypatch.setattr(updater, "install_kind", lambda: "macos")
    release = updater.UpdateInfo("0.66.0", "", "https://example.invalid", download_url="https://example.invalid/release.dmg")
    assert not release.can_self_install


def test_prefetch_direction_follows_backwards_navigation(monkeypatch):
    from types import SimpleNamespace
    from unittest.mock import MagicMock
    from negpy.desktop import controller

    files = [{"path": f"/{index}", "hash": str(index)} for index in range(5)]
    stub = SimpleNamespace(
        _prefetch_gen=1,
        _foreground_work_active=lambda: False,
        _last_prefetch_index=3,
        _prefetch_direction=1,
        state=SimpleNamespace(selected_file_idx=2, uploaded_files=files, hq_preview=True),
        session=SimpleNamespace(asset_model=MagicMock(visible_actual_indices_ordered=MagicMock(return_value=list(range(5))))),
        _neighbor_prefetch_task=lambda asset, generation, protected: SimpleNamespace(file_hash=asset["hash"]),
        _start_next_neighbor_prefetch=MagicMock(),
    )
    monkeypatch.setattr(controller, "full_resolution_prefetch", lambda hq: True)
    controller.AppController._prepare_neighbor_prefetch(stub, 1)
    assert stub._prefetch_direction == -1
    assert [task.file_hash for task in stub._neighbor_prefetch_queue] == ["1", "3"]


def test_singleflight_ignores_separate_handles_but_keeps_decode_settings(tmp_path):
    started, release = threading.Event(), threading.Event()
    calls = []

    class Decoder:
        @budget.coordinated_decode
        def decode(self, raw, metadata, file_path, full_resolution=False, should_cancel=None):
            calls.append(full_resolution)
            started.set()
            assert release.wait(5)
            return full_resolution

    decoder = Decoder()
    path = str(tmp_path / "frame.raw")
    before = budget.DECODE_FLIGHTS.snapshot()["shared_requests"]
    with ThreadPoolExecutor(2) as pool:
        first = pool.submit(decoder.decode, object(), {}, path)
        assert started.wait(5)
        second = pool.submit(decoder.decode, object(), {}, path)
        wait_until(lambda: budget.DECODE_FLIGHTS.snapshot()["shared_requests"] > before)
        release.set()
        assert first.result(5) is False
        assert second.result(5) is False
    assert calls == [False]
    assert decoder.decode(object(), {}, path, full_resolution=True) is True
    assert calls == [False, True]
