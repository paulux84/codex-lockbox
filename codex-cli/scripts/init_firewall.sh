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
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy allowed-domains6 2>/dev/null || true

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

# Create ipset with CIDR support
ipset create allowed-domains hash:net
ipset create allowed-domains6 hash:net family inet6

is_private_v4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^0\. ]] && return 0
    [[ "$ip" == "255.255.255.255" ]] && return 0
    return 1
}

is_private_v6() {
    local ip="$1"
    [[ "$ip" =~ ^::1(/128)?$ ]] && return 0
    [[ "$ip" =~ ^fe[89abAB] ]] && return 0    # fe80::/10 link-local
    [[ "$ip" =~ ^ff ]] && return 0             # ff00::/8 multicast
    return 1
}

# Resolve and add other allowed domains
for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    mapfile -t resolved_ips < <(dig +short A "$domain" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
    mapfile -t resolved_ips_v6 < <(dig +short AAAA "$domain" | grep -iE '^[0-9a-f:]+$')
    if [ ${#resolved_ips[@]} -eq 0 ] && [ ${#resolved_ips_v6[@]} -eq 0 ]; then
        echo "ERROR: Failed to resolve $domain to IPv4 or IPv6"
        exit 1
    fi

    filtered_v4=()
    for ip in "${resolved_ips[@]}"; do
        if [[ "${ALLOW_PRIVATE_DNS:-0}" != "1" ]] && is_private_v4 "$ip"; then
            echo "Skipping private/reserved IPv4 $ip for $domain" >&2
            continue
        fi
        filtered_v4+=("$ip")
    done

    filtered_v6=()
    for ip6 in "${resolved_ips_v6[@]}"; do
        if [[ "${ALLOW_PRIVATE_DNS:-0}" != "1" ]] && is_private_v6 "$ip6"; then
            echo "Skipping private/reserved IPv6 $ip6 for $domain" >&2
            continue
        fi
        filtered_v6+=("$ip6")
    done

    if [ ${#filtered_v4[@]} -eq 0 ] && [ ${#filtered_v6[@]} -eq 0 ]; then
        echo "ERROR: All IPs for $domain filtered (private/reserved); refusing to allow" >&2
        exit 1
    fi

    for ip in "${filtered_v4[@]}"; do
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done

    for ip6 in "${filtered_v6[@]}"; do
        echo "Adding $ip6 for $domain"
        ipset add -exist allowed-domains6 "$ip6"
    done
done

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains (TCP 443)
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT
ip6tables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains6 dst -j ACCEPT

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
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Always verify OpenAI API access is working
if ! curl --connect-timeout 5 https://api.openai.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.openai.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.openai.com as expected"
fi
