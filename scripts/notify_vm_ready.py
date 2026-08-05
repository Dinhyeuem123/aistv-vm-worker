#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Notify bot (Railway) that a VM instance is ready or failed - Webhook Event-Driven.
# Doc: reads vm-creds.json (neu co) + env CLIP_URL, POST toi BOT_WEBHOOK_URL.
# Neu thieu vm-creds.json -> gui payload status=failed de bot bao user ngay lap tuc.
import json
import os
import sys
import urllib.request

def main() -> int:
    url = os.environ.get("BOT_WEBHOOK_URL", "").strip()
    if not url:
        return 0
    if os.path.exists("vm-creds.json"):
        with open("vm-creds.json", encoding="utf-8") as f:
            data = json.load(f)
        clip = os.environ.get("CLIP_URL", "").strip()
        if clip:
            data["clip_url"] = clip
        data.setdefault("status", "ready")
    else:
        data = {
            "discord_id": os.environ.get("DISCORD_ID", "").strip(),
            "instance_id": os.environ.get("INSTANCE_ID", "1").strip(),
            "kind": "windows",
            "run_id": os.environ.get("GITHUB_RUN_ID", "0").strip(),
            "status": "failed",
        }
    headers = {"Content-Type": "application/json"}
    secret = os.environ.get("BOT_WEBHOOK_SECRET", "").strip()
    if secret:
        headers["X-Bot-Secret"] = secret
    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
    print("POST bot webhook status=%s" % data.get("status"))
    try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            print("bot webhook response status=%s" % resp.status)
    except Exception as e:
        print("bot webhook failed: %s" % e)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
