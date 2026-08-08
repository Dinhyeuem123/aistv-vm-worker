#!/bin/bash
# ============================================================================
#  setup.sh v3 - Windows VM (dockurr/windows) trên Codespace 4 core/16GB
#  CHỐNG MẤT DỮ LIỆU 3 LỚP (GitHub thường thay ổ 512G khi stop/start):
#    L1. UUID-marker (ổ đổi -> cảnh báo, không cài đè)
#    L2. Backup VM vào /workspaces/vm/backup (sparse, sống qua restart)
#    L3. Tự phục hồi backup khi ổ 512G mới/trống
#  Cách dùng:  sudo bash setup.sh          (Win10/4core/12G mặc định)
# ============================================================================
set -uo pipefail

USERNAME="${USERNAME:-dockurr}"
PASSWORD="${PASSWORD:-Passw0rd!123}"
VNC_PASSWORD="${VNC_PASSWORD:-vnc1234}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-12G}"
DISK_SIZE="${DISK_SIZE:-60G}"
VERSION="${VERSION:-10}"
MANUAL="${MANUAL:-N}"
TINY="${TINY:-N}"
MIN_DISK_G="${MIN_DISK_G:-300}"
MNT="${MNT:-/mnt/data}"
SWAP_MB="${SWAP_MB:-4096}"
PORT="${PORT:-8006}"
RDP_PORT="${RDP_PORT:-3389}"

# REPO_DIR auto-detect (tên folder codespace có thể khác nhau)
REPO_DIR="${REPO_DIR:-$(find /workspaces -maxdepth 2 -name .git -type d -printf '%h\n' 2>/dev/null | head -1)}"
[ -n "$REPO_DIR" ] || REPO_DIR="/workspaces/aistv-vm-worker"
SCR_DIR="${SCR_DIR:-$REPO_DIR/vm/scripts}"
STATE_DIR="${STATE_DIR:-$REPO_DIR/vm/state}"
BACKUP_DIR="${BACKUP_DIR:-$REPO_DIR/vm/backup}"
MARKER="$STATE_DIR/uuid.marker"

log()  { echo -e "\e[1;32m[setup]\e[0m $*"; }
warn() { echo -e "\e[1;33m[setup]\e[0m $*"; }
die()  { echo -e "\e[1;31m[setup]\e[0m $*"; exit 1; }

# ---------------- 1. KIỂM TRA + TÌM Ổ ----------------
[ "$(id -u)" = "0" ] || die "Chạy root: sudo bash setup.sh"
[ -e /dev/kvm ] || die "Thiếu /dev/kvm"
command -v docker >/dev/null || die "Thiếu docker"
mkdir -p "$SCR_DIR" "$STATE_DIR" "$BACKUP_DIR"
log "KVM OK cores=$(nproc) RAM=$(free -g 2>/dev/null | awk '/Mem:/{print $2}')G - repo=$REPO_DIR"

find_data_dev() {
  local dev
  [ -f "$MARKER" ] && dev=$(blkid -U "$(cat "$MARKER")" 2>/dev/null | head -1)
  [ -n "$dev" ] && { echo "$dev"; return; }
  dev=$(blkid -L DATA 2>/dev/null | head -1)
  [ -n "$dev" ] && { echo "$dev"; return; }
  lsblk -rno NAME,TYPE,SIZE | awk -v min="$MIN_DISK_G" '
    $2=="part" { n=$3; gsub(/[^0-9.]/,"",n); if (n+0>=min+0 && n+0>best+0) { best=n; name=$1 } }
    END { if (name) print "/dev/"name }'
}

# Backup có tồn tại?
BACKUP_IMG="$BACKUP_DIR/data.img"
if [ -s "$BACKUP_IMG" ]; then
  log "CÓ BACKUP: $BACKUP_IMG ($(du -h "$BACKUP_IMG" | cut -f1))"
fi

DEV=$(find_data_dev)
if [ -z "$DEV" ]; then
  warn "Không thấy ổ >= ${MIN_DISK_G}GB"
  if [ -s "$BACKUP_IMG" ]; then
    warn "Có backup nhưng không có ổ lớn để phục hồi - xem hướng dẫn"
  fi
  die "DỪNG - không tự tạo ổ để tránh mất dữ liệu"
