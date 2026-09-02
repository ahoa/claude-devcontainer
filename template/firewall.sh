# firewall.sh — extra firewall rules for this project. EDIT THIS FILE.
#
# Sourced as bash by .template/init-firewall.sh as root, on every container start,
# at the point where all the template's own allow rules are in place but the chain
# policies are still ACCEPT and the catch-all REJECT has not been appended yet. So
# a rule added here takes effect: it lands before the rule that rejects the rest.
#
# This file is yours: the installer creates it once and never overwrites it, so
# template updates leave your rules alone. It is baked into the image, so start.sh
# forces a rebuild when you change it.
#
# Most projects need nothing here. The template already allows outbound to the
# hosts in domains.conf, the GitHub ranges, the container's directly-connected
# subnets, and the host itself — so talking to the application running on your
# machine, or to a sibling compose service, needs no rule.
#
# Inbound dev-server ports need no rule either: the directly-connected subnets are
# already accepted, which covers published-port traffic. Publishing the port in
# docker-compose.override.yml is what makes it reachable.
#
# What does belong here is anything the template cannot know about:
#
#   # An IP range no hostname resolves to
#   ipset add allowed-domains 10.20.0.0/16 -exist
#
#   # A specific outbound host:port, rather than every port on that host
#   iptables -A OUTPUT -p tcp -d 10.30.1.5 --dport 8443 -j ACCEPT
#
#   # Inbound from something outside the container's own subnets, e.g. another
#   # machine on the LAN reaching a published port
#   iptables -A INPUT -s 10.10.10.0/24 -p tcp --dport 5173 -j ACCEPT
#
# IPv6 is closed as a whole before this file is sourced, because every rule the
# template writes is IPv4. An `ip6tables` rule added here survives that and takes
# effect, in the same way an iptables rule does: it lands before the catch-all
# reject, which is appended after this file has run.
#
# Beware that `set -euo pipefail` is in force, so a failing command aborts the
# firewall setup. The container then closes its network and does not finish
# starting, rather than run on with the rules half applied. Fix the cause, then
# run `sudo /usr/local/bin/init-firewall.sh` to apply them again.
