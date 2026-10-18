FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# --- Base dependencies ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        gnupg2 \
        wget \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# --- Add SignalWire FreeSwitch package repo + install FreeSwitch and modules ---
# Docs: https://freeswitch.org/confluence/display/FREESWITCH/Debian+12+Bookworm
#
# SIGNALWIRE_TOKEN is a build-time-only secret (a SignalWire Personal Access
# Token — app.signalwire.com → profile → Personal Access Tokens), passed via
# BuildKit's secret mount, NOT --build-arg:
#   docker build --secret id=signalwire_token,env=SIGNALWIRE_TOKEN ...
#
# This whole block is deliberately ONE RUN instruction, not several. BuildKit
# secret mounts never touch a layer, so that part alone would be enough to
# keep the token out of `docker history` — but /etc/apt/auth.conf (which
# apt needs in plaintext to authenticate) is a real file, and a file written
# in one RUN and rm'd in a LATER one is still recoverable from the earlier
# layer (Docker layers are additive; `docker save` + untar can read it back).
# Keeping auth.conf's entire lifecycle — create, use, delete — inside this
# single RUN means it never appears in any layer's diff at all. Confirmed
# empirically (2026-09-09) that the old ARG-based version leaked the token
# into `docker history --no-trunc`; this is the fix for both halves of that.
RUN --mount=type=secret,id=signalwire_token,required=true \
    SIGNALWIRE_TOKEN="$(cat /run/secrets/signalwire_token)" && \
    wget --quiet \
        --http-user=signalwire \
        --http-password="${SIGNALWIRE_TOKEN}" \
        -O /usr/share/keyrings/signalwire-freeswitch-repo.gpg \
        https://files.freeswitch.org/repo/deb/debian-release/signalwire-freeswitch-repo.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] \
        https://files.freeswitch.org/repo/deb/debian-release/ bookworm main" \
        > /etc/apt/sources.list.d/freeswitch.list && \
    echo "machine files.freeswitch.org login signalwire password ${SIGNALWIRE_TOKEN}" \
        > /etc/apt/auth.conf && \
    chmod 600 /etc/apt/auth.conf && \
    apt-get update && apt-get install -y --no-install-recommends \
        freeswitch \
        freeswitch-mod-commands \
        freeswitch-mod-console \
        freeswitch-mod-logfile \
        freeswitch-mod-sofia \
        freeswitch-mod-signalwire \
        freeswitch-mod-dialplan-xml \
        freeswitch-mod-dptools \
        freeswitch-mod-voicemail \
        freeswitch-mod-loopback \
        freeswitch-mod-sndfile \
        freeswitch-mod-native-file \
        freeswitch-mod-tone-stream \
        freeswitch-mod-opus \
        freeswitch-mod-g723-1 \
        freeswitch-mod-g729 \
        freeswitch-mod-local-stream \
        freeswitch-mod-event-socket \
        freeswitch-mod-http-cache \
        freeswitch-mod-hash \
        freeswitch-sounds-en-us-callie \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/auth.conf

# --- Ports ---
# SIP internal/external
EXPOSE 5060/udp 5060/tcp
EXPOSE 5080/udp 5080/tcp
# SignalWire trunk: 6050 is FreeSWITCH's own local bind port for the
# "signalwire" sofia profile; the actual outbound connection to SignalWire's
# listening port runs on 5061 (see README.md Firewall section / NOTES.md)
EXPOSE 6050/tcp
# ESL (Event Socket Layer - fs_cli)
EXPOSE 8021/tcp
# RTP media — actual range set via RTPSTARTPORT/RTPENDPORT in .env (currently
# 20000-20100; see vars.xml/switch.conf.xml). This EXPOSE has no functional
# effect under network_mode: host (Docker port publishing is bypassed
# entirely) — kept only as documentation of the default upstream range.
EXPOSE 16384-32768/udp

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["freeswitch", "-nonatmap", "-nonat"]
