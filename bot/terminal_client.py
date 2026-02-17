"""
terminal_client.py — Terminal chat client for Matrix rooms.

Logs in as admin and lets you send/receive messages from the terminal.
Messages sync with FluffyChat/Element on your phone.

Usage:
  python terminal_client.py [--homeserver http://localhost:8008] [--room ROOM_ID]
"""

import asyncio
import argparse
import sys
import logging
from datetime import datetime

from nio import (
    AsyncClient,
    InviteMemberEvent,
    LoginResponse,
    MatrixRoom,
    RoomMessageText,
    SyncResponse,
)

logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger("terminal-client")

ADMIN_USER = "admin"
ADMIN_PASS = "admin-secure-password-change-me"

# ANSI colors
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"


class TerminalClient:
    def __init__(self, homeserver: str, room_id: str | None = None):
        self.homeserver = homeserver
        self.target_room_id = room_id
        self.client: AsyncClient | None = None
        self._synced = False

    async def start(self):
        self.client = AsyncClient(self.homeserver, f"@{ADMIN_USER}:localhost")
        resp = await self.client.login(ADMIN_PASS, device_name="terminal-client")
        if not isinstance(resp, LoginResponse):
            print(f"Login failed: {resp}")
            sys.exit(1)

        # Auto-accept invites
        self.client.add_event_callback(self._on_invite, InviteMemberEvent)
        self.client.add_event_callback(self._on_message, RoomMessageText)

        # Initial sync
        await self.client.sync(timeout=10000, full_state=True)
        self._synced = True

        # List rooms or select target
        if not self.target_room_id:
            await self._select_room()

        print(f"\n{BOLD}Connected to room: {self.target_room_id}{RESET}")
        print(f"{DIM}Type messages and press Enter. Ctrl+C to quit.{RESET}\n")

        # Show last few messages
        await self._show_history()

        # Start sync loop in background
        sync_task = asyncio.create_task(self._sync_loop())

        # Read stdin in a thread
        try:
            await self._input_loop()
        except (KeyboardInterrupt, EOFError):
            pass
        finally:
            sync_task.cancel()
            await self.client.close()
            print(f"\n{DIM}Disconnected.{RESET}")

    async def _select_room(self):
        rooms = self.client.rooms
        if not rooms:
            print("No rooms found. Start a bot first.")
            sys.exit(1)

        print(f"\n{BOLD}Available rooms:{RESET}")
        room_list = list(rooms.items())
        for i, (room_id, room) in enumerate(room_list):
            name = room.display_name or room.name or room_id
            members = ", ".join(list(room.users.keys())[:5])
            print(f"  {CYAN}[{i+1}]{RESET} {name} {DIM}({members}){RESET}")

        while True:
            try:
                choice = await asyncio.get_event_loop().run_in_executor(
                    None, lambda: input(f"\n{YELLOW}Select room [1-{len(room_list)}]: {RESET}")
                )
                idx = int(choice) - 1
                if 0 <= idx < len(room_list):
                    self.target_room_id = room_list[idx][0]
                    break
            except (ValueError, IndexError):
                pass
            print("Invalid choice.")

    async def _show_history(self):
        """Show recent messages from the room."""
        from nio import RoomMessagesResponse
        resp = await self.client.room_messages(
            self.target_room_id, start="", limit=20, direction="b"
        )
        if isinstance(resp, RoomMessagesResponse):
            messages = []
            for event in resp.chunk:
                if isinstance(event, RoomMessageText):
                    ts = datetime.fromtimestamp(event.server_timestamp / 1000).strftime("%H:%M")
                    sender = event.sender.split(":")[0][1:]  # @user:server -> user
                    messages.append((ts, sender, event.body))
            messages.reverse()
            print(f"{DIM}--- Recent messages ---{RESET}")
            for ts, sender, body in messages[-15:]:
                self._print_message(ts, sender, body)
            print(f"{DIM}--- End of history ---{RESET}\n")

    def _print_message(self, timestamp: str, sender: str, body: str):
        if sender == ADMIN_USER:
            color = GREEN
        else:
            color = CYAN
        print(f"  {DIM}{timestamp}{RESET} {color}{BOLD}{sender}{RESET}: {body}")

    async def _on_invite(self, room: MatrixRoom, event: InviteMemberEvent):
        if event.state_key == f"@{ADMIN_USER}:localhost":
            await self.client.join(room.room_id)
            print(f"\n{YELLOW}Auto-joined room: {room.display_name or room.room_id}{RESET}")

    async def _on_message(self, room: MatrixRoom, event: RoomMessageText):
        if not self._synced:
            return
        if room.room_id != self.target_room_id:
            return
        if event.sender == f"@{ADMIN_USER}:localhost":
            return  # Don't echo our own messages

        ts = datetime.fromtimestamp(event.server_timestamp / 1000).strftime("%H:%M")
        sender = event.sender.split(":")[0][1:]
        # Move cursor to start of line, print message, then reprint prompt
        print(f"\r  {DIM}{ts}{RESET} {CYAN}{BOLD}{sender}{RESET}: {event.body}")
        print(f"{GREEN}> {RESET}", end="", flush=True)

    async def _sync_loop(self):
        try:
            await self.client.sync_forever(timeout=30000, full_state=True)
        except asyncio.CancelledError:
            pass

    async def _input_loop(self):
        loop = asyncio.get_event_loop()
        while True:
            try:
                msg = await loop.run_in_executor(
                    None, lambda: input(f"{GREEN}> {RESET}")
                )
            except EOFError:
                break

            msg = msg.strip()
            if not msg:
                continue

            if msg.lower() in ("/quit", "/exit"):
                break

            if msg.lower() == "/rooms":
                await self._select_room()
                await self._show_history()
                continue

            await self.client.room_send(
                self.target_room_id,
                message_type="m.room.message",
                content={"msgtype": "m.text", "body": msg},
            )


def main():
    parser = argparse.ArgumentParser(description="Terminal Matrix chat client")
    parser.add_argument("--homeserver", default="http://localhost:8008")
    parser.add_argument("--room", default=None, help="Room ID to join directly")
    args = parser.parse_args()

    try:
        asyncio.run(TerminalClient(args.homeserver, args.room).start())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
