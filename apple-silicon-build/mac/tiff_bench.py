"""16-bit TIFF export on Apple Silicon: where the time goes, and which encoder settings
keep the decoded pixels bit-identical while using more cores."""

import cProfile
import hashlib
import io
import json
import os
import pstats
import sys
import time
from dataclasses import replace

import numpy as np
import tifffile

FILES = {"T": "/tmp/claude-0/t.tif"} if __import__("os").environ.get("TB_SMOKE") else {
    "RW2_96MP": "/path/to/reference.RW2",
    "DNG_M11": "/path/to/reference M11/L1009237.DNG",
}
OUT = sys.argv[1] if len(sys.argv) > 1 else "tiff_bench.json"


def timed(fn, n=2):
    best, out = None, None
    for _ in range(n):
        t0 = time.perf_counter()
        out = fn()
        dt = (time.perf_counter() - t0) * 1000
        best = dt if best is None else min(best, dt)
    return out, round(best, 1)


def main():
    from negpy.domain.models import ExportConfig, ExportFormat, WorkspaceConfig
    from negpy.kernel.image.logic import float_to_uint16
    from negpy.kernel.system.parallel import set_parallel_enabled
    from negpy.services.export import encoders
    from negpy.services.rendering.image_processor import ImageProcessor

    set_parallel_enabled(True)
    report = {"cpu": os.cpu_count(), "tifffile": tifffile.__version__}
    try:
        import imagecodecs

        report["imagecodecs"] = imagecodecs.__version__
    except Exception:
        pass
    cfg = WorkspaceConfig()
    exp = replace(ExportConfig(), export_fmt=ExportFormat.TIFF, export_bit_depth=16)

    for key, path in FILES.items():
        if not os.path.exists(path):
            continue
        r = report[key] = {}
        print(f"== {key}", flush=True)
        proc = ImageProcessor(use_gpu=True)
        proc.process_export(path, cfg, exp, f"tb-warm-{key}")

        # Whole export, profiled.
        pr = cProfile.Profile()
        t0 = time.perf_counter()
        pr.enable()
        data, kind = proc.process_export(path, cfg, exp, f"tb-{key}")
        pr.disable()
        r["export_tiff16_ms"] = round((time.perf_counter() - t0) * 1000, 1)
        r["bytes"] = len(data)
        sio = io.StringIO()
        pstats.Stats(pr, stream=sio).sort_stats("tottime").print_stats(18)
        r["profile_tottime"] = sio.getvalue()
        print(f"   export TIFF16 {r['export_tiff16_ms']} ms, {len(data) / 2**20:.0f} MB", flush=True)

        # Encoder alone, on the same pixels, under settings that keep pixels identical.
        buf, _ = proc.render_export(path, cfg, exp, f"tb-r-{key}")
        u16 = float_to_uint16(buf)
        ref = None
        variants = {
            "default": {"maxworkers": 1},  # NegPy 0.65.0 behaviour: one compression thread
            "threads": {},  # this build: all cores
            "strips_threads": {"rowsperstrip": 64, "maxworkers": os.cpu_count()},
            "tiles_threads": {"tile": (512, 512), "maxworkers": os.cpu_count()},
        }
        r["encode"] = {}
        for name, extra in variants.items():
            blob, ms = timed(lambda extra=extra: encoders.encode_tiff(u16, **extra))
            dec = tifffile.imread(io.BytesIO(blob))
            same = np.array_equal(dec, u16)
            ref = ref if ref is not None else hashlib.sha256(blob).hexdigest()[:12]
            with tifffile.TiffFile(io.BytesIO(blob)) as tif:
                p = tif.pages[0]
                layout = f"{'tiles' if p.is_tiled else 'strips'}:{len(p.dataoffsets)}"
            r["encode"][name] = {"ms": ms, "MB": round(len(blob) / 2**20, 1), "pixels_identical": bool(same),
                                 "bytes_identical_to_default": hashlib.sha256(blob).hexdigest()[:12] == ref, "layout": layout}
            print(f"   encode {name:15} {ms:8.1f} ms  {len(blob) / 2**20:6.1f} MB  pixels identical={same}  {layout}", flush=True)
        proc.destroy_all()
        with open(OUT, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"\n✅ {OUT}")


if __name__ == "__main__":
    main()
