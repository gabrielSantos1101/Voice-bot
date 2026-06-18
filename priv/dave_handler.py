import sys
import json
import base64
import traceback

try:
    from sorrydave import DaveSession
    HAVE_SORRYDAVE = True
except ImportError:
    HAVE_SORRYDAVE = False

sessions = {}
handlers = {}


def cmd_init(data):
    gid = data["guild_id"]
    uid = data["user_id"]
    sessions[gid] = DaveSession(local_user_id=uid)
    return {"type": "ok"}


def cmd_prepare_epoch(data):
    gid = data["guild_id"]
    epoch = data.get("epoch", 1)
    session = sessions[gid]
    key_package = session.prepare_epoch(epoch)
    payload_b64 = base64.b64encode(key_package).decode()
    return {"type": "response", "guild_id": gid, "opcode": 26, "payload": payload_b64}


def cmd_handle_external_sender(data):
    gid = data["guild_id"]
    payload = base64.b64decode(data["payload"])
    session = sessions[gid]
    session.handle_external_sender_package(bytes([0, 0, 25]) + payload)
    return {"type": "ok"}


def cmd_handle_proposals(data):
    gid = data["guild_id"]
    payload = base64.b64decode(data["payload"])
    session = sessions[gid]
    result = session.handle_proposals(bytes([0, 0, 27]) + payload)
    if result:
        payload_b64 = base64.b64encode(result).decode()
        return {"type": "response", "guild_id": gid, "opcode": 28, "payload": payload_b64}
    return {"type": "ok"}


def cmd_handle_commit(data):
    gid = data["guild_id"]
    transition_id = data["transition_id"]
    payload = base64.b64decode(data["payload"])
    session = sessions[gid]
    session.handle_commit(transition_id, payload)
    return {"type": "ok"}


def cmd_handle_welcome(data):
    gid = data["guild_id"]
    transition_id = data["transition_id"]
    payload = base64.b64decode(data["payload"])
    session = sessions[gid]
    session.handle_welcome(transition_id, payload)
    return {"type": "ok"}


def cmd_execute_transition(data):
    gid = data["guild_id"]
    transition_id = data["transition_id"]
    session = sessions[gid]
    session.execute_transition(transition_id)
    return {"type": "ok"}


def cmd_get_encryptor(data):
    gid = data["guild_id"]
    session = sessions[gid]
    enc = session.get_encryptor()
    codec = data.get("codec", "OPUS")
    frame = base64.b64decode(data["frame"])
    encrypted = enc.encrypt(frame, codec=codec)
    payload_b64 = base64.b64encode(encrypted).decode()
    return {"type": "response", "guild_id": gid, "payload": payload_b64}


def cmd_handshake_done(data):
    gid = data["guild_id"]
    session = sessions[gid]
    try:
        session.get_encryptor()
        return {"type": "ready", "guild_id": gid}
    except Exception:
        return {"type": "not_ready", "guild_id": gid}


def cmd_close(data):
    gid = data["guild_id"]
    sessions.pop(gid, None)
    return {"type": "ok"}


handlers["init"] = cmd_init
handlers["prepare_epoch"] = cmd_prepare_epoch
handlers["handle_external_sender"] = cmd_handle_external_sender
handlers["handle_proposals"] = cmd_handle_proposals
handlers["handle_commit"] = cmd_handle_commit
handlers["handle_welcome"] = cmd_handle_welcome
handlers["execute_transition"] = cmd_execute_transition
handlers["get_encryptor"] = cmd_get_encryptor
handlers["handshake_done"] = cmd_handshake_done
handlers["close"] = cmd_close

HELLO = json.dumps({"type": "hello", "have_sorrydave": HAVE_SORRYDAVE})
sys.stdout.write(HELLO + "\n")
sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        cmd = json.loads(line)
        if not HAVE_SORRYDAVE and cmd.get("cmd") != "close":
            resp = {"type": "error", "guild_id": cmd.get("guild_id"), "message": "sorrydave not installed"}
        else:
            handler = handlers.get(cmd.get("cmd"))
            if handler:
                resp = handler(cmd)
            else:
                resp = {"type": "error", "guild_id": cmd.get("guild_id"), "message": f"unknown cmd: {cmd.get('cmd')}"}
    except Exception as e:
        gid = None
        try:
            gid = cmd.get("guild_id")
        except Exception:
            pass
        resp = {"type": "error", "guild_id": gid, "message": str(e), "traceback": traceback.format_exc()}
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()
