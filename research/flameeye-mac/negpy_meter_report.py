"""Export the active NegPy trichrome's film-base measurements for Flameeye.

Run in the NegPy Python environment. Only NegPy reads the RAWs and session.
The report contains measurements and file names, without source paths.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sqlite3
import tempfile
import unicodedata
from contextlib import closing
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

NEGPY_ROOT = Path(__file__).resolve().parents[2]
NEGPY_SUPPORT = (
    Path.home() / "Library" / "Application Support" / "NegPy-AppleSilicon-067"
)
DEFAULT_SETTINGS_DB = NEGPY_SUPPORT / "settings.db"
DEFAULT_REPORT = NEGPY_SUPPORT / "flameeye-trichrome-report.json"
METERING_METHOD = "negpy-sensor-linear-half-size-v1"
CHANNELS = ("red", "green", "blue")
MIN_ROI_SAMPLES = 1000


class ReportError(ValueError):
    """A selection or measurement that cannot produce a valid report."""


@dataclass(frozen=True)
class SampleRegion:
    """A rectangle in fractions of the unrotated visible sensor image."""

    x: float
    y: float
    width: float
    height: float

    def __post_init__(self) -> None:
        x, y, width, height = self.x, self.y, self.width, self.height
        if (
            not all(math.isfinite(v) for v in (x, y, width, height))
            or not (0 <= x < 1 and 0 <= y < 1 and width > 0 and height > 0)
            or x + width > 1.000000001
            or y + height > 1.000000001
        ):
            raise ReportError("Choose a nonempty ROI inside the visible sensor image.")


@dataclass(frozen=True)
class ActiveTriplet:
    settings_db: Path
    paths: tuple[Path, ...]
    saved_hashes: tuple[str, ...]
    source_hashes: tuple[str, ...]

    @property
    def triplet_id(self) -> str:
        hashes = b"".join(bytes.fromhex(value) for value in self.source_hashes)
        return hashlib.sha256(b"NegPy trichrome report v1\0" + hashes).hexdigest()


def _valid_text(value: str, limit: int) -> bool:
    return (
        bool(value.strip())
        and len(value) <= limit
        and all(not unicodedata.category(char).startswith("C") for char in value)
    )


def _selection(settings_db: Path) -> tuple[tuple[Path, ...], tuple[str, ...]]:
    if not settings_db.is_file():
        raise ReportError(
            "NegPy settings database not found. Use --settings-db to select it."
        )
    try:
        with closing(
            sqlite3.connect(settings_db.as_uri() + "?mode=ro", uri=True, timeout=0.6)
        ) as db:
            db.execute("PRAGMA query_only = ON")
            rows = dict(
                db.execute(
                    "SELECT key, value_json FROM global_settings WHERE key IN ('session_active_path', 'session_triplets')"
                )
            )
        red = json.loads(rows["session_active_path"])
        triplets = json.loads(rows["session_triplets"])
        members = triplets[red]
        green, blue, align, saved_hashes = members[:4]
    except (KeyError, TypeError, ValueError, sqlite3.Error) as exc:
        raise ReportError(
            "Open a three-exposure trichrome group in NegPy, then try again."
        ) from exc

    if (
        not isinstance(members, list)
        or not isinstance(align, bool)
        or not isinstance(saved_hashes, list)
        or len(saved_hashes) != 3
        or any(
            not isinstance(value, str) or (value and not _is_sha256(value))
            for value in saved_hashes
        )
        or any(
            not isinstance(value, str) or not Path(value).is_absolute()
            for value in (red, green, blue)
        )
    ):
        raise ReportError(
            "The active NegPy item is not a three-exposure trichrome group."
        )

    paths = tuple(Path(value) for value in (red, green, blue))
    if len({p.name for p in paths}) != 3 or any(
        not _valid_text(p.name, 255) or "\\" in p.name for p in paths
    ):
        raise ReportError("The trichrome source names must be valid and distinct.")
    for path in paths:
        if not path.is_file():
            raise ReportError(f"Trichrome source is missing: {path.name}.")
    return paths, tuple(saved_hashes)


def _is_sha256(value: str) -> bool:
    return len(value) == 64 and all(char in "0123456789abcdefABCDEF" for char in value)


def _source_hashes(paths: tuple[Path, ...]) -> tuple[str, ...]:
    hashes = []
    for path in paths:
        with path.open("rb") as source:
            hashes.append(hashlib.file_digest(source, "sha256").hexdigest())
    return tuple(hashes)


def read_active_triplet(settings_db: Path = DEFAULT_SETTINGS_DB) -> ActiveTriplet:
    """Take a snapshot of the ordered RAW files for the active NegPy group."""
    from negpy.kernel.image.logic import calculate_file_hash

    settings_db = settings_db.expanduser().resolve()
    paths, saved_hashes = _selection(settings_db)
    sources = _source_hashes(paths)
    for path, saved in zip(paths, saved_hashes, strict=True):
        if saved and calculate_file_hash(str(path)) != saved.lower():
            raise ReportError(
                f"{path.name} changed after NegPy grouped it. Reopen the triplet in NegPy."
            )
    if len(set(sources)) != 3:
        raise ReportError("The trichrome group must contain three different exposures.")
    if _selection(settings_db) != (paths, saved_hashes):
        raise ReportError("The active NegPy triplet changed. Read it again.")
    return ActiveTriplet(settings_db, paths, saved_hashes, sources)


def _confirm_selection(triplet: ActiveTriplet) -> None:
    if _selection(triplet.settings_db) != (triplet.paths, triplet.saved_hashes):
        raise ReportError("The active NegPy triplet changed. Read it again.")


def _exif_text(value: object) -> str:
    return (
        value.decode("utf-8", errors="replace").strip()
        if isinstance(value, bytes)
        else ""
    )


def _camera_and_time(path: Path) -> tuple[str, str | None]:
    import piexif

    from negpy.infrastructure.loaders.helpers import read_exif_from_file

    data = read_exif_from_file(str(path)) or {}
    image = data.get("0th", {})
    make = _exif_text(image.get(piexif.ImageIFD.Make))
    model = _exif_text(image.get(piexif.ImageIFD.Model))
    camera = (
        f"{make} {model}"
        if make and not (model == make or model.startswith(make + " "))
        else model
    )
    if not model or not _valid_text(camera, 128):
        raise ReportError(f"{path.name} has no valid camera model metadata.")

    tags = data.get("Exif", {})
    timestamp = _exif_text(tags.get(piexif.ExifIFD.DateTimeOriginal))
    subseconds = _exif_text(tags.get(piexif.ExifIFD.SubSecTimeOriginal))
    offset = _exif_text(tags.get(piexif.ExifIFD.OffsetTimeOriginal))
    if not timestamp or not offset:
        return camera, None
    try:
        date = datetime.strptime(timestamp, "%Y:%m:%d %H:%M:%S").isoformat()
        fraction = (
            "." + subseconds[:6]
            if subseconds.isascii() and subseconds.isdigit()
            else ""
        )
        captured = datetime.fromisoformat(date + fraction + offset)
    except ValueError:
        return camera, None
    return camera, captured.isoformat(
        timespec="milliseconds"
    ) if captured.tzinfo else None


def _measure_frame(path: Path, index: int, region: SampleRegion) -> tuple[dict, tuple]:
    import negpy_core
    import numpy as np
    import rawpy

    from negpy.infrastructure.capture.raw_demosaic import (
        linear_demosaic,
        raw_channel_clip_fraction,
    )
    from negpy.services.capture.calibration import (
        CLIP_CEILING,
        SATURATION_VALUE,
        Roi,
        meter_base,
    )

    camera, captured = _camera_and_time(path)
    with rawpy.imread(str(path)) as raw:
        other = raw.other
        settings = (
            float(other.iso_speed),
            float(other.aperture),
            float(other.shutter_speed),
        )
        if any(not math.isfinite(value) or value <= 0 for value in settings):
            raise ReportError(
                f"{path.name} must include ISO, aperture, and shutter metadata."
            )
        pattern = raw.raw_pattern
        image = raw.raw_image_visible
        colors = raw.raw_colors_visible
        if (
            pattern is None
            or pattern.shape != (2, 2)
            or image.ndim != 2
            or image.dtype != np.uint16
            or colors.shape != image.shape
        ):
            raise ReportError(f"{path.name} must be an integer RGB Bayer RAW.")
        if int(pattern.max()) >= len(raw.color_desc):
            raise ReportError(f"{path.name} has invalid Bayer color indices.")
        labels = sorted(raw.color_desc[int(site)] for site in pattern.flat)
        if labels != sorted(b"RGBG"):
            raise ReportError(f"{path.name} must have an RGB Bayer pattern.")
        h, w = image.shape
        geometry = (h, w, raw.sizes.flip)
        white = raw.white_level
        limits = np.minimum(
            raw.camera_white_level_per_channel or [white] * len(raw.color_desc), white
        )
        black = np.asarray(raw.black_level_per_channel)
        if (
            not 0 < white <= 65535
            or int(colors.max()) >= min(len(limits), len(black))
            or np.any(limits[pattern] <= black[pattern])
        ):
            raise ReportError(
                f"{path.name} has invalid sensor black or linearity levels."
            )
        # Count visible Bayer photosites at their own declared limit. The separate ROI
        # plateau fraction measures a pileup and can detect clipping below that limit.
        clipped = int(np.count_nonzero(image >= limits.astype(np.uint16)[colors]))

    decoded = linear_demosaic(str(path), half_size=True)
    if decoded.shape != ((h + 1) // 2, (w + 1) // 2, 3) or decoded.dtype != np.uint16:
        raise ReportError(
            f"{path.name} does not match the unrotated visible sensor geometry."
        )
    roi = Roi(region.x, region.y, region.width, region.height)
    height, width = decoded.shape[:2]
    x0, y0, x1, y1 = roi.pixels(width, height)
    plane = decoded[..., index]
    patch = np.ascontiguousarray(plane[y0:y1, x0:x1])
    if min(patch.shape) < 2 or patch.size < MIN_ROI_SAMPLES:
        raise ReportError(
            f"Choose a larger ROI with at least {MIN_ROI_SAMPLES} samples in {path.name}."
        )

    clip_fraction, median = negpy_core.patch_level_stats(
        patch, float(SATURATION_VALUE), 50.0
    )
    p50 = float(median) / CLIP_CEILING
    p999 = float(meter_base(plane, roi)) / CLIP_CEILING
    linearity, plateau = raw_channel_clip_fraction(str(path), index, roi)
    values = (p50, p999, float(clip_fraction), float(linearity), float(plateau))
    if (
        not all(math.isfinite(value) and 0 <= value <= 1 for value in values)
        or p50 > p999
    ):
        raise ReportError(f"{path.name} produced invalid exposure measurements.")

    frame = {
        "channel": CHANNELS[index],
        "fileName": path.name,
        "camera": camera,
        "iso": settings[0],
        "aperture": settings[1],
        "shutterSeconds": settings[2],
        "p50Fraction": p50,
        "p999Fraction": p999,
        "clippedPixels": clipped,
        "roiClippedPixels": int(round(float(clip_fraction) * patch.size)),
        "roiSampleCount": int(patch.size),
        "roiLinearityFraction": max(float(clip_fraction), float(linearity)),
        "roiPlateauFraction": float(plateau),
    }
    if captured is not None:
        frame["capturedAt"] = captured
    return frame, (camera, *settings, *geometry)


def measure_report(triplet: ActiveTriplet, region: SampleRegion) -> dict:
    """Meter a common ROI, then verify that the same files are still active."""
    import rawpy

    _confirm_selection(triplet)
    results = []
    for index, path in enumerate(triplet.paths):
        try:
            results.append(_measure_frame(path, index, region))
        except rawpy.LibRawError as exc:
            raise ReportError(
                f"Could not decode trichrome source {path.name}."
            ) from exc
    if any(settings != results[0][1] for _, settings in results[1:]):
        raise ReportError(
            "Use the same camera, sensor orientation, ISO, aperture, and shutter for all three exposures."
        )
    if _source_hashes(triplet.paths) != triplet.source_hashes:
        raise ReportError(
            "A trichrome source changed while metering. Reopen the triplet in NegPy."
        )
    _confirm_selection(triplet)
    producer_version = (NEGPY_ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not _valid_text(producer_version, 128):
        raise ReportError("NegPy version is unavailable.")
    return {
        "schemaVersion": 1,
        "producer": "NegPy",
        "producerVersion": producer_version,
        "generatedAt": datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z"),
        "tripletId": triplet.triplet_id,
        "sampleRegion": asdict(region),
        "meteringMethod": METERING_METHOD,
        "frames": [frame for frame, _ in results],
    }


def export_report(
    triplet: ActiveTriplet, region: SampleRegion, output: Path = DEFAULT_REPORT
) -> dict:
    """Measure and atomically write a path-free JSON report."""
    output = output.expanduser().absolute()
    if output.suffix.lower() != ".json" or output.resolve() in {
        triplet.settings_db,
        *(path.resolve() for path in triplet.paths),
    }:
        raise ReportError("Choose a separate JSON report file.")
    report = measure_report(triplet, region)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=output.parent,
            prefix=f".{output.name}.",
            delete=False,
        ) as target:
            temporary = Path(target.name)
            json.dump(report, target, ensure_ascii=False, allow_nan=False, indent=2)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        _confirm_selection(triplet)
        temporary.replace(output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--roi",
        nargs=4,
        type=float,
        required=True,
        metavar=("X", "Y", "W", "H"),
        help="unrotated sensor fractions",
    )
    parser.add_argument(
        "--settings-db",
        type=Path,
        default=DEFAULT_SETTINGS_DB,
        help="NegPy session database (read-only)",
    )
    parser.add_argument(
        "--output", type=Path, default=DEFAULT_REPORT, help="destination JSON report"
    )
    args = parser.parse_args()
    try:
        region = SampleRegion(*args.roi)
        export_report(read_active_triplet(args.settings_db), region, args.output)
    except (ValueError, OSError, ImportError, RuntimeError) as exc:
        parser.exit(1, f"{exc}\n")
    print(args.output)


if __name__ == "__main__":
    main()
