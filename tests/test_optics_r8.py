from dataclasses import replace

import cv2
import numpy as np
import pytest

from negpy.domain.models import WorkspaceConfig
from negpy.features.flatfield.logic import scaled_gain, self_corrected, flatfield_token, set_gain_provider
from negpy.features.flatfield.models import FlatFieldConfig
from negpy.features.flatfield.analysis import distribution_maps, reference_quality
from negpy.features.lens.calibration import CalibrationError, apply_calibrated_ca, calibrate_ca
from negpy.kernel.image.logic import apply_exif_orientation
from negpy.services.rendering.lens import metadata_lens_corrections, prepare_lens_source


def texture():
    sample = np.random.default_rng(7).uniform(0.1, 0.8, (720, 960)).astype(np.float32)
    return cv2.GaussianBlur(sample, (0, 0), 1.2)


def test_split_gain_preserves_legacy_and_separates_log_components():
    gain = np.random.default_rng(4).uniform(0.4, 2, (40, 60, 3)).astype(np.float32)
    np.testing.assert_array_equal(scaled_gain(gain, 1), gain)
    np.testing.assert_array_equal(scaled_gain(gain, 0.7), gain**0.7)
    brightness = scaled_gain(gain, 1, 1, 0)
    color = scaled_gain(gain, 1, 0, 1)
    np.testing.assert_allclose(brightness[..., 0], brightness[..., 1], rtol=1e-6)
    np.testing.assert_allclose(np.prod(color, axis=2), 1, rtol=1e-6)
    np.testing.assert_allclose(brightness * color, gain, rtol=1e-6)
    np.testing.assert_array_equal(scaled_gain(gain, 1, 0, 0), np.ones_like(gain))


def test_split_strength_persists_and_changes_cache_identity():
    gain = np.ones((8, 8, 3), np.float32) * 1.2
    set_gain_provider(lambda profile: (gain, "gain") if profile == "test" else None)
    try:
        legacy = FlatFieldConfig(apply=True, profile_id="test")
        changed = replace(legacy, flatfield_luminance=0.5, flatfield_color=1.2)
        assert flatfield_token(changed) != flatfield_token(legacy)
        workspace = replace(WorkspaceConfig(), flatfield=changed)
        assert WorkspaceConfig.from_flat_dict(workspace.to_dict()) == workspace
        assert FlatFieldConfig(flatfield_color=float("nan")).flatfield_color == 1
    finally:
        set_gain_provider(None)


def test_quality_detects_clipping_noise_and_limited_gain():
    sample = np.full((200, 300, 3), 0.5, np.float32)
    gain = np.full((80, 120, 3), 4, np.float32)
    sample[:20] = 1
    noisy = np.clip(sample + np.random.default_rng(1).normal(0, 0.06, sample.shape), 0, 1).astype(np.float32)
    result = reference_quality(noisy, gain)
    assert result.clipped_fraction > 0.001
    assert result.high_frequency > 0.02
    assert result.gain_limited_fraction == 1


def test_distribution_maps_use_identical_before_after_scale():
    coordinate = np.linspace(0.5, 1.5, 300, dtype=np.float32)[None, :, None]
    reference = np.ones((200, 300, 3), np.float32) * 0.4 * coordinate
    gain = 0.4 / reference
    before = distribution_maps(reference, reference)
    after = distribution_maps(self_corrected(reference, gain), reference)
    assert after[2] < before[2] * 0.05
    assert after[3] < 1e-5


def test_calibration_recovers_optical_shift_without_modifying_green():
    base = texture()
    original = np.repeat(base[..., None], 3, axis=2)
    distorted = apply_calibrated_ca(original, (0.003, 0.001), (-0.002, -0.001))
    saved = distorted.copy()
    measured = calibrate_ca(distorted)
    corrected = apply_calibrated_ca(distorted, measured.red.coefficients, measured.blue.coefficients, aspect=measured.aspect)
    np.testing.assert_array_equal(distorted, saved)
    np.testing.assert_array_equal(corrected[..., 1], original[..., 1])
    area = np.s_[20:-20, 20:-20]
    for channel in (0, 2):
        before = np.mean((distorted[area][..., channel] - base[area]) ** 2)
        after = np.mean((corrected[area][..., channel] - base[area]) ** 2)
        assert after < before * 0.1
    assert measured.red.after_px < measured.red.before_px * 0.75


