#!/bin/bash
# ============================================================================
# setup.sh v4 - Windows VM (dockurr/windows) trên Codespace 4 core / 16 GB
#
#   - Ổ 500GB  -> ĐĨA C: (ổ hệ thống Windows, lưu trên ổ 500GB)
#   - Ổ ~110GB -> /tmp -> ĐĨA D: (dữ liệu, tạo ổ ảo 96G nằm trên ổ 110GB)
#   - User: AISTV      Pass: AISTVCloudVM2026
#   - Hỗ trợ RDP (3389) + Web VNC (8006) + Tailscale (cài trong Windows)
#
# Cách dùng:  sudo bash vm/scripts/setup.sh
# ============================================================================
set -uo pipefail

USERNAME="${USERNAME:-AISTV}"
PASSWORD="${PASSWORD:-AISTVCloudVM2026}"
CPU_CORES="${CPU_CORES:-4}"
RAM_SIZE="${RAM_SIZE:-12G}"
DISK_SIZE="${DISK_SIZE:-450G}"
DISK2_SIZE="${DISK2_SIZE:-96G}"
VERSION="${VERSION:-10}"
PORT="${PORT:-8006}"
RDP_PORT="${RDP_PORT:-3389}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/data}"
D2_DIR="${D2_DIR:-/tmp/dock2}"

