# Project notes

Historical record of non-obvious decisions, incidents, and gotchas hit while building this out.
Not needed to install or operate the system — see `README.md` for that. This file exists so none
of this has to be re-discovered or re-explained a year from now.

---

## Secrets handling

**Why the SignalWire PAT is a BuildKit secret, not `--build-arg`.** The original Dockerfile used
`ARG SIGNALWIRE_TOKEN` and referenced it directly in `RUN` commands. Docker's own linter flags this
(`SecretsUsedInArgOrEnv`) — confirmed the hard way: `docker history --no-trunc freeswitch:latest`
showed the token in plaintext. Fixed with `--mount=type=secret`, which never touches a layer.

One subtlety that made this more than a one-line swap: `/etc/apt/auth.conf` (plaintext token, needed
by `apt` itself) was being created in one `RUN` step and `rm -f`'d in a *later* one. Docker layers
are additive — a file deleted in a later layer is still recoverable from the earlier layer that
created it (`docker save` + untar). The fix merges the GPG-key-fetch, `auth.conf` write, `apt-get
install`, and `auth.conf` removal into **one** `RUN` instruction, so the file's entire lifecycle
never appears in any layer's diff. Verified by exporting the built image and grepping every layer
for the token — zero hits.

**Where the PAT itself should live:** outside the repo entirely, e.g. `~/.swenv` (`chmod 600`,
`export SIGNALWIRE_TOKEN=...`), sourced manually right before a build. Never `.bashrc` — that
auto-loads into every shell, far broader exposure than a build needs.

**How FreeSWITCH gets `.env` values at all.** FreeSWITCH's XML config can't read OS environment
variables directly — `${env(VARNAME)}` only evaluates inside live call/dialplan processing, not in
static module settings, and doesn't work even in the generic `eval` API outside a call context
(confirmed empirically, not assumed). The actual mechanism: `entrypoint.sh` runs a `sed` pass at
every container start, filling in `configs/freeswitch/vars.local.xml.template`'s `__TOKEN__`
placeholders from `.env` and writing the gitignored `vars.local.xml`, which `vars.xml` includes via
`$${var}` (double-dollar — FreeSWITCH's XML-preprocessor substitution, a genuinely different
mechanism from the single-dollar runtime function, and the one that actually works for this).
Per-extension passwords follow the same pattern from `configs/storage/extension-passwords.txt` (the
source of truth, not `.env`) into `ext-passwords.local.xml` via an `awk` pass.

**A bug that stayed hidden for a month**, found the first time the image was actually rebuilt after
this logic was written: that `awk` pass used `/^1[0-9]{3}$/` (an `{n}` interval), which the
container's `mawk` silently fails to match at all — while the *host's* `awk` matched it fine, which
is exactly why testing on the host never caught it. Fixed by spelling out `[0-9][0-9][0-9]`
(portable across both). Also added a sanity check to `entrypoint.sh`: if the generated file has
fewer than 1 entry, the container refuses to boot rather than silently running every extension on
its placeholder password.

---

## The September 2026 SIP flood incident

A single IP (`117.55.202.187`, with a second IP sending related INVITEs) flooded the `ext-phones-5070`
profile with ~220 SIP registration attempts/second against random nonexistent extension numbers.
212,420 attempts in 16 minutes generated enough `WARNING`-level log volume to fill the VM's 19GB
root disk and lock the box out entirely.

Verified afterward that nothing in the attack actually succeeded — zero successful registrations,
zero answered/bridged calls, across the entire log. One extension ID the attacker tried (`1014`)
happened to be real, but the REGISTER request used the wrong domain (the external IP instead of the
real configured domain), so it still failed at the directory-lookup stage, before ever reaching a
password check.

