"""
test_window_debug_commands.py — Integration tests for Window Management, Debug,
Fullscreen, and Command Palette debug commands.

Requires Namu to be running with NAMU_SOCKET set.
Run: python -m pytest Tests/test_window_debug_commands.py -v
"""

import os
import unittest
from namu import NamuClient, NamuError, NamuTestCase


# ---------------------------------------------------------------------------
# Window Management (window.*)
# ---------------------------------------------------------------------------


class WindowListTests(NamuTestCase):
    """Tests for window.list."""

    def test_list_returns_windows(self):
        result = self.client.call("window.list")
        self.assertIn("windows", result)
        self.assertIsInstance(result["windows"], list)

    def test_list_has_count(self):
        result = self.client.call("window.list")
        self.assertIn("count", result)
        self.assertGreaterEqual(result["count"], 1)

    def test_list_window_has_required_fields(self):
        result = self.client.call("window.list")
        for win in result["windows"]:
            self.assertIn("id", win)
            self.assertIn("index", win)
            self.assertIn("is_key", win)
            self.assertIn("is_visible", win)
            self.assertIn("workspace_count", win)
            self.assertIn("selected_workspace_id", win)


class WindowCurrentTests(NamuTestCase):
    """Tests for window.current."""

    def test_current_returns_window_id(self):
        result = self.client.call("window.current")
        self.assertIn("window_id", result)

    def test_current_returns_workspace_info(self):
        result = self.client.call("window.current")
        self.assertIn("workspace_count", result)
        self.assertIn("selected_workspace_id", result)


class WindowCreateCloseTests(NamuTestCase):
    """Tests for window.create and window.close."""

    def test_create_window(self):
        result = self.client.call("window.create")
        self.assertIn("window_id", result)
        self.assertTrue(result.get("created", False))
        # Clean up
        window_id = result["window_id"]
        if window_id != "unknown":
            try:
                self.client.call("window.close", {"window_id": window_id})
            except NamuError:
                pass

    def test_close_primary_window_rejected(self):
        with self.assertRaises(NamuError) as ctx:
            self.client.call("window.close", {"window_id": "primary"})
        self.assertIn("Cannot close primary", str(ctx.exception))

    def test_close_nonexistent_window(self):
        with self.assertRaises(NamuError):
            self.client.call("window.close", {"window_id": "00000000-0000-0000-0000-000000000000"})


class WindowFocusTests(NamuTestCase):
    """Tests for window.focus."""

    def test_focus_missing_param(self):
        with self.assertRaises(NamuError) as ctx:
            self.client.call("window.focus")
        self.assertIn("window_id", str(ctx.exception))

    def test_focus_nonexistent_window(self):
        with self.assertRaises(NamuError):
            self.client.call("window.focus", {"window_id": "00000000-0000-0000-0000-000000000000"})


# ---------------------------------------------------------------------------
# Debug Layout (debug.layout)
# ---------------------------------------------------------------------------


class DebugLayoutTests(NamuTestCase):
    """Tests for debug.layout."""

    def test_layout_returns_tree(self):
        result = self.client.call("debug.layout")
        self.assertIn("tree", result)
        self.assertIn("workspace_id", result)

    def test_layout_has_container_frame(self):
        result = self.client.call("debug.layout")
        self.assertIn("container_frame", result)
        frame = result["container_frame"]
        self.assertIn("width", frame)
        self.assertIn("height", frame)

    def test_layout_has_panes(self):
        result = self.client.call("debug.layout")
        self.assertIn("panes", result)
        self.assertIsInstance(result["panes"], list)
        self.assertGreater(len(result["panes"]), 0)

    def test_layout_tree_has_type(self):
        result = self.client.call("debug.layout")
        tree = result["tree"]
        self.assertIn("type", tree)
        self.assertIn(tree["type"], ("pane", "split"))

    def test_layout_has_window_numbers(self):
        result = self.client.call("debug.layout")
        self.assertIn("main_window_number", result)
        self.assertIn("key_window_number", result)

    def test_layout_pane_has_panel_metadata(self):
        result = self.client.call("debug.layout")
        tree = result["tree"]
        # Walk to a pane node
        node = tree
        while node.get("type") == "split":
            node = node.get("first", node)
        if node.get("type") == "pane":
            self.assertIn("id", node)
            self.assertIn("frame", node)

    def test_layout_nsview_debug(self):
        """Pane nodes should include NSView-level debug info."""
        result = self.client.call("debug.layout")
        tree = result["tree"]
        node = tree
        while node.get("type") == "split":
            node = node.get("first", node)
        if node.get("type") == "pane" and "nsview_debug" in node:
            dbg = node["nsview_debug"]
            self.assertIn("in_window", dbg)
            self.assertIn("hidden", dbg)