log() { echo -e "\e[1;32m[setup]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[setup]\e[0m $*"; }
die() { echo -e "\e[1;31m[setup]\e[0m $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Chạy với sudo:  sudo bash setup.sh"
[ -e /dev/kvm ]   || die "Thiếu /dev/kvm (không có KVM)"
command -v docker >/dev/null || die "Thiếu docker"
log "Máy: $(nproc) core / $(free -g 2>/dev/null | awk '/Mem:/{print $2}')G RAM / $(df -h / | awk 'NR==2{print $2}')G hệ thống"

# ---------------------------------------------------------------------------
# 1. TÌM Ổ 500GB + MOUNT VÀO /mnt/data (chứa ĐĨA C của VM)
# ---------------------------------------------------------------------------
mkdir -p "$MOUNT_POINT"

find_dev() {
  local part disk
  part=$(lsblk -rno NAME,SIZE,TYPE | awk '
    $3=="part" { gsub(/G$/,"",$2); if ($2+0>=300 && ($2+0<best+0 || best==0)) { best=$2+0; name=$1 } }
    END { if (name) print "/dev/" name }')
  [ -n "$part" ] && { echo "$part"; return; }
  disk=$(lsblk -rno NAME,SIZE,TYPE | awk '
    $3=="disk" { gsub(/G$/,"",$2); if ($2+0>=300 && ($2+0<best+0 || best==0)) { best=$2+0; name=$1 } }
    END { if (name) print "/dev/" name }')
  [ -n "$disk" ] && echo "$disk"
}

DATA_DEV=$(find_dev)
[ -n "$DATA_DEV" ] || die "Không tìm thấy ổ >= 300GB (máy này chỉ có ổ nhỏ?)"
log "Ổ dữ liệu cho ĐĨA C: $DATA_DEV"

if [ -z "$(blkid -s TYPE -o value "$DATA_DEV")" ]; then
  warn "$DATA_DEV chưa có filesystem -> mkfs.ext4"
  mkfs.ext4 -L DATA "$DATA_DEV" >/dev/null || die "mkfs thất bại"
fi
mountpoint -q "$MOUNT_POINT" || mount "$DATA_DEV" "$MOUNT_POINT" || die "Không mount được $DATA_DEV"
grep -qF "$MOUNT_POINT" /etc/fstab 2>/dev/null || \
  echo "UUID=$(blkid -s UUID -o value "$DATA_DEV") $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
log "Mount OK: $(df -h "$MOUNT_POINT" | awk 'NR==2{print $4}') trống -> $MOUNT_POINT"

# ---------------------------------------------------------------------------
# 2. ĐĨA D: (ổ ảo 96G đặt trên ổ ~110GB đang mount tại /tmp)
# ---------------------------------------------------------------------------
D2=""
FREE_TMP=$(df -k /tmp | awk 'NR==2{print $4}')
if [ "${FREE_TMP:-0}" -gt 83886080 ]; then
  mkdir -p "$D2_DIR"
  D2="$D2_DIR"
  log "ĐĨA D: ổ ảo $DISK2_SIZE trên /tmp ($(df -h /tmp | awk 'NR==2{print $4}') trống)"
else
  warn "Ổ 110GB (/tmp) không đủ trống -> bỏ ĐĨA D"
fi

# ---------------------------------------------------------------------------
# 3. BOOT-MOUNT (khi shell mở lại thì mount lại nếu chưa có)
# ---------------------------------------------------------------------------
mkdir -p /workspaces/aistv-vm-worker/vm/scripts
cat > /workspaces/aistv-vm-worker/vm/scripts/boot-mount.sh <<SH
#!/bin/bash
sudo mkdir -p "$MOUNT_POINT"
mountpoint -q "$MOUNT_POINT" || sudo mount "$DATA_DEV" "$MOUNT_POINT" 2>/dev/null
sudo chmod -R 777 "$MOUNT_POINT" 2>/dev/null
[ -f "$MOUNT_POINT/dockur/data.img" ] && echo "[boot] VM disk OK" || echo "[boot] VM chưa cài: chạy sudo bash /workspaces/aistv-vm-worker/vm/scripts/setup.sh"
command -v gh >/dev/null && gh codespace ports visibility "$PORT:public" >/dev/null 2>&1 || true
command -v gh >/dev/null && gh codespace ports visibility "$RDP_PORT:public" >/dev/null 2>&1 || true
SH
chmod +x /workspaces/aistv-vm-worker/vm/scripts/boot-mount.sh
grep -q "boot-mount.sh" ~/.bashrc 2>/dev/null || \
  printf '\n[ -x /workspaces/aistv-vm-worker/vm/scripts/boot-mount.sh ] && sudo /workspaces/aistv-vm-worker/vm/scripts/boot-mount.sh 2>/dev/null || true\n' >> ~/.bashrc
log "boot-mount đã cài vào ~/.bashrc"

# ---------------------------------------------------------------------------
# 4. SWAP + PACKAGES
# ---------------------------------------------------------------------------
[ -f /tmp/swap.img ] || { dd if=/dev/zero of=/tmp/swap.img bs=1M count=4096 status=none; chmod 600 /tmp/swap.img; mkswap /tmp/swap.img >/dev/null; }
swapon --show | grep -q /tmp/swap.img || swapon /tmp/swap.img
log "SWAP 4G OK"

# ---------------------------------------------------------------------------
# 5. DOCKER WINDOWS VM
# ---------------------------------------------------------------------------
ENVS=(
  -e "VERSION=$VERSION"
  -e "CPU_CORES=$CPU_CORES"
  -e "RAM_SIZE=$RAM_SIZE"
  -e "DISK_SIZE=$DISK_SIZE"
  -e "USERNAME=$USERNAME"
  -e "PASSWORD=$PASSWORD"
)
VOLS=( -v "$MOUNT_POINT:/storage" )
[ -n "$D2" ] && ENVS+=( -e "DISK2_SIZE=$DISK2_SIZE" ) && VOLS+=( -v "$D2:/storage2" )

docker rm -f windows >/dev/null 2>&1 || true
docker run -d --name windows --restart unless-stopped \
  "${ENVS[@]}" \
  "${VOLS[@]}" \
  -p "$PORT:8006" -p "$RDP_PORT:3389" \
  --device /dev/kvm --device /dev/net/tun \
  --cap-add NET_ADMIN \
  --stop-timeout 120 \
  dockurr/windows || die "docker run windows thất bại"

command -v gh >/dev/null && gh codespace ports visibility "$PORT:public" >/dev/null 2>&1 || true
command -v gh >/dev/null && gh codespace ports visibility "$RDP_PORT:public" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6. THÔNG BÁO
# ---------------------------------------------------------------------------
log "=========================================================================="
log "  Windows 10  -  $CPU_CORES vCPU / $RAM_SIZE"
log "  User: AISTV           Pass: AISTVCloudVM2026"
log "  ĐĨA C: trên ổ $DATA_DEV (500GB) | ĐĨA D: $([ -n "$D2" ] && echo "$DISK2_SIZE trên ổ 110GB" || echo "không có")"
log ""
log "  ▶ WEB VNC : https://${HOSTNAME:-codespace}-$PORT.app.github.dev"
log "  ▶ RDP     : gh codespace ports forward $RDP_PORT:$RDP_PORT  -> mstsc 127.0.0.1:$RDP_PORT"
log "  ▶ Log     : docker logs -f windows"
log "  ▶ Tailscale: sau khi Windows cài xong, mở VNC -> vào web tải"
log "      https://tailscale.com/download/windows -> cài & đăng nhập,"
log "      rồi từ máy khác RDP tới IP tailnet của máy này (port $RDP_PORT)."
log "============================================================================="
log "Windows đang khởi tạo (tải ISO ~ 5-10 phút đầu, cài ~ 15-25 phút)."
log "Khi xong sẽ tự đăng nhập Desktop với user AISTV."
