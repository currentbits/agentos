#!/bin/bash
# Drop NEW forwarded connections into containers unless they arrive via tailnet or local bridges.
set -euo pipefail
iptables -N AGENTOS-DOCKER 2>/dev/null || iptables -F AGENTOS-DOCKER
iptables -A AGENTOS-DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
for i in lo docker0 'br-+' tailscale0; do iptables -A AGENTOS-DOCKER -i "$i" -j RETURN; done
iptables -A AGENTOS-DOCKER -j DROP
iptables -C DOCKER-USER -j AGENTOS-DOCKER 2>/dev/null || iptables -I DOCKER-USER -j AGENTOS-DOCKER
# ponytail: IPv4 only; Docker's IPv6 is off by default. Mirror with ip6tables if ip6 is enabled in daemon.json.
