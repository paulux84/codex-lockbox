#!/usr/bin/env bash
set -euo pipefail

# Install uv (provides uvx) and ensure it's on PATH.
# Docs: https://docs.astral.sh/uv/

install_uv_for_user() {
  local target_user="$1"
  local target_home
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  if [ -z "$target_home" ]; then
    echo "Error: could not resolve home for user '$target_user'."
    return 1
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$target_user" -H bash -lc '
      set -euo pipefail
      if command -v uvx >/dev/null 2>&1; then
        echo "uvx already available for user: $(command -v uvx)"
        exit 0
      fi
      if command -v curl >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://astral.sh/uv/install.sh | sh
      else
        echo "Error: neither curl nor wget is available to download uv."
        exit 1
      fi
    '
  elif [ "$(id -u)" -eq 0 ]; then
    su - "$target_user" -c '
      set -euo pipefail
      if command -v uvx >/dev/null 2>&1; then
        echo "uvx already available for user: $(command -v uvx)"
        exit 0
      fi
      if command -v curl >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://astral.sh/uv/install.sh | sh
      else
        echo "Error: neither curl nor wget is available to download uv."
        exit 1
      fi
    '
  else
    # Non-root: just install for current user.
    if command -v uvx >/dev/null 2>&1; then
      echo "uvx is already available: $(command -v uvx)"
      return 0
    fi
    if command -v curl >/dev/null 2>&1; then
      curl -LsSf https://astral.sh/uv/install.sh | sh
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- https://astral.sh/uv/install.sh | sh
    else
      echo "Error: neither curl nor wget is available to download uv."
      return 1
    fi
  fi
}

echo "Installing uv (includes uvx) for current user..."
install_uv_for_user "$(id -un)"

# If a 'codex' user exists and we are root, ensure uv/uvx for codex too.
if id -u codex >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  echo "Installing uv (includes uvx) for user codex..."
  install_uv_for_user "codex"
fi

# Ensure PATH includes the default install location (current shell).
export PATH="$HOME/.local/bin:$PATH"

if command -v uvx >/dev/null 2>&1; then
  echo "uvx is now available: $(command -v uvx)"
else
  echo "uvx installation completed but not found on PATH."
  echo "Add this to your shell profile:"
  echo "  export PATH=\"$HOME/.local/bin:\$PATH\""
  exit 1
fi

# Make uv/uvx available for future shells (and different entry methods).
if command -v uvx >/dev/null 2>&1; then
  uvx_path="$(command -v uvx)"
  uv_path="$(command -v uv || true)"

  # Prefer a global symlink if /usr/local/bin is writable.
  if [ -w /usr/local/bin ]; then
    ln -sf "$uvx_path" /usr/local/bin/uvx
    if [ -n "$uv_path" ]; then
      ln -sf "$uv_path" /usr/local/bin/uv
    fi
    echo "Linked uvx (and uv) into /usr/local/bin."
  elif [ -w /etc/profile.d ]; then
    # Fallback to system-wide PATH config.
    cat > /etc/profile.d/uv.sh <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
EOF
    echo "Added /etc/profile.d/uv.sh to expose ~/.local/bin."
  else
    echo "Warning: cannot write /usr/local/bin or /etc/profile.d."
    # User-level fallback for shells started via docker exec.
    user_profile="$HOME/.profile"
    user_bashrc="$HOME/.bashrc"
    if ! grep -q 'uvx PATH' "$user_profile" 2>/dev/null; then
      {
        echo ""
        echo "# uvx PATH"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
      } >> "$user_profile"
    fi
    if ! grep -q 'uvx PATH' "$user_bashrc" 2>/dev/null; then
      {
        echo ""
        echo "# uvx PATH"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
      } >> "$user_bashrc"
    fi
    echo "Added PATH export to $user_profile and $user_bashrc."
  fi
fi

install_python_for_user() {
  local target_user="$1"
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$target_user" -H bash -lc '
      set -euo pipefail
      if command -v python3 >/dev/null 2>&1; then
        echo "python3 already available for user: $(command -v python3)"
        exit 0
      fi
      export PATH="$HOME/.local/bin:$PATH"
      uv python install
      uv python install --default
      uv python list
      if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 still not found on PATH for user."
        exit 1
      fi
    '
  elif [ "$(id -u)" -eq 0 ]; then
    su - "$target_user" -c '
      set -euo pipefail
      if command -v python3 >/dev/null 2>&1; then
        echo "python3 already available for user: $(command -v python3)"
        exit 0
      fi
      export PATH="$HOME/.local/bin:$PATH"
      uv python install
      uv python install --default
      uv python list
      if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 still not found on PATH for user."
        exit 1
      fi
    '
  else
    if command -v python3 >/dev/null 2>&1; then
      echo "python3 is already available: $(command -v python3)"
      return 0
    fi
    echo "Installing Python via uv..."
    uv python install
    uv python install --default
    uv python list
    if command -v python3 >/dev/null 2>&1; then
      echo "python3 is now available: $(command -v python3)"
    else
      echo "Python installation completed but python3 not found on PATH."
      echo "Try opening a new shell, or run: uv python install --default"
      return 1
    fi
  fi
}

install_python_for_user "$(id -un)"
if id -u codex >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  install_python_for_user "codex"
fi

# Provide a /usr/local/bin/python symlink if possible (some tools call `python`).
if command -v python3 >/dev/null 2>&1; then
  python3_path="$(command -v python3)"
  if [ -w /usr/local/bin ]; then
    ln -sf "$python3_path" /usr/local/bin/python
    echo "Linked python -> python3 in /usr/local/bin."
  else
    echo "Note: python3 is installed but /usr/local/bin is not writable; 'python' may be missing."
  fi
fi
