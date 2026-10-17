# FreeSwitch + SignalWire Setup — freeswitch2026

**Completed:** 2026-08-06  
**Host VM:** freeswitch2026 at 192.168.100.114 (KVM/QEMU on dell2, 192.168.101.152)  
**FreeSwitch version:** 1.11.1 (SignalWire official Debian Bookworm packages)  
**Replaces:** safarov/freeswitch 1.10.0 container on 192.168.100.128  
**SignalWire phone number:** +16303874223  

---

## Architecture

```
Zoiper SIP client (192.168.100.100, UDP port 55601)
        |
        | SIP/UDP + RTP (LAN — no pfSense rules needed)
        |
FreeSwitch 1.11.1 Docker container (192.168.100.114:5060)
        |
        | SIP/TLS port 6050 (mod_signalwire)
        |
SignalWire cloud trunk ──── PSTN ──── mobile / landline
```

**Key point:** No pfSense NAT/port-forward rules are required for internal SIP clients. The SignalWire trunk on port 6050 (TCP/TLS, outbound from FreeSwitch) does require a pfSense allow rule.

---

## VM Setup

- **Hypervisor:** KVM/QEMU on dell2 (192.168.101.152)
- **Guest OS:** Ubuntu 24.04 (cloud image, cloud-init provisioned)
- **VM image location:** `/home/VMs/` on dell2
- **Networking:** Bridged via `br0` on dell2 — VM gets a real LAN IP via DHCP
- **DHCP lease:** freeswitch2026, 52:54:00:58:70:75, 192.168.100.114
- **SSH:** `ssh -i ~/.ssh/050720id_rsa jkozik@192.168.100.114`

---

## Docker Image

The image is built locally on the VM — it is **not** pushed to Docker Hub.

```bash
# Build (requires a valid SignalWire PAT, passed as a BuildKit secret — NOT --build-arg,
# which records the token in plaintext in `docker history`, confirmed the hard way)
cd ~/projects/freeswitchsignalwire2026
# Store the PAT outside this repo first, e.g. ~/.swenv (chmod 600):
#   export SIGNALWIRE_TOKEN=<your-PAT>
source ~/.swenv
docker build --secret id=signalwire_token,env=SIGNALWIRE_TOKEN -t freeswitch:1.11.1 -t freeswitch:latest .
```

**Why a custom image?** SignalWire/FreeSwitch does not publish an official Docker image. The community image `safarov/freeswitch` was last updated ~2019. This Dockerfile builds directly from SignalWire's official Debian Bookworm package repository, giving a current, maintained install.

**Package repo URL:** `https://files.freeswitch.org/repo/deb/debian-release/`  
(Not `freeswitch.org` — that returns 404.)

**Key packages beyond the base:**
- `freeswitch-mod-signalwire` — SignalWire trunk integration
- `freeswitch-mod-hash` — Required by default dialplan (`default.xml` uses the `hash` application)
- `freeswitch-sounds-en-us-callie` — Callie voice prompts (no `-8000`/`-16000` suffix in package name)

---

## Project Directory Layout

```
~/projects/freeswitchsignalwire2026/
├── Dockerfile                          # Custom FreeSwitch 1.11.1 image
├── entrypoint.sh                       # Fixes ownership of mounted volumes
├── docker-compose.yml                  # Service definition
├── .env                                # Runtime environment variables
├── SETUP.md                            # This file
├── 01_aaSignalWirePSTN.xml             # Source copy of outbound dialplan
├── 01_abSignalWireIncomingFromPSTN.xml # Source copy of inbound dialplan
├── configs/
│   ├── freeswitch/                     # Mounted to /etc/freeswitch in container
│   │   ├── sip_profiles/
│   │   │   ├── internal.xml           # Internal SIP profile (port 5060)
│   │   │   ├── external.xml           # External SIP profile (port 5080)
│   │   │   └── ext-phones-5070.xml    # Extra phones profile
│   │   ├── dialplan/
│   │   │   ├── default/
│   │   │   │   ├── 01_aaSignalWirePSTN.xml          # Outbound PSTN via SignalWire
│   │   │   │   └── 01_abSignalWireIncomingFromPSTN.xml # Inbound PSTN → extension 1001
│   │   │   └── public/
│   │   └── directory/
│   ├── freeswitch-sounds/              # Mounted to /usr/share/freeswitch/sounds
│   └── storage/                        # Mounted to /var/lib/freeswitch/storage
│       └── signalwire-conf.dat         # Auto-provisioned SignalWire credentials
└── logs/                               # Mounted to /var/log/freeswitch
```

---

## docker-compose.yml

```yaml
services:
  freeswitch:
    image: freeswitch:latest
    container_name: freeswitch
    network_mode: "host"        # Required: FreeSwitch needs direct access to LAN for RTP
    cap_add:
      - SYS_NICE               # Allows FreeSwitch to set thread priorities
    env_file: .env
    volumes:
      - ./configs/freeswitch:/etc/freeswitch
      - ./configs/freeswitch-sounds:/usr/share/freeswitch/sounds
      - ./configs/storage:/var/lib/freeswitch/storage
      - ./logs:/var/log/freeswitch
    command: ["freeswitch", "-nonatmap", "-nonat"]
    restart: unless-stopped
```

---

## .env File

```
MYSIGNALWIREPHONENUMBERWITHPLUS=+16303874223
FREESWITCHDEFAULTPASSWORD=12345
RTPSTARTPORT=20000
RTPENDPORT=20100
```

---

## SignalWire Configuration

### mod_signalwire
FreeSwitch connects to SignalWire via `mod_signalwire` which auto-provisions credentials stored in `configs/storage/signalwire-conf.dat`. This file was migrated from the old container on 192.168.100.128 and updated with the new IP/port.