def test_calibration_does_not_correct_a_uniform_or_unrelated_color_reference():
    with pytest.raises(CalibrationError):
        calibrate_ca(np.full((360, 480, 3), 0.3, np.float32))
    sample = np.random.default_rng(17).uniform(0.1, 0.8, (360, 480, 3)).astype(np.float32)
    with pytest.raises(CalibrationError):
        calibrate_ca(sample)


def test_identity_reference_does_not_invent_a_correction():
    sample = np.repeat(texture()[..., None], 3, axis=2)
    measured = calibrate_ca(sample)
    assert measured.red.coefficients == measured.blue.coefficients == (0, 0)
    assert apply_calibrated_ca(sample, (0, 0), (0, 0)) is sample


@pytest.mark.parametrize("orientation", [1, 3, 6, 8])
def test_ca_rotation_and_size_independent_model(orientation):
    sample = np.repeat(texture()[..., None], 3, axis=2)
    expected = apply_calibrated_ca(sample, (0.002, 0.001), (-0.002, 0), aspect=960 / 720)
    rotated = apply_exif_orientation(sample, orientation)
    result = apply_calibrated_ca(rotated, (0.002, 0.001), (-0.002, 0), orientation, 960 / 720)
    np.testing.assert_array_equal(result, apply_exif_orientation(expected, orientation))
    assert apply_calibrated_ca(rotated, (0.002, 0.001), (-0.002, 0), orientation, 2) is rotated


def test_custom_ca_replaces_embedded_ca_and_round_trips():
    config = WorkspaceConfig()
    config = replace(
        config,
        geometry=replace(
            config.geometry,
            lens_ca_custom=True,
            lens_ca_from_metadata=True,
            lens_ca_red=(0.002, 0),
            lens_ca_blue=(-0.001, 0),
            lens_ca_aspect=4 / 3,
            lens_ca_name="macro",
        ),
    )
    decoded = WorkspaceConfig.from_flat_dict(config.to_dict())
    assert decoded == config
    correction = metadata_lens_corrections(config)
    assert correction.custom_ca and not correction.ca
    sample = np.repeat(texture()[..., None], 3, axis=2)
    expected = apply_calibrated_ca(sample, (0.002, 0), (-0.001, 0), aspect=4 / 3)
    result = prepare_lens_source(sample, {"orientation": 1}, config.flatfield, correction)
    np.testing.assert_array_equal(result, expected)


def test_profile_is_stored_outside_app_and_inline_edit_survives_missing_file(tmp_path, monkeypatch):
    from negpy.services.assets import lens_ca

    monkeypatch.setattr(lens_ca, "directory", lambda: tmp_path)
    values = dict(lens_ca_red=(0.002, 0), lens_ca_blue=(-0.001, 0), lens_ca_aspect=4 / 3, lens_ca_name="macro")
    identifier = lens_ca.save_profile(values)
    assert lens_ca.profiles()[0][1] == values
    config = replace(WorkspaceConfig(), geometry=replace(WorkspaceConfig().geometry, lens_ca_custom=True, **values))
    (tmp_path / f"{identifier}.json").unlink()
    assert metadata_lens_corrections(config).custom_ca


def test_calibration_cancellation():
    with pytest.raises(InterruptedError):
        calibrate_ca(np.repeat(texture()[..., None], 3, axis=2), lambda: True)


@pytest.mark.parametrize("bad", [{"lens_ca_red": [float("nan"), 0]}, {"lens_ca_blue": [1, 0]}, {"lens_ca_aspect": 0}, {"lens_ca_name": ""}])
def test_profile_rejects_invalid_calibration(tmp_path, monkeypatch, bad):
    import json
    from negpy.services.assets import lens_ca

    monkeypatch.setattr(lens_ca, "directory", lambda: tmp_path)
    values = dict(lens_ca_red=(0.002, 0), lens_ca_blue=(-0.001, 0), lens_ca_aspect=4 / 3, lens_ca_name="macro", **{})
    values.update(bad)
    with pytest.raises(ValueError):
        lens_ca.save_profile(values)
    (tmp_path / "bad.json").write_text(json.dumps(dict(values, schema=1)))
    (tmp_path / "list.json").write_text("[]")
    assert lens_ca.profiles() == []
    assert not replace(WorkspaceConfig().geometry, lens_ca_custom=True, lens_ca_aspect=0).lens_ca_custom


