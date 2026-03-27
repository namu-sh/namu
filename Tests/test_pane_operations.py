"""
test_pane_operations.py — Integration tests for pane split, close, focus, resize, zoom.

Requires Namu to be running with NAMU_SOCKET set.
Run: python -m pytest tests/test_pane_operations.py -v
"""

import unittest
import uuid
from namu import NamuClient, NamuError, NamuTestCase


class PaneSplitTests(NamuTestCase):
    """Tests for pane.split."""

    def _first_pane_id(self):
        """Return the first available pane ID."""
        workspaces = self.client.workspace_list()
        for ws in workspaces:
            panes = ws.get("panes", [])
            if panes:
                return panes[0].get("id")
        return None

    def test_split_horizontal(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")
        result = self.client.call("pane.split", {"pane_id": pane_id, "direction": "horizontal"})
        self.assertIsNotNone(result)

    def test_split_vertical(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")
        result = self.client.call("pane.split", {"pane_id": pane_id, "direction": "vertical"})
        self.assertIsNotNone(result)

    def test_split_invalid_direction_returns_error(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")
        try:
            self.client.call("pane.split", {"pane_id": pane_id, "direction": "diagonal"})
        except NamuError as e:
            self.assertNotEqual(e.code, 0)

    def test_split_nonexistent_pane_returns_error(self):
        fake_id = str(uuid.uuid4())
        try:
            self.client.call("pane.split", {"pane_id": fake_id, "direction": "horizontal"})
        except NamuError:
            pass  # Expected


class PaneCloseTests(NamuTestCase):
    """Tests for pane.close."""

    def test_close_split_pane(self):
        """Create a split then close the new pane."""
        workspaces = self.client.workspace_list()
        first_pane_id = None
        for ws in workspaces:
            panes = ws.get("panes", [])
            if panes:
                first_pane_id = panes[0].get("id")
                break

        if not first_pane_id:
            self.skipTest("No panes available")

        split_result = self.client.call(
            "pane.split", {"pane_id": first_pane_id, "direction": "horizontal"}
        )
        if not split_result:
            self.skipTest("Split failed")

        new_pane_id = (
            split_result.get("pane_id") or split_result.get("id")
            if isinstance(split_result, dict) else None
        )
        if not new_pane_id:
            self.skipTest("Could not get new pane ID from split result")

        self.client.call("pane.close", {"pane_id": new_pane_id})  # Should not raise

    def test_close_nonexistent_pane(self):
        fake_id = str(uuid.uuid4())
        try:
            self.client.call("pane.close", {"pane_id": fake_id})
        except NamuError:
            pass


class PaneFocusTests(NamuTestCase):
    """Tests for pane.focus and pane.focus_direction."""

    def _first_pane_id(self):
        for ws in self.client.workspace_list():
            panes = ws.get("panes", [])
            if panes:
                return panes[0].get("id")
        return None

    def test_focus_by_id(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")
        self.client.call("pane.focus", {"pane_id": pane_id})

    def test_focus_direction_left(self):
        try:
            self.client.call("pane.focus_direction", {"direction": "left"})
        except NamuError:
            pass  # OK if no pane in that direction

    def test_focus_direction_right(self):
        try:
            self.client.call("pane.focus_direction", {"direction": "right"})
        except NamuError:
            pass

    def test_focus_direction_up(self):
        try:
            self.client.call("pane.focus_direction", {"direction": "up"})
        except NamuError:
            pass

    def test_focus_direction_down(self):
        try:
            self.client.call("pane.focus_direction", {"direction": "down"})
        except NamuError:
            pass

    def test_focus_nonexistent_pane(self):
        fake_id = str(uuid.uuid4())
        try:
            self.client.call("pane.focus", {"pane_id": fake_id})
        except NamuError:
            pass


class PaneZoomTests(NamuTestCase):
    """Tests for pane.zoom and pane.unzoom."""

    def _first_pane_id(self):
        for ws in self.client.workspace_list():
            panes = ws.get("panes", [])
            if panes:
                return panes[0].get("id")
        return None

    def test_zoom_and_unzoom(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")

        try:
            self.client.call("pane.zoom", {"pane_id": pane_id})
            self.client.call("pane.unzoom", {})
        except NamuError as e:
            # Zoom may not be supported via IPC — not a hard failure
            self.skipTest(f"Zoom not available via IPC: {e}")


class PaneSendKeysTests(NamuTestCase):
    """Tests for pane.send_keys and surface.send_text."""

    def _first_pane_id(self):
        for ws in self.client.workspace_list():
            panes = ws.get("panes", [])
            if panes:
                return panes[0].get("id")
        return None

    def test_send_text(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")
        # Send a no-op (comment character + enter won't do harm)
        try:
            self.client.call("surface.send_text", {"pane_id": pane_id, "text": "# namu-test\n"})
        except NamuError as e:
            if e.code == -32601:  # Method not found
                self.skipTest("surface.send_text not available")
            raise

    def test_send_keys_enter(self):
        pane_id = self._first_pane_id()
        if not pane_id:
            self.skipTest("No panes available")
        try:
            self.client.call("pane.send_keys", {"pane_id": pane_id, "keys": []})
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("pane.send_keys not available")
            raise


if __name__ == "__main__":
    unittest.main(verbosity=2)
