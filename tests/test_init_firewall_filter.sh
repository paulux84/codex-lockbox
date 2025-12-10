#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LOG="$TMP_DIR/log"
MOCK_BIN="$TMP_DIR/mockbin"
mkdir -p "$MOCK_BIN"

ALLOWED_DOMAINS_FILE="$TMP_DIR/domains.txt"
RESOLV_CONF_FILE="$TMP_DIR/resolv.conf"
echo "nameserver 8.8.8.8" > "$RESOLV_CONF_FILE"

# Mock iptables/ip6tables/ipset to avoid touching host firewall
for bin in iptables ip6tables ipset; do
  cat <<'EOS' > "$MOCK_BIN/$bin"
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "$MOCK_BIN/$bin"
done

# Mock dig to return controlled answers
cat <<'EOS' > "$MOCK_BIN/dig"
#!/usr/bin/env bash
set -e
domain="${@: -1}"
record="A"
for arg in "$@"; do
  if [[ "$arg" == "AAAA" ]]; then
    record="AAAA"
    break
  fi
done
case "$domain" in
  good.com)
    if [[ "$record" == "A" ]]; then
      printf '%s\n' "1.2.3.4" "10.0.0.1"
    else
      printf '%s\n' "2001:db8::1" "::1"
    fi
    ;;
  private-only.com)
    if [[ "$record" == "A" ]]; then
      printf '%s\n' "10.10.10.10"
    else
      printf '%s\n' "::1"
    fi
    ;;
esac
EOS
chmod +x "$MOCK_BIN/dig"

# Mock curl for final verification step
cat <<'EOS' > "$MOCK_BIN/curl"
#!/usr/bin/env bash
case "$*" in
  *example.com*) exit 1 ;;  # expect to be blocked
  *api.openai.com*) exit 0 ;;  # expect to be allowed
esac
exit 0
EOS
chmod +x "$MOCK_BIN/curl"

export PATH="$MOCK_BIN:/usr/bin:/bin"
export INIT_FIREWALL_SKIP_CONTAINER_CHECK=1

# Test 1: mixed public/private records -> private filtered out, public kept
echo "good.com" > "$ALLOWED_DOMAINS_FILE"
: > "$LOG"
if ! ALLOWED_DOMAINS_FILE="$ALLOWED_DOMAINS_FILE" \
     RESOLV_CONF_FILE="$RESOLV_CONF_FILE" \
     bash "$ROOT_DIR/codex-cli/scripts/init_firewall.sh" \
     >"$LOG" 2>&1; then
  echo "Expected firewall init to succeed for good.com" >&2
  cat "$LOG" >&2
  exit 1
fi

if grep -q "Adding 10.0.0.1" "$LOG"; then
  echo "Private IPv4 should have been skipped, but was added" >&2
  cat "$LOG" >&2
  exit 1
fi
if grep -q "Adding ::1" "$LOG"; then
  echo "Private IPv6 should have been skipped, but was added" >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -q "Skipping private/reserved IPv4 10.0.0.1" "$LOG"; then
  echo "Expected private IPv4 skip message" >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -q "Skipping private/reserved IPv6 ::1" "$LOG"; then
  echo "Expected private IPv6 skip message" >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -q "Adding 1.2.3.4 for good.com" "$LOG"; then
  echo "Expected public IPv4 to be allowed" >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -q "Adding 2001:db8::1 for good.com" "$LOG"; then
  echo "Expected public IPv6 to be allowed" >&2
  cat "$LOG" >&2
  exit 1
fi

# Test 2: only private records -> fail hard
echo "private-only.com" > "$ALLOWED_DOMAINS_FILE"
: > "$LOG"
if ALLOWED_DOMAINS_FILE="$ALLOWED_DOMAINS_FILE" \
   RESOLV_CONF_FILE="$RESOLV_CONF_FILE" \
   bash "$ROOT_DIR/codex-cli/scripts/init_firewall.sh" \
   >"$LOG" 2>&1; then
  echo "Expected firewall init to fail when all IPs are private" >&2
  cat "$LOG" >&2
  exit 1
fi

if ! grep -q "All IPs for private-only.com filtered" "$LOG"; then
  echo "Expected error about filtering all IPs for private-only.com" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "init_firewall private-IP filtering tests passed"