# ---------------------------------------------------------------------------
# Debug Screenshot (debug.window.screenshot)
# ---------------------------------------------------------------------------


class DebugScreenshotTests(NamuTestCase):
    """Tests for debug.window.screenshot."""

    def test_screenshot_returns_path(self):
        result = self.client.call("debug.window.screenshot")
        self.assertIn("path", result)
        self.assertIn("snapshot_id", result)
        self.assertTrue(os.path.exists(result["path"]))

    def test_screenshot_has_dimensions(self):
        result = self.client.call("debug.window.screenshot")
        self.assertIn("width", result)
        self.assertIn("height", result)
        self.assertGreater(result["width"], 0)
        self.assertGreater(result["height"], 0)

    def test_screenshot_with_label(self):
        result = self.client.call("debug.window.screenshot", {"label": "test"})
        self.assertIn("test", result["path"])


# ---------------------------------------------------------------------------
# Debug Render Stats (debug.render_stats)
# ---------------------------------------------------------------------------


class DebugRenderStatsTests(NamuTestCase):
    """Tests for debug.render_stats."""

    def test_render_stats_returns_surfaces(self):
        result = self.client.call("debug.render_stats")
        self.assertIn("surfaces", result)
        self.assertIsInstance(result["surfaces"], list)

    def test_render_stats_has_app_state(self):
        result = self.client.call("debug.render_stats")
        self.assertIn("app_is_active", result)
        self.assertIn("window_is_key", result)
        self.assertIn("window_occlusion_visible", result)

    def test_render_stats_surface_has_fields(self):
        result = self.client.call("debug.render_stats")
        if result["surfaces"]:
            surface = result["surfaces"][0]
            self.assertIn("draw_count", surface)
            self.assertIn("last_draw_time", surface)
            self.assertIn("present_count", surface)
            self.assertIn("layer_class", surface)
            self.assertIn("layer_contents_key", surface)

    def test_render_stats_with_panel(self):
        """When targeting a specific panel, should return panel-level fields."""
        result = self.client.call("debug.render_stats")
        if "panel_id" in result:
            self.assertIn("is_first_responder", result)
            self.assertIn("in_window", result)
            self.assertIn("flash_count", result)
            self.assertIn("has_surface", result)


# ---------------------------------------------------------------------------
# Debug Flash Counters (debug.flash.*)
# ---------------------------------------------------------------------------


class DebugFlashTests(NamuTestCase):
    """Tests for debug.flash.count and debug.flash.reset."""

    def test_flash_count_returns_count(self):
        result = self.client.call("debug.flash.count")
        self.assertIn("count", result)
        self.assertIsInstance(result["count"], int)

    def test_flash_reset(self):
        result = self.client.call("debug.flash.reset")
        self.assertTrue(result.get("reset", False))


# ---------------------------------------------------------------------------
# Debug Panel Snapshot (debug.panel_snapshot*)
# ---------------------------------------------------------------------------


class DebugPanelSnapshotTests(NamuTestCase):
    """Tests for debug.panel_snapshot and debug.panel_snapshot.reset.

    Panel snapshot requires the terminal surface to be visible on screen
    (CGWindowListCreateImage needs a visible window). Tests that capture
    snapshots are skipped if the surface is not available.
    """

    def _try_snapshot(self):
        """Attempt a snapshot, skip test if surface not capturable."""
        try:
            return self.client.call("debug.panel_snapshot")
        except NamuError as e:
            if "capture" in str(e).lower():
                self.skipTest("Surface not capturable (window may not be visible)")
            raise

    def test_snapshot_returns_path(self):
        result = self._try_snapshot()
        self.assertIn("path", result)
        self.assertIn("panel_id", result)
        self.assertIn("width", result)
        self.assertIn("height", result)

    def test_snapshot_first_has_negative_changed_pixels(self):
        """First snapshot has nothing to compare — changed_pixels should be -1."""
        self.client.call("debug.panel_snapshot.reset")
        result = self._try_snapshot()
        self.assertEqual(result["changed_pixels"], -1)

    def test_snapshot_second_has_zero_or_positive(self):
        """Second snapshot should have 0 or positive changed pixels."""
        self.client.call("debug.panel_snapshot.reset")
        self._try_snapshot()
        result = self._try_snapshot()
        self.assertGreaterEqual(result["changed_pixels"], 0)

    def test_snapshot_reset_all(self):
        result = self.client.call("debug.panel_snapshot.reset")
        self.assertTrue(result.get("reset", False))
        self.assertTrue(result.get("all", False))

    def test_snapshot_reset_per_panel(self):
        """Reset with surface_id should only clear that panel."""
        snap = self._try_snapshot()
        panel_id = snap["panel_id"]
        result = self.client.call("debug.panel_snapshot.reset", {"surface_id": panel_id})
        self.assertTrue(result.get("reset", False))
        self.assertEqual(result.get("surface_id"), panel_id)