def test_new_dialogs_show_diagnostics_and_save_validated_coefficients(qapp, tmp_path, monkeypatch):
    from negpy.desktop.view.widgets.optical_diagnostics import FlatFieldAnalysisDialog, LensCACalibrationDialog
    from negpy.services.assets.flatfield import StoredCheck
    from negpy.services.assets import lens_ca
    from tests.conftest import FakeRepo

    monkeypatch.setattr(lens_ca, "directory", lambda: tmp_path)
    sample = np.repeat(texture()[..., None], 3, axis=2)
    measured = calibrate_ca(apply_calibrated_ca(sample, (0.003, 0.001), (-0.002, -0.001)))
    stored = StoredCheck(np.ones_like(sample), sample, None)
    dialog = FlatFieldAnalysisDialog(stored, FlatFieldConfig(), repo=FakeRepo())
    dialog.show()
    qapp.processEvents()
    assert dialog.isVisible()
    dialog.accept()
    calibration = LensCACalibrationDialog(repo=FakeRepo())
    assert not calibration.save_button.isEnabled()
    calibration.name.setText("LAOWA 85mm f/5.6 - reference test")
    calibration._measured(measured, sample[:160, :160], sample[:160, :160])
    calibration._refresh()
    assert calibration.save_button.isEnabled()
    saved = []
    calibration.profile_saved.connect(saved.append)
    calibration._save()
    assert saved[0]["lens_ca_custom"]
    assert not saved[0]["lens_ca_from_metadata"]
    assert lens_ca.profiles()[0][1]["lens_ca_red"] == measured.red.coefficients


def test_calibration_worker_uses_uncorrected_sensor_reference(qapp, monkeypatch):
    from negpy.desktop.workers.lens_calibration import LensCalibrationWorker
    from negpy.services.rendering.preview_manager import PreviewManager

    sample = np.repeat(texture()[..., None], 3, axis=2)
    sample = apply_calibrated_ca(sample, (0.003, 0.001), (-0.002, -0.001))

    def load(_self, _path, **kwargs):
        assert kwargs["full_resolution"]
        assert not kwargs["use_camera_wb"]
        return apply_exif_orientation(sample, 6), None, {"orientation": 6}

    monkeypatch.setattr(PreviewManager, "load_linear_preview", load)
    worker = LensCalibrationWorker("reference.dng")
    results, errors = [], []
    worker.measured.connect(lambda fit, before, after: results.append((fit, before, after)))
    worker.failed.connect(errors.append)
    worker.run()
    assert not errors
    fit, before, after = results[0]
    assert fit.aspect == 4 / 3
    assert before.shape == after.shape == (320, 320, 3)
    assert fit.red.after_px < fit.red.before_px * 0.75


def test_custom_ca_and_flatfield_share_preview_and_export_source(tmp_path):
    import tifffile
    from negpy.services.rendering.preview_manager import PreviewManager
    from negpy.services.rendering.image_processor import ImageProcessor

    sample = np.repeat(texture()[..., None], 3, axis=2)
    path = tmp_path / "neutral.tif"
    tifffile.imwrite(path, (sample * 65535).astype(np.uint16), photometric="rgb")
    config = WorkspaceConfig()
    config = replace(
        config,
        geometry=replace(config.geometry, lens_ca_custom=True, lens_ca_red=(0.002, 0), lens_ca_blue=(-0.001, 0), lens_ca_aspect=4 / 3),
        flatfield=FlatFieldConfig(apply=True, profile_id="test", flatfield_luminance=0.7, flatfield_color=1.3),
    )
    gain = np.full((32, 48, 3), [1.05, 1, 0.95], np.float32)
    set_gain_provider(lambda identifier: (gain, "gain"))
    try:
        preview, _, _ = PreviewManager().load_linear_preview(
            str(path), full_resolution=True, lens_corrections=metadata_lens_corrections(config), lens_flatfield=config.flatfield
        )
        exported, _, _ = ImageProcessor()._load_source_f32(str(path), config)
        np.testing.assert_array_equal(preview, exported)
    finally:
        set_gain_provider(None)
