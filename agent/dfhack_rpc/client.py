"""
Minimal, synchronous DFHack RPC client.

Speaks DFHack's remote protocol over a TCP socket (default 127.0.0.1:5000).
This module is deliberately small and read-only-oriented: the only DFHack
primitive it exposes is RunCommand, which we drive exclusively with a
fixed, audited set of read-only Lua scripts (see ../scripts/ and brewery.py).

Wire protocol (after the plaintext handshake):
  - Every message: 8-byte header = int16 id (LE, signed) + 2 pad bytes
    + int32 size (LE), followed by `size` bytes of protobuf payload.
  - Reserved method ids: BindMethod = 0, RunCommand = 1.
  - Reply ids: RESULT = -1, FAIL = -2, TEXT = -3, QUIT = -4.
    For a FAIL reply there is no body; the "size" field carries the
    DFHack command-result code instead.
"""

import os
import socket
import struct

# Generated protobuf bindings live alongside this file.
from . import CoreProtocol_pb2 as core

# Reserved / special ids
_BIND_METHOD = 0
_RUN_COMMAND = 1

RPC_REPLY_RESULT = -1
RPC_REPLY_FAIL = -2
RPC_REPLY_TEXT = -3
RPC_REQUEST_QUIT = -4

_HANDSHAKE_MAGIC_REQ = b"DFHack?\n"
_HANDSHAKE_MAGIC_REP = b"DFHack!\n"
_PROTOCOL_VERSION = 1

# 8-byte header: signed int16 id, 2 pad bytes, signed int32 size.
_HEADER = struct.Struct("<hxxi")

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = int(os.environ.get("DFHACK_PORT", "5000"))


class DFHackError(RuntimeError):
    """Raised when the RPC connection or a remote call fails."""


class DFHackClient:
    """A blocking DFHack RPC client. Use as a context manager."""

    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT,
                 timeout: float = 5.0):
        # Hard guard: this client only ever talks to the local loopback
        # interface. Refuse anything else so we can never reach off-box.
        if host not in ("127.0.0.1", "localhost", "::1"):
            raise DFHackError(
                f"refusing non-loopback host {host!r}; this client is "
                "localhost-only by design")
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._bound: dict[str, int] = {}

    # -- connection lifecycle -------------------------------------------------

    def __enter__(self) -> "DFHackClient":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def connect(self) -> None:
        try:
            self._sock = socket.create_connection(
                (self.host, self.port), timeout=self.timeout)
        except OSError as e:
            raise DFHackError(
                f"could not connect to DFHack at {self.host}:{self.port} "
                f"({e}). Is Dwarf Fortress running with DFHack?") from e

        self._sock.sendall(
            _HANDSHAKE_MAGIC_REQ + struct.pack("<i", _PROTOCOL_VERSION))
        reply = self._recv_exactly(12)
        if reply[:8] != _HANDSHAKE_MAGIC_REP:
            self.close()
            raise DFHackError(f"unexpected handshake reply: {reply!r}")

    def close(self) -> None:
        if self._sock is not None:
            try:
                # Politely tell the server we're done.
                self._send(RPC_REQUEST_QUIT, b"")
            except OSError:
                pass
            try:
                self._sock.close()
            finally:
                self._sock = None

    # -- low-level framing ----------------------------------------------------

    def _recv_exactly(self, n: int) -> bytes:
        assert self._sock is not None
        buf = bytearray()
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise DFHackError("connection closed by DFHack mid-message")
            buf.extend(chunk)
        return bytes(buf)

    def _send(self, msg_id: int, payload: bytes) -> None:
        assert self._sock is not None
        self._sock.sendall(_HEADER.pack(msg_id, len(payload)) + payload)

    def _read_header(self) -> tuple[int, int]:
        msg_id, size = _HEADER.unpack(self._recv_exactly(8))
        return msg_id, size

    # -- RPC ------------------------------------------------------------------

    def bind_method(self, method: str, input_msg: str, output_msg: str,
                    plugin: str = "") -> int:
        """Resolve (and cache) the numeric id for a remote method by name."""
        if method in self._bound:
            return self._bound[method]
        req = core.CoreBindRequest(
            method=method, input_msg=input_msg, output_msg=output_msg,
            plugin=plugin)
        body, _text = self._call(_BIND_METHOD, req.SerializeToString())
        reply = core.CoreBindReply()
        reply.ParseFromString(body)
        self._bound[method] = reply.assigned_id
        return reply.assigned_id

    def _call(self, method_id: int, payload: bytes):
        """Send a request and drain the reply stream.

        Returns (result_payload_bytes, captured_text). Raises on FAIL,
        attaching any text DFHack emitted before failing.
        """
        self._send(method_id, payload)
        # Accumulate text fragments as raw bytes and decode only once, at the
        # end. DFHack emits text in DF's native CP437 encoding and splits long
        # output into fixed-size fragments; a fragment whose bytes aren't valid
        # UTF-8 comes back from protobuf as bytes rather than str. We collect
        # raw bytes and decode the whole buffer as CP437 (which maps all 256
        # byte values, so special glyphs in names survive intact).
        text_parts: list[bytes] = []
        while True:
            msg_id, size = self._read_header()
            if msg_id == RPC_REPLY_FAIL:
                # No body; `size` is the command-result code.
                detail = b"".join(text_parts).decode("cp437", "replace").strip()
                msg = f"DFHack RPC call failed (code {size})"
                if detail:
                    msg += f": {detail}"
                raise DFHackError(msg)
            if msg_id == RPC_REPLY_TEXT:
                note = core.CoreTextNotification()
                note.ParseFromString(self._recv_exactly(size))
                for f in note.fragments:
                    t = f.text
                    text_parts.append(t if isinstance(t, bytes)
                                      else t.encode("utf-8"))
                continue
            if msg_id == RPC_REPLY_RESULT:
                body = self._recv_exactly(size) if size > 0 else b""
                return body, b"".join(text_parts).decode("cp437", "replace")
            # Any other id: read and ignore its body to stay in sync.
            if size > 0:
                self._recv_exactly(size)

    def run_command(self, command: str, arguments: list[str] | None = None) -> str:
        """Run a DFHack console command and return its captured text output.

        NOTE: RunCommand can execute *any* DFHack command, including
        state-changing ones. Higher layers in this project must only ever
        pass vetted read-only commands. This transport does not police the
        command string itself.
        """
        rid = self.bind_method(
            "RunCommand", "dfproto.CoreRunCommandRequest", "dfproto.EmptyMessage")
        req = core.CoreRunCommandRequest(
            command=command, arguments=list(arguments or []))
        _body, text = self._call(rid, req.SerializeToString())
        return text
