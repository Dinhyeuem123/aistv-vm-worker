#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Post rich Discord embed (MAY AO / VPS DA KHOI TAO THANH CONG) qua DISCORD_WEBHOOK_URL.
# Doc: reads vm-creds.json + env CLIP_URL (link clip Driveway).
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

def main() -> int:
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not url or not os.path.exists("vm-creds.json"):
        return 0
    with open("vm-creds.json", encoding="utf-8") as f:
        data = json.load(f)
    clip = os.environ.get("CLIP_URL", "").strip()
    uid = os.environ.get("DISCORD_USER_ID", "").strip()
    fields = [
        {"name": "🌐 IP/Host", "value": "`%s`" % (data.get("ip") or data.get("hostname") or "pending"), "inline": True},
        {"name": "🔑 Tài khoản", "value": "`%s` | `%s`" % (data.get("login") or data.get("username") or "-", data.get("password") or "-"), "inline": True},
    ]
    if clip:
        fields.append({"name": "🎬 Link Clip (Driveway)", "value": clip, "inline": False})
    payload = {
        "content": "<@%s>" % uid if uid else "",
        "embeds": [{
            "title": "🚀 MÁY ẢO / VPS ĐÃ KHỞI TẠO THÀNH CÔNG!",
            "color": 0x2ECC71,
            "fields": fields,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }],
    }
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            print("discord webhook response status=%s" % resp.status)
    except Exception as e:
        print("discord webhook failed: %s" % e)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
