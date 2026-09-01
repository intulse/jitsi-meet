#!/bin/sh
#
# Publish a built jitsi-meet tree into the local jitsi-meet web root.
#
# Usage:
#   ./deploy-local.sh [SRC_DIR] [DST_DIR]
#
# SRC_DIR defaults to the directory this script lives in, so running it from a
# checkout just works.  Both can also come from the environment:
#   JITSI_SRC_DIR=/home/intulseadmin/jitsi-meet ./deploy-local.sh
#
# Run `make` first.  libs/ is build output and is not in git, so a fresh
# checkout has nothing to publish until it has been built.
#
# NOTE: config.js is deliberately NOT copied.  The live config is
# /etc/jitsi/meet/<domain>-config.js on the server; the copy in the repo is a
# reference artifact and would clobber the deployed settings.
#
set -eu

SRC_DIR="${1:-${JITSI_SRC_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}}"
DST_DIR="${2:-${JITSI_DST_DIR:-/usr/share/jitsi-meet}}"

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

echo "deploy-local: done"
