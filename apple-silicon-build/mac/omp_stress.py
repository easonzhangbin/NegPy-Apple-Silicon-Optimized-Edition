"""Stress LibRaw from many short-lived threads, the way NegPy's preview, prefetch,
thumbnail and RGB-decode threads do.

A static libomp shuts its runtime down when the last thread that used it exits; a thread
entering LibRaw at that moment segfaults in __kmpc_critical_with_hint (libraw_memmgr).
This keeps threads starting and exiting with overlap for DURATION seconds.

Exit 0: survived. A crash kills the process (exit code 139 / -11). A hang (the static
runtime can also deadlock instead of crashing) exits 3 after 15 s without progress.
A second failure mode, with a shared libomp: its default queuing lock for `omp critical`
deadlocks concurrent decodes on Apple Silicon (all threads in __kmp_acquire_queuing_lock
in LibRaw::copy_bayer). negpy sets KMP_LOCK_KIND=tas at import; NEGPY_SRC=<src> tests that.
Env: STRESS_CONC (threads, 8), STRESS_FULL_RATIO (share of full decodes, 0.15),
STRESS_SAMPLE (write `sample` stacks here on a hang).
Usage: python omp_stress.py SECONDS RAW [RAW ...]
"""

import faulthandler
import os
import random
import sys
import threading
import time

if os.environ.get("NEGPY_SRC"):  # test what the app does: importing negpy picks the OpenMP lock
    sys.path.insert(0, os.environ["NEGPY_SRC"])
    import negpy  # noqa: F401

    print(f"   KMP_LOCK_KIND={os.environ.get('KMP_LOCK_KIND')}（由 negpy 设置）", flush=True)

import rawpy

faulthandler.enable()
duration = float(sys.argv[1])
paths = sys.argv[2:]
if not paths:
    sys.exit("no RAW files given")

done = 0
lock = threading.Lock()


def work(path: str, full: bool) -> None:
    global done
    with rawpy.imread(path) as raw:  # open_file -> identify -> LibRaw::calloc -> omp critical
        _ = raw.sizes
        if full:  # an OpenMP parallel region too
            raw.postprocess(half_size=True, output_bps=16, user_flip=0)
    with lock:
        done += 1


STALL = 15.0
FULL_RATIO = float(os.environ.get("STRESS_FULL_RATIO", "0.15"))
CONC = int(os.environ.get("STRESS_CONC", "8"))
deadline = time.time() + duration
alive: list[threading.Thread] = []
started = 0
last = time.time()
progress_at, progress_n = time.time(), 0


def check_stall() -> None:
    global progress_at, progress_n
    if done != progress_n:
        progress_at, progress_n = time.time(), done
    elif time.time() - progress_at > STALL:
        print(f"   ❌ 卡死：{STALL:.0f} 秒没有任何一次 RAW 打开完成（已完成 {done} 次）", flush=True)
        out = os.environ.get("STRESS_SAMPLE")
        if out:  # native stacks of every thread, for diagnosis
            import subprocess

            subprocess.run(["sample", str(os.getpid()), "3", "-file", out], capture_output=True)
            with open(out + ".py.txt", "w") as f:
                faulthandler.dump_traceback(file=f, all_threads=True)
        os._exit(3)


while time.time() < deadline:
    check_stall()
    alive = [t for t in alive if t.is_alive()]
    while len(alive) < CONC:
        t = threading.Thread(target=work, args=(random.choice(paths), random.random() < FULL_RATIO), daemon=True)
        t.start()
        alive.append(t)
        started += 1
    time.sleep(random.random() * 0.004)
    if time.time() - last > 10:
        last = time.time()
        print(f"   {int(deadline - last)} 秒后结束 · 已完成 {done} 次打开", flush=True)
while any(t.is_alive() for t in alive):
    check_stall()
    time.sleep(0.2)
print(f"   存活：{started} 个线程、{done} 次 RAW 打开，没有崩溃", flush=True)
