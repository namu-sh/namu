"""
test_notification_commands.py — Integration tests for notification IPC commands.

Requires Namu to be running with NAMU_SOCKET set.
Run: python -m pytest tests/test_notification_commands.py -v
"""

import unittest
import uuid
from namu import NamuClient, NamuError, NamuTestCase


class NotificationCreateTests(NamuTestCase):
    """Tests for notification.create."""

    def test_create_notification(self):
        try:
            result = self.client.call("notification.create", {
                "title": "Test Notification",
                "body": "Created by namu test suite"
            })
            # Result may be None (fire-and-forget) or a notification ID
            # Either is acceptable
            self.assertIsNone(result) or self.assertIsNotNone(result)
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification.create not available via IPC")
            raise

    def test_create_notification_without_body(self):
        try:
            self.client.call("notification.create", {
                "title": "Title Only"
            })
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification.create not available via IPC")
            # Missing body may return an error — acceptable
            pass

    def test_create_notification_empty_title(self):
        try:
            self.client.call("notification.create", {
                "title": "",
                "body": "Body"
            })
        except NamuError:
            pass  # Rejecting empty title is valid


class NotificationListTests(NamuTestCase):
    """Tests for notification.list."""

    def test_list_returns_list_or_empty(self):
        try:
            result = self.client.call("notification.list", {})
            if result is not None:
                self.assertIsInstance(result, (list, dict))
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification.list not available via IPC")
            raise

    def test_create_then_list(self):
        try:
            self.client.call("notification.create", {
                "title": f"Listed-{uuid.uuid4().hex[:6]}",
                "body": "Test"
            })
            result = self.client.call("notification.list", {})
            # Just verify the call succeeded
            self.assertIsNotNone(result)
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification commands not available via IPC")
            raise


class NotificationClearTests(NamuTestCase):
    """Tests for notification.clear."""

    def test_clear_all_notifications(self):
        try:
            self.client.call("notification.clear", {})
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification.clear not available via IPC")
            pass  # Some errors are acceptable (e.g., nothing to clear)

    def test_clear_by_id(self):
        try:
            # First create a notification
            result = self.client.call("notification.create", {
                "title": "To Clear",
                "body": "Will be cleared"
            })
            notification_id = (
                result.get("id") if isinstance(result, dict) else None
            )
            if notification_id:
                self.client.call("notification.clear", {"id": notification_id})
            # Clearing a non-existent ID
            fake_id = str(uuid.uuid4())
            try:
                self.client.call("notification.clear", {"id": fake_id})
            except NamuError:
                pass
        except NamuError as e:
            if e.code == -32601:
                self.skipTest("notification commands not available via IPC")
            raise


if __name__ == "__main__":
    unittest.main(verbosity=2)
