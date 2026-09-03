#!/bin/sh
# Upload the derived outputs to a web host. One-shot: connects, uploads, exits.
# No daemon, no loop, no background process. Run it after a generation, or from
# the same scheduled job:  ./run-once.sh && ./publish.sh
#
# This exists for the split deployment described in NAMECHEAP.md: the generation
# runs where compute is allowed, and the shared host serves the resulting static
# files -- which is what shared hosting is sold for.
#
# Credentials come from cell4.env (chmod 600, never committed). Example:
#   CELL4_FTP_HOST=ftp.yourdomain.com
#   CELL4_FTP_USER=cell4@yourdomain.com
#   CELL4_FTP_PASS='...'
#   CELL4_FTP_DIR=/public_html/cell4
#
# FTPS is required (--ssl-reqd): plain FTP would put the password on the wire in
# clear text on every scheduled run.

cd "$(dirname "$0")" || exit 1
[ -f cell4.env ] && . ./cell4.env

: "${CELL4_FTP_HOST:?set CELL4_FTP_HOST in cell4.env}"
: "${CELL4_FTP_USER:?set CELL4_FTP_USER in cell4.env}"
: "${CELL4_FTP_PASS:?set CELL4_FTP_PASS in cell4.env}"
: "${CELL4_FTP_DIR:=/public_html}"

up() {
  [ -f "$1" ] || return 0
  curl --ssl-reqd --fail --silent --show-error --max-time 60 \
       --user "$CELL4_FTP_USER:$CELL4_FTP_PASS" \
       --upload-file "$1" \
       "ftp://$CELL4_FTP_HOST$CELL4_FTP_DIR/$2" || echo "publish: failed to upload $1" >&2
}

up live.json              live.json
up rsi/www/index.html     index.html
up rsi/www/state.json     state.json
up rsi/www/progress.json  progress.json
up JOURNAL.md             JOURNAL.md
up HISTORY.md             HISTORY.md