# ---------------------------------------------------------------------------
# App Focus Override (debug.app_focus.*)
# ---------------------------------------------------------------------------


class DebugAppFocusTests(NamuTestCase):
    """Tests for debug.app_focus.override and debug.app_focus.simulate_active."""

    def test_override_active(self):
        result = self.client.call("debug.app_focus.override", {"state": "active"})
        self.assertEqual(result["override"], True)

    def test_override_inactive(self):
        result = self.client.call("debug.app_focus.override", {"state": "inactive"})
        self.assertEqual(result["override"], False)

    def test_override_clear(self):
        self.client.call("debug.app_focus.override", {"state": "active"})
        result = self.client.call("debug.app_focus.override", {"state": "clear"})
        self.assertIsNone(result["override"])

    def test_override_with_focused_bool(self):
        result = self.client.call("debug.app_focus.override", {"focused": True})
        self.assertEqual(result["override"], True)

    def test_override_invalid_state(self):
        with self.assertRaises(NamuError):
            self.client.call("debug.app_focus.override", {"state": "invalid"})

    def test_simulate_active(self):
        result = self.client.call("debug.app_focus.simulate_active")
        self.assertIsInstance(result, dict)

    def tearDown(self):
        # Always clear the override after tests
        try:
            self.client.call("debug.app_focus.override", {"state": "clear"})
        except Exception:
            pass
        super().tearDown()


# ---------------------------------------------------------------------------
# Fullscreen (fullscreen.*)
# ---------------------------------------------------------------------------


class FullscreenTests(NamuTestCase):
    """Tests for fullscreen.toggle and fullscreen.status."""

    def test_status_returns_is_fullscreen(self):
        # This may error if no key window, so we handle both cases
        try:
            result = self.client.call("fullscreen.status")
            self.assertIn("is_fullscreen", result)
            self.assertIsInstance(result["is_fullscreen"], bool)
        except NamuError as e:
            # No active window — acceptable in headless test
            self.assertIn("No active window", str(e))


# ---------------------------------------------------------------------------
# Command Palette Debug (debug.command_palette.*)
# ---------------------------------------------------------------------------


class DebugCommandPaletteTests(NamuTestCase):
    """Tests for debug.command_palette.* commands."""

    def test_visible_returns_bool(self):
        result = self.client.call("debug.command_palette.visible")
        self.assertIn("visible", result)
        self.assertIsInstance(result["visible"], bool)

    def test_selection_returns_index(self):
        result = self.client.call("debug.command_palette.selection")
        self.assertIn("selected_index", result)

    def test_results_returns_results(self):
        result = self.client.call("debug.command_palette.results")
        self.assertIn("visible", result)
        self.assertIn("query", result)
        self.assertIn("results", result)
        self.assertIsInstance(result["results"], list)

    def test_results_with_limit(self):
        result = self.client.call("debug.command_palette.results", {"limit": 5})
        self.assertLessEqual(len(result["results"]), 5)


# ---------------------------------------------------------------------------
# System Capabilities (verify new commands are registered)
# ---------------------------------------------------------------------------


class CapabilitiesTests(NamuTestCase):
    """Verify all new commands appear in system.capabilities."""

    def test_window_commands_registered(self):
        result = self.client.call("system.capabilities")
        methods = result.get("methods", [])
        for cmd in ["window.list", "window.current", "window.focus", "window.create", "window.close"]:
            self.assertIn(cmd, methods, f"Missing: {cmd}")

    def test_debug_commands_registered(self):
        result = self.client.call("system.capabilities")
        methods = result.get("methods", [])
        for cmd in [
            "debug.layout", "debug.window.screenshot",
            "debug.panel_snapshot", "debug.panel_snapshot.reset",
            "debug.flash.count", "debug.flash.reset",
            "debug.render_stats",
            "debug.app_focus.override", "debug.app_focus.simulate_active",
        ]:
            self.assertIn(cmd, methods, f"Missing: {cmd}")

    def test_fullscreen_commands_registered(self):
        result = self.client.call("system.capabilities")
        methods = result.get("methods", [])
        for cmd in ["fullscreen.toggle", "fullscreen.status"]:
            self.assertIn(cmd, methods, f"Missing: {cmd}")

    def test_palette_debug_commands_registered(self):
        result = self.client.call("system.capabilities")
        methods = result.get("methods", [])
        for cmd in [
            "debug.command_palette.toggle",
            "debug.command_palette.visible",
            "debug.command_palette.results",
            "debug.command_palette.selection",
        ]:
            self.assertIn(cmd, methods, f"Missing: {cmd}")


if __name__ == "__main__":
    unittest.main()
