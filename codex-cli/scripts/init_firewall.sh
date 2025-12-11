#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

INIT_FIREWALL_MODE="${INIT_FIREWALL_MODE:-proxy}"  # proxy|acl
case "$INIT_FIREWALL_MODE" in
  proxy|acl) ;;
  *)
    echo "ERROR: INIT_FIREWALL_MODE must be 'proxy' or 'acl' (got '$INIT_FIREWALL_MODE')" >&2
    exit 1
    ;;
esac

required_cmds=(iptables ip6tables curl)
if [[ "$INIT_FIREWALL_MODE" == "acl" ]]; then
  required_cmds+=(ipset dig)
fi

for cmd in "${required_cmds[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# Proxy configuration (firewall only allows egress to this proxy; domain ACL is enforced by the proxy)
PROXY_CONFIG_FILE="${PROXY_CONFIG_FILE:-/etc/codex/proxy.conf}"
PROXY_IP_V4="${PROXY_IP_V4:-}"
PROXY_IP_V6="${PROXY_IP_V6:-}"
PROXY_PORT="${PROXY_PORT:-3128}"

if [[ "$INIT_FIREWALL_MODE" == "proxy" ]]; then
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$PROXY_CONFIG_FILE"
    fi

    PROXY_IP_V4="${PROXY_IP_V4:-}"
    PROXY_IP_V6="${PROXY_IP_V6:-}"
    PROXY_PORT="${PROXY_PORT:-3128}"

    if [ -z "$PROXY_IP_V4" ] && [ -z "$PROXY_IP_V6" ]; then
        echo "ERROR: PROXY_IP_V4 or PROXY_IP_V6 must be set (via env or $PROXY_CONFIG_FILE)" >&2
        exit 1
    fi

    if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: PROXY_PORT must be numeric (got '$PROXY_PORT')" >&2
        exit 1
    fi
fi

