#!/usr/bin/env bash
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Keep-Alive chong bi ngat ket noi do idle
export SSHX_KEEP_ALIVE=true

# Cai sshx (neu chua co) va cho phep sudo tim thay no
if ! command -v sshx >/dev/null 2>&1; then
  curl -sSf https://sshx.io/get | sh
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
fi
SSHX_BIN="$(command -v sshx || true)"
if [ -n "$SSHX_BIN" ] && ! sudo sh -c 'command -v sshx' >/dev/null 2>&1; then
  sudo cp "$SSHX_BIN" /usr/local/bin/sshx 2>/dev/null || true
fi

LOG_DIR="$HOME/sshx_logs"
mkdir -p "$LOG_DIR"
chmod 777 "$LOG_DIR" 2>/dev/null || true
OUT="$LOG_DIR/sshx.out"
: > "$OUT"

# Khoi dong sshx nen, setsid de khong bi GitHub kill khi step doi step khac
RUN_ID="${GITHUB_RUN_ID:-0}"
MINS="${DURATION_MINUTES:-60}"
DEADLINE=$(( $(date +%s) + MINS * 60 ))
setsid nohup sudo script -q -e -c "SSHX_KEEP_ALIVE=true sshx" "$LOG_DIR/sshx.pty" >> "$OUT" 2>&1 &
SSHX_PID=$!

# Doi URL toi da ~60s, ghi file + bao webhook NGAY trong step nay (link con song)
URL=""
for i in $(seq 1 30); do
  URL="$(sed -r 's/\x1B\[[0-9;]*[mK]//g' "$OUT" 2>/dev/null \
    | grep -oE 'https://sshx\.io/[^[:space:]"]+' | tail -n 1 || true)"
  if [ -n "$URL" ]; then
    echo "SSHX_URL: $URL"
    export SSHX_LINK="$URL"
    printf '{"sshx_url":"%s","username":"root","hostname":"root","instance_id":"%s","discord_id":"%s","kind":"vps","run_id":"%s"}\n' \
      "$URL" "${INSTANCE_ID:-1}" "${DISCORD_ID:-}" "$RUN_ID" > ssh_url.txt
    if [ -n "${BOT_WEBHOOK_URL:-}" ]; then
      curl -sS -X POST "${BOT_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -H "X-Bot-Secret: ${BOT_WEBHOOK_SECRET:-}" \
        --data-binary @ssh_url.txt \
        && echo "Webhook sent OK" || echo "Webhook failed"
    fi
    # Discord embed trực tiếp từ GitHub Action (event-driven, không poll)
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ] && command -v python3 >/dev/null 2>&1; then
      python3 - <<'PY' && curl -sS -X POST "${DISCORD_WEBHOOK_URL}" -H "Content-Type: application/json" --data-binary @discord-vps-payload.json >/dev/null 2>&1 || echo "Discord notify failed"
import json, os, datetime
uid = os.environ.get("DISCORD_USER_ID", "").strip()
mention = f"<@{uid}>" if uid else ""
ssh_url = os.environ.get("SSHX_LINK", "").strip()
payload = {
    "content": mention,
    "embeds": [{
        "title": "🚀 MÁY ẢO / VPS ĐÃ KHỞI TẠO THÀNH CÔNG!",
        "color": 0x2ECC71,
        "fields": [
            {"name": "🌐 Link Terminal (sshx)", "value": f"{ssh_url}", "inline": False},
            {"name": "🔑 Tài khoản", "value": "`AISTV` (root · sudo)", "inline": True},
        ],
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }],
}
json.dump(payload, open("discord-vps-payload.json", "w", encoding="utf-8"), ensure_ascii=False)
PY
    fi
    break
  fi
  sleep 2
done
echo "SSHX_URL: ${URL:-pending}"

# Giu session song den deadline NGAY TRONG step nay (step chay full thoi luong)
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if ! kill -0 "$SSHX_PID" 2>/dev/null; then
    echo "sshx died, restarting..."
    setsid nohup sudo script -q -e -c "SSHX_KEEP_ALIVE=true sshx" "$LOG_DIR/sshx.pty" >> "$OUT" 2>&1 &
    SSHX_PID=$!
  fi
  sleep 60
done
echo "Session finished after ${MINS} minutes."
exit 0
