"""Build a separate custom application without installing it or opening user data."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "NegPy 中文优化版"
VARIANT = json.loads((ROOT / "BUILD_VARIANT.json").read_text(encoding="utf-8"))
REVISION = VARIANT["revision"]
STEM = f"NegPy-{VARIANT['base_version']}-zh_CN-AppleSilicon-{REVISION}"
EXCLUDED = {".venv", ".git", ".pytest_cache", ".ruff_cache", "__pycache__", "build", "dist", "outputs", ".DS_Store"}


def run(*arguments, **kwargs):
    subprocess.run(arguments, check=True, **kwargs)


def ignore(directory, names):
    return [name for name in names if name in EXCLUDED or name.endswith((".egg-info", ".pyc", ".spec"))]


def validate_runtime(runtime: Path) -> None:
    library = runtime / "libraw_r.25.dylib"
    if not library.is_file() or not (runtime / ".dylibs/libomp.dylib").is_file():
        raise RuntimeError("The dynamic OpenMP RAW runtime is missing")
    symbols = subprocess.check_output(["nm", "-m", str(library)], text=True)
    dependencies = subprocess.check_output(["otool", "-L", str(library)], text=True)
    if "kmpc" not in symbols or "@loader_path/.dylibs/libomp.dylib" not in dependencies:
        raise RuntimeError("LibRaw must use the shared OpenMP runtime")
    if any("__kmp_internal_end_thread" in line and "undefined" not in line for line in symbols.splitlines()):
        raise RuntimeError("A static OpenMP runtime is not supported")
    linked_paths = "\n".join(dependencies.splitlines()[1:])
    if "/opt/homebrew/" in linked_paths or "/Users/" in linked_paths:
        raise RuntimeError("LibRaw depends on a non-portable library path")


def install_runtime(runtime: Path) -> None:
    validate_runtime(runtime)
    destination = Path(sysconfig.get_path("purelib")) / "rawpy"
    if destination.resolve() == runtime.resolve():
        return
    extension = f"_rawpy.cpython-{sys.version_info.major}{sys.version_info.minor}-darwin.so"
    if not (runtime / extension).is_file():
        raise RuntimeError("The bundled RAW extension does not match this Python ABI")
    installed = destination / "libraw_r.25.dylib"
    if installed.exists() and installed.read_bytes() == (runtime / installed.name).read_bytes():
        return
    staging = Path(tempfile.mkdtemp(prefix="negpy-runtime-", dir=destination.parent))
    shutil.copytree(runtime, staging / "rawpy", ignore=ignore)
    backup = staging / "previous-rawpy"
    destination.rename(backup)
    try:
        (staging / "rawpy").rename(destination)
    except BaseException:
        backup.rename(destination)
        raise


def source_archive(output: Path) -> Path:
    archive = output / f"{STEM}-source.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for directory, folders, files in os.walk(ROOT):
            folders[:] = sorted(name for name in folders if name not in ignore(directory, folders))
            for name in sorted(files):
                if name in ignore(directory, [name]):
                    continue
                path = Path(directory) / name
                package.write(path, Path(STEM) / path.relative_to(ROOT))
    with zipfile.ZipFile(archive) as package:
        bad = package.testzip()
        if bad:
            raise RuntimeError(f"Source archive CRC failure: {bad}")
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rawpy-runtime", type=Path, default=ROOT / "third_party/rawpy-macos-arm64")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("Build on an Apple Silicon Mac")
    if sys.prefix == sys.base_prefix:
        parser.error("Run through the project virtual environment")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    install_runtime(args.rawpy_runtime.resolve())
    stage = Path(tempfile.mkdtemp(prefix=f"negpy-{REVISION}-build-", dir="/private/tmp"))
    shutil.copytree(ROOT, stage / "source", ignore=ignore, symlinks=True, copy_function=shutil.copyfile)
    scratch = stage / "user-data"
    scratch.mkdir()
    environment = dict(
        os.environ,
        NEGPY_USER_DIR=str(scratch),
        NEGPY_APP_NAME=APP_NAME,
        NEGPY_REQUIRE_CAMERA="1",
        NEGPY_SKIP_PACKAGE="1",
        MACOSX_DEPLOYMENT_TARGET="11.0",
    )
    environment["PYTHONPATH"] = str(stage / "source")
    run(sys.executable, "build.py", cwd=stage / "source", env=environment)
    app = stage / "source/dist" / f"{APP_NAME}.app"
    run("chflags", "-R", "nohidden", str(app))
    run("xattr", "-cr", str(app))
    run("codesign", "--force", "--deep", "--sign", "-", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    archive = source_archive(args.output)
    dmg_stage = stage / "dmg"
    dmg_stage.mkdir()
    run("ditto", str(app), str(dmg_stage / app.name))
    (dmg_stage / "Applications").symlink_to("/Applications")
    shutil.copy2(archive, dmg_stage / archive.name)
    shutil.copy2(ROOT / "README.APPLE_SILICON.zh_CN.md", dmg_stage / "安装与变更说明.md")
    image = stage / f"{STEM}-macOS-arm64.dmg"
    run("hdiutil", "create", "-volname", f"NegPy 中文优化版 {REVISION}", "-srcfolder", str(dmg_stage), "-ov", "-format", "UDZO", str(image))
    run("hdiutil", "verify", str(image))
    published = args.output / image.name
    temporary = args.output / f".{image.name}.partial"
    shutil.copyfile(image, temporary)
    os.replace(temporary, published)
    image = published
    result = {
        "stage": str(stage),
        "application": str(app),
        "artifacts": {
            path.name: {"bytes": path.stat().st_size, "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest()}
            for path in (image, archive)
        },
        "installed": False,
    }
    (args.output / f"{STEM}-build.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
