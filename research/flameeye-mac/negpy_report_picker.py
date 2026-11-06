"""Select a film-base region on the current NegPy triplet and export a local report."""

from __future__ import annotations

import argparse
import json
from collections.abc import Callable
from pathlib import Path
import sys

import numpy as np
from PyQt6.QtCore import (
    QObject,
    QPoint,
    QRect,
    QRunnable,
    Qt,
    QThreadPool,
    QTimer,
    pyqtSignal,
)
from PyQt6.QtGui import QCloseEvent, QImage, QMouseEvent, QPixmap
from PyQt6.QtWidgets import (
    QApplication,
    QDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QRubberBand,
    QVBoxLayout,
)

from negpy.desktop.view.sidebar.roi_image import RoiImageLabel
from negpy.infrastructure.capture.raw_demosaic import linear_demosaic

from negpy_meter_report import (
    DEFAULT_REPORT,
    DEFAULT_SETTINGS_DB,
    MIN_ROI_SAMPLES,
    ActiveTriplet,
    SampleRegion,
    export_report,
    read_active_triplet,
)


class FilmBaseImage(RoiImageLabel):
    """Retain the native image/ROI drawing and add rectangle dragging for this dialog."""

    def __init__(self) -> None:
        super().__init__()
        self.roi_mode = False
        self.setAccessibleName("Unrotated green RAW preview")
        self.setAccessibleDescription(
            "Drag a rectangle around a clear film-base patch."
        )
        self._anchor: QPoint | None = None
        self._band = QRubberBand(QRubberBand.Shape.Rectangle, self)
        self._band.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        frame = self.frame_rect()
        position = event.position().toPoint()
        if (
            event.button() == Qt.MouseButton.LeftButton
            and not self._roi_locked
            and frame is not None
            and frame.contains(position)
        ):
            self._anchor = position
            self._band.setGeometry(QRect(position, position))
            self._band.show()
            event.accept()

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._anchor is not None:
            frame = self.frame_rect()
            if frame is not None:
                self._band.setGeometry(
                    QRect(self._anchor, event.position().toPoint()).normalized() & frame
                )
            event.accept()

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        if event.button() != Qt.MouseButton.LeftButton or self._anchor is None:
            return
        anchor = self._anchor
        self._anchor = None
        self._band.hide()
        frame = self.frame_rect()
        if frame is None or self._roi_locked:
            return
        selection = QRect(anchor, event.position().toPoint()).normalized() & frame
        if selection.width() >= 3 and selection.height() >= 3:
            self._roi = (
                (selection.x() - frame.x()) / frame.width(),
                (selection.y() - frame.y()) / frame.height(),
                selection.width() / frame.width(),
                selection.height() / frame.height(),
            )
            self.update()
            self.roiChanged.emit()
        event.accept()

    def sample_region(self) -> SampleRegion | None:
        roi = self.roi()
        return SampleRegion(roi.x, roi.y, roi.w, roi.h) if roi is not None else None

    def restore_region(self, region: SampleRegion) -> None:
        self._roi = (region.x, region.y, region.width, region.height)
        self.update()
        self.roiChanged.emit()