# Domains file (used by the proxy ACL, not by iptables)
DEFAULT_ALLOWED_DOMAINS=(
    "api.openai.com"
    "chat.openai.com"
    "chatgpt.com"
    "auth0.openai.com"
    "platform.openai.com"
    "openai.com"
)

ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/etc/codex/allowed_domains.txt}"
if [ -f "$ALLOWED_DOMAINS_FILE" ]; then
    mapfile -t ALLOWED_DOMAINS < <(grep -v '^[[:space:]]*#' "$ALLOWED_DOMAINS_FILE" | sed '/^[[:space:]]*$/d')
    if [ ${#ALLOWED_DOMAINS[@]} -eq 0 ]; then
        echo "ERROR: Allowed domains file is empty after filtering comments/blank lines: $ALLOWED_DOMAINS_FILE" >&2
        exit 1
    fi
    echo "Using domains from file: ${ALLOWED_DOMAINS[*]}"
else
    ALLOWED_DOMAINS=("${DEFAULT_ALLOWED_DOMAINS[@]}")
    echo "Domains file not found, falling back to default: ${ALLOWED_DOMAINS[*]}"
fi

RESOLV_CONF_FILE="${RESOLV_CONF_FILE:-/etc/resolv.conf}"
NAMESERVERS_V4=()
NAMESERVERS_V6=()
DEFAULT_NS_V4=("8.8.8.8" "1.1.1.1")
DEFAULT_NS_V6=("2001:4860:4860::8888" "2001:4860:4860::8844")
is_private_ipv4() {
    local ip="$1"
    local ip_lc="${ip,,}"
    ip="$ip_lc"
    [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
    [[ "$ip" =~ ^127\. ]] || [[ "$ip" =~ ^169\.254\. ]] || [[ "$ip" =~ ^0\. ]] || [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] || \
    [[ "$ip" =~ ^192\.0\.0\. ]] || [[ "$ip" =~ ^192\.0\.2\. ]] || [[ "$ip" =~ ^198\.1[8-9]\. ]] || [[ "$ip" =~ ^198\.51\.100\. ]] || \
    [[ "$ip" =~ ^203\.0\.113\. ]] || [[ "$ip" =~ ^255\.255\.255\.255$ ]]
}

is_private_ipv6() {
    local ip="$1"
    local ip_lc="${ip,,}"
    ip="$ip_lc"
    [[ "$ip" =~ ^(::1|::)$ ]] || [[ "$ip" =~ ^fc|^fd ]] || [[ "$ip" =~ ^fe80 ]] || [[ "$ip" =~ ^ff ]] || \
    [[ "$ip" =~ ^2001:db8: ]] || [[ "$ip" =~ ^2001:10: ]] || [[ "$ip" =~ ^64:ff9b:: ]] # documentation/ula/link-local/mcast/well-known
}

if [ -f "$RESOLV_CONF_FILE" ]; then
    while read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^nameserver[[:space:]]+ ]]; then
            ns=$(awk '{print $2}' <<< "$line")
            if [[ "$ns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                if is_private_ipv4 "$ns"; then
                    echo "Skipping private/reserved IPv4 resolver $ns"
                    continue
                fi
                NAMESERVERS_V4+=("$ns")
            elif [[ "$ns" =~ ^[0-9a-fA-F:]+$ ]]; then
                if is_private_ipv6 "$ns"; then
                    echo "Skipping private/reserved IPv6 resolver $ns"
                    continue
                fi
                NAMESERVERS_V6+=("$ns")
            fi
        fi
    done < "$RESOLV_CONF_FILE"
fi

if [ ${#NAMESERVERS_V4[@]} -eq 0 ] && [ ${#NAMESERVERS_V6[@]} -eq 0 ]; then
    echo "No public nameservers found in $RESOLV_CONF_FILE, falling back to default public resolvers."
    NAMESERVERS_V4=("${DEFAULT_NS_V4[@]}")
    NAMESERVERS_V6=("${DEFAULT_NS_V6[@]}")
fi

if [[ "$INIT_FIREWALL_MODE" == "acl" ]]; then
    ipset create allowed-domains hash:net -exist
    ipset create allowed-domains6 hash:net family inet6 -exist

    add_ip_if_public() {
        local ip="$1" domain="$2" family="$3"
        if [[ "$family" == "ipv4" ]]; then
            if is_private_ipv4 "$ip"; then
                echo "Skipping private/reserved IPv4 $ip for $domain"
                return 1
            fi
            ipset add -exist allowed-domains "$ip"
        else
            if is_private_ipv6 "$ip"; then
                echo "Skipping private/reserved IPv6 $ip for $domain"
                return 1
            fi
            ipset add -exist allowed-domains6 "$ip"
        fi
        echo "Adding $ip for $domain"
        return 0
    }

    is_ipv4() {
        local ip="$1"
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
    }

    is_ipv6() {
        local ip="$1"
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:* ]]
    }

    for domain in "${ALLOWED_DOMAINS[@]}"; do
        have_public=false
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            is_ipv4 "$ip" || continue
            if add_ip_if_public "$ip" "$domain" "ipv4"; then
                have_public=true
            fi
        done < <(dig +short A "$domain")

        while IFS= read -r ip6; do
            [[ -z "$ip6" ]] && continue
            is_ipv6 "$ip6" || continue
            if add_ip_if_public "$ip6" "$domain" "ipv6"; then
                have_public=true
            fi
        done < <(dig +short AAAA "$domain")

        if [[ "$have_public" == "false" ]]; then
            echo "ERROR: All IPs for $domain filtered as private/reserved"
            exit 1
        fi
    done
else
    echo "INIT_FIREWALL_MODE=proxy: skipping ipset/domain ACL population (enforced by Squid)"
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

# Flush existing rules (IPv4 + IPv6)
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
done

for ns6 in "${NAMESERVERS_V6[@]}"; do
    ip6tables -A OUTPUT -p udp -d "$ns6" --dport 53 -j ACCEPT
    ip6tables -A OUTPUT -p tcp -d "$ns6" --dport 53 -j ACCEPT
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

# Mode-specific allow rules
if [[ "$INIT_FIREWALL_MODE" == "proxy" ]]; then
    # Allow outbound traffic only to the configured proxy
    if [ -n "$PROXY_IP_V4" ]; then
        echo "Allowing proxy IPv4 $PROXY_IP_V4:$PROXY_PORT"
        iptables -A OUTPUT -p tcp -d "$PROXY_IP_V4" --dport "$PROXY_PORT" -j ACCEPT
    fi

    if [ -n "$PROXY_IP_V6" ]; then
        echo "Allowing proxy IPv6 [$PROXY_IP_V6]:$PROXY_PORT"
        ip6tables -A OUTPUT -p tcp -d "$PROXY_IP_V6" --dport "$PROXY_PORT" -j ACCEPT
    fi
else
    # Allow outbound HTTPS/HTTP only towards the resolved public IPs of allowed domains
    iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst --dport 443 -j ACCEPT
    iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst --dport 80 -j ACCEPT
    ip6tables -A OUTPUT -p tcp -m set --match-set allowed-domains6 dst --dport 443 -j ACCEPT
    ip6tables -A OUTPUT -p tcp -m set --match-set allowed-domains6 dst --dport 80 -j ACCEPT
fi

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
if NO_PROXY="*" HTTPS_PROXY="" HTTP_PROXY="" curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com without proxy"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com directly as expected"
fi

TARGET_HOST="api.openai.com"
if [[ "$INIT_FIREWALL_MODE" == "proxy" ]]; then
    PROXY_URL_V4=""
    if [ -n "$PROXY_IP_V4" ]; then
        PROXY_URL_V4="http://${PROXY_IP_V4}:${PROXY_PORT}"
    fi
    PROXY_URL_V6=""
    if [ -n "$PROXY_IP_V6" ]; then
        PROXY_URL_V6="http://[${PROXY_IP_V6}]:${PROXY_PORT}"
    fi

    verify_via_proxy() {
        local proxy_url="$1"
        local attempts=3
        local delay=2
        local i
        for i in $(seq 1 "$attempts"); do
            if HTTPS_PROXY="$proxy_url" HTTP_PROXY="$proxy_url" NO_PROXY="" curl --connect-timeout 8 -s "https://${TARGET_HOST}" >/dev/null 2>&1; then
                echo "Firewall verification passed - able to reach https://${TARGET_HOST} via proxy $proxy_url"
                return 0
            fi
            echo "Attempt $i/$attempts: unable to reach https://${TARGET_HOST} via proxy $proxy_url, retrying in ${delay}s..."
            sleep "$delay"
        done
        echo "ERROR: Firewall verification failed - unable to reach https://${TARGET_HOST} via proxy $proxy_url after ${attempts} attempts"
        return 1
    }

    if [ -n "$PROXY_URL_V4" ]; then
        verify_via_proxy "$PROXY_URL_V4" || exit 1
    fi

    if [ -n "$PROXY_URL_V6" ]; then
        verify_via_proxy "$PROXY_URL_V6" || exit 1
    fi
else
    # Direct reachability check without proxy
    if HTTPS_PROXY="" HTTP_PROXY="" NO_PROXY="*" curl --connect-timeout 8 -s "https://${TARGET_HOST}" >/dev/null 2>&1; then
        echo "Firewall verification passed - able to reach https://${TARGET_HOST} directly (ACL mode)"
    else
        echo "ERROR: Firewall verification failed - unable to reach https://${TARGET_HOST} directly in ACL mode"
        exit 1
    fi
fi

echo "Verification complete"
