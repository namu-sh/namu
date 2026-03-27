"""
namu.py — Test helper for Namu IPC socket (JSON-RPC 2.0 over Unix domain socket).

Usage:
    from namu import NamuClient

    client = NamuClient()  # Uses NAMU_SOCKET env var or default path
    result = client.call("workspace.list")
    client.notify("pane.send_keys", {"pane_id": "...", "keys": ["enter"]})
    client.close()
"""

import json
import os
import socket
import threading
import time
import uuid
from typing import Any, Optional


DEFAULT_SOCKET_PATH = os.environ.get(
    "NAMU_SOCKET",
    os.path.expanduser("~/Library/Application Support/Namu/namu.sock"),
)


class NamuError(Exception):
    """Raised when the server returns a JSON-RPC error response."""

    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
        self.data = data


class NamuConnectionError(Exception):
    """Raised when the socket connection fails."""


class NamuClient:
    """
    Synchronous JSON-RPC 2.0 client over a Unix domain socket.

    Each `call()` opens a fresh connection, sends the request, reads until the
    server closes the connection (or a newline-delimited response arrives), then
    closes the socket.  This matches Namu's one-request-per-connection model.
    """

    def __init__(
        self,
        socket_path: str = DEFAULT_SOCKET_PATH,
        timeout: float = 5.0,
    ):
        self.socket_path = socket_path
        self.timeout = timeout

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def call(self, method: str, params: Optional[dict] = None) -> Any:
        """Send a JSON-RPC request and return the result.

        Raises NamuError if the server returns an error response.
        Raises NamuConnectionError if the socket is not reachable.
        """
        request_id = str(uuid.uuid4())
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
        }
        if params:
            request["params"] = params

        raw = self._roundtrip(json.dumps(request))
        response = json.loads(raw)

        if "error" in response and response["error"] is not None:
            err = response["error"]
            raise NamuError(
                code=err.get("code", -1),
                message=err.get("message", "unknown error"),
                data=err.get("data"),
            )

        return response.get("result")

    def notify(self, method: str, params: Optional[dict] = None) -> None:
        """Send a JSON-RPC notification (fire-and-forget, no response expected)."""
        request = {
            "jsonrpc": "2.0",
            "method": method,
        }
        if params:
            request["params"] = params

        self._send_only(json.dumps(request))

    def close(self) -> None:
        """No-op: connections are closed after each call."""

    # ------------------------------------------------------------------
    # Convenience helpers
    # ------------------------------------------------------------------

    def workspace_list(self) -> list:
        result = self.call("workspace.list")
        return result if isinstance(result, list) else (result or {}).get("workspaces", [])

    def workspace_create(self, title: str = "New Workspace") -> dict:
        return self.call("workspace.create", {"title": title})

    def workspace_select(self, workspace_id: str) -> None:
        self.call("workspace.select", {"id": workspace_id})

    def workspace_rename(self, workspace_id: str, title: str) -> None:
        self.call("workspace.rename", {"id": workspace_id, "title": title})

    def workspace_delete(self, workspace_id: str) -> None:
        self.call("workspace.delete", {"id": workspace_id})

    def pane_split(self, pane_id: str, direction: str = "horizontal") -> dict:
        return self.call("pane.split", {"pane_id": pane_id, "direction": direction})

    def pane_close(self, pane_id: str) -> None:
        self.call("pane.close", {"pane_id": pane_id})

    def pane_focus(self, pane_id: str) -> None:
        self.call("pane.focus", {"pane_id": pane_id})

    def pane_send_keys(self, pane_id: str, keys: list) -> None:
        self.call("pane.send_keys", {"pane_id": pane_id, "keys": keys})

    def pane_send_text(self, pane_id: str, text: str) -> None:
        self.call("surface.send_text", {"pane_id": pane_id, "text": text})

    # ------------------------------------------------------------------
    # Internal socket helpers
    # ------------------------------------------------------------------

    def _connect(self) -> socket.socket:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            sock.connect(self.socket_path)
            return sock
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            raise NamuConnectionError(
                f"Cannot connect to Namu socket at {self.socket_path!r}: {e}"
            ) from e

    def _roundtrip(self, payload: str) -> str:
        sock = self._connect()
        try:
            sock.sendall((payload + "\n").encode())
            # Read until EOF or newline
            chunks = []
            while True:
                try:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    chunks.append(chunk)
                    # Stop on newline-delimited response
                    if b"\n" in chunk:
                        break
                except socket.timeout:
                    break
            return b"".join(chunks).decode().strip()
        finally:
            sock.close()

    def _send_only(self, payload: str) -> None:
        sock = self._connect()
        try:
            sock.sendall((payload + "\n").encode())
        finally:
            sock.close()


# ------------------------------------------------------------------
# Context manager support
# ------------------------------------------------------------------

class NamuSession:
    """Context manager wrapping NamuClient for use in `with` statements."""

    def __init__(self, **kwargs):
        self.client = NamuClient(**kwargs)

    def __enter__(self) -> NamuClient:
        return self.client

    def __exit__(self, *_):
        self.client.close()


# ------------------------------------------------------------------
# Test base class
# ------------------------------------------------------------------

import unittest


class NamuTestCase(unittest.TestCase):
    """Base class for Namu integration tests.

    Skips all tests if the socket is not reachable (i.e., Namu is not running).
    """

    client: NamuClient

    @classmethod
    def setUpClass(cls):
        cls.client = NamuClient()
        try:
            cls.client.call("workspace.list")
        except NamuConnectionError as e:
            raise unittest.SkipTest(f"Namu socket not available: {e}") from e

    @classmethod
    def tearDownClass(cls):
        cls.client.close()

    def assertSuccess(self, result: Any) -> Any:
        """Assert a result is not None (or is a valid empty response)."""
        # None is OK for void calls; just verify no exception was raised
        return result

    def get_any_pane_id(self) -> Optional[str]:
        """Return the first pane ID from the selected workspace, or None."""
        try:
            result = self.client.call("workspace.list")
            workspaces = result if isinstance(result, list) else []
            for ws in workspaces:
                panes = ws.get("panes", [])
                if panes:
                    return panes[0].get("id")
        except Exception:
            pass
        return None
