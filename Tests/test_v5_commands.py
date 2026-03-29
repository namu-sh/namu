#!/usr/bin/env python3
"""
test_v5_commands.py — E2E socket tests for v5 IPC commands.

Requires Namu to be running. Run with:
    python -m pytest Tests/test_v5_commands.py -v
  or:
    python -m unittest Tests/test_v5_commands -v

The NAMU_SOCKET env var overrides the default socket path.
All tests are skipped automatically when Namu is not running.
"""

import unittest
import uuid

from namu import NamuClient, NamuError, NamuTestCase


# ---------------------------------------------------------------------------
# system.identify
# ---------------------------------------------------------------------------

class SystemIdentifyTests(NamuTestCase):
    """Tests for system.identify."""

    def test_system_identify_returns_workspace_id(self):
        result = self.client.call("system.identify")
        self.assertIsInstance(result, dict)
        self.assertIn("workspace_id", result)
        self.assertIsInstance(result["workspace_id"], str)
        self.assertGreater(len(result["workspace_id"]), 0)

    def test_system_identify_returns_pane_id(self):
        result = self.client.call("system.identify")
        self.assertIsInstance(result, dict)
        self.assertIn("pane_id", result)
        self.assertIsInstance(result["pane_id"], str)
        self.assertGreater(len(result["pane_id"]), 0)


# ---------------------------------------------------------------------------
# workspace.current
# ---------------------------------------------------------------------------

class WorkspaceCurrentTests(NamuTestCase):
    """Tests for workspace.current."""

    def test_workspace_current_returns_workspace_id(self):
        result = self.client.call("workspace.current")
        self.assertIsInstance(result, dict)
        self.assertIn("workspace_id", result)
        self.assertIsInstance(result["workspace_id"], str)
        self.assertGreater(len(result["workspace_id"]), 0)

    def test_workspace_current_returns_title(self):
        result = self.client.call("workspace.current")
        self.assertIsInstance(result, dict)
        self.assertIn("title", result)
        # Title can be empty string — just verify the key is present
        self.assertIsNotNone(result["title"])


# ---------------------------------------------------------------------------
# workspace.list
# ---------------------------------------------------------------------------

class WorkspaceListV5Tests(NamuTestCase):
    """Tests for workspace.list (v5 shape)."""

    def test_workspace_list_returns_non_empty_array(self):
        result = self.client.call("workspace.list")
        workspaces = result if isinstance(result, list) else (result or {}).get("workspaces", [])
        self.assertIsInstance(workspaces, list)
        self.assertGreater(len(workspaces), 0)


# ---------------------------------------------------------------------------
# workspace.next / workspace.previous
# ---------------------------------------------------------------------------

class WorkspaceNavigationTests(NamuTestCase):
    """Tests for workspace.next and workspace.previous."""

    def _current_workspace_id(self):
        result = self.client.call("workspace.current")
        if isinstance(result, dict):
            return result.get("workspace_id") or result.get("id")
        return None

    def test_workspace_next_then_previous_returns_to_original(self):
        workspaces = self.client.workspace_list()
        if len(workspaces) < 2:
            self.skipTest("Need at least 2 workspaces to test next/previous")

        original_id = self._current_workspace_id()
        if not original_id:
            self.skipTest("Could not determine current workspace ID")

        try:
            self.client.call("workspace.next")
            self.client.call("workspace.previous")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("workspace.next/previous not available via IPC")
            raise

        restored_id = self._current_workspace_id()
        self.assertEqual(original_id, restored_id)


# ---------------------------------------------------------------------------
# surface.current
# ---------------------------------------------------------------------------

class SurfaceCurrentTests(NamuTestCase):
    """Tests for surface.current."""

    def test_surface_current_returns_surface_id(self):
        try:
            result = self.client.call("surface.current")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.current not available via IPC")
            raise
        self.assertIsInstance(result, dict)
        self.assertIn("surface_id", result)
        self.assertIsInstance(result["surface_id"], str)
        self.assertGreater(len(result["surface_id"]), 0)

    def test_surface_current_returns_pane_id(self):
        try:
            result = self.client.call("surface.current")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.current not available via IPC")
            raise
        self.assertIsInstance(result, dict)
        self.assertIn("pane_id", result)
        self.assertIsInstance(result["pane_id"], str)


