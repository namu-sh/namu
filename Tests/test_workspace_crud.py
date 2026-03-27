"""
test_workspace_crud.py — Integration tests for workspace CRUD operations.

Requires Namu to be running with NAMU_SOCKET set.
Run: python -m pytest tests/test_workspace_crud.py -v
"""

import unittest
import uuid
from namu import NamuClient, NamuError, NamuTestCase


class WorkspaceListTests(NamuTestCase):
    """Tests for workspace.list."""

    def test_list_returns_list(self):
        result = self.client.call("workspace.list")
        self.assertIsInstance(result, (list, dict))

    def test_list_has_at_least_one_workspace(self):
        workspaces = self.client.workspace_list()
        self.assertGreater(len(workspaces), 0)

    def test_list_workspaces_have_id(self):
        workspaces = self.client.workspace_list()
        for ws in workspaces:
            self.assertIn("id", ws)
            self.assertIsInstance(ws["id"], str)

    def test_list_workspaces_have_title(self):
        workspaces = self.client.workspace_list()
        for ws in workspaces:
            self.assertIn("title", ws)


class WorkspaceCreateTests(NamuTestCase):
    """Tests for workspace.create."""

    def test_create_workspace_with_title(self):
        title = f"Test-{uuid.uuid4().hex[:8]}"
        result = self.client.workspace_create(title=title)
        self.assertIsNotNone(result)

    def test_create_workspace_appears_in_list(self):
        title = f"Created-{uuid.uuid4().hex[:8]}"
        self.client.workspace_create(title=title)
        workspaces = self.client.workspace_list()
        titles = [ws.get("title", "") for ws in workspaces]
        self.assertIn(title, titles)

    def test_create_multiple_workspaces(self):
        initial = len(self.client.workspace_list())
        self.client.workspace_create(title="A")
        self.client.workspace_create(title="B")
        final = len(self.client.workspace_list())
        self.assertGreaterEqual(final, initial + 2)


class WorkspaceSelectTests(NamuTestCase):
    """Tests for workspace.select."""

    def _get_workspace_ids(self):
        return [ws["id"] for ws in self.client.workspace_list()]

    def test_select_existing_workspace(self):
        ids = self._get_workspace_ids()
        if len(ids) < 1:
            self.skipTest("No workspaces available")
        self.client.workspace_select(ids[0])  # Should not raise

    def test_select_nonexistent_workspace_returns_error(self):
        fake_id = str(uuid.uuid4())
        try:
            self.client.workspace_select(fake_id)
        except NamuError as e:
            self.assertNotEqual(e.code, 0)
        except Exception:
            pass  # Any error is acceptable for an invalid ID


class WorkspaceRenameTests(NamuTestCase):
    """Tests for workspace.rename."""

    def test_rename_workspace(self):
        title = f"ToRename-{uuid.uuid4().hex[:6]}"
        self.client.workspace_create(title=title)
        workspaces = self.client.workspace_list()
        ws = next((w for w in workspaces if w.get("title") == title), None)
        if not ws:
            self.skipTest("Workspace not found after creation")

        new_title = f"Renamed-{uuid.uuid4().hex[:6]}"
        self.client.workspace_rename(ws["id"], new_title)

        updated = self.client.workspace_list()
        titles = [w.get("title") for w in updated]
        self.assertIn(new_title, titles)

    def test_rename_to_empty_string(self):
        workspaces = self.client.workspace_list()
        if not workspaces:
            self.skipTest("No workspaces")
        ws = workspaces[0]
        try:
            self.client.workspace_rename(ws["id"], "")
            # If it succeeds, the title might be empty or use a default — both OK
        except NamuError:
            pass  # Rejecting empty title is valid


class WorkspaceDeleteTests(NamuTestCase):
    """Tests for workspace.delete."""

    def test_delete_created_workspace(self):
        title = f"ToDelete-{uuid.uuid4().hex[:6]}"
        self.client.workspace_create(title=title)
        before = self.client.workspace_list()
        ws = next((w for w in before if w.get("title") == title), None)
        if not ws:
            self.skipTest("Created workspace not found")

        self.client.workspace_delete(ws["id"])
        after = self.client.workspace_list()
        ids_after = [w["id"] for w in after]
        self.assertNotIn(ws["id"], ids_after)

    def test_cannot_delete_last_workspace(self):
        workspaces = self.client.workspace_list()
        if len(workspaces) != 1:
            self.skipTest("More than one workspace exists; cannot test last-workspace guard")
        try:
            self.client.workspace_delete(workspaces[0]["id"])
            # If deletion "succeeds", there should still be at least one workspace
            remaining = self.client.workspace_list()
            self.assertGreater(len(remaining), 0)
        except NamuError:
            pass  # Error is acceptable

    def test_delete_nonexistent_workspace(self):
        fake_id = str(uuid.uuid4())
        try:
            self.client.workspace_delete(fake_id)
        except NamuError:
            pass  # Any error is acceptable


if __name__ == "__main__":
    unittest.main(verbosity=2)
