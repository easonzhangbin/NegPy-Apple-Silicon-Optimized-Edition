from dataclasses import replace
from unittest.mock import MagicMock

import cv2
import numpy as np
import pytest

from negpy.domain.models import WorkspaceConfig
from negpy.features.flatfield import logic as flatfield
from negpy.features.flatfield.models import FlatFieldConfig
from negpy.kernel.image.logic import apply_exif_orientation


@pytest.fixture
def gain():
    values = np.linspace(0.5, 2.0, 8 * 10 * 3, dtype=np.float32).reshape(8, 10, 3)
    flatfield.set_gain_provider(lambda profile_id: (values, "test-gain") if profile_id == "test" else None)
    try:
        yield values
    finally:
        flatfield.set_gain_provider(None)


@pytest.mark.parametrize("strength", [0.0, 0.25, 0.5, 1.0, 1.5, 2.0])
def test_strength_scales_exposure_without_mutating_source_or_gain(gain, strength):
    image = np.full(gain.shape, 0.75, dtype=np.float32)
    original_gain = gain.copy()
    config = FlatFieldConfig(apply=True, profile_id="test", flatfield_strength=strength)
    corrected = flatfield.apply_flatfield(image, config, orientation=1)
    np.testing.assert_allclose(corrected, image * gain**strength, rtol=1e-6)
    np.testing.assert_array_equal(gain, original_gain)
    np.testing.assert_array_equal(image, np.full(gain.shape, 0.75, dtype=np.float32))
    assert corrected.dtype == np.float32
    if strength == 0.0:
        assert corrected is image
    if strength == 1.0:
        np.testing.assert_array_equal(corrected, image * gain)
    if strength == 2.0:
        assert corrected.max() > 1.0


def test_zero_strength_does_not_resolve_a_profile(monkeypatch):
    resolver = MagicMock(side_effect=AssertionError("A zero-strength edit must not load a gain"))
    monkeypatch.setattr(flatfield, "_resolve", resolver)
    config = FlatFieldConfig(apply=True, profile_id="test", flatfield_strength=0.0)
    image = np.ones((2, 2, 3), dtype=np.float32)
    assert flatfield.apply_flatfield(image, config, orientation=1) is image
    assert flatfield.flatfield_token(config) == ""
    resolver.assert_not_called()


