# CSCE-765-HW4
# CSCE 465/765 Homework 4: Detect and Block Agent Exfiltration

Team: Moshmitha Suthapalli and Asritha Sai Annamreddi (contribution split 50% / 50%)

This repository builds a small, fully simulated data-exfiltration incident inside a private Docker network, then investigates, blocks and detects it. Everything runs locally in an Ubuntu VM. No real secrets, external servers or real malware are used.

## What the lab does

| Container | IP : port | Role in the incident |
|---|---|---|
| `agent-node` | 172.30.0.10 | The machine where an AI agent runs its tools. It runs the mock skill, which opens an unauthorized listener on TCP 9009 and, given the trigger argument, leaks a fake secret. |
| `web-lab` | 172.30.0.40 : 8000 | Web server with a benign page and an adversarial page carrying an indirect prompt injection (marker `CSCE465-COURSE-MARKER`). |
| `mock-c2` | 172.30.0.66 : 8080 | Stand-in for an attacker's command-and-control server. Stores the POST body in `/data/received.bin` and replies 204. |

Network: user-defined bridge `172.30.0.0/24`, Linux bridge interface `br-hw4`.

## Repository contents

| File / folder | Purpose |
|---|---|
| `Dockerfile` | One small image (`python:3.12.16-slim-trixie`, with `socat` and `curl`) used by all three containers. Creates `/data`. |
| `docker-compose.yml` | Defines the three services, fixed IPs, and the `br-hw4` bridge network. |
| `mock_skill.sh` | The mock skill. Starts a harmless `socat` listener on TCP 9009. With the exact argument `exfiltrate-course-file`, it also POSTs `fake_secrets.txt` to mock-c2 over plaintext HTTP. |
| `c2.py` | The mock C2 receiver (Python `http.server`). Saves the POST body to `/data/received.bin` and returns HTTP 204. |
| `fake_secrets.txt` | The unique fake token (no trailing newline). |
| `web/benign.html` | An ordinary page without the marker. |
| `web/adversarial.html` | A page containing `CSCE465-COURSE-MARKER` and an injected instruction to run the skill with `exfiltrate-course-file`. |
| `scan.txt` | Output of the Task 2 nmap scan. |
| `firewall.sh` | Task 3: default-deny egress for agent-node using the `DOCKER-USER` chain (own chain `HW4-EGRESS`). Run with `sudo`. |
| `firewall-reset.sh` | Removes only the HW4 firewall rules. |
| `local.rules` | Task 4: the three Suricata rules (SIDs 1000001, 1000002, 1000003). |
| `report.pdf` | The graded report. |
| `AI_USAGE.md` | AI-use disclosure (and the conversation log file it names). |

Generated while working through the tasks (not source files): `hw4-malicious.pcap`, `hw4-clean.pcap`, `objs/`, and the `suricata-malicious/` and `suricata-clean/` output folders.

## Requirements

- Ubuntu VM on a **NAT** virtual network (not bridged).
- Docker Engine and the Compose plugin, `nmap`, `tcpdump`, `tshark`, `netcat-openbsd`, `suricata`, `iptables` (nf_tables backend).
- Verify with: `docker run --rm hello-world`, `docker compose version`, `nmap --version`, `tshark --version`, `suricata -V`.
- Safety: scan only 172.30.0.10. Use only the fake secret and local mock services. Never mount your home directory or the Docker socket into a container.

## Getting started

Clone into a folder named `hw4` so that the Compose project, network and container names match the report (`hw4_hw4net`, `hw4-agent-node-1`, and so on):

```bash
git clone https://github.com/asritha-tamu/CSCE-765-HW4 hw4
cd hw4
chmod +x mock_skill.sh firewall.sh firewall-reset.sh
```

If you use a different folder name, add `-p hw4` to every `docker compose` command, or look up the network name with `docker network ls`.

## How to run each task

### Task 1: Build and start the lab
```bash
docker compose up -d --build
docker compose ps
docker network inspect hw4_hw4net
```
Run the skill with the trigger and compare hashes (before any firewall):
```bash
docker compose exec agent-node /lab/mock_skill.sh exfiltrate-course-file    # prints: mock-c2 replied HTTP 204
sha256sum fake_secrets.txt
docker compose exec mock-c2 sha256sum /data/received.bin                     # must match
```