# ---------------------------------------------------------------------------
# surface.read_text
# ---------------------------------------------------------------------------

class SurfaceReadTextTests(NamuTestCase):
    """Tests for surface.read_text."""

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

    def test_surface_read_text_returns_text_field(self):
        workspace_id, surface_id = self._get_surface_context()
        result = self.client.call("surface.read_text", {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
        })
        self.assertIsInstance(result, dict)
        self.assertIn("text", result)
        self.assertIsInstance(result["text"], str)


# ---------------------------------------------------------------------------
# pane.list
# ---------------------------------------------------------------------------

class PaneListV5Tests(NamuTestCase):
    """Tests for pane.list (v5)."""

    def _workspace_id(self):
        result = self.client.call("workspace.current")
        if isinstance(result, dict):
            return result.get("workspace_id") or result.get("id")
        workspaces = self.client.workspace_list()
        return workspaces[0]["id"] if workspaces else None

    def test_pane_list_returns_panes_array(self):
        ws_id = self._workspace_id()
        if not ws_id:
            self.skipTest("No workspace available")
        result = self.client.call("pane.list", {"workspace_id": ws_id})
        self.assertIsInstance(result, dict)
        self.assertIn("panes", result)
        self.assertIsInstance(result["panes"], list)

    def test_pane_list_panes_have_geometry_fields(self):
        ws_id = self._workspace_id()
        if not ws_id:
            self.skipTest("No workspace available")
        result = self.client.call("pane.list", {"workspace_id": ws_id})
        panes = result.get("panes", [])
        if not panes:
            self.skipTest("No panes in current workspace")
        for pane in panes:
            with self.subTest(pane_id=pane.get("id")):
                self.assertIn("columns", pane, "pane missing 'columns' geometry field")
                self.assertIn("rows", pane, "pane missing 'rows' geometry field")
                self.assertIsInstance(pane["columns"], int)
                self.assertIsInstance(pane["rows"], int)


# ---------------------------------------------------------------------------
# surface.split + surface.close
# ---------------------------------------------------------------------------

class SurfaceSplitAndCloseTests(NamuTestCase):
    """Tests for surface.split and surface.close."""

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

    def test_surface_split_then_close(self):
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
        new_surface_id = split_result.get("surface_id") or split_result.get("id")
        if not new_surface_id:
            self.skipTest("surface.split did not return a surface_id")

        # Close the newly created surface
        try:
            self.client.call("surface.close", {
                "workspace_id": workspace_id,
                "surface_id": new_surface_id,
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.close not available via IPC")
            raise


# ---------------------------------------------------------------------------
# workspace.last
# ---------------------------------------------------------------------------

class WorkspaceLastTests(NamuTestCase):
    """Tests for workspace.last."""

    def _current_workspace_id(self):
        result = self.client.call("workspace.current")
        if isinstance(result, dict):
            return result.get("workspace_id") or result.get("id")
        return None

    def test_workspace_last_returns_to_previous_workspace(self):
        original_id = self._current_workspace_id()
        if not original_id:
            self.skipTest("Could not determine current workspace ID")

        # Create a new workspace and switch to it
        new_title = f"LastTest-{uuid.uuid4().hex[:6]}"
        try:
            self.client.workspace_create(title=new_title)
        except NamuError as e:
            self.skipTest(f"workspace.create not available: {e}")

        # Find and select the new workspace
        workspaces = self.client.workspace_list()
        new_ws = next((w for w in workspaces if w.get("title") == new_title), None)
        if not new_ws:
            self.skipTest("Newly created workspace not found in list")

        try:
            self.client.workspace_select(new_ws["id"])
        except NamuError as e:
            self.skipTest(f"workspace.select not available: {e}")

        # Call workspace.last — should return to original
        try:
            self.client.call("workspace.last")
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("workspace.last not available via IPC")
            raise

        restored_id = self._current_workspace_id()
        self.assertEqual(
            original_id,
            restored_id,
            "workspace.last did not return to the original workspace",
        )

        # Cleanup: delete the test workspace
        try:
            self.client.workspace_delete(new_ws["id"])
        except NamuError:
            pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
