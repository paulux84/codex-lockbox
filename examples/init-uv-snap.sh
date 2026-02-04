#!/usr/bin/env bash
set -euo pipefail

# Install uv (provides uvx) via Snap.
# Snap package: astral-uv
# Docs: https://docs.astral.sh/uv/

ensure_root_or_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  echo "Error: need root or sudo to install via snap."
  exit 1
}

apt_install_snapd() {
  if command -v snap >/dev/null 2>&1; then
    return 0
  fi

  echo "snap not found. Installing snapd via apt..."
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    apt-get install -y snapd
  else
    sudo apt-get update
    sudo apt-get install -y snapd
  fi
}

start_snapd_if_possible() {
  if [ -S /run/snapd.socket ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "snapd socket not active. Attempting to start snapd..."
    if [ "$(id -u)" -eq 0 ]; then
      systemctl enable --now snapd.socket || true
      systemctl start snapd.socket || true
      systemctl start snapd.service || true
    else
      sudo systemctl enable --now snapd.socket || true
      sudo systemctl start snapd.socket || true
      sudo systemctl start snapd.service || true
    fi
  fi

  if [ ! -S /run/snapd.socket ]; then
    echo "Error: snapd socket not available. Snap likely not supported in this container."
    exit 1
  fi
}

install_uv_snap() {
  echo "Installing astral-uv via snap..."
  if [ "$(id -u)" -eq 0 ]; then
    snap install astral-uv --classic
  else
    sudo snap install astral-uv --classic
  fi
}

ensure_root_or_sudo
apt_install_snapd
start_snapd_if_possible
install_uv_snap

if command -v uv >/dev/null 2>&1; then
  echo "uv is now available: $(command -v uv)"
else
  echo "Error: uv not found after snap install."
  exit 1
fi

if command -v uvx >/dev/null 2>&1; then
  echo "uvx is now available: $(command -v uvx)"
else
  echo "Warning: uvx not found on PATH. Try opening a new shell."
fi
