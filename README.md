# AI STV VM Worker

GitHub Actions workers for temporary cloud sessions:
- `start-vm` — Windows VM (Remote Desktop + Tailscale)
- `start-vps` — Ubuntu interactive terminal (sshx)

Workflows trigger via `repository_dispatch` with a `matrix` + `duration` client payload. All setup scripts are plain-text and live in `scripts/`.