- **SIP profile:** `signalwire` on port 6050 (TLS)
- **Gateway name:** `signalwire` (under profile `signalwire`)
- **SIP domain:** `jkozik-63eecb1e59a343e4b71567f323a71d52.sip.signalwire.com`
- **Status check:** `docker exec freeswitch fs_cli -x 'sofia status gateway'` → should show `REGED`

### SignalWire Dashboard
- **Phone number:** +16303874223
- **Assigned Resource:** "freeswitch 128 080925" (FreeSWITCH Connector) — the connector name reflects the old host but the credentials are what matter; it routes to this FreeSwitch instance.
- **Portal:** app.signalwire.com

### PAT Token
The SignalWire Personal Access Token is needed only at Docker **build** time to download packages. It is not stored in the running container, and — since the switch to BuildKit's `--secret` — not recoverable from `docker history` or any image layer either (verified by exporting the image and grepping every layer). Rotate it at `app.signalwire.com → Profile → Personal Access Tokens`.

---

## Dialplan

### Outbound — `01_aaSignalWirePSTN.xml`
Routes any 11-digit number (e.g., `16302153142`) from internal extensions out through SignalWire to PSTN.

```xml
<extension name="signalwire INTEGRATIONS outgoing call">
  <condition field="destination_number" expression="^(\d{11})$">
    <action application="bridge" data="sofia/gateway/signalwire/+$1"/>
  </condition>
</extension>
```

### Inbound — `01_abSignalWireIncomingFromPSTN.xml`
Routes inbound calls to +16303874223 to Zoiper (extension 1001).

```xml
<extension name="SignalWire INTEGRATIONS incoming call">
  <condition field="destination_number" expression="^(\+16303874223)$">
    <action application="bridge" data="user/1001"/>
  </condition>
</extension>
```

---

## SIP Clients

### Extension 1001 — Zoiper
- **Server:** 192.168.100.114 (or 192.168.100.114:5060)
- **Username:** 1001
- **Password:** 12345 (set via `FREESWITCHDEFAULTPASSWORD` in `.env`, applied in `directory/default/1001.xml`)
- **Transport:** **UDP** (important — see Troubleshooting below)

### Yealink desk phone
Registered directly to FreeSwitch on the internal profile. No special configuration needed beyond pointing at 192.168.100.114.

---

## Day-to-Day Operations

```bash
# SSH to VM
ssh -i ~/.ssh/050720id_rsa jkozik@192.168.100.114

# Container management
cd ~/projects/freeswitchsignalwire2026
docker compose ps
docker compose logs -f --tail=50
docker compose down
docker compose up -d

# FreeSwitch console (from VM)
docker exec -it freeswitch fs_cli

# Useful fs_cli commands
sofia status                          # All SIP profiles and gateways
sofia status profile internal reg     # Registered extensions
sofia status gateway                  # SignalWire gateway status (want: REGED)
show calls                            # Active calls
originate user/1001 &echo             # Test call to extension 1001
reloadxml                             # Reload dialplan without restart
```

---

## Troubleshooting

### SignalWire gateway shows NOREG instead of REGED
1. Check `configs/storage/signalwire-conf.dat` — verify IP is 192.168.100.114 and port is 6050
2. Check logs: `docker compose logs -f | grep -i signalwire`
3. Verify port 6050 TCP is allowed outbound in pfSense

### SIP client registers but doesn't receive calls (RECOVERY_ON_TIMER_EXPIRE)
**Root cause:** FreeSwitch cannot open a new connection back to the SIP client (device firewall blocks incoming connections).

**Fix:** Set the SIP client's transport to **UDP**. With UDP, the client's outgoing REGISTER creates a stateful firewall entry that allows FreeSwitch's INVITE back in — no inbound firewall rule needed.

**Do NOT use TCP transport** for SIP clients on this setup unless you also configure RFC 5626 (SIP Outbound) connection reuse on both ends.

### After rebuilding the Docker image, old container keeps running
`docker compose restart` does not pull the new image. Use:
```bash
docker compose down && docker compose up -d
```

### signalwire-conf.dat owned by root (can't edit)
```bash
sudo sed -i 's/old-value/new-value/' configs/storage/signalwire-conf.dat
```

---

## What's Left / Future Work

- [ ] **Port swaia-google-agent** from 192.168.100.128 to this VM (separate project, separate container — do not disturb the existing instance on .128 until ready)
- [ ] **Git init** this project directory for version control
- [ ] **Rotate SignalWire PAT** — the token used during this migration should be rotated at app.signalwire.com
- [ ] **WebRTC** — pfSense rules for 5066 (WS) and 7443 (WSS) are already in place; FreeSwitch profile has `ws-binding` and `wss-binding` configured
- [ ] **ring_ready** — Consider adding `<action application="ring_ready" data=""/>` before the bridge in the inbound dialplan so PSTN callers hear ringback while Zoiper rings

---

## Migration Notes (for historical reference)

Migrated from `safarov/freeswitch:latest` (FreeSwitch 1.10.0, ~2019) running on 192.168.100.128. That container has been retired. The SignalWire AI agent (`swaia-google-agent` container) remains running on 192.168.100.128 and is unaffected.

Key differences in the new setup:
- FreeSwitch 1.11.1 vs 1.10.0
- Built from official SignalWire Debian packages (not a community Docker image)
- Running on a dedicated VM (Ubuntu 24.04 on KVM) instead of directly on dell1
- RTP port range narrowed to 20000–20100 (sufficient for home use, reduces pfSense exposure)
