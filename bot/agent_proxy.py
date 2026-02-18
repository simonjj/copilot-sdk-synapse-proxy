"""
agent_proxy.py — Matrix bot that brokers messages to GitHub Copilot via the SDK.

One bot user per machine (pre-registered). Each working directory gets its own
Matrix room. Persists Copilot session IDs so restarting resumes the prior conversation.
"""

import asyncio
import json
import logging
import os
import sys
from pathlib import Path

from nio import (
    AsyncClient,
    InviteMemberEvent,
    LoginResponse,
    MatrixRoom,
    RoomMessageText,
    RoomCreateResponse,
)

from copilot import CopilotClient
from copilot.generated.session_events import SessionEventType

from config import BotConfig

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("agent-proxy")


# ---------------------------------------------------------------------------
# Session persistence helpers
# ---------------------------------------------------------------------------

def _session_file(config: BotConfig) -> Path:
    """Path to the JSON file that stores the Copilot session ID for this CWD."""
    dir_slug = Path(config.work_dir).name
    return Path(config.store_path) / f"copilot_session_{dir_slug}.json"


def load_saved_session(config: BotConfig) -> str | None:
    path = _session_file(config)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        sid = data.get("session_id")
        if sid:
            logger.info("Found saved session: %s", sid)
        return sid
    except Exception as e:
        logger.warning("Could not read saved session: %s", e)
        return None


def save_session(config: BotConfig, session_id: str):
    path = _session_file(config)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"session_id": session_id}))
    logger.info("Saved session %s to %s", session_id, path)


class CopilotAgent:
    """Manages a Copilot SDK session for one working directory."""

    def __init__(self, config: BotConfig):
        self.config = config
        self.copilot_client: CopilotClient | None = None
        self.session = None

    async def start(self):
        """Initialize the Copilot SDK client, resuming a prior session if available."""
        logger.info("Starting Copilot SDK client for %s...", self.config.work_dir)

        client_opts = {"cwd": self.config.work_dir}
        if self.config.copilot_cli_url:
            logger.info("Connecting to external Copilot CLI at %s", self.config.copilot_cli_url)
            client_opts["cli_url"] = self.config.copilot_cli_url

        self.copilot_client = CopilotClient(client_opts)
        await self.copilot_client.start()

        session_cfg = {
            "model": self.config.copilot_model,
            "streaming": True,
            "systemMessage": {
                "content": (
                    f"You are a helpful coding assistant. "
                    f"The user is working in directory: {self.config.work_dir}. "
                    f"Provide concise, actionable answers. "
                    f"When suggesting code changes, show diffs or complete file snippets. "
                    f"When asked to run commands, show the command and expected output."
                ),
            },
        }

        # Try resuming a prior session
        saved_id = load_saved_session(self.config)
        resumed = False
        if saved_id:
            try:
                session_cfg["session_id"] = saved_id
                self.session = await self.copilot_client.create_session(session_cfg)
                logger.info("Resumed prior Copilot session %s", saved_id)
                resumed = True
            except Exception as e:
                logger.warning("Could not resume session %s: %s — starting fresh", saved_id, e)
                session_cfg.pop("session_id", None)

        if not resumed:
            self.session = await self.copilot_client.create_session(session_cfg)
            logger.info("Created new Copilot session (model: %s)", self.config.copilot_model)

        # Persist session ID for next time
        if hasattr(self.session, "session_id") and self.session.session_id:
            save_session(self.config, self.session.session_id)

        self.resumed = resumed

    async def send(self, prompt: str, on_delta=None) -> str:
        """Send a message to Copilot. Event-driven — no timeout.

        Args:
            prompt: The user message.
            on_delta: Optional async callback(text) called with each streamed chunk.
        """
        if not self.session:
            return "❌ Copilot session not initialized"

        collected = []
        done_event = asyncio.Event()
        error_holder = [None]

        def handle_event(event):
            if event.type == SessionEventType.ASSISTANT_MESSAGE_DELTA:
                chunk = event.data.delta_content
                if chunk:
                    collected.append(chunk)
                    if on_delta:
                        asyncio.get_event_loop().create_task(on_delta(chunk))
            elif event.type == SessionEventType.SESSION_IDLE:
                done_event.set()
            elif event.type == SessionEventType.SESSION_ERROR:
                msg = getattr(event.data, 'message', str(event.data))
                error_holder[0] = msg
                done_event.set()

        unsubscribe = self.session.on(handle_event)

        try:
            logger.info("Sending to Copilot: %s", prompt[:100])
            await self.session.send({"prompt": prompt})
            # Wait indefinitely for session.idle — no timeout
            await done_event.wait()

            if error_holder[0]:
                partial = "".join(collected).strip()
                if partial:
                    return f"{partial}\n\n⚠️ *Error: {error_holder[0]}*"
                return f"❌ Copilot error: {error_holder[0]}"

            response = "".join(collected)
            logger.info("Copilot responded: %d chars", len(response))
            return response if response.strip() else "(empty response)"
        except Exception as e:
            logger.exception("Copilot SDK error")
            partial = "".join(collected).strip()
            if partial:
                return f"{partial}\n\n⚠️ *(error: {e})*"
            return f"❌ Copilot error: {e}"
        finally:
            unsubscribe()

    async def stop(self):
        if self.copilot_client:
            await self.copilot_client.stop()