@pytest.mark.parametrize("orientation", [1, 3, 6, 8])
def test_strength_follows_gain_orientation_half_frame_and_resize(gain, orientation):
    config = FlatFieldConfig(apply=True, profile_id="test", flatfield_strength=0.6)
    image = np.ones((5, 7, 3), dtype=np.float32)

    def crop_half(values):
        return values[:, : values.shape[1] // 2]

    expected_gain = cv2.resize(crop_half(apply_exif_orientation(gain, orientation)), (7, 5))
    corrected = flatfield.apply_flatfield(image, config, gain_crop=crop_half, orientation=orientation)
    np.testing.assert_allclose(corrected, expected_gain**0.6, rtol=1e-6)


def test_check_reference_uses_the_same_strength_math(gain):
    reference = np.full((11, 17, 3), 0.4, dtype=np.float32)
    strength = 1.6
    config = FlatFieldConfig(apply=True, profile_id="test", flatfield_strength=strength)
    np.testing.assert_array_equal(
        flatfield.self_corrected(reference, gain, strength),
        flatfield.apply_flatfield(reference, config, orientation=1),
    )


def test_source_tokens_preserve_old_default_and_distinguish_strengths(gain):
    from negpy.services.rendering.source_identity import source_token

    config = FlatFieldConfig(apply=True, profile_id="test")
    assert flatfield.flatfield_token(config) == "|ff:test:test-gain"
    tokens = {flatfield.flatfield_token(replace(config, flatfield_strength=value)) for value in (0.0, 0.5, 1.0, 1.5, 2.0)}
    assert len(tokens) == 5
    workspace = WorkspaceConfig()
    workspace = replace(workspace, flatfield=config, stitch=replace(workspace.stitch, stitch_enabled=True))
    assert source_token(workspace) != source_token(replace(workspace, flatfield=replace(config, flatfield_strength=1.5)))


@pytest.mark.parametrize("value,expected", [(-1, 0.0), (4, 2.0), (float("nan"), 1.0), (float("inf"), 1.0)])
def test_strength_has_safe_finite_limits(value, expected):
    assert FlatFieldConfig(flatfield_strength=value).flatfield_strength == expected


def test_strength_round_trip_and_legacy_default():
    legacy = WorkspaceConfig.from_flat_dict({"apply": True, "profile_id": "test"})
    assert legacy.flatfield.flatfield_strength == 1.0
    config = replace(legacy, flatfield=replace(legacy.flatfield, flatfield_strength=1.47))
    assert WorkspaceConfig.from_flat_dict(config.to_dict()) == config
    assert config.to_dict()["flatfield_strength"] == 1.47


@pytest.mark.parametrize("locked", [False, True])
def test_strength_commit_invalidates_only_unlocked_metering_bounds(locked):
    from negpy.desktop.controller import AppController, _autocrop_fingerprint

    config = WorkspaceConfig()
    config = replace(config, process=replace(config.process, local_floors=(0.1, 0.1, 0.1), local_ceils=(0.8, 0.8, 0.8), lock_bounds=locked))
    previewed = AppController._with_card_values(config, "flatfield", {"flatfield_strength": 0.75}, remeter=False)
    assert previewed.process == config.process
    committed = AppController._with_card_values(config, "flatfield", {"flatfield_strength": 0.75})
    assert committed.process.local_floors == (config.process.local_floors if locked else (0.0, 0.0, 0.0))
    assert committed.process.local_ceils == (config.process.local_ceils if locked else (0.0, 0.0, 0.0))
    assert _autocrop_fingerprint(config, "Adobe RGB") != _autocrop_fingerprint(committed, "Adobe RGB")


def test_default_strength_does_not_invalidate_existing_thumbnails():
    from negpy.services.assets.thumbnail_fingerprint import _changed_fields

    assert _changed_fields(FlatFieldConfig(), frozenset()) == {}
    assert _changed_fields(FlatFieldConfig(apply=True, profile_id="test"), frozenset()) == {"apply": True, "profile_id": "test"}
    assert _changed_fields(FlatFieldConfig(flatfield_strength=0.8), frozenset()) == {"flatfield_strength": 0.8}


def test_strength_is_copyable_and_roll_scoped(tmp_path):
    from negpy.desktop.session import DesktopSessionManager
    from negpy.desktop.settings_catalog import all_rows
    from negpy.infrastructure.storage.repository import StorageRepository
    from negpy.services.assets import rolls

    row = next(row for row in all_rows() if row.id == "flatfield.flatfield_strength")
    assert "flatfield_strength" in rolls.card_fields("flatfield")
    repo = StorageRepository(str(tmp_path / "edits.db"), str(tmp_path / "settings.db"))
    repo.initialize()
    session = DesktopSessionManager(repo)
    path = str(tmp_path / "frame.tif")
    roll_id = rolls.create_virtual_roll(repo, "Test roll", [path])
    session.state.active_roll_id = roll_id
    rolls.set_roll_defaults(repo, roll_id, flatfield_strength=1.3)
    repo.save_file_settings("test-hash", WorkspaceConfig(), file_path=path)
    asset = {"name": "frame.tif", "path": path, "hash": "test-hash"}
    assert session.config_for_asset(asset).flatfield.flatfield_strength == 1.3
    assert row.fields == ("flatfield_strength",)


def test_sidebar_sync_preview_commit_and_enable_state(qapp, monkeypatch):
    from negpy.desktop.session import AppState
    from negpy.desktop.view.sidebar.flatfield import FlatFieldSidebar

    monkeypatch.setattr("negpy.services.assets.flatfield.FlatFieldProfiles.list_profiles", lambda: [("test", "Test reference")])
    controller = MagicMock()
    controller.state = AppState()
    config = controller.state.config
    controller.state.config = replace(config, flatfield=FlatFieldConfig(apply=True, profile_id="test", flatfield_strength=0.75))
    sidebar = FlatFieldSidebar(controller)
    slider = sidebar.strength_slider
    assert slider.value() == 75
    assert slider.default_value() == 100
    assert slider.isEnabled()
    controller.set_roll_default.assert_not_called()
    slider.valueChanged.emit(125)
    controller.set_roll_default.assert_called_with("flatfield", persist=False, flatfield_strength=1.25)
    slider.valueCommitted.emit(125)
    controller.set_roll_default.assert_called_with("flatfield", flatfield_strength=1.25)
    controller.state.config = replace(config, flatfield=FlatFieldConfig(apply=True, profile_id="test", flatfield_strength=0))
    sidebar.sync_ui()
    assert slider.isEnabled()
    controller.state.config = replace(config, flatfield=FlatFieldConfig(apply=False, profile_id="test"))
    sidebar.sync_ui()
    assert not slider.isEnabled()
    sidebar.close()


def test_stitch_preview_applies_strength_per_part_and_invalidates_cache(tmp_path, gain):
    import tifffile

    from negpy.features.stitch.models import StitchConfig
    from negpy.services.rendering.preview_manager import PreviewManager

    primary = tmp_path / "primary.tif"
    other = tmp_path / "other.tif"
    image = np.full((8, 10, 3), 10000, dtype=np.uint16)
    tifffile.imwrite(primary, image)
    tifffile.imwrite(other, image)
    stitch = StitchConfig(
        stitch_enabled=True,
        stitch_paths=(str(other),),
        stitch_transforms=((1.0, 0.0, 0.0, 0.0, 1.0, 0.0), (1.0, 0.0, 10.0, 0.0, 1.0, 0.0)),
        stitch_canvas=(20, 8),
        stitch_sizes=((10, 8), (10, 8)),
    )
    preview = PreviewManager()
    outputs = []
    for strength in (0.0, 1.0, 2.0):
        output, _, _ = preview.load_linear_preview_stitch(
            str(primary),
            stitch,
            "Adobe RGB",
            file_hash="test#stitch",
            flatfield_profile_id="test",
            flatfield_strength=strength,
        )
        expected_part = image.astype(np.float32) / 65535.0 * gain**strength
        np.testing.assert_allclose(output, np.concatenate([expected_part, expected_part], axis=1), rtol=1e-5, atol=1e-6)
        outputs.append(output)
    cached, _, _ = preview.load_linear_preview_stitch(
        str(primary),
        stitch,
        "Adobe RGB",
        file_hash="test#stitch",
        flatfield_profile_id="test",
        flatfield_strength=2.0,
    )
    assert cached is outputs[-1]