fi
DATA_UUID=$(blkid -s UUID -o value "$DEV")
HAS_FS=$(blkid -s TYPE -o value "$DEV")
log "Ổ dữ liệu: $DEV (UUID=$DATA_UUID)"

# ---------------- 2. UUID-MARKER + PHỤC HỒI ----------------
NEED_RESTORE=0
if [ -f "$MARKER" ]; then
  OLD=$(cat "$MARKER")
  if [ "$OLD" != "$DATA_UUID" ]; then
    warn "Ổ ĐÃ ĐỔI UUID: $OLD -> $DATA_UUID (GitHub thường thay ổ khi restart)"
    if [ -s "$BACKUP_IMG" ]; then
      warn "Đang xử lý: ổ mới trống -> sẽ phục hồi VM từ backup"
      NEED_RESTORE=1
    else
      warn "KHÔNG có backup. Ổ mới = VM mới (cài lại)."
      read -r -p "? Ấn y để tiếp tục tạo VM mới trên ổ này [y/n]: " ans
      [ "${ans:-n}" = "y" ] || die "Đã hủy"
    fi
  fi
else
  log "UUID-marker lần đầu ($DATA_UUID)"
fi
echo "$DATA_UUID" > "$MARKER"

# format nếu trống
if [ -z "$HAS_FS" ]; then
  warn "$DEV chưa có FS -> format ext4"
  mkfs.ext4 -L DATA "$DEV" || die "mkfs thất bại"
  DATA_UUID=$(blkid -s UUID -o value "$DEV")
  echo "$DATA_UUID" > "$MARKER"
fi

# mount
mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  mount "$DEV" "$MNT" || die "mount $DEV thất bại"
fi
log "Mount OK: $(df -h "$MNT" | tail -1 | awk '{print $4}') trống"
mkdir -p "$MNT/dockur"
chmod -R 777 "$MNT"
grep -q "$MNT " /etc/fstab 2>/dev/null || \
  echo "UUID=$DATA_UUID $MNT ext4 defaults,nofail 0 2" >> /etc/fstab

# phục hồi từ backup
if [ "$NEED_RESTORE" = "1" ]; then
  log "PHỤC HỒI VM từ backup -> $MNT/dockur/data.img"
  cp --sparse=always "$BACKUP_IMG" "$MNT/dockur/data.img"
  cp "$BACKUP_DIR/"*.rom "$BACKUP_DIR/"*.vars "$BACKUP_DIR/"*.mac "$BACKUP_DIR/"*.base "$MNT/dockur/" 2>/dev/null
  log "Đã phục hồi $(du -h "$MNT/dockur/data.img" | cut -f1)"
fi

# ---------------- 3. boot-mount.sh + HELPER (tự mount + restore trước docker) ----------------
cat > "$SCR_DIR/boot-mount.sh" <<SH
#!/bin/bash
MNT_D="$MNT"
UUID_D="\$(cat "$MARKER" 2>/dev/null)"
BK="$BACKUP_DIR/data.img"
sudo mkdir -p "\$MNT_D"
if ! mountpoint -q "\$MNT_D"; then
  DEV_D=\$(blkid -U "\$UUID_D" 2>/dev/null || blkid -L DATA 2>/dev/null | head -1)
  [ -n "\$DEV_D" ] && sudo mount "\$DEV_D" "\$MNT_D" && echo "[boot] mounted \$DEV_D"
fi
sudo chmod -R 777 "\$MNT_D" 2>/dev/null
if [ -f "\$MNT_D/dockur/data.img" ]; then
  echo "[boot] VM disk OK"
else
  if [ -s "\$BK" ]; then
    echo "[boot] restore backup -> \$MNT_D/dockur/"
    sudo cp --sparse=always "\$BK" "\$MNT_D/dockur/data.img"
    echo "[boot] restored"
  else
    echo "[boot] VM disk chưa có - chạy sudo bash $SCR_DIR/setup.sh"
  fi
