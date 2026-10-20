"""NegPy Apple Silicon benchmark: real files, real code paths.

Sections (each isolated; a failure is recorded, not fatal):
  decode_rawpy   rawpy.postprocess with NegPy's full-resolution parameters (AHD)
  open_full      PreviewManager.load_linear_preview(full_resolution=True)  -- HQ preview open
  open_rgb       PreviewManager.load_linear_preview_rgb(full_resolution=True) -- trichrome open
  render         ImageProcessor.run_pipeline: first frame + slider drags (GPU), CPU frame
  export         ImageProcessor.process_export (full size, default export settings)

Every section stores a SHA-256 of its pixels, so two builds can be compared exactly.
"""

import argparse
import glob
import hashlib
import json
import os
import platform
import statistics
import sys
import time
import traceback
from dataclasses import replace

FILES = {
    "RW2": "/path/to/reference.RW2",
    "DNG_M11": "/path/to/reference M11/L1009237.DNG",
    "ARW": "/path/to/reference.ARW",
}
RGB_RED = "/path/to/reference.RW2"
if os.environ.get("BENCH_FILES"):
    FILES = json.loads(os.environ["BENCH_FILES"])

RUNS = int(os.environ.get("BENCH_RUNS", "3"))


def sha(arr) -> str:
    import numpy as np

    a = np.ascontiguousarray(arr)
    return hashlib.sha256(a.tobytes()).hexdigest()[:16]


def timed(fn, runs):
    out, times = None, []
    for _ in range(runs):
        t0 = time.perf_counter()
        out = fn()
        times.append((time.perf_counter() - t0) * 1000)
    return out, {"median_ms": round(statistics.median(times), 1), "min_ms": round(min(times), 1), "all_ms": [round(t, 1) for t in times]}


