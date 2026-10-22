#!/usr/bin/env python3
"""Write ios/Tau/Secrets/Aqua.plist from the Aqua Voice app on this Mac: its sign-in token and the dictionary and
language set there. The app bundles the plist (it is gitignored) and dictates through Aqua's realtime API with it
(Tau/Chat/AquaDictation.swift).

Usage: uv run ios/scripts/aqua_secrets.py   (exits quietly, writing nothing, when Aqua Voice is not signed in here)
"""
import base64
import json
import os
import plistlib
import re
import sys
import time

SUPPORT = os.path.expanduser("~/Library/Application Support/Aqua Voice")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Tau", "Secrets", "Aqua.plist")
JWT = re.compile(rb"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")


def claims(token: str) -> dict:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def find_token() -> str | None:
    # The Electron app keeps it in localStorage, a LevelDB: the newest unexpired JWT in its files.
    folder = os.path.join(SUPPORT, "Local Storage", "leveldb")
    if not os.path.isdir(folder):
        return None
    found: list[tuple[int, str]] = []
    for name in os.listdir(folder):
        if not (name.endswith(".ldb") or name.endswith(".log")):
            continue
        with open(os.path.join(folder, name), "rb") as f:
            data = f.read()
        for match in JWT.finditer(data):
            token = match.group().decode()
            try:
                info = claims(token)
            except Exception:
                continue
            if info.get("exp", 0) > time.time() and "user_id" in info:
                found.append((info.get("iat", 0), token))
    return max(found)[1] if found else None


def main() -> None:
    token = find_token()
    if token is None:
        print("aqua_secrets: no Aqua Voice sign-in on this Mac; dictation will say so", file=sys.stderr)
        return
    settings = {}
    try:
        with open(os.path.join(SUPPORT, "settings.json")) as f:
            settings = json.load(f)
    except Exception:
        pass
    words = [w for w in settings.get("dictionary", []) if isinstance(w, str)]
    replacements = [r for r in settings.get("replacements", []) if isinstance(r, dict)]
    value = {
        "token": token,
        "language": settings.get("language") or "auto",
        "model": settings.get("transcriptionModel") or "avalon-v1.1",
        "dictionary": words,
        "replacements": [{str(k): str(v) for k, v in r.items()} for r in replacements],
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    data = plistlib.dumps(value)
    try:
        with open(OUT, "rb") as f:
            if f.read() == data:
                return
    except FileNotFoundError:
        pass
    with open(OUT, "wb") as f:
        f.write(data)
    days = int((claims(token)["exp"] - time.time()) / 86400)
    print(f"aqua_secrets: wrote {os.path.relpath(OUT)} (token valid {days} more days, {len(words)} dictionary words)")


if __name__ == "__main__":
    main()