fi
command -v gh >/dev/null && gh codespace ports visibility "$PORT:public" >/dev/null 2>&1 || true
SH
chmod +x "$SCR_DIR/boot-mount.sh"
grep -q "boot-mount.sh" ~/.bashrc 2>/dev/null || \
  printf '\n[ -x %s ] && sudo %s 2>/dev/null || true\n' "$SCR_DIR/boot-mount.sh" "$SCR_DIR/boot-mount.sh" >> ~/.bashrc

# mount-helper: container tự chạy sớm (aaa-...) mount/restore trước khi windows boot
docker rm -f aaa-mount-helper >/dev/null 2>&1
cat > /tmp/mh.sh <<SH
#!/bin/bash
BK="$BACKUP_DIR/data.img"
MNT_D="$MNT"
UUID_D="\$(cat "$MARKER" 2>/dev/null)"
while true; do
  DEV_D=\$(blkid -U "\$UUID_D" 2>/dev/null || blkid -L DATA 2>/dev/null | head -1)
  if [ -n "\$DEV_D" ]; then
    sudo mkdir -p "\$MNT_D"
    sudo mount "\$DEV_D" "\$MNT_D" 2>/dev/null
  fi
  if [ -f "\$MNT_D/dockur/data.img" ]; then
    [ -s "\$BK" ] && sudo cp --sparse=always "\$MNT_D/dockur/data.img" "\$BK" && echo "[mh] backup updated \$(du -h "\$BK" | cut -f1)"
    sleep 600
  else
    if [ -s "\$BK" ]; then
      sudo cp --sparse=always "\$BK" "\$MNT_D/dockur/data.img" && echo "[mh] restored from backup"
    fi
    sleep 15
  fi
done
SH
chmod +x /tmp/mh.sh
docker run -d --name aaa-mount-helper --restart always --privileged \
  --device /dev/kvm -v /dev:/dev -v /tmp/mh.sh:/mh.sh --entrypoint /mh.sh \
  alpine:3.19 sh -c "apk add --no-cache util-linux blkid >/dev/null 2>&1; /mh.sh" 2>/dev/null || \
  docker run -d --name aaa-mount-helper --restart always --privileged \
  --device /dev/kvm -v /dev:/dev -v /tmp/mh.sh:/mh.sh --entrypoint /mh.sh \
  dockurr/windows sh -c "/mh.sh"
log "mount-helper chạy: tự mount + backup/restore mỗi 10 phút"

# ---------------- 4. SWAP + PACKAGES ----------------
[ -f /tmp/swap.img ] || { dd if=/dev/zero of=/tmp/swap.img bs=1M count="$SWAP_MB" status=none; chmod 600 /tmp/swap.img; mkswap /tmp/swap.img >/dev/null; }
swapon --show | grep -q /tmp/swap.img || swapon /tmp/swap.img
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-x86 qemu-utils ovmf swtpm websockify novnc xorriso wget curl >/dev/null 2>&1

# ---------------- 5. DOCKER VM ----------------
log "Khởi động VM: $CPU_CORES vCPU / $RAM_SIZE / $DISK_SIZE / Win$VERSION"
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
  docker start windows >/dev/null 2>&1 || true
fi
if ! docker ps -a --format '{{.Names}}' | grep -qx windows; then
  docker run -d --name windows --restart unless-stopped \
    "${ENVS[@]}" \
    -p "$PORT:8006" -p "$RDP_PORT:3389" \
    --device /dev/kvm --device /dev/net/tun \
    -v "$MNT/dockur:/storage" \
    dockurr/windows || die "docker run thất bại"
fi
command -v gh >/dev/null && gh codespace ports visibility "$PORT:public" >/dev/null 2>&1 || true

# ---------------- 6. THÔNG BÁO ----------------
log "========================================================================"
log "  WEB VNC:  https://${HOSTNAME:-codespace}-$PORT.app.github.dev"
log "  User:     $USERNAME / $PASSWORD"
log "  Ổ:        $DEV (UUID=$DATA_UUID) -> $MNT"
log "  Backup:   $BACKUP_DIR/data.img (helper tự cập nhật 10 phút/lần)"
log "  RDP:      gh codespace ports forward $RDP_PORT:$RDP_PORT -> mstsc 127.0.0.1"
log "  Log:      docker logs -f windows"
log "=========================================================================="