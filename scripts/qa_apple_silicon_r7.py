"""Read-only RAW soak test and isolated Chinese widget captures."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import faulthandler
import hashlib
import json
import os
from pathlib import Path
import resource
import statistics
import threading
import time
from unittest.mock import MagicMock, patch

import numpy as np


def capture(output: Path) -> None:
    from negpy.kernel.system import i18n

    i18n.configure("zh_CN")
    from PyQt6.QtWidgets import QApplication
    from negpy.desktop.session import AppState
    from negpy.desktop.view.sidebar.flatfield import FlatFieldSidebar
    from negpy.desktop.view.styles.templates import load_stylesheet
    from negpy.desktop.view.widgets.section_help_dialog import SectionHelpDialog
    from negpy.features.flatfield.models import FlatFieldConfig

    app = QApplication([])
    app.setStyle("Fusion")
    app.setStyleSheet(load_stylesheet())
    controller = MagicMock()
    controller.state = AppState()
    config = controller.state.config
    controller.state.config = replace(config, flatfield=FlatFieldConfig(apply=True, profile_id="qa", flatfield_strength=1.25))
    with patch("negpy.services.assets.flatfield.FlatFieldProfiles.list_profiles", return_value=[("qa", "测试平场参考")]):
        sidebar = FlatFieldSidebar(controller)
        sidebar.resize(760, 260)
        sidebar.show()
        app.processEvents()
        assert sidebar.strength_slider.value() == 125
        assert sidebar.strength_slider.isEnabled()
        sidebar.grab().save(str(output / "flatfield-zh_CN.png"))
        dialog = SectionHelpDialog("optics", "光学")
        dialog.show()
        app.processEvents()
        dialog.grab().save(str(output / "optics-help-zh_CN.png"))
        dialog.close()
        sidebar.close()
    app.quit()


def checksum(image) -> str:
    return hashlib.sha256(memoryview(np.ascontiguousarray(image))).hexdigest()


def soak(paths: list[str], seconds: float) -> dict:
    from negpy.kernel.system.work_budget import DECODE_FLIGHTS
    from negpy.services.rendering.preview_manager import PreviewManager
    from negpy.services.rendering.image_processor import ImageProcessor

    manager = PreviewManager()
    processor = ImageProcessor(use_gpu=False)
    expected = {}
    for path in paths:
        image, _, _ = manager.load_linear_preview(path, "Adobe RGB", use_camera_wb=False, full_resolution=True)
        expected[path] = checksum(image)
    deadline = time.monotonic() + seconds
    lock = threading.Lock()
    timings = []
    failures = []
    operations = {"preview": 0, "export_decode": 0}

    def run(worker):
        sequence = worker
        while time.monotonic() < deadline:
            path = paths[sequence % len(paths)]
            started = time.perf_counter()
            mode = "preview" if sequence % 3 else "export_decode"
            try:
                if mode == "preview":
                    image, _, _ = manager.load_linear_preview(path, "Adobe RGB", use_camera_wb=False, full_resolution=True)
                    assert checksum(image) == expected[path], "preview pixels changed"
                else:
                    image, _ = processor._decode_sensor_rgb(path, True)
                    assert image.dtype == np.uint16 and image.ndim == 3
                del image
                with lock:
                    timings.append(time.perf_counter() - started)
                    operations[mode] += 1
            except Exception as error:
                with lock:
                    failures.append({"mode": mode, "file": Path(path).name, "error": str(error)})
                return
            sequence += 1

    faulthandler.dump_traceback_later(seconds + 120, exit=True)
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(run, worker) for worker in range(4)]
            for future in futures:
                future.result()
    finally:
        faulthandler.cancel_dump_traceback_later()
    return {
        "duration_requested_seconds": seconds,
        "operations": operations,
        "failures": failures,
        "operation_p50_seconds": statistics.median(timings) if timings else None,
        "operation_p95_seconds": float(np.percentile(timings, 95)) if timings else None,
        "peak_rss_bytes_macos": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "preview_checksums": {Path(path).name: value for path, value in expected.items()},
        "decode_metrics": DECODE_FLIGHTS.snapshot(),
        "note": "Mixed-load latency includes queueing and checksum verification; not a standalone speed benchmark.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--raw", action="append", default=[])
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--ui", action="store_true")
    args = parser.parse_args()
    if not os.environ.get("NEGPY_USER_DIR"):
        parser.error("Set NEGPY_USER_DIR to an isolated scratch directory")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.ui:
        capture(args.output)
    if args.raw:
        result = soak(args.raw, args.seconds)
        (args.output / "raw-soak.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        if result["failures"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
