#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

FW_LOG_FILE="$LOG_DIR/fw.log"
export FW_LOG_FILE

ALLOWED_DOMAINS_FILE="$LOG_DIR/allowed_domains.txt"
cat > "$ALLOWED_DOMAINS_FILE" <<'EOF'
api.openai.com
chat.openai.com
chatgpt.com
auth0.openai.com
platform.openai.com
openai.com
EOF
export ALLOWED_DOMAINS_FILE
export OPENAI_ALLOWED_DOMAINS="api.openai.com chat.openai.com chatgpt.com auth0.openai.com platform.openai.com openai.com"

RESOLV_CONF_FILE="$LOG_DIR/resolv.conf"
cat > "$RESOLV_CONF_FILE" <<'EOF'
nameserver 9.9.9.9
nameserver 2001:4860:4860::8888
EOF
export RESOLV_CONF_FILE
export INIT_FIREWALL_SKIP_CONTAINER_CHECK=1

MOCK_BIN="$LOG_DIR/mockbin"
mkdir -p "$MOCK_BIN"

cat <<'EOS' > "$MOCK_BIN/iptables"
#!/usr/bin/env bash
printf 'iptables %s\n' "$*" >> "$FW_LOG_FILE"
EOS

cat <<'EOS' > "$MOCK_BIN/ip6tables"
#!/usr/bin/env bash
printf 'ip6tables %s\n' "$*" >> "$FW_LOG_FILE"
EOS

cat <<'EOS' > "$MOCK_BIN/ipset"
#!/usr/bin/env bash
printf 'ipset %s\n' "$*" >> "$FW_LOG_FILE"
EOS

cat <<'EOS' > "$MOCK_BIN/dig"
#!/usr/bin/env bash
printf 'dig %s\n' "$*" >> "$FW_LOG_FILE"
if [[ "${@: -1}" == "example.com" ]]; then
  printf '93.184.216.34\n'
elif [[ "${@: -1}" == "chat.openai.com" ]]; then
  printf 'chat.openai.com.cdn.cloudflare.net.\n1.1.1.1\n'
elif [[ "${@: -1}" == "api.openai.com" ]]; then
  printf '2600:1f18:abcd::1\n2.2.2.2\n'
else
  printf '1.1.1.1\n'
fi
EOS

cat <<'EOS' > "$MOCK_BIN/curl"
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FW_LOG_FILE"
if [[ "$*" == *"https://example.com"* ]]; then
  exit 7
fi
exit 0
EOS

chmod +x "$MOCK_BIN/iptables" "$MOCK_BIN/ipset" "$MOCK_BIN/dig" "$MOCK_BIN/curl"
chmod +x "$MOCK_BIN/ip6tables"

PATH="$MOCK_BIN:$PATH"

cd "$ROOT_DIR"

bash codex-cli/scripts/init_firewall.sh >/dev/null

assert_contains() {
  local substring="$1"
  if ! grep -Fq "$substring" "$FW_LOG_FILE"; then
    echo "Expected log to contain: $substring" >&2
    cat "$FW_LOG_FILE" >&2
    exit 1
  fi
}

assert_contains "iptables -A OUTPUT -p udp -d 9.9.9.9 --dport 53 -j ACCEPT"
assert_contains "iptables -A OUTPUT -p tcp -d 9.9.9.9 --dport 53 -j ACCEPT"
assert_contains "iptables -A INPUT -i lo -j ACCEPT"
assert_contains "iptables -A OUTPUT -o lo -j ACCEPT"
assert_contains "iptables -P INPUT DROP"
assert_contains "iptables -P OUTPUT DROP"
assert_contains "iptables -P FORWARD DROP"
assert_contains "iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT"
assert_contains "iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT"
assert_contains "iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT"
assert_contains "ipset create allowed-domains hash:net"
assert_contains "ipset add -exist allowed-domains 1.1.1.1"
assert_contains "ipset create allowed-domains6 hash:net family inet6"
assert_contains "ipset add -exist allowed-domains6 2600:1f18:abcd::1"
assert_contains "ip6tables -P INPUT DROP"
assert_contains "ip6tables -P OUTPUT DROP"
assert_contains "ip6tables -P FORWARD DROP"
assert_contains "ip6tables -A INPUT -i lo -j ACCEPT"
assert_contains "ip6tables -A OUTPUT -o lo -j ACCEPT"
assert_contains "ip6tables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains6 dst -j ACCEPT"
assert_contains "ip6tables -A OUTPUT -p udp -d 2001:4860:4860::8888 --dport 53 -j ACCEPT"
assert_contains "ip6tables -A OUTPUT -p tcp -d 2001:4860:4860::8888 --dport 53 -j ACCEPT"
assert_contains "dig +short A api.openai.com"
assert_contains "dig +short AAAA api.openai.com"
assert_contains "dig +short A chat.openai.com"
assert_contains "dig +short A chatgpt.com"
assert_contains "dig +short A auth0.openai.com"
assert_contains "dig +short A platform.openai.com"
assert_contains "dig +short A openai.com"
assert_contains "curl --connect-timeout 5 https://example.com"
assert_contains "curl --connect-timeout 5 https://api.openai.com"

echo "Firewall rules test passed"