class AgentProxyBot:
    """Matrix bot that proxies messages to Copilot via the SDK."""

    def __init__(self, config: BotConfig):
        self.config = config
        self.matrix_client: AsyncClient | None = None
        self.copilot_agent: CopilotAgent | None = None
        self.room_id: str | None = None
        self._startup_sync_done = False

    async def start(self):
        """Login (pre-registered user), init Copilot session, ensure room, listen."""
        cfg = self.config
        Path(cfg.store_path).mkdir(parents=True, exist_ok=True)

        # Login to Matrix (user must be pre-registered)
        self.matrix_client = AsyncClient(
            cfg.homeserver_url,
            cfg.bot_user_id,
            store_path=cfg.store_path,
        )
        resp = await self.matrix_client.login(cfg.bot_password, device_name=cfg.bot_username)
        if not isinstance(resp, LoginResponse):
            logger.error("Login failed: %s", resp)
            logger.error("Is user %s registered? Register from LAN first.", cfg.bot_user_id)
            sys.exit(1)
        logger.info("Logged in as %s (device: %s)", cfg.bot_user_id, resp.device_id)

        await self.matrix_client.set_displayname(cfg.bot_display_name)

        # Initialize Copilot SDK session
        self.copilot_agent = CopilotAgent(cfg)
        await self.copilot_agent.start()

        # Ensure DM room
        await self._ensure_room()

        # Register callbacks
        self.matrix_client.add_event_callback(self._on_message, RoomMessageText)
        self.matrix_client.add_event_callback(self._on_invite, InviteMemberEvent)

        # Initial sync
        logger.info("Performing initial sync...")
        await self.matrix_client.sync(timeout=10000, full_state=True)
        self._startup_sync_done = True
        logger.info("Bot ready. Listening in room %s", self.room_id)

        await self._send(
            f"🤖 **{cfg.bot_display_name}** online.\n"
            f"📁 Working directory: `{cfg.work_dir}`\n"
            f"🧠 Model: `{cfg.copilot_model}`\n"
            f"{'🔄 Resumed prior session.' if self.copilot_agent.resumed else '🆕 New session.'}\n\n"
            f"Send me a message and I'll forward it to GitHub Copilot."
        )

        # Sync forever
        await self.matrix_client.sync_forever(timeout=30000, full_state=True)

    async def _ensure_room(self):
        """Create or find existing room for this working directory."""
        cfg = self.config
        await self.matrix_client.sync(timeout=10000, full_state=True)

        # Look for existing room matching this directory
        for room_id, room in self.matrix_client.rooms.items():
            if room.name and cfg.room_name == room.name:
                self.room_id = room_id
                logger.info("Found existing room: %s (%s)", room.name, room_id)
                return

        resp = await self.matrix_client.room_create(
            name=cfg.room_name,
            topic=f"Copilot agent for {cfg.work_dir}",
            invite=[cfg.admin_user],
            is_direct=False,
        )
        if isinstance(resp, RoomCreateResponse):
            self.room_id = resp.room_id
            logger.info("Created room '%s' (%s), invited %s", cfg.room_name, resp.room_id, cfg.admin_user)
        else:
            logger.error("Failed to create room: %s", resp)
            sys.exit(1)

    async def _on_invite(self, room: MatrixRoom, event: InviteMemberEvent):
        if event.state_key == self.config.bot_user_id:
            await self.matrix_client.join(room.room_id)
            logger.info("Accepted invite to %s", room.room_id)

    async def _on_message(self, room: MatrixRoom, event: RoomMessageText):
        if event.sender == self.config.bot_user_id:
            return
        if not self._startup_sync_done:
            return
        if self.room_id and room.room_id != self.room_id:
            return
        if event.sender != self.config.admin_user:
            logger.warning("Ignoring message from unauthorized user: %s", event.sender)
            return

        user_msg = event.body.strip()
        if not user_msg:
            return

        logger.info("Received from %s: %s", event.sender, user_msg[:100])
        await self._send("⏳ Thinking...")

        # Forward to Copilot SDK
        result = await self.copilot_agent.send(user_msg)

        # Split long responses for Matrix
        max_len = 30000
        if len(result) <= max_len:
            await self._send(result)
        else:
            chunks = [result[i:i + max_len] for i in range(0, len(result), max_len)]
            for i, chunk in enumerate(chunks):
                await self._send(f"**[Part {i+1}/{len(chunks)}]**\n{chunk}")

    async def _send(self, text: str):
        if not self.room_id:
            logger.warning("Cannot send — no room_id set")
            return
        try:
            resp = await self.matrix_client.room_send(
                self.room_id,
                message_type="m.room.message",
                content={
                    "msgtype": "m.text",
                    "body": text,
                    "format": "org.matrix.custom.html",
                    "formatted_body": text.replace("\n", "<br>"),
                },
            )
            logger.info("Sent message (%d chars) to %s", len(text), self.room_id)
        except Exception as e:
            logger.error("Failed to send message: %s", e)

    async def stop(self):
        if self.matrix_client:
            await self._send(f"👋 **{self.config.bot_display_name}** going offline.")
            await self.matrix_client.close()
        if self.copilot_agent:
            await self.copilot_agent.stop()


async def main():
    config = BotConfig()
    logger.info("Starting agent proxy for directory: %s", config.work_dir)
    logger.info("Bot user: %s (%s)", config.bot_user_id, config.bot_display_name)
    logger.info("Admin user: %s", config.admin_user)
    logger.info("Copilot model: %s", config.copilot_model)

    bot = AgentProxyBot(config)
    try:
        await bot.start()
    except KeyboardInterrupt:
        await bot.stop()
    except Exception:
        logger.exception("Bot crashed")
        await bot.stop()
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
