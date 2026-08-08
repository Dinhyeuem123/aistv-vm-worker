#!/bin/bash
# ============================================================================
#  setup.sh v2 - Dành riêng cho codespace PREMIUM: 4 cores / 16GB RAM / ổ 512GB
#  Chống mất dữ liệu:
#    - Tìm ổ dữ liệu bằng LABEL "DATA" hoặc UUID (tên ổ đổi /dev/sdc->sdb khi restart)
#    - UUID-marker trong state/:ễn ổ đổi -> CẢNH BÁO, không cài đè âm thầm
#    - Tự mount lại mỗi lần boot, KHÔNG format/đè nếu đã có VM
#  Cách dùng:   sudo bash setup.sh
#  Ghi đè:      sudo VERSION=11 CPU_CORES=4 RAM_SIZE=12G bash setup.sh
# ============================================================================
set -uo pipefail

# ----------------------------- CẤU HÌNH (MẶC ĐỊNH 4C/16G) -----------------------------
USERNAME="${USERNAME:-dockurr}"
PASSWORD="${PASSWORD:-Passw0rd!123}"
VNC_PASSWORD="${VNC_PASSWORD:-vnc1234}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-12G}"
DISK_SIZE="${DISK_SIZE:-200G}"
VERSION="${VERSION:-10}"                 # 10 hoặc 11
MANUAL="${MANUAL:-N}"
TINY="${TINY:-N}"
REPO_DIR="/workspaces/Dinhyeuem123/aistv-vm-worker"
SCR_DIR="${SCR_DIR:-$REPO_DIR/vm/scripts}"
STATE_DIR="${STATE_DIR:-$REPO_DIR/vm/state}"
MNT="${MNT:-/mnt/data}"
SWAP_MB="${SWAP_MB:-4096}"
PORT="${PORT:-8006}"
RDP_PORT="${RDP_PORT:-3389}"
MIN_DISK_G="${MIN_DISK_G:-300}"

log()  { echo -e "\e[1;32m[setup]\e[0m $*"; }
warn() { echo -e "\e[1;33m[setup]\e[0m $*"; }
die()  { echo -e "\e[1;31m[setup]\e[0m $*"; exit 1; }

# ---------------------------- KIỂM TRA ----------------------------
[ "$(id -u)" = "0" ] || die "Chạy với quyền root:  sudo bash setup.sh"
[ -e /dev/kvm ] || die "Thiếu /dev/kvm (máy này không hỗ trợ nested KVM)"
command -v docker >/dev/null || die "Thiếu docker"
mkdir -p "$SCR_DIR" "$STATE_DIR"
log "KVM OK - cores=$(nproc) RAM=$(free -g 2>/dev/null | awk '/Mem:/{print $2}')G"
[ "$(nproc)" -lt 4 ] && warn "Máy < 4 core - VM sẽ chậm, nên dùng máy 4 cores/16GB (có ổ 512GB)"

# --------------- 1. TÌM Ổ DỮ LIỆU (label/UUID, không phụ thuộc /dev/sd*) ---------------
find_data_dev() {
  local dev
  dev=$(blkid -L DATA 2>/dev/null | head -1)
  [ -n "$dev" ] && { echo "$dev"; return; }
  lsblk -rno NAME,TYPE,SIZE | awk -v min="$MIN_DISK_G" '
    $2=="part" { n=$3; gsub(/[^0-9.]/,"",n); if (n+0>=min+0 && n+0>best+0) { best=n; name=$1 } }
    END { if (name) print "/dev/"name }'
}
DEV=$(find_data_dev)
[ -n "$DEV" ] || die "KHÔNG tìm thấy ổ dữ liệu >= ${MIN_DISK_G}GB - máy này không có ổ dữ liệu!"
DATA_UUID=$(blkid -s UUID -o value "$DEV")
HAS_FS=$(blkid -s TYPE -o value "$DEV")
log "Ổ dữ liệu: $DEV (UUID=$DATA_UUID) - tìm theo label/UUID, không phụ thuộc tên /dev/sd*"

# --------------- 2. UUID-MARKER (chống cài đè khi GitHub đổi ổ) ---------------
MARKER="$STATE_DIR/uuid.marker"
if [ -f "$MARKER" ]; then
  OLD=$(cat "$MARKER")
  if [ "$OLD" = "$DATA_UUID" ]; then
    log "UUID-marker khớp nhau ($DATA_UUID)"
  else
    warn "======================================================================"
    warn " CẢNH BÁO: Ổ dữ liệu ĐÃ ĐỔI! marker cũ=$OLD, ổ mới=$DATA_UUID"
    warn " => Có thể GitHub đã tạo lại máy với ổ MỚI (VM cũ nằm trên ổ cũ)."
    warn " Tiếp tục = tạo VM MỚI trên ổ này. Để hủy: nhấn n; để chạy tiếp: nhấn y"
    warn "======================================================================"
    read -r -p "? [y/n]: " ans
    [ "${ans:-n}" = "y" ] || die "Đã hủy - bảo vệ dữ liệu"
  fi
else
  log "UUID-marker lần đầu ($DATA_UUID)"
fi
echo "$DATA_UUID" > "$MARKER"

# --------------- 3. FORMAT (chỉ khi trống) + MOUNT + fstab ---------------
if [ -z "$HAS_FS" ]; then
  log "$DEV chưa có partition/filesystem -> format ext4 (label DATA)"
  mkfs.ext4 -L DATA "$DEV" || die "mkfs thất bại"
  DATA_UUID=$(blkid -s UUID -o value "$DEV")
  echo "$DATA_UUID" > "$MARKER"
