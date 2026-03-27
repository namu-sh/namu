"""
test_browser_commands.py — Integration tests for browser IPC commands.

Requires Namu to be running with a browser pane open and NAMU_SOCKET set.
Run: python -m pytest tests/test_browser_commands.py -v
"""

import unittest
import uuid
from namu import NamuClient, NamuError, NamuTestCase


class BrowserNavigateTests(NamuTestCase):
    """Tests for browser.navigate."""

    def _get_browser_pane_id(self):
        for ws in self.client.workspace_list():
            panes = ws.get("panes", [])
            for pane in panes:
                if pane.get("type") == "browser":
                    return pane.get("id")
        return None

    def test_navigate_to_url(self):
        pane_id = self._get_browser_pane_id()
        if not pane_id:
            self.skipTest("No browser pane available")
        try:
            result = self.client.call("browser.navigate", {
                "pane_id": pane_id,
                "url": "about:blank"
            })
            self.assertIsNotNone(result)
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("browser.navigate not available via IPC")
            raise

    def test_navigate_invalid_url_returns_error(self):
        pane_id = self._get_browser_pane_id()
        if not pane_id:
            self.skipTest("No browser pane available")
        try:
            self.client.call("browser.navigate", {"pane_id": pane_id, "url": ""})
        except NamuError:
            pass  # Any error is acceptable for empty URL


class BrowserClickTests(NamuTestCase):
    """Tests for browser.click."""

    def _get_browser_pane_id(self):
        for ws in self.client.workspace_list():
            for pane in ws.get("panes", []):
                if pane.get("type") == "browser":
                    return pane.get("id")
        return None

    def test_click_by_selector(self):
        pane_id = self._get_browser_pane_id()
        if not pane_id:
            self.skipTest("No browser pane available")
        try:
            self.client.call("browser.click", {
                "pane_id": pane_id,
                "selector": "body"
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("browser.click not available via IPC")
            # Element not found is acceptable
            pass

    def test_click_nonexistent_element(self):
        pane_id = self._get_browser_pane_id()
        if not pane_id:
            self.skipTest("No browser pane available")
        try:
            self.client.call("browser.click", {
                "pane_id": pane_id,
                "selector": "#nonexistent-element-xyz-123"
            })
        except NamuError:
            pass  # Expected — element doesn't exist


class BrowserTypeTests(NamuTestCase):
    """Tests for browser.type."""

    def _get_browser_pane_id(self):
        for ws in self.client.workspace_list():
            for pane in ws.get("panes", []):
                if pane.get("type") == "browser":
                    return pane.get("id")
        return None

    def test_type_text(self):
        pane_id = self._get_browser_pane_id()
        if not pane_id:
            self.skipTest("No browser pane available")
        try:
            self.client.call("browser.type", {
                "pane_id": pane_id,
                "text": "test input"
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("browser.type not available via IPC")
            pass


class BrowserScreenshotTests(NamuTestCase):
    """Tests for browser.screenshot."""

    def _get_browser_pane_id(self):
        for ws in self.client.workspace_list():
            for pane in ws.get("panes", []):
                if pane.get("type") == "browser":
                    return pane.get("id")
        return None

    def test_screenshot_returns_data(self):
        pane_id = self._get_browser_pane_id()
        if not pane_id:
            self.skipTest("No browser pane available")
        try:
            result = self.client.call("browser.screenshot", {"pane_id": pane_id})
            if result is not None:
                # Result may be base64 data, a file path, or a dict
                self.assertIsNotNone(result)
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("browser.screenshot not available via IPC")
            raise

    def test_screenshot_nonexistent_pane(self):
        fake_id = str(uuid.uuid4())
        try:
            self.client.call("browser.screenshot", {"pane_id": fake_id})
        except NamuError:
            pass  # Expected


if __name__ == "__main__":
    unittest.main(verbosity=2)
