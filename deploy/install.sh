#!/usr/bin/env bash
# Installs the CELL4 RSI loop into an obscure directory under your web root and starts it as a service.
# Usage: sudo bash deploy/install.sh /var/www/html/research-7f3a9c2e1b
set -euo pipefail
TARGET="${1:?usage: install.sh <target directory under your web root>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

command -v lua >/dev/null || command -v lua5.4 >/dev/null || { echo "install lua first: apt-get install -y lua5.4 (or luajit)"; exit 1; }
command -v curl >/dev/null || { echo "install curl first"; exit 1; }

mkdir -p "$TARGET"
cp -r "$SRC/rsi" "$SRC/run.lua" "$SRC/CELL2" "$SRC/main.lua" "$TARGET/"
mkdir -p "$TARGET/source" "$TARGET/rsi/state" "$TARGET/rsi/www" "$TARGET/rsi/versions" "$TARGET/rsi/data/arc" "$TARGET/rsi/data/research"
# the console lives at <url>/rsi/www/ ; give it a stable top-level entry as well
cat > "$TARGET/index.html" <<'EOF'
<!DOCTYPE html><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><meta http-equiv="refresh" content="0; url=rsi/www/">
EOF
# block indexing and hide sources that should not be served
cat > "$TARGET/.htaccess" <<'EOF'
Options -Indexes
# mod_headers may not be enabled; an unguarded Header directive 500s the whole directory
<IfModule mod_headers.c>
  Header set X-Robots-Tag "noindex, nofollow"
  <FilesMatch "\.(json|jsonl)$">
    Header set Cache-Control "no-store"
  </FilesMatch>
</IfModule>
<FilesMatch "\.(lua|jsonl)$">
  Require all denied
</FilesMatch>
<Files "lineage.jsonl">
  Require all granted
</Files>
EOF
chown -R www-data:www-data "$TARGET"

LUA_BIN="$(command -v lua || command -v lua5.4)"
sed -e "s#/var/www/html/research-CHANGE-ME#$TARGET#" -e "s#/usr/bin/lua #$LUA_BIN #" -e "s#ExecStart=/usr/bin/lua #ExecStart=$LUA_BIN #" \
  "$SRC/deploy/cell4-rsi.service" > /etc/systemd/system/cell4-rsi.service
systemctl daemon-reload
systemctl enable --now cell4-rsi.service
echo "started. console: <your host>/$(basename "$TARGET")/rsi/www/   logs: journalctl -u cell4-rsi -f"
