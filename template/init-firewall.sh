#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

echo "=== Initializing container firewall ==="

# --- Helper functions ---

add_cidrs() {
    local label="$1"
    # Reads CIDRs from stdin, validates, and adds to ipset
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from $label: $cidr"
            exit 1
        fi
        echo "Adding $label range $cidr"
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done
}

fetch_json() {
    local url="$1"
    local label="$2"
    local result
    result=$(curl -s "$url")
    if [ -z "$result" ]; then
        echo "ERROR: Failed to fetch $label from $url"
        exit 1
    fi
    echo "$result"
}

# --- Main script ---

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- Project-specific inbound ports ---
# Add dev-server / API ports your app listens on so a browser on the host can
# reach them (e.g. a Vite dev server on 5173). Empty by default.
#   OPEN_PORTS=(3000 5173)
OPEN_PORTS=()
for port in "${OPEN_PORTS[@]}"; do
    echo "Allowing inbound TCP port $port"
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
done

# Create ipset with CIDR support (maxelem increased for CloudFront ranges)
ipset create allowed-domains hash:net maxelem 65536

# Fetch and add GitHub IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(fetch_json "https://api.github.com/meta" "GitHub IP ranges")

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q | add_cidrs "GitHub"

# Resolve domains from config
CONF="/usr/local/bin/allowed-domains.conf"

if [[ -f "$CONF" ]]; then
    while IFS= read -r domain; do
        [[ -z "$domain" || "$domain" =~ ^# ]] && continue
        domain=$(echo "$domain" | xargs)
        ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
        for ip in $ips; do
            ipset add allowed-domains "$ip" -exist
        done
    done < "$CONF"
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow traffic to Docker Compose internal networks (for DB and other services)
# Docker Compose typically uses 172.x.0.0/16 ranges for internal networks
for net in $(ip route | grep -oP '172\.\d+\.\d+\.\d+/\d+'); do
    echo "Allowing Docker internal network: $net"
    iptables -A INPUT -s "$net" -j ACCEPT
    iptables -A OUTPUT -d "$net" -j ACCEPT
done

# Forward localhost:PORT connections to docker-compose service containers, so
# app config can keep using localhost:PORT both natively and inside the
# devcontainer.
echo "Configuring localhost port forwarding to service containers..."

# Format: "<local_port> <service_name> <service_port>". Empty by default.
PORT_FORWARDS=(

)

for entry in "${PORT_FORWARDS[@]}"; do
    IFS=' ' read -r local_port service_host service_port <<<"$entry"
    service_ip=$(getent hosts "$service_host" | awk '{print $1}' | head -1)
    if [ -z "$service_ip" ]; then
        echo "ERROR: Failed to resolve service host $service_host"
        exit 1
    fi
    echo "Forwarding localhost:$local_port -> $service_host ($service_ip):$service_port"
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport "$local_port" \
        -j DNAT --to-destination "$service_ip:$service_port"
    # MASQUERADE the source so the service's reply returns to this container
    # instead of being sent to 127.0.0.1 on the service host.
    iptables -t nat -A POSTROUTING -p tcp -d "$service_ip" --dport "$service_port" \
        -j MASQUERADE
done

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
