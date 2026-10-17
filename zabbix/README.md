# Zabbix Agent (Agent 1) — FreeSWITCH monitoring

This directory is a **record**, not an installer. It's a snapshot of everything on the
`freeswitch2026` host related to Zabbix monitoring, kept here so a future migration to a new
server has enough detail to rebuild it by hand — copy files to the listed destinations, set the
listed ownership/permissions, done. No setup script is provided on purpose.

**Scope:** agent side only. Zabbix Items, Triggers, and Value Maps live on the Zabbix
server/proxy and are not covered here — see the "Server-side reference" table at the bottom for
what to recreate there.

---

## Fleet conventions this host follows

Modeled on an existing reference host (`knode208`, IP `192.168.100.208`) in the same Zabbix
deployment:

- **Zabbix Agent 1** (package `zabbix-agent`, not `zabbix-agent2`), official Zabbix repo, channel
  `7.4/stable`, Ubuntu `noble` (24.04).
- **Hostname convention:** `<short-hostname>.kozik.net` — this host is `freeswitch2026.kozik.net`.
- **PSK is shared fleet-wide**, not per-host: identity `PSK 001` and one shared key value used
  across every host in the fleet. This is a deliberate choice on this fleet (confirmed with the
  fleet owner), not a security best-practice default — a from-scratch setup elsewhere might
  reasonably choose per-host PSKs instead.
- **`AllowKey=system.run[*]` is deliberately NOT set on this host**, unlike the reference host.
  This deployment only needs the specific UserParameters below, not open remote-command
  execution — don't add it without a specific reason.
- **`ServerActive=127.0.0.1` is copied from the fleet convention but does not actually work** —
  nothing listens on `127.0.0.1:10051` on this host or the reference host. Active checks fail
  silently (see the agent log); only passive checks (`Server=`) matter here. Kept for fleet
  consistency, not because it's functional.

---