### Task 2: Scan, capture and reconstruct
Start the listener, then scan only agent-node:
```bash
docker compose exec mock-c2 rm -f /data/received.bin
docker compose exec agent-node /lab/mock_skill.sh
nmap -sT -sV -p- 172.30.0.10 | tee scan.txt          # expect 9009/tcp open
```
Capture the incident (Terminal A), and reproduce it (Terminal B):
```bash
# Terminal A
sudo tcpdump -i br-hw4 -s 0 -w hw4-malicious.pcap 'net 172.30.0.0/24'

# Terminal B, in this order
docker compose exec agent-node curl -s http://172.30.0.40:8000/adversarial.html
docker compose exec agent-node /lab/mock_skill.sh exfiltrate-course-file
# then press Ctrl-C in Terminal A
sudo chown $USER:$USER hw4-malicious.pcap
```
Reconstruct with TShark (the exfiltration is stream 1):
```bash
tshark -r hw4-malicious.pcap -q -z conv,tcp
tshark -r hw4-malicious.pcap -Y 'http.request' -T fields -e frame.number -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e tcp.stream -e http.request.method -e http.request.uri
tshark -r hw4-malicious.pcap -q -z follow,tcp,ascii,1
mkdir -p objs && tshark -r hw4-malicious.pcap -q --export-objects http,objs/ && sha256sum objs/*
tshark -r hw4-malicious.pcap -Y 'tcp.stream==1' -T fields -e frame.number -e frame.time_utc -e frame.time_epoch -e tcp.flags.str | sed -n '1p;$p'
```
Clean baseline capture (benign request only):
```bash
sudo tcpdump -i br-hw4 -s 0 -w hw4-clean.pcap 'net 172.30.0.0/24'      # Terminal A
docker compose exec agent-node curl -s http://172.30.0.40:8000/benign.html   # Terminal B, then Ctrl-C in A
sudo chown $USER:$USER hw4-clean.pcap
```

### Task 3: Default-deny egress firewall
```bash
sudo ./firewall.sh
sudo iptables -L DOCKER-USER -n -v --line-numbers
sudo iptables -L HW4-EGRESS -n -v --line-numbers
sudo iptables -Z HW4-EGRESS            # zero counters before testing
```
Run the five tests in this order (test 5 writes an empty `received.bin`, so it goes last):
```bash
# 1. Benign fetch: expect HTTP 200
docker compose exec agent-node curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://172.30.0.40:8000/benign.html
# 2. Exfiltration: expect a timeout and an empty /data/
docker compose exec mock-c2 rm -f /data/received.bin
docker compose exec agent-node /lab/mock_skill.sh exfiltrate-course-file
docker compose exec mock-c2 ls -l /data/
# 3. Unapproved port: expect a timeout (not "refused")
docker compose exec agent-node curl --max-time 5 http://172.30.0.40:8080/
# 4. Response traffic: expect the banner HW4-MOCK-SKILL-LISTENER
nc 172.30.0.10 9009
# 5. Unrelated Docker traffic: expect HTTP 204
docker compose exec web-lab curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST http://172.30.0.66:8080/
```
View the blocked-attempt log lines: `sudo dmesg | grep HW4-C2-DROP` (or `sudo journalctl -k | grep HW4-C2-DROP`).

Optional: show why `br_netfilter` matters.
```bash
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0
docker compose exec agent-node /lab/mock_skill.sh exfiltrate-course-file   # succeeds again (204)
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1                       # turn it back on
docker compose exec mock-c2 rm -f /data/received.bin
```
Remove the firewall rules when finished: `sudo ./firewall-reset.sh`.

### Task 4: Suricata rules (offline)
```bash
mkdir -p suricata-malicious suricata-clean
suricata -k none -r hw4-malicious.pcap -S local.rules -l suricata-malicious
suricata -k none -r hw4-clean.pcap -S local.rules -l suricata-clean
cat suricata-malicious/fast.log        # expect 3 alerts: SIDs 1000001, 1000002, 1000003
cat suricata-clean/fast.log            # expect empty
```
`-k none` disables checksum validation; without it Suricata drops Docker-bridge packets and the payload rules never fire. `fake_secrets.txt` is already embedded in the rule for SID 1000001. If you regenerate the token, update that rule.

### Task 5: Incident summary
It is the last section of `report.pdf`, built from the Task 2 packet timestamps, the Task 4 alerts and the firewall log lines.

## Notes and troubleshooting

- After a VM reboot the containers are stopped and the 9009 listener is gone. Run `docker compose up -d`, then `docker compose exec agent-node /lab/mock_skill.sh`.
- `br_netfilter` and the bridge sysctl do not survive a reboot. `firewall.sh` sets both again, so re-run it after a reboot.
- Capture on `br-hw4`, not `-i any`, or TShark will show duplicate and retransmitted packets.
- `docker compose exec` fails on a file with no execute permission: run `chmod +x mock_skill.sh`.
- To tear everything down: `docker compose down`.

## AI use

See `AI_USAGE.md` and the conversation log it references.