def rgb_triplet(red):
    folder = os.path.dirname(red)
    files = sorted(glob.glob(os.path.join(folder, "*.RW2")))
    if red not in files:
        return None
    i = files.index(red)
    rest = [f for f in files if f != red]
    if len(rest) < 2:
        return None
    nxt = files[i + 1 : i + 3]
    if len(nxt) < 2:
        nxt = files[max(0, i - 2) : i]
    return red, nxt[0], nxt[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--sections", default="decode_rawpy,open_full,open_rgb,step_hq,render,export")
    args = ap.parse_args()
    sections = args.sections.split(",")

    import numpy as np
    import rawpy

    res = {
        "label": args.label,
        "machine": platform.machine(),
        "macos": platform.mac_ver()[0],
        "python": sys.version.split()[0],
        "rawpy": rawpy.__version__,
        "rawpy_openmp": bool(rawpy.flags.get("OPENMP")) if rawpy.flags else None,
        "cpu_count": os.cpu_count(),
        "files": {k: v for k, v in FILES.items() if os.path.exists(v)},
    }
    print(f"== {args.label}: rawpy {rawpy.__version__} OpenMP={res['rawpy_openmp']}", flush=True)

    def section(name, fn):
        if name not in sections:
            return
        print(f"▶ {name}", flush=True)
        t0 = time.perf_counter()
        try:
            res[name] = fn()
        except Exception:
            res[name] = {"error": traceback.format_exc()[-2000:]}
        print(f"   {name} done in {time.perf_counter() - t0:.1f}s", flush=True)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(res, f, ensure_ascii=False, indent=2)

    # --- decode_rawpy ---------------------------------------------------------
    def decode_rawpy():
        out = {}
        for key, path in res["files"].items():
            def run(path=path):
                with rawpy.imread(path) as raw:
                    return raw.postprocess(
                        gamma=(1, 1), no_auto_bright=True, adjust_maximum_thr=0.0, use_camera_wb=False,
                        user_wb=[1, 1, 1, 1], output_bps=16, output_color=rawpy.ColorSpace.raw,
                        demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD, user_flip=0, highlight_mode=0,
                    )
            img, t = timed(run, RUNS)
            t["shape"] = list(img.shape)
            t["sha"] = sha(img)
            out[key] = t
            print(f"   {key}: {t['median_ms']} ms", flush=True)
        return out

    section("decode_rawpy", decode_rawpy)

    from negpy.services.rendering.preview_manager import PreviewManager

    # --- open_full --------------------------------------------------------------
    def open_full():
        out = {}
        for key, path in res["files"].items():
            def run(path=path):
                return PreviewManager().load_linear_preview(path, None, False, True)  # fresh cache each run
            (buf, dims, meta), t = timed(run, RUNS)
            t["shape"] = list(np.asarray(buf).shape)
            t["sha"] = sha(np.asarray(buf))
            out[key] = t
            print(f"   {key}: {t['median_ms']} ms", flush=True)
        return out

    section("open_full", open_full)

    # --- open_rgb ---------------------------------------------------------------
    def open_rgb():
        from negpy.features.rgbscan.models import RgbScanConfig

        trip = rgb_triplet(RGB_RED)
        if not trip:
            return {"skipped": "triplet not found"}
        r, g, b = trip
        cfg = RgbScanConfig(enabled=True, green_path=g, blue_path=b, align=True)

        def run():
            return PreviewManager().load_linear_preview_rgb(r, cfg, None, False, True)

        (buf, dims, meta), t = timed(run, RUNS)
        t["files"] = [os.path.basename(p) for p in trip]
        t["sha"] = sha(np.asarray(buf))
        print(f"   triplet: {t['median_ms']} ms", flush=True)
        return t

    section("open_rgb", open_rgb)

    # --- step_hq: the next frame was warmed by the neighbour prefetch -----------------
    def step_hq():
        from negpy.kernel.system.apple_silicon import apply_cache_defaults, full_resolution_prefetch
        from negpy.kernel.system.config import APP_CONFIG
        from negpy.services.rendering import preview_manager as pmod

        raised = apply_cache_defaults(APP_CONFIG)  # what desktop/main.py does at startup
        decisions = []
        real = pmod.decide_prefetch

        def spy(*a, **k):
            d = real(*a, **k)
            decisions.append({"allowed": d.allowed, "reason": d.reason, "required_gb": round(d.required_ram_bytes / 2**30, 2),
                              "cached_gb": round(a[0].cached_bytes / 2**30, 2)})
            return d

        pmod.decide_prefetch = spy
        out = {"cache_defaults": {k: v for k, v in raised.items()}, "frames": {}}
        cs = "Adobe RGB"
        try:
            for key, path in res["files"].items():
                pm = PreviewManager()
                t0 = time.perf_counter()
                cold = pm.load_linear_preview(path, cs, False, True, f"cold-{key}")
                cold_ms = (time.perf_counter() - t0) * 1000
                pm = PreviewManager()
                full = full_resolution_prefetch(True)
                t0 = time.perf_counter()
                warmed = pm.prefetch_linear_preview(path, cs, use_camera_wb=False, file_hash=f"step-{key}", full_resolution=full)
                prefetch_ms = (time.perf_counter() - t0) * 1000
                t0 = time.perf_counter()
                hit = pm.load_linear_preview(path, cs, False, True, f"step-{key}")
                step_ms = (time.perf_counter() - t0) * 1000
                f = {"full_res_prefetch": full, "prefetch_admitted": bool(warmed), "decision": decisions[-1] if decisions else None,
                     "cold_open_ms": round(cold_ms, 1), "background_prefetch_ms": round(prefetch_ms, 1),
                     "step_open_ms": round(step_ms, 1), "same_pixels": sha(np.asarray(hit[0])) == sha(np.asarray(cold[0]))}
                out["frames"][key] = f
                print(f"   {key}: cold {f['cold_open_ms']} ms -> after prefetch {f['step_open_ms']} ms "
                      f"(admitted {f['prefetch_admitted']}, same pixels {f['same_pixels']}) {f['decision']}", flush=True)
        finally:
            pmod.decide_prefetch = real
        return out

    section("step_hq", step_hq)

    # --- render -----------------------------------------------------------------
    def render():
        from negpy.domain.models import WorkspaceConfig
        from negpy.kernel.system.config import APP_CONFIG
        from negpy.services.rendering.image_processor import ImageProcessor

        path = res["files"].get("RW2") or next(iter(res["files"].values()))
        buf, _, meta = PreviewManager().load_linear_preview(path, None, False, True)
        proc = ImageProcessor(use_gpu=True)
        base = WorkspaceConfig()
        size = APP_CONFIG.preview_render_size

        def frame(i, gpu=True):
            cfg = replace(base, exposure=replace(base.exposure, density=1.0 + 0.01 * i))
            r, m = proc.run_pipeline(buf, cfg, f"bench-{path}", render_size_ref=size, prefer_gpu=gpu)
            return r

        t0 = time.perf_counter()
        first = frame(0)
        first_ms = (time.perf_counter() - t0) * 1000
        drags = []
        for i in range(1, 13):
            t0 = time.perf_counter()
            frame(i)
            drags.append((time.perf_counter() - t0) * 1000)
        t0 = time.perf_counter()
        cpu = frame(20, gpu=False)
        cpu_ms = (time.perf_counter() - t0) * 1000
        cpu_arr = np.asarray(cpu)
        out = {
            "backend": proc.backend_name,
            "first_ms": round(first_ms, 1),
            "drag_median_ms": round(statistics.median(drags), 1),
            "drag_min_ms": round(min(drags), 1),
            "cpu_frame_ms": round(cpu_ms, 1),
            "cpu_sha": sha(cpu_arr),
        }
        try:
            from negpy.kernel.system.parallel import parallel_enabled, set_parallel_enabled

            prev = parallel_enabled()
            set_parallel_enabled(not prev)
            frame(21, gpu=False)
            t0 = time.perf_counter()
            frame(22, gpu=False)
            out[f"cpu_frame_ms_parallel_{not prev}"] = round((time.perf_counter() - t0) * 1000, 1)
            out[f"cpu_frame_ms_parallel_{prev}"] = out["cpu_frame_ms"]
            set_parallel_enabled(prev)
        except Exception as e:
            out["parallel_toggle_error"] = str(e)
        print(f"   first {out['first_ms']} ms, drag {out['drag_median_ms']} ms, cpu {out['cpu_frame_ms']} ms", flush=True)
        proc.destroy_all()
        return out

    section("render", render)

    # --- export -----------------------------------------------------------------
    def export():
        from negpy.domain.models import ExportConfig, WorkspaceConfig
        from negpy.services.rendering.image_processor import ImageProcessor

        out = {}
        proc = ImageProcessor(use_gpu=True)
        for key in ("RW2", "DNG_M11"):
            path = res["files"].get(key)
            if not path:
                continue
            cfg = WorkspaceConfig()

            def run(path=path):
                data, cs = proc.process_export(path, cfg, ExportConfig(), f"bench-export-{path}")
                return data

            data, t = timed(run, max(1, RUNS - 1))
            t["bytes"] = len(data) if data else 0
            t["sha"] = hashlib.sha256(data).hexdigest()[:16] if data else None
            out[key] = t
            print(f"   {key}: {t['median_ms']} ms", flush=True)
        proc.destroy_all()
        return out

    section("export", export)
    print(f"\n✅ {args.out}")


if __name__ == "__main__":
    main()
