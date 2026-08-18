#!/bin/bash
#
# DO NOT CHANGE THIS FILE. It belongs to the devcontainer template and is
# overwritten whenever the template is updated. The hosts a project needs are read
# from domains.conf, which is yours to edit.
#
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

# Flush our own rules and ipset. Only the filter table: every rule this script adds
# lives there, so nat and mangle are none of its business.
#
# It used to flush nat too, saving and restoring just the 127.0.0.11 DNS rules. That
# threw away the rest of the runtime's plumbing — including the DNAT that makes the
# host reachable at host.docker.internal — and left the container unable to talk to
# anything running on the host, which is where the application under development
# runs. Leaving nat alone fixes that and needs no save/restore dance.
iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

# Flushing rules does NOT reset the chain policies, so a re-run inside a container
# that is already firewalled would sit on DROP policies with every ACCEPT rule just
# deleted — no egress at all. The GitHub fetch below would then fail and this
# script would exit half-applied, leaving the container with no working network
# until it is recreated. Reset the policies explicitly; they go back to DROP at the
# end, once the allow rules are in place.
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

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

# Inbound ports need no rules of their own. The application under development runs
# on the host, not in here, and the directly-connected subnets allowed below cover
# everything that legitimately reaches this container. Exposing a port from the
# container to a host browser is a `ports:` entry in docker-compose.override.yml;
# the firewall does not stand in the way of it.

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

# Resolve domains from two config files: the template's baseline, which updates keep
# current, and the project's own additions, which they never touch.
for CONF in /usr/local/bin/domains-base.conf /usr/local/bin/domains.conf; do
    [[ -f "$CONF" ]] || continue
    while IFS= read -r domain; do
        [[ -z "$domain" || "$domain" =~ ^# ]] && continue
        domain=$(echo "$domain" | xargs)
        ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
        if [[ -z "$ips" ]]; then
            echo "WARNING: $domain (from $(basename "$CONF")) did not resolve — not allowed"
            continue
        fi
        for ip in $ips; do
            ipset add allowed-domains "$ip" -exist
        done
    done < "$CONF"
done

# Allow every subnet this container is directly attached to. That covers the path
# to the host — where the application under development normally runs — and any
# sibling compose containers.
#
# Read from the routing table rather than guessed. The previous version did both:
# it turned the default gateway into a /24 (right only when the gateway's prefix
# happens to be /24) and grepped the routes for 172.x (matching nothing at all on
# runtimes that use another range, e.g. OrbStack's 192.168.x). Where it worked, it
# worked by coincidence.
LINK_NETS=$(ip -4 route show scope link | awk '$1 ~ /\// && $1 !~ /^169\.254\./ {print $1}' | sort -u)
if [ -z "$LINK_NETS" ]; then
    echo "ERROR: no directly-connected IPv4 subnets found — cannot reach the host"
    exit 1
fi
for net in $LINK_NETS; do
    echo "Allowing directly-connected network: $net"
    iptables -A INPUT -s "$net" -j ACCEPT
    iptables -A OUTPUT -d "$net" -j ACCEPT
done

# The host itself, under the names the runtime publishes for it. This is the whole
# point of the sandbox as used here: the application under development runs on the
# host, and the container has to reach it.
#
# A directly-connected subnet is not enough. OrbStack answers host.docker.internal
# with an address outside every route (0.250.250.254), so without an explicit rule
# the host is unreachable — as it was until this rule existed. Nothing is assumed
# about the address: whatever the names resolve to is what gets allowed, and a name
# that does not resolve is skipped.
HOST_IPS=$(for host_alias in host.docker.internal gateway.docker.internal host.internal; do
    dig +short "$host_alias" 2>/dev/null | grep -E '^[0-9]+\.' || true
done | sort -u)
for ip in $HOST_IPS; do
    echo "Allowing host address: $ip"
    iptables -A OUTPUT -d "$ip" -j ACCEPT
    iptables -A INPUT -s "$ip" -j ACCEPT
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
