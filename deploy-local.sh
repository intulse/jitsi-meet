#!/bin/sh
#
# Publish a built jitsi-meet tree into the local jitsi-meet web root, and install
# this repo's config.js as the live client config.
#
# Usage:
#   sh deploy-local.sh [SRC_DIR] [DST_DIR]
#
# SRC_DIR defaults to the directory this script lives in, so running it from a
# checkout just works.  All three inputs can come from the environment:
#   JITSI_SRC_DIR=/path/to/jitsi-meet
#   JITSI_DST_DIR=/usr/share/jitsi-meet
#   JITSI_DOMAIN=meet.example.com        <- required to publish config.js
#
# Run `make` first.  libs/ is build output and is not in git, so a fresh
# checkout has nothing to publish until it has been built.
#
# CONFIG.JS
#   nginx serves /config.js by aliasing /etc/jitsi/meet/$JITSI_DOMAIN-config.js,
#   so that is where this repo's config.js has to land to take effect.
#
#   It cannot be copied verbatim.  The file in the repo is upstream's template
#   and still carries the placeholder host 'jitsi-meet.example.com' in
#   hosts.domain, hosts.muc, bosh and websocket.  Deploying it unsubstituted
#   points every client at a domain that does not exist.  This script rewrites
#   the placeholder to $JITSI_DOMAIN on the way across.
#
#   The <!--# echo var="subdomain" --> SSI markers are left alone: nginx has ssi
#   on for that location and expands them when serving.
#
#   Set JITSI_DOMAIN to publish it; leave it unset to deploy only the web tree.
#   The previous config is backed up next to it before being replaced.
#
set -eu

SRC_DIR="${1:-${JITSI_SRC_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}}"
DST_DIR="${2:-${JITSI_DST_DIR:-/usr/share/jitsi-meet}}"
JITSI_DOMAIN="${JITSI_DOMAIN:-}"
CONFIG_DIR="${JITSI_CONFIG_DIR:-/etc/jitsi/meet}"

# The placeholder host upstream ships in config.js.
PLACEHOLDER_DOMAIN='jitsi-meet.example.com'

# Single files copied to the web root.
FILES="
base.html
body.html
favicon.ico
head.html
index.html
interface_config.js
manifest.json
plugin.head.html
pwa-worker.js
title.html
"

# Directories whose *contents* are copied to the same-named directory.
DIRS="
css
fonts
images
lang
libs
sounds
static
"

fail() {
    echo "deploy-local: $*" >&2
    exit 1
}

[ -d "$SRC_DIR" ] || fail "source directory not found: $SRC_DIR"
[ -d "$DST_DIR" ] || fail "destination directory not found: $DST_DIR"

[ -d "$SRC_DIR/libs" ] || fail "$SRC_DIR/libs is missing -- run 'make' before deploying"

echo "deploy-local: $SRC_DIR -> $DST_DIR"

for f in $FILES; do
    [ -f "$SRC_DIR/$f" ] || fail "missing file: $SRC_DIR/$f"
    cp -- "$SRC_DIR/$f" "$DST_DIR/$f"
done

for d in $DIRS; do
    [ -d "$SRC_DIR/$d" ] || fail "missing directory: $SRC_DIR/$d"
    mkdir -p -- "$DST_DIR/$d"
    cp -r -- "$SRC_DIR/$d/." "$DST_DIR/$d/"
done

# Prosody reads its plugins from the web root on a standard jitsi debian install.
mkdir -p -- "$DST_DIR/prosody-plugins"
cp -r -- "$SRC_DIR/resources/prosody-plugins/." "$DST_DIR/prosody-plugins/"

# The decryption helper is gitignored, so a fresh clone will not have it. Without
# it both Intulse prosody modules fail to load and rooms come up with no lobby and
# no password enforcement -- loud failure is much better than that.
if [ ! -f "$DST_DIR/prosody-plugins/intulse/util.lib.lua" ]; then
    echo "deploy-local: WARNING: prosody-plugins/intulse/util.lib.lua is missing." >&2
    echo "deploy-local:          Copy it from the Intulse mono repo into" >&2
    echo "deploy-local:          $SRC_DIR/resources/prosody-plugins/intulse/ and re-run," >&2
    echo "deploy-local:          or prosody will start with NO meeting security." >&2
fi

# config.js -> /etc/jitsi/meet/$JITSI_DOMAIN-config.js, with the placeholder host
# rewritten. See the header for why a straight copy is not safe.
if [ -n "$JITSI_DOMAIN" ]; then
    [ -f "$SRC_DIR/config.js" ] || fail "missing file: $SRC_DIR/config.js"
    [ -d "$CONFIG_DIR" ] || fail "config directory not found: $CONFIG_DIR"

    config_dst="$CONFIG_DIR/$JITSI_DOMAIN-config.js"

    if [ -f "$config_dst" ]; then
        backup="$config_dst.bak.$(date +%Y%m%d%H%M%S)"
        cp -- "$config_dst" "$backup"
        echo "deploy-local: backed up existing config to $backup"
    fi

    sed "s/$PLACEHOLDER_DOMAIN/$JITSI_DOMAIN/g" "$SRC_DIR/config.js" > "$config_dst"

    # Fail loudly rather than leaving a config pointed at a domain that does not exist.
    if grep -q "$PLACEHOLDER_DOMAIN" "$config_dst"; then
        fail "$config_dst still contains $PLACEHOLDER_DOMAIN -- substitution failed"
    fi

    echo "deploy-local: installed config.js -> $config_dst (domain $JITSI_DOMAIN)"
else
    echo "deploy-local: JITSI_DOMAIN not set -- skipping config.js (web tree only)"
fi

echo "deploy-local: done"