## Install steps (package + repo)

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.zabbix.com/zabbix-official-repo.key | sudo gpg --dearmor -o /etc/apt/keyrings/zabbix.gpg
sudo cp zabbix-repo.list /etc/apt/sources.list.d/zabbix.list
sudo apt-get update
sudo apt-get install -y zabbix-agent zabbix-get   # zabbix-get is optional, useful for testing
```

`zabbix-repo.list` in this directory → `/etc/apt/sources.list.d/zabbix.list` (root:root, 644).

---

## Files in this directory and where they go

| File here | Destination on host | Owner:Group | Mode | Purpose |
|---|---|---|---|---|
| `scripts/fs_cli_zabbix.sh` | `/usr/local/bin/fs_cli_zabbix.sh` | `root:root` | `750` | The **only** thing with ESL-password access. Whitelist-only dispatcher — see "Access model" below. |
| `scripts/freeswitch-check-gateway.sh` | `/usr/local/bin/freeswitch-check-gateway.sh` | `root:root` | `755` | UserParameter backing script: `freeswitch.gateway.state` |
| `scripts/freeswitch-check-ext1001.sh` | `/usr/local/bin/freeswitch-check-ext1001.sh` | `root:root` | `755` | UserParameter backing script: `freeswitch.ext1001.registered` |
| `scripts/freeswitch-check-changeme.sh` | `/usr/local/bin/freeswitch-check-changeme.sh` | `root:root` | `755` | UserParameter backing script: `freeswitch.secrets.placeholder_detected` |
| `scripts/freeswitch-check-loopback.sh` | `/usr/local/bin/freeswitch-check-loopback.sh` | `root:root` | `755` | UserParameter backing script: `freeswitch.loopback.ok` |
| `zabbix_agentd.d/freeswitch.conf` | `/etc/zabbix/zabbix_agentd.d/freeswitch.conf` | `root:root` | `644` | The 4 `UserParameter=` definitions, picked up via the stock config's `Include=` directive |
| `sudoers.d/zabbix-freeswitch` | `/etc/sudoers.d/zabbix-freeswitch` | `root:root` | `440` | Scoped sudo rule — see "Access model" below. **Validate with `sudo visudo -c -f <file>` before installing**, and always `chmod 440` (sudoers refuses looser permissions). |
| `zabbix_agentd.conf.active-directives.txt` | *(not a direct copy — see below)* | — | — | The specific directives that differ from the stock `zabbix_agentd.conf` template |

**`zabbix_agentd.conf.active-directives.txt` is not meant to replace the whole config file.**
`zabbix_agentd.conf` itself comes from the package (a ~500-line heavily-commented template); only
these specific directives were changed or added. On a new host: install the package fresh, then
edit its stock `/etc/zabbix/zabbix_agentd.conf` to set/add exactly these lines (adjusting
`Hostname=` for the new host's name):

```
Server=192.168.100.0/24
ServerActive=127.0.0.1
Hostname=freeswitch2026.kozik.net
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=PSK 001
TLSPSKFile=/etc/zabbix/zabbix_agentd.psk
```
(`PidFile`, `LogFile`, `LogFileSize`, and `Include` are already correct at their stock defaults —
listed in the full active-directives file for completeness, not because they need changing.)

After any config change: `sudo systemctl restart zabbix-agent` (UserParameter/config changes need
a restart; there's no live reload the way FreeSWITCH has `reloadxml`).

---

## NOT included here: the PSK itself

`/etc/zabbix/zabbix_agentd.psk` (the actual shared secret, `zabbix:zabbix` `640`) is **deliberately
not copied into this directory** — this project directory is intended to eventually go into git,
and this is a real fleet-wide credential. On migration, provision it out-of-band (copy directly
host-to-host over SSH, or however you'd move any other fleet secret) — never through this repo.

---

## Access model — why it's built this way

The `zabbix` user needs to (a) read the ESL password and (b) run `docker exec` against the
FreeSWITCH container. Neither is given directly:

- **Not added to the `docker` group** — that's effectively host-root-equivalent access (you can
  bind-mount arbitrary host paths into a container and escalate). Too broad for what's needed.
- **Root-owned wrapper + scoped `sudoers` NOPASSWD rule instead**: `zabbix` can run
  `/usr/local/bin/fs_cli_zabbix.sh` as root, nothing else.
- **The wrapper itself is a whitelist of check *names*, not a pass-through for arbitrary `fs_cli`
  commands.** This matters because FreeSWITCH's `system` API can shell out — if the wrapper
  accepted any command string, a compromised `zabbix` account (or agent) could pass one through
  and get a shell escape via FreeSWITCH itself. New checks are added as new `case` arms in the
  script, never as free-form pass-through.
- The ESL password is read from `configs/storage/esl-password.txt` in the main project directory
  (gitignored — see the project's own README/`.gitignore`). **This is a hard dependency**: if that
  file moves or its format changes, `fs_cli_zabbix.sh`'s `ESL_PW_FILE` path needs updating.

---

## Dependency outside this directory

`freeswitch.loopback.ok` depends on a dedicated dialplan extension that lives in the *main*
FreeSWITCH config (already git-tracked there, not duplicated here):
`configs/freeswitch/dialplan/default/01_acZabbixHealthcheck.xml` — a no-ring extension on `9999`
that answers, holds briefly, and hangs up on its own, specifically so this hourly check never
rings a real phone (extension 1001 is a real desk phone/softphone).

---

## Post-install verification

Same commands used to build and test each check originally — run these after installing on a new
host, in order:

```bash
# 1. Agent itself answers (adjust host IP/PSK as needed)
zabbix_get -s <host-ip> -p 10050 --tls-connect=psk --tls-psk-identity="PSK 001" \
  --tls-psk-file=<(sudo cat /etc/zabbix/zabbix_agentd.psk) -k agent.ping

# 2. The zabbix user can reach FreeSWITCH through the wrapper
sudo -u zabbix sudo -n /usr/local/bin/fs_cli_zabbix.sh gateway_status

# 3. Each UserParameter, both directly and through the real TLS-PSK path
sudo -u zabbix /usr/local/bin/freeswitch-check-gateway.sh
zabbix_get -s <host-ip> -p 10050 --tls-connect=psk --tls-psk-identity="PSK 001" \
  --tls-psk-file=<(sudo cat /etc/zabbix/zabbix_agentd.psk) -k freeswitch.gateway.state
# repeat for freeswitch.ext1001.registered, freeswitch.secrets.placeholder_detected, freeswitch.loopback.ok
```

If `zabbix_get` from `127.0.0.1` fails with "unencrypted connections are not allowed" or an ACL
rejection, query the host's real LAN IP instead — `Server=192.168.100.0/24` rejects `127.0.0.1` as
an unrecognized source, which is expected, not a bug.

---

## Server-side reference (not set up by anything in this directory)

For recreating Items/Triggers/Value Maps on a new Zabbix server:

| UserParameter key | Meaning | Polarity | Suggested interval |
|---|---|---|---|
| `freeswitch.gateway.state` | SignalWire trunk registration | 1=REGED (good), 0=NOREG | 1m |
| `freeswitch.ext1001.registered` | Extension 1001 SIP registration | 1=Registered (good), 0=Not registered | 1m |
| `freeswitch.secrets.placeholder_detected` | Did secrets-templating silently fail? | **1=BAD (placeholder found)**, 0=Healthy — inverted from the others | 5m |
| `freeswitch.loopback.ok` | Real test call through the dialplan | 1=succeeded (good), 0=failed | 1h — this one places an actual call each poll |
