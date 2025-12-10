#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

DEFAULT_ALLOWED_DOMAINS=(
    "api.openai.com"
    "chat.openai.com"
    "chatgpt.com"
    "auth0.openai.com"
    "platform.openai.com"
    "openai.com"
)

HAPROXY_PORT="${HAPROXY_PORT:-8443}"
HAPROXY_USER="${HAPROXY_USER:-haproxy}"

# Read allowed domains from file
ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/etc/codex/allowed_domains.txt}"
if [ -f "$ALLOWED_DOMAINS_FILE" ]; then
    ALLOWED_DOMAINS=()
    while IFS= read -r domain; do
        ALLOWED_DOMAINS+=("$domain")
    done < "$ALLOWED_DOMAINS_FILE"
    echo "Using domains from file: ${ALLOWED_DOMAINS[*]}"
else
    # Fallback to default domains
    ALLOWED_DOMAINS=("${DEFAULT_ALLOWED_DOMAINS[@]}")
    echo "Domains file not found, using default: ${ALLOWED_DOMAINS[*]}"
fi

# Ensure we have at least one domain
if [ ${#ALLOWED_DOMAINS[@]} -eq 0 ]; then
    echo "ERROR: No allowed domains specified"
    exit 1
fi

if ! id -u "$HAPROXY_USER" >/dev/null 2>&1; then
    echo "ERROR: HAProxy user '$HAPROXY_USER' not found"
    exit 1
fi

RESOLV_CONF_FILE="${RESOLV_CONF_FILE:-/etc/resolv.conf}"
NAMESERVERS_V4=()
NAMESERVERS_V6=()
if [ -f "$RESOLV_CONF_FILE" ]; then
    while read -r line; do
        ns="${line##nameserver }"
        if [[ "$line" =~ ^nameserver[[:space:]]+ ]]; then
            if [[ "$ns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                NAMESERVERS_V4+=("$ns")
            elif [[ "$ns" =~ ^[0-9a-fA-F:]+$ ]]; then
                NAMESERVERS_V6+=("$ns")
            fi
        fi
    done < "$RESOLV_CONF_FILE"
fi

if [ ${#NAMESERVERS_V4[@]} -eq 0 ] && [ ${#NAMESERVERS_V6[@]} -eq 0 ]; then
    echo "ERROR: No nameservers found in $RESOLV_CONF_FILE"
    exit 1
fi

ensure_container_env() {
    if [[ "${INIT_FIREWALL_SKIP_CONTAINER_CHECK:-0}" == "1" ]]; then
        echo "Warning: container guard bypassed via INIT_FIREWALL_SKIP_CONTAINER_CHECK=1" >&2
        return
    fi

    if [ -f "/.dockerenv" ] || [ -f "/run/.containerenv" ]; then
        return
    fi

    if grep -qE '(docker|containerd|podman|kubepods)' /proc/1/cgroup 2>/dev/null; then
        return
    fi

    echo "ERROR: init_firewall.sh must run inside the container network namespace; refusing to modify host firewall."
    exit 1
}

ensure_container_env

# Flush existing rules and delete existing ipsets (IPv4 + IPv6)
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ip6tables -F
ip6tables -X
ip6tables -t nat -F 2>/dev/null || true
ip6tables -t nat -X 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -t mangle -X 2>/dev/null || true

# Set default policies to DROP immediately to fail closed on errors
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# First allow DNS only towards configured nameservers and localhost before any restrictions (IPv4 + IPv6)
for ns in "${NAMESERVERS_V4[@]}"; do
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    iptables -A INPUT -p udp -s "$ns" --sport 53 -j ACCEPT
    iptables -A INPUT -p tcp -s "$ns" --sport 53 -j ACCEPT
done

for ns6 in "${NAMESERVERS_V6[@]}"; do
    ip6tables -A OUTPUT -p udp -d "$ns6" --dport 53 -j ACCEPT
    ip6tables -A OUTPUT -p tcp -d "$ns6" --dport 53 -j ACCEPT
    ip6tables -A INPUT -p udp -s "$ns6" --sport 53 -j ACCEPT
    ip6tables -A INPUT -p tcp -s "$ns6" --sport 53 -j ACCEPT
done

# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow traffic to the local HAProxy forward proxy listener
iptables -A OUTPUT -p tcp --dport "$HAPROXY_PORT" -d 127.0.0.1/32 -j ACCEPT
ip6tables -A OUTPUT -p tcp --dport "$HAPROXY_PORT" -d ::1/128 -j ACCEPT

# Allow HAProxy user to reach remote 443 after allowlist/SNI verification
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$HAPROXY_USER" -j ACCEPT
ip6tables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$HAPROXY_USER" -j ACCEPT

# Append final REJECT rules for immediate error responses
# For TCP traffic, send a TCP reset; for UDP, send ICMP port unreachable (IPv4) / ICMPv6 port unreachable (IPv6).
iptables -A INPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A INPUT -p udp -j REJECT --reject-with icmp-port-unreachable
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT -p udp -j REJECT --reject-with icmp-port-unreachable
iptables -A FORWARD -p tcp -j REJECT --reject-with tcp-reset
iptables -A FORWARD -p udp -j REJECT --reject-with icmp-port-unreachable
ip6tables -A INPUT -p tcp -j REJECT --reject-with tcp-reset
ip6tables -A INPUT -p udp -j REJECT --reject-with icmp6-port-unreachable
ip6tables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
ip6tables -A OUTPUT -p udp -j REJECT --reject-with icmp6-port-unreachable
ip6tables -A FORWARD -p tcp -j REJECT --reject-with tcp-reset
ip6tables -A FORWARD -p udp -j REJECT --reject-with icmp6-port-unreachable

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
PROXY_URL="http://127.0.0.1:${HAPROXY_PORT}"
export HTTPS_PROXY="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"

if curl --connect-timeout 5 --proxy "$PROXY_URL" https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Always verify OpenAI API access is working
if ! curl --connect-timeout 5 --proxy "$PROXY_URL" https://api.openai.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.openai.com via proxy $PROXY_URL"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.openai.com via proxy as expected"
fi