def green_preview(path: Path | str) -> tuple[QImage, tuple[int, int]]:
    """Return a display-only grayscale image in the same sensor orientation as the meter."""
    rgb = linear_demosaic(str(path), half_size=True)
    height, width = rgb.shape[:2]
    meter_size = (width, height)
    stride = max(1, (max(width, height) + 1599) // 1600)
    green = rgb[::stride, ::stride, 1].astype(np.float32)
    del rgb
    white = max(1.0, float(np.percentile(green, 99.5)))
    np.clip(green / white, 0, 1, out=green)
    np.sqrt(green, out=green)
    pixels = np.ascontiguousarray(np.rint(green * 255).astype(np.uint8))
    height, width = pixels.shape
    image = QImage(
        pixels.data, width, height, pixels.strides[0], QImage.Format.Format_Grayscale8
    ).copy()
    return image, meter_size


class _TaskSignals(QObject):
    finished = pyqtSignal(object, object)


class _Task(QRunnable):
    def __init__(self, work: Callable[[], object]) -> None:
        super().__init__()
        self.work = work
        self.signals = _TaskSignals()

    def run(self) -> None:
        try:
            result = self.work()
        except Exception as error:
            self.signals.finished.emit(None, str(error) or type(error).__name__)
        else:
            self.signals.finished.emit(result, None)


class ReportPicker(QDialog):
    def __init__(self, settings_db: Path, output: Path) -> None:
        super().__init__()
        self.settings_db = settings_db
        self.output = output
        self.triplet: ActiveTriplet | None = None
        self._meter_size: tuple[int, int] | None = None
        self._task: _Task | None = None
        self._completed: Callable[[object], None] | None = None

        self.setWindowTitle("NegPy Film Base Meter")
        self.resize(850, 660)
        self.setMinimumSize(560, 400)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 16, 16, 16)
        layout.setSpacing(9)

        heading = QLabel("Export a trichrome film-base report")
        heading.setStyleSheet("font-size: 18px; font-weight: bold;")
        layout.addWidget(heading)
        guide = QLabel(
            "Select the triplet in NegPy, reload it here, then drag a rectangle over clean film base "
            "visible at the same position in all three exposures."
        )
        guide.setWordWrap(True)
        layout.addWidget(guide)

        files = QFormLayout()
        self.file_labels = [self._selectable_label("—") for _ in range(3)]
        for color, label in zip(("Red RAW", "Green RAW", "Blue RAW"), self.file_labels):
            files.addRow(color, label)
        layout.addLayout(files)

        self.preview_title = QLabel("Preview · green RAW in sensor orientation")
        layout.addWidget(self.preview_title)
        self.preview = FilmBaseImage()
        self.preview.roiChanged.connect(self._sync_controls)
        layout.addWidget(self.preview, 1)

        self.region_label = self._selectable_label("")
        layout.addWidget(self.region_label)
        output_label = self._selectable_label(f"Report: {output}")
        output_label.setWordWrap(True)
        layout.addWidget(output_label)

        self.status = self._selectable_label("")
        self.status.setWordWrap(True)
        layout.addWidget(self.status)

        actions = QHBoxLayout()
        self.reload_button = QPushButton("Reload current group")
        self.reload_button.clicked.connect(self.reload_group)
        actions.addWidget(self.reload_button)
        self.clear_button = QPushButton("Clear selection")
        self.clear_button.clicked.connect(self.preview.clear_roi)
        actions.addWidget(self.clear_button)
        actions.addStretch()
        self.export_button = QPushButton("Export report")
        self.export_button.clicked.connect(self.export_selected)
        actions.addWidget(self.export_button)
        self.close_button = QPushButton("Close")
        self.close_button.clicked.connect(self.reject)
        actions.addWidget(self.close_button)
        layout.addLayout(actions)
        try:
            previous = json.loads(output.read_text(encoding="utf-8"))
            if previous["schemaVersion"] == 1 and previous["producer"] == "NegPy":
                self.preview.restore_region(SampleRegion(**previous["sampleRegion"]))
        except (OSError, KeyError, TypeError, ValueError):
            pass
        self._sync_controls()

    @staticmethod
    def _selectable_label(text: str) -> QLabel:
        label = QLabel(text)
        label.setTextFormat(Qt.TextFormat.PlainText)
        label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        return label

    def _sync_controls(self) -> None:
        busy = self._task is not None
        roi = self.preview.roi()
        usable = self._roi_large_enough()
        self.reload_button.setEnabled(not busy)
        self.clear_button.setEnabled(not busy and roi is not None)
        self.export_button.setEnabled(not busy and self.triplet is not None and usable)
        self.close_button.setEnabled(not busy)
        self.preview.set_roi_locked(busy or self.triplet is None)
        if roi is None:
            self.region_label.setText("Sample region: drag a rectangle in the preview.")
        elif not usable:
            self.region_label.setText(
                f"Select a larger patch with at least {MIN_ROI_SAMPLES:,} samples."
            )
        else:
            self.region_label.setText(
                f"Sample region: x {roi.x:.2%}, y {roi.y:.2%} · {roi.w:.2%} × {roi.h:.2%} of frame"
            )

    def _roi_large_enough(self) -> bool:
        roi = self.preview.roi()
        if roi is None or self._meter_size is None:
            return False
        x0, y0, x1, y1 = roi.pixels(*self._meter_size)
        width, height = x1 - x0, y1 - y0
        return min(width, height) >= 2 and width * height >= MIN_ROI_SAMPLES

    def _start(
        self,
        work: Callable[[], object],
        completed: Callable[[object], None],
        status: str,
    ) -> None:
        if self._task is not None:
            return
        self.status.setText(status)
        self._completed = completed
        self._task = _Task(work)
        self._task.signals.finished.connect(
            self._task_finished, Qt.ConnectionType.QueuedConnection
        )
        self._sync_controls()
        QThreadPool.globalInstance().start(self._task)

    def _task_finished(self, result: object, error: str | None) -> None:
        completed = self._completed
        self._task = None
        self._completed = None
        self.preview.set_loading(False)
        if error is not None:
            self.status.setText(f"Could not complete the operation. {error}")
        elif completed is not None:
            completed(result)
        self._sync_controls()

    def reload_group(self) -> None:
        if self._task is not None:
            return
        self.triplet = None
        self._meter_size = None
        self.preview.clear_frame()
        self.preview.set_loading(True)
        for label in self.file_labels:
            label.setText("—")
            label.setToolTip("")

        def load() -> tuple[ActiveTriplet, QImage, tuple[int, int]]:
            triplet = read_active_triplet(self.settings_db)
            image, meter_size = green_preview(triplet.paths[1])
            return triplet, image, meter_size

        self._start(
            load, self._show_group, "Reading the current NegPy group and preview…"
        )

    def _show_group(
        self, result: tuple[ActiveTriplet, QImage, tuple[int, int]]
    ) -> None:
        self.triplet, image, self._meter_size = result
        for label, file in zip(self.file_labels, self.triplet.paths):
            path = Path(file)
            label.setText(path.name)
            label.setToolTip(str(path))
        self.preview.set_frame(QPixmap.fromImage(image))
        if self.preview.roi() is None:
            self.status.setText(
                "Group loaded. Select a patch of clear film base, then export the report."
            )
        else:
            self.status.setText(
                "Check that the retained rectangle covers the same clear film base."
            )

    def export_selected(self) -> None:
        triplet = self.triplet
        region = self.preview.sample_region()
        if (
            triplet is None
            or region is None
            or self._task is not None
            or not self._roi_large_enough()
        ):
            return

        self._start(
            lambda: export_report(triplet, region, self.output),
            self._show_export,
            "Measuring the three RAW files and exporting the report…",
        )

    def _show_export(self, report: dict) -> None:
        values = "  ·  ".join(
            f"{frame['channel'].title()} {frame['p50Fraction']:.1%}"
            for frame in report["frames"]
        )
        self.status.setText(f"Report exported. Film-base P50  ·  {values}")

    def reject(self) -> None:
        if self._task is None:
            super().reject()

    def closeEvent(self, event: QCloseEvent) -> None:
        if self._task is not None:
            event.ignore()
        else:
            super().closeEvent(event)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings-db", type=Path, default=DEFAULT_SETTINGS_DB)
    parser.add_argument("--output", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args(argv)

    app = QApplication([sys.argv[0]])
    app.setApplicationName("NegPy Film Base Meter")
    dialog = ReportPicker(args.settings_db.expanduser(), args.output.expanduser())
    QTimer.singleShot(0, dialog.reload_group)
    dialog.exec()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
