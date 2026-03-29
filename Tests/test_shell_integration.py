#!/usr/bin/env python3
"""
test_shell_integration.py -- E2E socket tests for shell integration and notifications.

Requires Namu to be running. Run with:
    python -m pytest Tests/test_shell_integration.py -v
  or:
    python -m unittest Tests/test_shell_integration -v

The NAMU_SOCKET env var overrides the default socket path.
All tests are skipped automatically when Namu is not running.
"""

import unittest

from namu import NamuClient, NamuError, NamuTestCase


# ---------------------------------------------------------------------------
# Shell environment
# ---------------------------------------------------------------------------

class ShellEnvironmentTests(NamuTestCase):
    """Test that shell environment and surface queries work correctly."""

    def _get_surface_context(self):
        """Return (workspace_id, surface_id) for the current surface, or skip."""
        try:
            surface = self.client.call("surface.current")
            workspace = self.client.call("workspace.current")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.current / workspace.current not available")
            raise
        workspace_id = (workspace or {}).get("workspace_id") or (workspace or {}).get("id")
        surface_id = (surface or {}).get("surface_id") or (surface or {}).get("id")
        if not workspace_id or not surface_id:
            self.skipTest("Could not resolve workspace_id / surface_id")
        return workspace_id, surface_id

    def test_surface_read_text_returns_content(self):
        """Verify surface.read_text returns terminal content."""
        workspace_id, surface_id = self._get_surface_context()
        result = self.client.call("surface.read_text", {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
        })
        self.assertIsInstance(result, dict)
        self.assertIn("text", result)
        self.assertIsInstance(result["text"], str)

    def test_pane_list_has_geometry_fields(self):
        """Verify pane.list returns panes with geometry fields."""
        workspace_id, _ = self._get_surface_context()
        result = self.client.call("pane.list", {
            "workspace_id": workspace_id,
        })
        panes = result.get("panes", [])
        self.assertGreater(len(panes), 0, "Should have at least one pane")
        pane = panes[0]
        self.assertIn("columns", pane)
        self.assertIn("rows", pane)


# ---------------------------------------------------------------------------
# Shell lifecycle
# ---------------------------------------------------------------------------

class ShellLifecycleTests(NamuTestCase):
    """Test shell lifecycle events via IPC."""

    def _get_context(self):
        """Return (workspace_id, surface_id) or skip."""
        try:
            surface = self.client.call("surface.current")
            workspace = self.client.call("workspace.current")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.current / workspace.current not available")
            raise
        workspace_id = (workspace or {}).get("workspace_id") or (workspace or {}).get("id")
        surface_id = (surface or {}).get("surface_id") or (surface or {}).get("id")
        if not workspace_id or not surface_id:
            self.skipTest("Could not resolve workspace_id / surface_id")
        return workspace_id, surface_id

    def test_split_creates_new_surface(self):
        """Verify splitting creates a new surface with its own ID."""
        workspace_id, surface_id = self._get_context()

        try:
            split_result = self.client.call("surface.split", {
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "direction": "right",
                "focus": False,
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.split not available via IPC")
            raise

        self.assertIsInstance(split_result, dict)
        new_surface = split_result.get("surface_id") or split_result.get("id")
        self.assertIsNotNone(new_surface, "Split should return a surface_id")
        self.assertNotEqual(new_surface, surface_id,
                            "New surface should have different ID")

        # Clean up — close the new surface.
        try:
            self.client.call("surface.close", {
                "workspace_id": workspace_id,
                "surface_id": new_surface,
            })
        except NamuError:
            pass


# ---------------------------------------------------------------------------
# Notification IPC
# ---------------------------------------------------------------------------

class NotificationIPCTests(NamuTestCase):
    """Test notification-related IPC commands."""

    def test_system_identify_returns_focus_info(self):
        """Verify system.identify returns current focus context."""
        result = self.client.call("system.identify")
        self.assertIsInstance(result, dict)
        self.assertIn("workspace_id", result)
        self.assertIn("pane_id", result)

    def test_notification_list_returns_array(self):
        """Verify notification.list returns a list (even if empty)."""
        try:
            result = self.client.call("notification.list")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification.list not available via IPC")
            raise
        # Result could be a list or dict with a list field.
        if isinstance(result, list):
            notifications = result
        elif isinstance(result, dict):
            notifications = result.get("notifications", [])
        else:
            self.fail(f"Unexpected result type: {type(result)}")
        self.assertIsInstance(notifications, list)


if __name__ == "__main__":
    unittest.main(verbosity=2)
