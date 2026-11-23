#!/bin/bash
# HW4 Task 3: default-deny egress for agent-node (172.30.0.10)
set -euo pipefail

AGENT=172.30.0.10
WEB=172.30.0.40
C2=172.30.0.66
CHAIN=HW4-EGRESS

# Bridged container-to-container traffic reaches iptables only with br_netfilter
modprobe br_netfilter
sysctl -w net.bridge.bridge-nf-call-iptables=1

# Idempotent: remove any previous jump and chain first
while iptables -D DOCKER-USER -s ${AGENT} -j ${CHAIN} 2>/dev/null; do :; done
iptables -F ${CHAIN} 2>/dev/null || true
iptables -X ${CHAIN} 2>/dev/null || true

iptables -N ${CHAIN}

# 1) Return traffic of existing connections
iptables -A ${CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 2) agent-node may open connections to web-lab TCP 8000
iptables -A ${CHAIN} -p tcp -d ${WEB} --dport 8000 -m conntrack --ctstate NEW -j ACCEPT
# 3) log, then drop, new connections to mock-c2 TCP 8080
iptables -A ${CHAIN} -p tcp -d ${C2} --dport 8080 -m conntrack --ctstate NEW \
  -j LOG --log-prefix "HW4-C2-DROP: " --log-level 4
iptables -A ${CHAIN} -p tcp -d ${C2} --dport 8080 -m conntrack --ctstate NEW -j DROP
# 4) drop every other new connection from agent-node
iptables -A ${CHAIN} -m conntrack --ctstate NEW -j DROP

# 5) Only agent-node's traffic enters the chain; all other Docker traffic is untouched
iptables -I DOCKER-USER 1 -s ${AGENT} -j ${CHAIN}

echo "HW4 firewall installed."
