#!/usr/bin/env python3
"""
test_shell_env.py -- E2E socket tests for shell environment and terminal I/O.

Requires Namu to be running. Run with:
    python -m pytest Tests/test_shell_env.py -v
  or:
    python -m unittest Tests/test_shell_env -v

The NAMU_SOCKET env var overrides the default socket path.
All tests are skipped automatically when Namu is not running.
"""

import re
import time
import unittest

from namu import NamuClient, NamuError, NamuTestCase


class _SurfaceContextMixin:
    """Shared helper to get (workspace_id, surface_id) for the current surface."""

    def _get_surface_context(self):
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


# ---------------------------------------------------------------------------
# Shell I/O via socket
# ---------------------------------------------------------------------------

class ShellIOTests(_SurfaceContextMixin, NamuTestCase):
    """Test terminal I/O through the IPC socket."""

    def test_surface_send_and_read(self):
        """Send echo command, read output, verify it appears."""
        workspace_id, surface_id = self._get_surface_context()

        # Send echo command with a unique marker.
        try:
            self.client.call("surface.send_text", {
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "text": "echo NAMU_TEST_MARKER_12345\n",
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.send_text not available via IPC")
            raise

        time.sleep(1)

        # Read terminal text.
        result = self.client.call("surface.read_text", {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
        })
        text = result.get("text", "")
        self.assertIn("NAMU_TEST_MARKER_12345", text,
                       "Echo output should appear in terminal text")


# ---------------------------------------------------------------------------
# Shell environment variables
# ---------------------------------------------------------------------------

class ShellEnvVarTests(_SurfaceContextMixin, NamuTestCase):
    """Test that NAMU_* environment variables are set in the shell."""

    def test_pane_env_var_is_set(self):
        """Verify NAMU_PANE_ID env var is set to a UUID in the shell."""
        workspace_id, surface_id = self._get_surface_context()

        try:
            self.client.call("surface.send_text", {
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "text": "echo PANE_CHECK:$NAMU_PANE_ID:END\n",
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.send_text not available via IPC")
            raise

        time.sleep(1)

        result = self.client.call("surface.read_text", {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
        })
        text = result.get("text", "")
        self.assertRegex(
            text,
            r"PANE_CHECK:[0-9a-fA-F-]+:END",
            "NAMU_PANE_ID should be set to a UUID in the shell environment",
        )

    def test_workspace_env_var_is_set(self):
        """Verify NAMU_WORKSPACE_ID env var is set to a UUID in the shell."""
        workspace_id, surface_id = self._get_surface_context()

        try:
            self.client.call("surface.send_text", {
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "text": "echo WS_CHECK:$NAMU_WORKSPACE_ID:END\n",
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("surface.send_text not available via IPC")
            raise

        time.sleep(1)

        result = self.client.call("surface.read_text", {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
        })
        text = result.get("text", "")
        self.assertRegex(
            text,
            r"WS_CHECK:[0-9a-fA-F-]+:END",
            "NAMU_WORKSPACE_ID should be set to a UUID in the shell environment",
        )


# ---------------------------------------------------------------------------
# Pane count after split
# ---------------------------------------------------------------------------

class PaneCountTests(_SurfaceContextMixin, NamuTestCase):
    """Test that splits correctly change pane count."""

    def test_split_changes_pane_count(self):
        """Split creates a new pane visible in pane.list."""
        workspace_id, surface_id = self._get_surface_context()

        # Count panes before split.
        before = self.client.call("pane.list", {"workspace_id": workspace_id})
        count_before = len(before.get("panes", []))

        # Split.
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

        time.sleep(1)

        # Count panes after split.
        after = self.client.call("pane.list", {"workspace_id": workspace_id})
        count_after = len(after.get("panes", []))

        self.assertEqual(
            count_after, count_before + 1,
            f"Split should add one pane (was {count_before}, now {count_after})",
        )

        # Cleanup: close the new pane.
        new_surface = (split_result or {}).get("surface_id") or (split_result or {}).get("id")
        if new_surface:
            try:
                self.client.call("surface.close", {
                    "workspace_id": workspace_id,
                    "surface_id": new_surface,
                })
            except NamuError:
                pass


# ---------------------------------------------------------------------------
# Workspace create/delete round-trip
# ---------------------------------------------------------------------------

class WorkspaceRoundTripTests(NamuTestCase):
    """Test workspace create + delete round-trip via IPC."""

    def test_workspace_create_and_delete(self):
        """Create a workspace, verify it appears in list, then delete it."""
        # Get initial count.
        before = self.client.workspace_list()
        count_before = len(before)

        # Create.
        import uuid
        title = f"RoundTrip-{uuid.uuid4().hex[:6]}"
        try:
            new_ws = self.client.workspace_create(title=title)
        except NamuError as e:
            self.skipTest(f"workspace.create not available: {e}")
            return

        # Verify it appears in list.
        after = self.client.workspace_list()
        count_after = len(after)
        self.assertEqual(
            count_after, count_before + 1,
            f"workspace.create should add one workspace (was {count_before}, now {count_after})",
        )

        # Find the new workspace.
        new_id = (new_ws or {}).get("id") or (new_ws or {}).get("workspace_id")
        found = any(
            (w.get("id") or w.get("workspace_id")) == new_id for w in after
        )
        self.assertTrue(found, "Newly created workspace should appear in workspace.list")

        # Delete.
        if new_id:
            try:
                self.client.workspace_delete(new_id)
            except NamuError:
                pass

            # Verify count returned to original.
            final = self.client.workspace_list()
            self.assertEqual(
                len(final), count_before,
                "workspace.delete should remove the workspace",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
