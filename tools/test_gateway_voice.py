#!/usr/bin/env python3
import asyncio
import json
from pathlib import Path
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay.server as relay


class FakeSocket:
    def __init__(self):
        self.messages = []

    async def send(self, value):
        self.messages.append(json.loads(value))


async def main():
    with tempfile.TemporaryDirectory() as directory:
        apns_key = Path(directory) / "AuthKey.p8"
        apns_key.write_text("test-key", encoding="utf-8")
        ptt_only_config = relay.APNsConfig("live", "TEAM", "KEY", str(apns_key), "")
        assert ptt_only_config.credentials_ready()
        assert not ptt_only_config.live_ready()
        store = relay.RelayStore(str(Path(directory) / "gateway.sqlite3"))
        now = int(time.time())
        with store.lock, store.db:
            for user_id in ("sender", "receiver"):
                store.db.execute(
                    "INSERT INTO users (user_id, created_at, updated_at) VALUES (?, ?, ?)",
                    (user_id, now, now),
                )
            store.db.execute(
                "INSERT INTO rooms (room_id, room_code, name, owner_user_id, created_at, updated_at) "
                "VALUES ('room-1', 'ROOM1234', 'Test', 'sender', ?, ?)",
                (now, now),
            )
            for user_id in ("sender", "receiver"):
                store.db.execute(
                    "INSERT INTO room_members "
                    "(room_code, member_id, user_id, joined_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                    ("ROOM1234", user_id, user_id, now, now),
                )

        token = "a" * 64
        subscription = store.register_ptt_subscription(
            "receiver", token, "ROOM1234", "8BB18014-7F75-48DB-B174-F97E7C76B26A",
            "com.sn5.DragonRadarMVP", "sandbox",
        )
        assert subscription["room"] == "ROOM1234"

        original_store = relay.store
        original_push = relay.push_notifications
        relay.store = store
        relay.push_notifications = relay.PushNotificationService(
            relay.APNsConfig("dry_run", "", "", "", "")
        )
        try:
            assert not relay.push_notifications.config.credentials_ready()
            assert not relay.push_notifications.config.live_ready()
            sender_socket = FakeSocket()
            receiver_socket = FakeSocket()
            sender = relay.Peer(
                sender_socket, "app", "ROOM1234", "sender-peer", "sender-group",
                user_id="sender", app_id="app-sender",
                last_payload={"name": "Sender"},
            )
            receiver = relay.Peer(
                receiver_socket, "app", "ROOM1234", "receiver-peer", "receiver-group",
                user_id="receiver", app_id="app-receiver",
            )
            room = relay.Room("ROOM1234", peers={
                sender.member_id: sender,
                receiver.member_id: receiver,
            })
            request_id = "request-1"
            await relay.handle_gateway_voice_message(sender, room, {
                "type": "gateway_voice_request", "request_id": request_id,
            })
            assert room.voice_request_id == request_id
            assert any(item["type"] == "gateway_voice_granted" for item in sender_socket.messages)
            assert any(item["type"] == "gateway_voice_wake" for item in receiver_socket.messages)

            frame = b"DR\x01" + b"\x00" * 10
            await relay.handle_gateway_voice_message(sender, room, {
                "type": "gateway_voice_frame",
                "request_id": request_id,
                "sequence": 1,
                "audio_b64": relay.base64.b64encode(frame).decode("ascii"),
            })
            assert any(item["type"] == "gateway_voice_frame" for item in receiver_socket.messages)
            assert len(room.voice_buffer) == 1

            await relay.handle_gateway_voice_message(sender, room, {
                "type": "gateway_voice_release", "request_id": request_id,
            })
            assert not room.speaker_group_id
            assert any(item["type"] == "gateway_voice_end" for item in receiver_socket.messages)

            dry_run = relay.push_notifications.send_push_to_talk_room(
                store, "ROOM1234", "sender", "request-2", "Sender"
            )
            assert dry_run["status"] == "dry_run"
            assert dry_run["attempt_count"] == 1
        finally:
            relay.store = original_store
            relay.push_notifications = original_push
            store.db.close()

    print("gateway voice relay test: ok")


if __name__ == "__main__":
    asyncio.run(main())