fi
mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  mount -U "$DATA_UUID" "$MNT" 2>/dev/null || mount "$DEV" "$MNT" || die "mount $DEV thất bại"
fi
log "Đã mount $MNT: $(df -h "$MNT" | tail -1 | awk '{print $4}') trống"
mkdir -p "$MNT/dockur"
chmod -R 777 "$MNT"
grep -q "$MNT " /etc/fstab 2>/dev/null || \
  echo "UUID=$DATA_UUID $MNT ext4 defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
log "fstab OK (UUID=$DATA_UUID)"

# --------------- 4. boot-mount.sh (auto-remount theo UUID + mở port) ---------------
cat > "$SCR_DIR/boot-mount.sh" <<SH
#!/bin/bash
UUID_D="$DATA_UUID"
MNT_D="$MNT"
PORT_D="$PORT"
VARS_D="$STATE_DIR/uuid.marker"
DEV_D=\$(blkid -U "\$UUID_D" 2>/dev/null || blkid -L DATA 2>/dev/null | head -1)
sudo mkdir -p "\$MNT_D"
if mountpoint -q "\$MNT_D"; then
  echo "[boot] \$MNT_D đã mount"
else
  if [ -n "\$DEV_D" ]; then
    sudo mount "\$DEV_D" "\$MNT_D" && echo "[boot] Mounted \$DEV_D -> \$MNT_D"
  else
    echo "[boot] WARNING: không thấy ổ (UUID=\$UUID_D). KHÔNG tạo VM mới!"
  fi
fi
sudo chmod -R 777 "\$MNT_D" 2>/dev/null
if [ -f "\$MNT_D/dockur/data.img" ]; then
  echo "[boot] VM disk OK"
else
  echo "[boot] VM disk chưa có - chạy sudo bash $SCR_DIR/setup.sh để tạo"
fi
command -v gh >/dev/null && gh codespace ports visibility "\$PORT_D:public" >/dev/null 2>&1 || true
SH
chmod +x "$SCR_DIR/boot-mount.sh"
grep -q "boot-mount.sh" ~/.bashrc 2>/dev/null || \
  printf '\n[ -x %s ] && sudo %s 2>/dev/null || true\n' "$SCR_DIR/boot-mount.sh" "$SCR_DIR/boot-mount.sh" >> ~/.bashrc
log "boot-mount.sh OK (theo UUID)"

# --------------- 5. Ổ TMP: swap + cache ---------------
[ -f /tmp/swap.img ] || { dd if=/dev/zero of=/tmp/swap.img bs=1M count="$SWAP_MB" status=none; chmod 600 /tmp/swap.img; mkswap /tmp/swap.img >/dev/null; }
swapon --show | grep -q /tmp/swap.img || swapon /tmp/swap.img
mkdir -p /tmp/dockur-cache
log "Swap: $(free -h | awk '/Swap:/{print $2}')"

# --------------- 6. CÀI PACKAGE ---------------
log "Cài qemu/ovmf/swtpm/novnc..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-x86 qemu-utils ovmf swtpm websockify novnc xorriso wget curl >/dev/null 2>&1
command -v qemu-system-x86_64 >/dev/null && log "QEMU OK"
command -v swtpm >/dev/null && log "swtpm OK (TPM 2.0)"

# --------------- 7. CHẠY DOCKER VM ---------------
log "Khởi động dockurr/windows: $CPU_CORES vCPU / $RAM_SIZE / $DISK_SIZE / Win$VERSION..."
ENVS=(
  -e "VERSION=$VERSION"
  -e "CPU_CORES=$CPU_CORES"
  -e "RAM_SIZE=$RAM_SIZE"
  -e "DISK_SIZE=$DISK_SIZE"
  -e "USERNAME=$USERNAME"
  -e "PASSWORD=$PASSWORD"
  -e "VNC_PASSWORD=$VNC_PASSWORD"
  -e "KVM=Y"
  -e "MANUAL=$MANUAL"
)
[ "$TINY" = "Y" ] && ENVS+=( -e "TINY=Y" )

if docker ps -a --format '{{.Names}}' | grep -qx windows; then
  echo "[setup] Container 'windows' đã có - chỉ khởi động lại (dữ liệu giữ nguyên)"
  docker start windows >/dev/null 2>&1 || true
fi
if ! docker ps -a --format '{{.Names}}' | grep -qx windows; then
  docker run -d --name windows --restart unless-stopped \
    "${ENVS[@]}" \
    -p "$PORT:8006" -p "$RDP_PORT:3389" \
    --device /dev/kvm --device /dev/net/tun \
    -v "$MNT/dockur:/storage" \
    -v /tmp/dockur-cache:/tmp/cache \
    dockurr/windows || die "docker run thất bại"
fi
log "Container OK - Windows đang cài tự động (10-30 phút)"
command -v gh >/dev/null && gh codespace ports visibility "$PORT:public" >/dev/null 2>&1 || true

# --------------- 8. THÔNG BÁO ---------------
log "========================================================================"
log "  WEB VNC:  https://${HOSTNAME:-codespace}-$PORT.app.github.dev"
log "  User:     $USERNAME     Password: $PASSWORD"
log "  Ổ dữ liệu: $DEV (UUID=$DATA_UUID) -> $MNT (persistent, chống đổi tên)"
log "  RDP:      gh codespace ports forward $RDP_PORT:$RDP_PORT"
log "            rồi mstsc -> 127.0.0.1:$RDP_PORT"
log "  Log VM:   docker logs -f windows"
log "=========================================================================="