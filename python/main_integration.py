"""
JARVIS Daemon -- IPC Integration Guide
======================================
This file shows the exact changes needed in jarvis/main.py (or wherever
your Jarvis class lives) to integrate the IPCServer.

Search for the TODO comments and apply the matching changes to your
existing main.py / Jarvis class.
"""

import asyncio
import logging

# -- TODO 1: import IPCServer at the top of your main.py ----------------------
from jarvis.ipc_server import IPCServer

logger = logging.getLogger("jarvis.main")


class Jarvis:
    """
    Example showing where to add IPC hooks in your existing Jarvis class.
    Only the relevant additions are shown; keep everything else as-is.
    """

    def __init__(self):
        # -- TODO 2: instantiate IPCServer -----------------------------------------
        self.ipc = IPCServer(on_text_message=self.handle_text_input)

        # ... your existing __init__ code ...

    # -- TODO 3: start IPC server inside your async startup method -----------------
    async def start(self):
        """Called once when the daemon starts."""
        await self.ipc.start()
        # ... your existing startup code (load models, etc.) ...

    # -- TODO 4: stop IPC server in your shutdown/cleanup method -------------------
    async def stop(self):
        await self.ipc.stop()
        # ... your existing teardown code ...

    # -- TODO 5: add this method if it doesn't exist -------------------------------
    async def handle_text_input(self, content: str) -> None:
        """
        Called when a UI client sends a text message via the IPC socket.
        Wire this into the same code path your CLI / voice loop uses.
        """
        logger.info(f"IPC text input: {content!r}")

        try:
            await self.ipc.set_state("processing")

            # -- Replace this block with your actual LLM call ----------------------
            # Streaming:
            #   async for chunk in self.llm.stream(content):
            #       await self.ipc.send_response_chunk(chunk, done=False)
            #   await self.ipc.send_response_chunk("", done=True)
            #
            # Non-streaming:
            #   response = await self.llm.query(content)
            #   await self.ipc.send_response_chunk(response, done=True)

            response = await self._query_llm(content)
            await self.ipc.send_response_chunk(response, done=True)

        except Exception as e:
            logger.error(f"Error processing text input: {e}", exc_info=True)
            await self.ipc.send_error(str(e))
        finally:
            await self.ipc.set_state("idle")

    # -- TODO 6: broadcast state changes from your existing voice loop -------------
    #
    #   On wake-word detection:
    #       await self.ipc.send_wake_word_detected()
    #       await self.ipc.set_state("listening")
    #
    #   Before TTS / speaking:
    #       await self.ipc.set_state("speaking")
    #
    #   After TTS finishes:
    #       await self.ipc.set_state("idle")
    #
    #   Before querying the LLM:
    #       await self.ipc.set_state("processing")

    async def _query_llm(self, content: str) -> str:
        """Stub -- replace with your real Ollama / LLM call."""
        raise NotImplementedError

    def listen_with_activation(self):
        asyncio.run(self._async_listen_loop())

    async def _async_listen_loop(self):
        await self.start()
        try:
            await asyncio.Event().wait()
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        finally:
            await self.stop()
