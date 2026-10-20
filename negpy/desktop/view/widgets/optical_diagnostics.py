"""Flat-reference maps and reference-based optical channel calibration."""

from pathlib import Path

import numpy as np
from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtGui import QImage, QPixmap
from PyQt6.QtWidgets import QDialog, QFileDialog, QGridLayout, QHBoxLayout, QLabel, QLineEdit, QPushButton, QVBoxLayout, QWidget

from negpy.desktop.view.styles.templates import field_row, hint_label, pin_dialog_default
from negpy.desktop.view.widgets.dialog_geometry import remember_dialog_geometry
from negpy.desktop.view.widgets.file_dialogs import last_open_folder, pick_start_dir
from negpy.desktop.workers.lens_calibration import LensCalibrationWorker
from negpy.features.flatfield.analysis import distribution_maps, reference_quality
from negpy.features.flatfield.logic import scaled_gain, self_corrected
from negpy.kernel.image.logic import float_to_uint8
from negpy.kernel.system.i18n import tr
from negpy.services.assets import lens_ca


def picture(image: np.ndarray) -> QLabel:
    pixels = np.ascontiguousarray(float_to_uint8(image))
    height, width = pixels.shape[:2]
    frame = QImage(pixels.data, width, height, pixels.strides[0], QImage.Format.Format_RGB888).copy()
    label = QLabel()
    label.setAlignment(Qt.AlignmentFlag.AlignCenter)
    label.setPixmap(
        QPixmap.fromImage(frame).scaled(320, 240, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
    )
    return label


class FlatFieldAnalysisDialog(QDialog):
    def __init__(self, stored, config, parent=None, *, repo=None):
        super().__init__(parent)
        self.setWindowTitle(tr("Flat Field Analysis"))
        self.resize(760, 720)
        root = QVBoxLayout(self)
        if stored.reference is None:
            root.addWidget(hint_label(tr("This older profile has no reference preview. Recreate it to inspect correction quality.")))
        else:
            before = stored.reference.astype(np.float32)
            after = self_corrected(before, stored.gain, config.flatfield_strength, config.flatfield_luminance, config.flatfield_color)
            first = distribution_maps(before, before)
            second = distribution_maps(after, before)
            grid = QGridLayout()
            for column, (title, maps) in enumerate(((tr("Before Correction"), first), (tr("After Correction"), second))):
                grid.addWidget(hint_label(title), 0, column)
                grid.addWidget(picture(maps[0]), 1, column)
                grid.addWidget(picture(maps[1]), 2, column)
                grid.addWidget(
                    hint_label(tr("Brightness P95: {brightness:.3f} EV; color P95: {color:.3f} EV", brightness=maps[2], color=maps[3])),
                    3,
                    column,
                )
            root.addLayout(grid)
            root.addWidget(
                hint_label(
                    tr(
                        "Top: brightness deviation (gray is zero, ±1 EV). Bottom: spatial color deviation (gray is neutral, ±0.25 EV). Scales match before and after; these are diagnostic maps, not color-managed photographs."
                    )
                )
            )
            quality = stored.quality if stored.quality is not None else reference_quality(before, stored.gain)
            effective = scaled_gain(stored.gain, config.flatfield_strength, config.flatfield_luminance, config.flatfield_color)
            messages = []
            if quality.clipped_fraction > 0.001 or (stored.check and stored.check.clipped):
                messages.append(tr("Reference highlights are clipped. Capture a lower exposure; clipped detail cannot be recovered."))
            if quality.high_frequency > 0.02:
                messages.append(tr("Reference noise or texture is high. Use a clean, evenly lit reference and a lower ISO."))
            if quality.gain_limited_fraction > 0.001:
                messages.append(tr("The reference gain reached its safety limit. Check exposure, carrier shadows and light coverage."))
            if float(np.max(effective)) > 3:
                messages.append(tr("Effective correction gain exceeds 3× and can amplify noise. Reduce strength or improve illumination."))
            if not messages:
                messages.append(tr("No clipping, high-noise or excessive-gain warning at the measured resolution."))
            root.addWidget(hint_label("\n".join(messages)))
            root.addWidget(
                hint_label(
                    tr(
                        "Noise is a high-frequency indicator at the stored measurement resolution, not sensor read noise. Older preview-only profiles may hide noise; recreate the reference for a fresh measurement."
                    )
                )
            )
        close = QPushButton(tr("Close"))
        close.clicked.connect(self.accept)
        pin_dialog_default(close)
        root.addWidget(close, alignment=Qt.AlignmentFlag.AlignRight)
        remember_dialog_geometry(self, repo, "flatfield_analysis")


class LensCACalibrationDialog(QDialog):
    profile_saved = pyqtSignal(object)

    def __init__(self, parent=None, *, repo=None):
        super().__init__(parent)
        self.setWindowTitle(tr("Calibrate Lens Chromatic Aberration"))
        self.resize(760, 700)
        self._repo = repo
        self._worker = None
        self._fit = None
        self._path = ""
        root = QVBoxLayout(self)
        root.addWidget(
            hint_label(
                tr(
                    "Photograph a neutral black-and-white textured target covering the center and all four corners. Keep the actual camera, lens, aperture, focus distance and magnification. Do not use a flat light field or a color negative: scene color and original-film fringes can bias calibration. This corrects radial lateral CA by channel remapping, not desaturation or defringing."
                )
            )
        )
        self.reference_button = QPushButton(tr("Choose Reference…"))
        self.reference_button.setToolTip(tr("Choose an uncorrected reference captured with the scanning lens."))
        self.reference_button.clicked.connect(self._choose)
        root.addWidget(self.reference_button)
        self.name = QLineEdit()
        self.name.setPlaceholderText(tr("Name the lens, aperture and magnification"))
        self.name.setToolTip(tr("Stored with the measured coefficients; reuse only under matching capture conditions."))
        root.addLayout(field_row(tr("Name"), self.name))
        self.views = QHBoxLayout()
        root.addLayout(self.views)
        self.status = hint_label(tr("Choose a reference, then measure. The fit must improve held-out patches before it can be saved."))
        self.status.setWordWrap(True)
        root.addWidget(self.status)
        root.addStretch()
        footer = QHBoxLayout()
        self.cancel_button = QPushButton(tr("Cancel"))
        self.cancel_button.clicked.connect(self.reject)
        self.measure_button = QPushButton(tr("Measure"))
        self.measure_button.clicked.connect(self._measure)
        self.save_button = QPushButton(tr("Save and Apply"))
        self.save_button.clicked.connect(self._save)
        self.save_button.setEnabled(False)
        self.measure_button.setEnabled(False)
        self.name.textChanged.connect(self._refresh)
        for button in (self.cancel_button, self.measure_button, self.save_button):
            footer.addWidget(button)
        root.addLayout(footer)
        pin_dialog_default(self.measure_button, self.cancel_button, self.save_button)
        remember_dialog_geometry(self, repo, "lens_ca_calibration")

    def _choose(self):
        path, _filter = QFileDialog.getOpenFileName(self, tr("Choose Reference"), pick_start_dir(last_open_folder(self._repo)))
        if not path:
            return
        self._path = path
        self._fit = None
        self._clear_views()
        self.reference_button.setText(Path(path).name)
        if not self.name.text().strip():
            self.name.setText(Path(path).stem)
        self._refresh()

    def _refresh(self):
        busy = self._worker is not None and self._worker.isRunning()
        self.measure_button.setEnabled(bool(self._path) and not busy)
        self.reference_button.setEnabled(not busy)
        self.save_button.setEnabled(self._fit is not None and bool(self.name.text().strip()) and not busy)

    def _measure(self):
        if not self._path or (self._worker is not None and self._worker.isRunning()):
            return
        self._fit = None
        self._clear_views()
        self.status.setText(tr("Measuring channel displacement and validating independent patches…"))
        self._worker = LensCalibrationWorker(self._path, self)
        self._worker.measured.connect(self._measured)
        self._worker.failed.connect(self._failed)
        self._worker.finished.connect(self._refresh)
        self._worker.start()
        self._refresh()

    def _measured(self, fit, before, after):
        self._fit = fit
        self._clear_views()
        for label, image in ((tr("Before Correction"), before), (tr("After Correction"), after)):
            view = QWidget()
            layout = QVBoxLayout(view)
            layout.addWidget(hint_label(label))
            layout.addWidget(picture(image))
            self.views.addWidget(view)
        self.status.setText(
            tr(
                "Held-out displacement at reference resolution — R/G: {red_before:.2f} → {red_after:.2f} px; B/G: {blue_before:.2f} → {blue_after:.2f} px. Accepted patches: {red_count}/{blue_count}. Preview: four corner crops; green is unchanged. This model does not correct axial color blur or restore lost detail.",
                red_before=fit.red.before_px / fit.analysis_scale,
                red_after=fit.red.after_px / fit.analysis_scale,
                blue_before=fit.blue.before_px / fit.analysis_scale,
                blue_after=fit.blue.after_px / fit.analysis_scale,
                red_count=fit.red.patches,
                blue_count=fit.blue.patches,
            )
        )

    def _clear_views(self):
        while self.views.count():
            self.views.takeAt(0).widget().deleteLater()

    def _failed(self, code):
        messages = {
            "low_texture": tr("Not enough reliable shared edges. Use a detailed neutral target, with no clipped highlights."),
            "poor_coverage": tr("Reliable edges do not cover the center and all corners. Reframe the reference target."),
            "unreliable_fit": tr("The model did not reliably improve independent patches. No correction was saved."),
            "reference_size": tr("The reference is too small or is not an RGB image."),
            "invalid_reference": tr("The reference is empty or contains invalid values."),
        }
        self.status.setText(messages.get(code, tr("Calibration failed: {error}", error=code)))

    def _save(self):
        if self._fit is None or not self.name.text().strip():
            return
        values = {
            "lens_ca_red": self._fit.red.coefficients,
            "lens_ca_blue": self._fit.blue.coefficients,
            "lens_ca_aspect": self._fit.aspect,
            "lens_ca_name": self.name.text().strip(),
        }
        try:
            lens_ca.save_profile(values)
        except (OSError, ValueError) as error:
            self.status.setText(tr("Could not save calibration: {error}", error=str(error)))
            return
        self.profile_saved.emit(dict(values, lens_ca_custom=True, lens_ca_from_metadata=False))
        self.accept()

    def done(self, result):
        if self._worker is not None:
            self._worker.requestInterruption()
            self._worker.wait()
        super().done(result)
