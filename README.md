# freeswitch-signalwire

[FreeSwitch](https://signalwire.com/developers/freeswitch) 1.11.1 running in Docker, connected to [SignalWire](https://signalwire.com/) for PSTN inbound and outbound calling. Supports SIP extensions (softphones, desk phones) on a home or small office LAN.

Built from [SignalWire's official Debian Bookworm packages](https://cubepath.com/docs/voip-and-communication/freeswitch-voip-server-installation) — no community Docker images.

<img width="1665" height="929" alt="image" src="https://github.com/user-attachments/assets/60b0ae82-5717-4eba-9fbd-4983ffdaf13b" />


---

## Prerequisites

- A Linux VM or host with Docker and Docker Compose installed
  - Recommended minimum: **4GB RAM + 2GB swap, 40GB+ disk**
- A [SignalWire account](https://signalwire.com) with:
  - A purchased phone number
  - A Personal Access Token (PAT)
  - A FreeSWITCH Connector configured and assigned to your phone number
- SSH access to the VM

---

## Background

Over the last few years, I have been using the [safarov/freeswitch](https://hub.docker.com/r/safarov/freeswitch) docker image to run my freeswitch container.  I found it very usable. 
After attending the [Cluecon 2026 conference](https://www.cluecon.com/post/what-to-expect-cluecon-2026), I decided that I wanted to build my own freeswitch image.  I wanted to build it preconfigured to work with my simple home LAN and integrated with my Signalwire account.  

Note that I already had a working Freeswitch/Signalwire configuration, so some of my setup was done by leverging configuration files I used from my old setup. The normal first install puts a key into the log file; with that key you can make a connection to Signalwire.  Since I already had a key, I leveraged that rather than creating a new one after each docker compose up -d execution.

Also, note that I setup a couple of simple cut/paste test call scripts.  It took awhile to get these setup.  Sorry I had to XXXX-out the dialed digits.  Once you get this working, you know you are setup.

## Architecture

```
┌───────────────────────────┐
│  Zoiper (SIP softphone)    │
│  LAN client                │
└─────────────┬───────────────┘
              │ SIP/UDP :5060
              │ RTP/UDP :20000-20100
              ▼
┌─────────────────────────────────┐
│  FreeSWITCH 1.11.1 (Docker)      │
│  192.168.100.114                 │
│                                  │
│  sofia profile "internal"       │  ← LAN-facing; SIP clients register here
│  sofia profile "signalwire"     │  ← trunk to SignalWire (mod_signalwire)
└─────────────┬───────────────────┘
              │ SIP/TLS :5061 (outbound, FreeSWITCH → SignalWire — no pfSense rule needed)
              │ RTP/UDP :20000-20100 (inbound, SignalWire → FreeSWITCH — pfSense port
              │   forward to .114; see Firewall below)
              ▼
┌─────────────────────────────────┐
│  SignalWire Cloud                │
│  SIP trunk / PSTN gateway        │
└─────────────┬───────────────────┘
              │ PSTN / cellular network
              ▼
┌───────────────────────────┐
│  Mobile phone (PSTN)       │
└───────────────────────────┘
```

No pfSense/NAT rules are needed for the Zoiper↔FreeSWITCH leg — it's LAN-local, and FreeSWITCH
reuses the client's own outbound registration to send calls back (see
[Troubleshooting](#troubleshooting) for why UDP transport matters here). The SignalWire trunk's
two legs are different: the signaling (outbound TCP 5061) doesn't need a rule either, as long as
pfSense's default LAN-to-any rule is still in place — but the RTP media (inbound UDP
20000-20100) does need a real NAT port forward. See [Firewall](#firewall) below for why.

## Installation

### 1. Clone the repository

```bash
git clone <this-repo> ~/projects/freeswitchsignalwire2026
cd ~/projects/freeswitchsignalwire2026
```

### 2. Create the `.env` file

```bash
cp .env.example .env
```

Edit `.env` with your values:

```
MYSIGNALWIREPHONENUMBERWITHPLUS=+16305551234   # Your SignalWire DID
MYMOBILEPHONENUMBERWITHPLUS=+16305557890       # Your mobile — used by the restricted dialplan context, see below
ESLPASSWORD=changeme                           # Event Socket (port 8021) admin password
RTPSTARTPORT=20000                             # RTP port range start
RTPENDPORT=20100                               # RTP port range end
```

> Per-extension SIP passwords are not set here — see [Restricted extensions](#restricted-extensions) below.

> **Note:** The SignalWire PAT is only needed at build time (see step 3). It does not go in `.env`.

> **How secrets reach FreeSWITCH:** FreeSWITCH's XML config can't read OS environment variables
> directly. `entrypoint.sh` generates `configs/freeswitch/vars.local.xml` (gitignored) from `.env`
> every time the container starts, and `vars.xml` includes it. The checked-in
> `vars.local.xml.template` has only placeholder tokens — never real values. If you edit `.env`,
> you need a container restart (`docker compose down && docker compose up -d`, not `restart`) for
> the new values to take effect; if you edit `entrypoint.sh` itself, you need a rebuild (step 3).

### 3. Build the Docker image

Pass your SignalWire PAT as a BuildKit secret, not `--build-arg` (see `NOTES.md` for why). Store
it outside this repo — e.g. `~/.swenv` (never inside the project directory), `chmod 600`:

```bash
# ~/.swenv
export SIGNALWIRE_TOKEN=pat_yourTokenHere
```

Then build:

```bash
source ~/.swenv
docker compose build
```

`docker-compose.yml` wires the service's `build:` to the same BuildKit secret
(`id=signalwire_token,env=SIGNALWIRE_TOKEN`) via its top-level `secrets:` block — it still reads
`SIGNALWIRE_TOKEN` from your shell environment, never from `.env`, so `docker compose build` and
plain `docker build --secret ...` are equivalent. This pulls FreeSwitch packages from
`files.freeswitch.org` using your PAT.

### 4. Configure the SignalWire connector

FreeSwitch connects to SignalWire via `mod_signalwire`. On first start, it needs a provisioned `signalwire-conf.dat` file in `configs/storage/`.

**Option A — fresh provisioning (new installation):**

1. Start the container once:
   ```bash
   docker compose up -d
   docker compose logs -f
   ```
2. Watch the logs for a provisioning URL like:
   ```
   NOTICE  mod_signalwire  Visit https://app.signalwire.com/... to activate
   ```
3. Open that URL in your browser and log in to your SignalWire account to authorize the connector.
4. The container will write `configs/storage/signalwire-conf.dat` automatically.

**Option B — migrate from an existing FreeSwitch instance:**

```bash
# Copy signalwire-conf.dat from the old container
docker cp old-freeswitch:/var/lib/freeswitch/storage/signalwire-conf.dat \
  configs/storage/signalwire-conf.dat

# Update the IP address to the new host
sudo sed -i 's/OLD_IP/NEW_IP/g' configs/storage/signalwire-conf.dat
```

### 5. Assign the phone number in the SignalWire dashboard

1. Log in to [app.signalwire.com](https://app.signalwire.com)
2. Go to **Phone Numbers** → select your DID
3. Under **Inbound Settings**, set **Assigned Resource** to your FreeSWITCH Connector
4. Save

### 6. Start FreeSwitch

```bash
docker compose up -d
docker compose logs -f
```

Wait for the log line:
```
NOTICE  mod_signalwire  FreeSWITCH is connected to SignalWire
```

---

## SIP Client Setup

### Recommended: Zoiper (softphone)

1. Download [Zoiper](https://www.zoiper.com) for your platform
2. Add a SIP account:
   - **Domain:** `<VM-IP>` (e.g., `192.168.100.114`)
   - **Username:** `1001`
   - **Password:** look up `1001` in `configs/storage/extension-passwords.txt` (gitignored; not in `.env`)
   - **Transport:** **UDP** (required — see Troubleshooting)
3. Save and register — the status should turn green

### Yealink / other desk phones

Point the phone at the same server IP with the same extension credentials. UDP transport is recommended.

---

## Restricted extensions

Extensions `1000` and `1002`–`1019` are **spares**, kept around specifically so you can plug in a new ATA
or softphone and test it without fear of toll fraud if something's misconfigured. Extension `1001` is the
one live extension with full calling.

**Why this is safe to leave wide open for testing:** the spare extensions have `user_context=restricted`
(set in `configs/freeswitch/directory/default/*.xml`) instead of `default`. The `restricted` context
(`configs/freeswitch/dialplan/restricted.xml`) only routes to three things:

- your mobile number (`MYMOBILEPHONENUMBERWITHPLUS` in `.env`)
- your own SignalWire DID (`MYSIGNALWIREPHONENUMBERWITHPLUS` in `.env`) — good for an echo/loopback test
- other internal `100X` extensions

There is no route to the SignalWire trunk for any other number, so a half-configured device can register,
place a real test call to your own phone, and call other test extensions — but it can't dial out to
anywhere else even if it tries.

**To set up a new ATA or softphone:**

1. Pick an unused spare extension number (e.g. `1005`) and its password from
   `configs/storage/extension-passwords.txt` (generated, gitignored — regenerate and update this file if
   you ever need to rotate a password).
2. Register the device with that extension and password.
3. Test: call your mobile number or your SignalWire DID directly from the device.

**To promote a spare extension to full/normal calling** once it's confirmed working, edit
`configs/freeswitch/directory/default/<ext>.xml`:

```xml
<variable name="user_context" value="default"/>          <!-- was: restricted -->
<variable name="toll_allow" value="domestic,international,local"/>  <!-- was: local -->
```

Then `docker exec freeswitch fs_cli -p "$ESL_PW" -x 'reloadxml'` (see [Verification Tests](#verification-tests) for `$ESL_PW`). To demote it back to a spare, reverse both lines.

---

## Firewall

No inbound NAT rules are needed for LAN SIP clients. FreeSwitch receives their registrations and reuses the network path to send calls back.

**The SignalWire trunk's two ports behave differently, and only one of them needs a real rule:**

- **Signaling — outbound TCP 5061 (SIP/TLS, `mod_signalwire`).** No explicit pfSense rule is
  actually needed, as long as pfSense's default LAN rule ("LAN net to any") is still in place.
  FreeSWITCH is the one that dials out and keeps this connection registered — SignalWire never
  connects in — so the default allow-outbound rule's statefulness covers the return signaling
  traffic. (This is TCP 5061, confirmed from a live connection via `ss` — not the `6050` that
  `sofia status` shows, which is only FreeSWITCH's own local bind port; see `NOTES.md`.) Confirmed
  in practice: no rule for this port exists in this deployment's pfSense config, and the trunk
  still registers fine. This only becomes relevant if LAN egress is ever locked down beyond the
  default — if so, add a LAN **pass** rule (not NAT), destination `any` (SignalWire's docs say not
  to firewall by their IPs since they can change):

  | Direction | Protocol | Port | Purpose |
  |-----------|----------|------|---------|
  | Outbound  | TCP      | 5061 | SignalWire SIP/TLS trunk signaling (mod_signalwire) |

- **Media — inbound UDP 20000–20100 (RTP), `RTPSTARTPORT`–`RTPENDPORT` from `.env`.** This one
  **is** a real, required NAT **port forward**, not a pass rule, and it's already in place on
  this deployment (pfSense: `WAN UDP 20000-20100` → `192.168.100.114:20000-20100`). Unlike
  signaling, RTP is a fresh connectionless flow per call, and the signaling-channel reasoning
  above doesn't apply: SignalWire's media server, not FreeSWITCH, is often the side that sends the
  first packet on a given call's RTP flow (e.g. ringback/early audio on an inbound PSTN call,
  before your extension has answered) — a stateful firewall drops that first inbound packet if
  nothing already forwards it. Confirmed this is load-bearing, not leftover: `signalwire-conf.dat`
  has `ext-rtp-ip`/`ext-sip-ip` explicitly set to the WAN's public IP rather than `.114`'s LAN
  IP — FreeSWITCH is deliberately advertising its public address in SDP to SignalWire, which only
  works if this forward exists. Doesn't touch the container or any file in this repo — it's a
  firewall-only rule, keyed off the same `RTPSTARTPORT`/`RTPENDPORT` range `.env` already defines:

  | Direction | Protocol | Port        | Purpose |
  |-----------|----------|-------------|---------|
  | Inbound   | UDP      | 20000-20100 | RTP media for the SignalWire trunk (NAT port forward to the FreeSWITCH host) |

Optional (future WebRTC support):

| Direction | Protocol | Port | Purpose |
|-----------|----------|------|---------|
| Inbound   | TCP      | 5066 | SIP over WebSocket (WS) |
| Inbound   | TCP      | 7443 | SIP over Secure WebSocket (WSS) |

---

## Operational notes

- **fail2ban + APIBAN** run directly on the host (not in Docker) to block SIP abuse. Check status
  with `fail2ban-client status`. See `NOTES.md` for why and how they're configured.
- **Zabbix monitoring** reports from an agent on the host. See
  [`zabbix/README.md`](zabbix/README.md) for the full setup.
- `configs/freeswitch/dialplan/public.xml` has two stock demo extensions deliberately disabled
  (they allowed unauthenticated dial-in) — see the comment in that file before re-enabling them.

---

## Verification Tests

Run these from the VM after the container is up.

Every `fs_cli` command below needs `-p <ESL password>`. This isn't something added on top —
FreeSWITCH's Event Socket (ESL, port 8021) always requires a password; the security decision made
here was replacing the module's stock default (`ClueCon`, identical on every FreeSWITCH install
everywhere) with a strong random one, and restricting ESL to loopback-only connections
(`apply-inbound-acl=loopback.auto`) so it's reachable only from inside the container/VM, never
the LAN. That's also why these commands only work run locally, not from another LAN machine. The
password is in `configs/storage/esl-password.txt` (gitignored, not in `.env`). To save retyping it:

```bash
ESL_PW=$(sudo head -1 configs/storage/esl-password.txt)
```

### Check FreeSwitch is running

```bash
docker compose ps
# Expected: freeswitch   running
```

### Check SignalWire gateway is registered

```bash
docker exec freeswitch fs_cli -p "$ESL_PW" -x 'sofia status gateway'
```

Expected output includes:
```
signalwire::signalwire   ...   REGED
```

If it shows `NOREG`, check `configs/storage/signalwire-conf.dat` and the container logs.

### Check SIP extensions are registered

```bash
docker exec freeswitch fs_cli -p "$ESL_PW" -x 'sofia status profile internal reg'
```

Expected output lists your registered phones with status `Registered(UDP)`.

### Test internal call (FreeSwitch → SIP client)

```bash
docker exec freeswitch fs_cli -p "$ESL_PW" -x 'originate user/1001 &echo'
```

Your SIP client should ring. Answer it — you should hear your own voice echoed back. `+OK` in the terminal confirms the call connected.

### Test outbound call (FreeSwitch → PSTN via SignalWire)

```bash
docker exec freeswitch fs_cli -p "$ESL_PW" -x \
  'originate {origination_caller_id_number=+1NPANXXXXXX}sofia/gateway/signalwire/+1NPANXXXXXX &echo'
```

Replace `+1NPANXXXXXX` with your SignalWire DID (caller ID) and a mobile number to call. Your mobile should ring; answer it and you should hear echo. `+OK` confirms success.

Or skip reconstructing that command from memory: `./scripts/test-pstn-call.sh` does the same thing,
reading your DID and mobile number from `.env` automatically.

### Test inbound call (PSTN → SIP client)

Call your SignalWire DID from any phone. Your registered SIP client (extension 1001) should ring.

---

## Troubleshooting

**SIP client registers but never receives calls**
Set the client's transport to **UDP**. TCP requires an inbound connection from FreeSwitch to the client, which a device firewall typically blocks. UDP uses the existing outbound registration flow and avoids this.

**Gateway shows NOREG after restart**
Run `docker compose down && docker compose up -d` (not `restart`) to ensure the new image and config are loaded. Check that port 5061 outbound is not blocked by your firewall (see [Firewall](#firewall)).

**`-ERR INVALID_GATEWAY` on originate**
The gateway name is `signalwire` (lowercase). Verify with `sofia status gateway`.

**`-ERR RECOVERY_ON_TIMER_EXPIRE` on originate**
FreeSwitch cannot reach the SIP client. Check the client's transport setting (UDP), verify it is still registered (`sofia status profile internal reg`), and re-register the client if needed.

**Dialplan changes not taking effect**
```bash
docker exec freeswitch fs_cli -p "$ESL_PW" -x 'reloadxml'
```