**Response:**
- Immediate: blocked both IPs with `iptables`, then installed `iptables-persistent` (the manual
  block wouldn't have survived a reboot otherwise).
- VM resized: 1.9GB RAM/no swap/19GB disk → 3.8GB RAM/2GB swap/43GB disk. The cloud image
  auto-grew the partition on first boot; no manual `growpart`/`resize2fs` needed.
- `logfile.conf.xml`'s file-logging map trimmed from `console,debug,info,notice,warning,err,crit,alert`
  down to `info,warning,err,crit,alert`, and `maximum-rotate` cut from 32 to 8 — still allows a
  determined flood to generate real volume (which is exactly what prompted fail2ban below), but
  caps the worst case well under the resized disk.
- `fail2ban` and `APIBAN` installed (detail below) — this is the fix that actually matters, since it
  stops a flood within a few hundred milliseconds instead of letting it run for 16 minutes.
- A second, independent finding surfaced while investigating the same attacker's numeric range:
  `configs/freeswitch/dialplan/public.xml` had two stock FreeSWITCH demo extensions
  (`public_extensions`, `public_conference_extensions`) that let *any* unauthenticated internet
  caller ring an internal extension directly — no registration or password needed at all, via
  INVITE rather than REGISTER. This incident's attacker never happened to trigger it (confirmed:
  no INVITE ever matched the pattern), but given they were probing in exactly that range, it was
  disabled rather than left as a standing gap. The real SignalWire inbound path doesn't use this
  context at all — `mod_signalwire`'s own gateway profile is configured with `context=default`
  directly, since it's FreeSWITCH's own outbound-registered connection, not anonymous inbound SIP.

---

## fail2ban

Three jails, all on the host (not in Docker — they need direct access to the host firewall):

- **`freeswitch-sip`** — custom filter matching `sofia_reg.c:3210 Can't find user [...@...] from
  <HOST>` (the exact pattern from the incident above). This line can only ever fire for a
  registration attempt against a nonexistent user/domain, so false positives are effectively
  impossible — settings are deliberately aggressive: `maxretry=3, findtime=60, bantime=86400` (24h).
  Reads directly from `logs/freeswitch.log` (the bind-mounted host file), not through `docker logs`.
- **`sshd`** — Ubuntu's stock jail, already enabled by default on install. Less aggressive
  (`maxretry=5, findtime=600, bantime=600`) since SSH, unlike the SIP filter, has real
  false-positive risk from a legitimate mistyped password.
- **`apiban`** — a dedicated no-op jail (empty `failregex`, never triggered by log scanning) that
  exists purely as a target for the `apiban-fail2ban` client's external `banip` calls, kept separate
  from `freeswitch-sip` specifically so `fail2ban-client status` can distinguish "APIBAN already
  knew about this IP" from "our own detection caught this."

**Two gotchas hit setting this up, worth remembering if a jail ever silently does nothing:**
1. `backend = auto` (the global default) silently chose the `systemd` journal backend for the
   `freeswitch-sip` jail and completely ignored `logpath` — zero detections despite a provably
   correct filter, because FreeSWITCH's logs go through Docker's `json-file` driver, never the
   journal. Fixed with an explicit `backend = polling`.
2. `iptables-allports` means all *ports*, not all *protocols* — its actual default is
   `protocol = tcp`, silently excluding UDP, which is what SIP flooding actually uses. Confirmed via
   `iptables -L INPUT` showing the jump rule as `prot 6` (TCP only) while packets kept getting
   through. Fixed with `action = iptables-allports[name=..., protocol="tcp,udp"]`.

Check status: `fail2ban-client status` / `fail2ban-client status <jail>`. Config in
`/etc/fail2ban/jail.d/` and `/etc/fail2ban/filter.d/` on the host — not in this repo.

## APIBAN

