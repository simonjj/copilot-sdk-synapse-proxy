"""Configuration for agent-synapse-proxy bot."""

import os
import platform
from dataclasses import dataclass
from pathlib import Path
from slugify import slugify


@dataclass
class BotConfig:
    # Synapse connection
    homeserver_url: str = os.getenv("MATRIX_HOMESERVER", "http://localhost:8008")

    # Human user to message
    admin_user: str = os.getenv("MATRIX_ADMIN_USER", "@admin:localhost")

    # Per-machine bot identity (pre-registered from LAN).
    # Defaults to hostname-based, e.g. "bot-surface-pro"
    bot_username: str = os.getenv("MATRIX_BOT_USERNAME", "")
    bot_password: str = os.getenv("MATRIX_BOT_PASSWORD", "")

    # Working directory this agent instance is associated with
    work_dir: str = os.getenv("AGENT_WORK_DIR", os.getcwd())

    # Copilot model to use
    copilot_model: str = os.getenv("COPILOT_MODEL", "claude-sonnet-4")

    # Optional: connect to an external Copilot CLI server instead of auto-spawning
    copilot_cli_url: str = os.getenv("COPILOT_CLI_URL", "")

    # Where to store nio session data (keys, device info) — shared across dirs
    store_path: str = ""

    # Derived
    bot_display_name: str = ""
    bot_user_id: str = ""
    room_name: str = ""

    def __post_init__(self):
        # Bot identity: one user per machine
        if not self.bot_username:
            hostname = slugify(platform.node(), lowercase=True) or "default"
            self.bot_username = f"bot-{hostname}"
        if not self.bot_password:
            self.bot_password = f"bot-{self.bot_username}-password"

        # Server name from admin_user
        server_name = self.admin_user.split(":", 1)[1] if ":" in self.admin_user else "localhost"
        if not self.bot_user_id:
            self.bot_user_id = f"@{self.bot_username}:{server_name}"

        # Room name derived from working directory
        dir_name = Path(self.work_dir).name
        self.room_name = f"Agent [{dir_name}]"
        if not self.bot_display_name:
            self.bot_display_name = f"Copilot [{self.bot_username}]"

        # Shared store per machine (not per directory)
        if not self.store_path:
            self.store_path = str(
                Path.home() / ".agent-synapse-proxy" / "store" / self.bot_username
            )
