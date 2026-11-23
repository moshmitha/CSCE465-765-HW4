#!/bin/bash
# Removes only the HW4 course rules
AGENT=172.30.0.10
CHAIN=HW4-EGRESS
while iptables -D DOCKER-USER -s ${AGENT} -j ${CHAIN} 2>/dev/null; do :; done
iptables -F ${CHAIN} 2>/dev/null || true
iptables -X ${CHAIN} 2>/dev/null || true
echo "HW4 firewall removed."
