import sys
import json
import base64
import traceback

try:
    from davey import DaveSession, ProposalsOperationType, CommitWelcome
    HAVE_DAVEY = True
except ImportError:
    HAVE_DAVEY = False

sessions = {}


def cmd_init(data):
    gid = data["guild_id"]
    uid = data["user_id"]
    cid = data["channel_id"]
    sessions[gid] = DaveSession(1, uid, cid)
    return {"type": "ok"}


def cmd_get_serialized_key_package(data):
    gid = data["guild_id"]
    session = sessions[gid]
    key_package = session.get_serialized_key_package()
    return {
        "type": "response",
        "guild_id": gid,
        "opcode": 26,
        "payload": base64.b64encode(key_package).decode(),
        "size": len(key_package),
    }


def cmd_set_external_sender(data):
    gid = data["guild_id"]
    payload = base64.b64decode(data["payload"])
    sessions[gid].set_external_sender(payload)
    return {"type": "ok"}


def cmd_process_proposals(data):
    gid = data["guild_id"]
    optype = data["optype"]
    proposals = base64.b64decode(data["payload"])
    session = sessions[gid]
    operation = ProposalsOperationType.append if optype == 0 else ProposalsOperationType.revoke
    result = session.process_proposals(operation, proposals)
    if result:
        payload = result.commit
        if result.welcome:
            payload = payload + result.welcome
        return {
            "type": "response",
            "guild_id": gid,
            "opcode": 28,
            "payload": base64.b64encode(payload).decode(),
        }
    return {"type": "ok"}


def cmd_process_commit(data):
    gid = data["guild_id"]
    commit = base64.b64decode(data["payload"])
    sessions[gid].process_commit(commit)
    return {"type": "ok"}


def cmd_process_welcome(data):
    gid = data["guild_id"]
    welcome = base64.b64decode(data["payload"])
    sessions[gid].process_welcome(welcome)
    return {"type": "ok"}


def cmd_handshake_done(data):
    gid = data["guild_id"]
    session = sessions[gid]
    return {"type": "ready" if session.ready else "not_ready", "guild_id": gid}


def cmd_encrypt_opus(data):
    gid = data["guild_id"]
    frame = base64.b64decode(data["frame"])
    encrypted = sessions[gid].encrypt_opus(frame)
    return {
        "type": "response",
        "guild_id": gid,
        "payload": base64.b64encode(encrypted).decode(),
    }


def cmd_close(data):
    gid = data["guild_id"]
    sessions.pop(gid, None)
    return {"type": "ok"}


handlers = {
    "init": cmd_init,
    "get_serialized_key_package": cmd_get_serialized_key_package,
    "set_external_sender": cmd_set_external_sender,
    "process_proposals": cmd_process_proposals,
    "process_commit": cmd_process_commit,
    "process_welcome": cmd_process_welcome,
    "handshake_done": cmd_handshake_done,
    "encrypt_opus": cmd_encrypt_opus,
    "close": cmd_close,
}

HELLO = json.dumps({"type": "hello", "have_davey": HAVE_DAVEY})
sys.stdout.write(HELLO + "\n")
sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        cmd = json.loads(line)
        if not HAVE_DAVEY and cmd.get("cmd") != "close":
            resp = {
                "type": "error",
                "guild_id": cmd.get("guild_id"),
                "message": "davey not installed",
            }
        else:
            handler = handlers.get(cmd.get("cmd"))
            if handler:
                resp = handler(cmd)
            else:
                resp = {
                    "type": "error",
                    "guild_id": cmd.get("guild_id"),
                    "message": f"unknown cmd: {cmd.get('cmd')}",
                }
    except Exception as e:
        gid = None
        try:
            gid = cmd.get("guild_id")
        except Exception:
            pass
        resp = {
            "type": "error",
            "guild_id": gid,
            "message": str(e),
            "traceback": traceback.format_exc(),
        }
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()