Proactive layer, complementary to fail2ban rather than redundant with it: fail2ban is reactive
(reacts to what's already hit this box), APIBAN blocks a community threat-intel feed of IPs already
known to attack SIP systems elsewhere, before they ever probe this one.

Uses the official `apiban-fail2ban` client (feeds the `apiban` jail above, not a separate iptables
mechanism), installed to `/usr/local/bin/apiban/`, config scoped to `set=sip` (not `all`), running
via a systemd timer every 5 minutes. API key tied to the account that requested it at apiban.org.

Notable: the two real attacker IPs from the incident above were *not* already on APIBAN's list — so
APIBAN wouldn't have prevented that specific incident, but the box is now protected against every
other IP the feed already knows about (over a thousand and growing).

---

## Monitoring

Zabbix Agent 1 installed directly on the host VM (not in Docker, for the same "needs host-level
access" reason as fail2ban). Full agent-side install record — exact file paths, ownership,
permissions, the access model — lives in [`zabbix/README.md`](zabbix/README.md); that's the file to
read before migrating this to a new server. This file just covers the "why":

- The **access model** matters: the `zabbix` user is never added to the `docker` group (that's
  effectively host-root-equivalent) and never sees the ESL password directly. It can only run one
  root-owned wrapper script via a narrowly-scoped `sudoers` rule, and that wrapper is a **whitelist
  of check names**, not a pass-through for arbitrary `fs_cli` commands — because FreeSWITCH's
  `system` API can shell out, so an unrestricted pass-through would be a shell-escape path for a
  compromised agent.
- Four FreeSWITCH-specific checks: `freeswitch.gateway.state` (trunk registered), `freeswitch.ext1001.registered`
  (the live extension), `freeswitch.secrets.placeholder_detected` (did the `entrypoint.sh` templating
  above silently fail — inverted polarity from the other two, 1=bad not 1=good), and
  `freeswitch.loopback.ok` (an hourly real test call through a dedicated no-ring extension, `9999`,
  that never touches extension 1001 — proving registration + dialplan + RTP all work without ringing
  a real phone).
- Standard OS-level checks (disk, CPU, memory) come from Zabbix's own stock Linux template, already
  linked to the host — no custom disk-usage item was needed; this is what actually caught the
  September incident.
- Value Mapping is used on every custom item specifically so the dashboard shows "REGED (registered)"
  instead of bare `1` — a deliberate style choice, not a default.

---

## The firewall port that wasn't

**`sofia status`/`sofia status profile signalwire` reports port 6050 for the `signalwire`
profile — but that's not the port that ever hits the wire to SignalWire.** 6050 is only
FreeSWITCH's own *local* bind port for that sofia profile (`TLS-BIND-URL
sips:mod_sofia@<ext-ip>:6050;...`). The actual outbound connection the registered gateway makes
to SignalWire's cloud (`jkozik-....sip.signalwire.com`) runs on TCP **5061** (standard SIP-TLS)
— confirmed 2026-10-17 by inspecting a live connection with `ss -tnp` on the host and finding the
`freeswitch` process's real `ESTAB` socket, not by reading any config file or doc. Every doc in
this repo (README.md, SETUP.md) had the wrong port (6050) until this was caught — written down
originally straight from `sofia status` output without checking what actually left the box.

Also worth remembering: SignalWire's SIP domain resolves to multiple IPs (seen:
`159.65.244.171`, `152.42.144.114`), and their own docs say not to firewall by IP since they can
change — the pfSense rule should match on destination port only, destination `any`.

This is the same "verify, don't trust the name/default" category this project keeps hitting (see
the fail2ban section above) — a seventh instance, if anyone's counting.

**Follow-up, same day: turns out no explicit pfSense rule was ever needed for either port.**
Checked the live pfSense ruleset — no rule exists for 6050 or 5061 — and the trunk still registers
and places calls. pfSense's default "LAN net to any" rule already permits this outbound traffic
(both the TLS signaling and the RTP media, same `RTPSTARTPORT`–`RTPENDPORT` range as LAN calls,
no per-gateway range), and being a stateful firewall, the same rule's state table covers the
return traffic — nothing SignalWire sends back is a *new* inbound connection. An explicit LAN pass
rule only becomes necessary if LAN egress is ever restricted beyond that default; README.md and
SETUP.md document what that rule would look like, framed as conditional rather than required.

---

## Repo hygiene notes

- `01_aaSignalWirePSTN.xml` and `01_abSignalWireIncomingFromPSTN.xml` exist both at the project root
  and in `configs/freeswitch/dialplan/default/` — confirmed byte-identical, confirmed nothing in this
  repo (no script, no Dockerfile step) reads from the root copies. Left in place at the user's
  request pending manual review of why they were created.
- `configs/freeswitch/config.FS0` is a harmless stock fax-config template (note the
  `+1.800.555.1212` placeholder number) — not real data, not referenced by anything active here.
- The real SignalWire DID appears in plaintext in `SETUP.md` and in the real inbound-routing
  dialplan file (where it's functionally required — that's the match pattern that routes inbound
  calls to extension 1001). Not an exploitable secret, but a real personal phone number; left as-is
  by choice, not oversight.
