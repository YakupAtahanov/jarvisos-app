"""
JARVIS IPC Server
=================
Bidirectional Unix socket server for communicating with UI clients.
Protocol: Newline-delimited JSON (JSON-L)

Client -> Daemon:
  {"type": "message", "content": "turn off wifi"}
  {"type": "start_listening"}
  {"type": "stop_listening"}
  {"type": "ping"}

Daemon -> All Clients:
  {"type": "state", "state": "idle|listening|processing|speaking|offline"}
  {"type": "response", "content": "...", "done": false}   <- streaming chunk
  {"type": "response", "content": "", "done": true}       <- stream finished
  {"type": "wake_word_detected"}
  {"type": "error", "message": "..."}
  {"type": "pong"}
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Callable, Optional, Set

logger = logging.getLogger("jarvis.ipc")

SOCKET_PATH = "/tmp/jarvis.sock"


class IPCServer:
    """
    Async Unix socket IPC server.

    Integrate into the JARVIS daemon like this:

        ipc = IPCServer(on_text_message=self.handle_text_input)
        await ipc.start()

        # Broadcast state changes from anywhere in the daemon:
        await ipc.set_state("processing")
        await ipc.send_response_chunk("Here is your answer...", done=False)
        await ipc.send_response_chunk("", done=True)
    """

    def __init__(self, on_text_message: Optional[Callable] = None):
        """
        Args:
            on_text_message: async callback(content: str) invoked when a
                             client sends {"type": "message", "content": "..."}.
        """
        self._on_text_message = on_text_message
        self._server: Optional[asyncio.AbstractServer] = None
        self._clients: Set[asyncio.StreamWriter] = set()
        self._current_state = "idle"

    async def start(self) -> None:
        path = Path(SOCKET_PATH)
        if path.exists():
            path.unlink()

        self._server = await asyncio.start_unix_server(
            self._handle_client, path=str(path)
        )
        os.chmod(SOCKET_PATH, 0o660)
        logger.info(f"IPC server listening on {SOCKET_PATH}")

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()

        for writer in list(self._clients):
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
        self._clients.clear()

        path = Path(SOCKET_PATH)
        if path.exists():
            path.unlink()

        logger.info("IPC server stopped")

    async def set_state(self, state: str) -> None:
        self._current_state = state
        await self._broadcast({"type": "state", "state": state})

    async def send_response_chunk(self, content: str, done: bool = False) -> None:
        await self._broadcast({"type": "response", "content": content, "done": done})

    async def send_error(self, message: str) -> None:
        await self._broadcast({"type": "error", "message": message})

    async def send_wake_word_detected(self) -> None:
        await self._broadcast({"type": "wake_word_detected"})

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        addr = writer.get_extra_info("peername", "unknown")
        logger.info(f"IPC client connected: {addr}")
        self._clients.add(writer)

        # Send current state to newly connected client immediately
        try:
            await self._write(writer, {"type": "state", "state": self._current_state})
        except Exception:
            pass

        try:
            while True:
                try:
                    line = await asyncio.wait_for(reader.readline(), timeout=60.0)
                except asyncio.TimeoutError:
                    # Send a keep-alive ping
                    try:
                        await self._write(writer, {"type": "ping"})
                    except Exception:
                        break
                    continue

                if not line:
                    break  # Client disconnected

                line = line.strip()
                if not line:
                    continue

                try:
                    msg = json.loads(line.decode("utf-8"))
                    await self._process_message(msg, writer)
                except json.JSONDecodeError as e:
                    logger.warning(f"IPC invalid JSON from client: {e}")

        except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
            pass
        except Exception as e:
            logger.error(f"IPC client error: {e}", exc_info=True)
        finally:
            self._clients.discard(writer)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
            logger.info(f"IPC client disconnected: {addr}")

    async def _process_message(
        self,
        msg: dict,
        writer: asyncio.StreamWriter,
    ) -> None:
        msg_type = msg.get("type")

        if msg_type == "message":
            content = msg.get("content", "").strip()
            if content and self._on_text_message:
                await self._on_text_message(content)

        elif msg_type == "start_listening":
            await self.set_state("listening")

        elif msg_type == "stop_listening":
            await self.set_state("idle")

        elif msg_type == "ping":
            try:
                await self._write(writer, {"type": "pong"})
            except Exception:
                pass

        else:
            logger.debug(f"IPC unknown message type: {msg_type}")

    async def _broadcast(self, message: dict) -> None:
        """Send a message to every connected client."""
        if not self._clients:
            return

        data = (json.dumps(message) + "\n").encode("utf-8")
        dead: Set[asyncio.StreamWriter] = set()

        for writer in list(self._clients):
            try:
                writer.write(data)
                await writer.drain()
            except Exception:
                dead.add(writer)

        self._clients -= dead

    @staticmethod
    async def _write(writer: asyncio.StreamWriter, message: dict) -> None:
        data = (json.dumps(message) + "\n").encode("utf-8")
        writer.write(data)
        await writer.drain()
