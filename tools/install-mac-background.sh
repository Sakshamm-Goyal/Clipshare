#!/bin/bash
# Installs ClipShare to run in the background on this Mac, starting at login:
#   - Postgres + Redis (brew services)
#   - relay        (launchd, auto-restart)       com.clipshare.relay
#   - Bonjour ad   (so Android finds a new IP)   com.clipshare.bonjour
#   - menu bar app (launchd, restarts on crash)  com.clipshare.mac
# Re-run any time to rebuild and reload. Uninstall: tools/install-mac-background.sh --uninstall
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/ClipShare"
LOGS="$HOME/Library/Logs/ClipShare"
AGENTS="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/ClipboardMac.app"
LABELS=(com.clipshare.relay com.clipshare.bonjour com.clipshare.mac)
DOMAIN="gui/$(id -u)"

for label in "${LABELS[@]}"; do launchctl bootout "$DOMAIN/$label" 2>/dev/null || true; done
pkill -x ClipboardMac 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
  for label in "${LABELS[@]}"; do rm -f "$AGENTS/$label.plist"; done
  echo "✓ Uninstalled launch agents (data in $SUPPORT kept)"
  exit 0
fi

mkdir -p "$SUPPORT" "$LOGS" "$AGENTS" "$HOME/Applications"

echo "→ Postgres + Redis"
brew services start postgresql@16 >/dev/null
brew services start redis >/dev/null
for _ in {1..20}; do pg_isready -q && break; sleep 0.5; done
createdb clipshare 2>/dev/null || true

if [[ ! -s "$SUPPORT/jwt_secret" ]]; then
  (umask 077; openssl rand -hex 32 > "$SUPPORT/jwt_secret")
fi

# Replacing a binary changes its ad-hoc signature, which silently voids the
# firewall rule, Keychain "Always Allow" and Screen Recording grant. So build
# reproducibly and only swap binaries whose bytes actually changed.
echo "→ Building relay"
RELAY="$SUPPORT/clipshare-server"
(cd "$ROOT/backend" && go build -trimpath -buildvcs=false -o "$RELAY.new" ./cmd/server)
RELAY_CHANGED=0
if cmp -s "$RELAY.new" "$RELAY"; then rm "$RELAY.new"; else mv "$RELAY.new" "$RELAY"; RELAY_CHANGED=1; fi

# A background relay never gets the "Allow incoming connections?" popup, so
# with the macOS firewall on the phone's connections are silently reset.
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
if "$FW" --getglobalstate | grep -q enabled && { [[ $RELAY_CHANGED == 1 ]] || ! "$FW" --listapps | grep -qF "$RELAY"; }; then
  echo "→ Allowing relay through macOS firewall (asks for your Mac password)"
  { sudo "$FW" --remove "$RELAY" >/dev/null 2>&1; sudo "$FW" --add "$RELAY" && sudo "$FW" --unblockapp "$RELAY"; } >/dev/null \
    || echo "✗ Firewall still blocks the relay; phone can't connect until it's allowed"
fi

echo "→ Building Mac app"
(cd "$ROOT/mac-app" && swift build -c release >/dev/null)
BUILT="$ROOT/mac-app/.build/release/ClipboardMac"
if [[ -x "$APP/Contents/MacOS/ClipboardMac" ]] && [[ "$(shasum -a 256 < "$BUILT")" == "$(cat "$SUPPORT/mac-app.sha256" 2>/dev/null)" ]]; then
  echo "  (unchanged, keeping signed app so permissions stay granted)"
else
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$ROOT/mac-app/Info.plist" "$APP/Contents/"
  cp "$BUILT" "$APP/Contents/MacOS/"
  # A stable local cert keeps Screen Recording + Keychain grants across rebuilds;
  # ad-hoc signatures are per-build hashes, so macOS treats each build as a new app.
  SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"ClipShare Local Signing"/ {print $2; exit}')
  codesign --force --sign "${SIGN_ID:--}" --identifier com.clipshare.mac "$APP"
  shasum -a 256 < "$BUILT" > "$SUPPORT/mac-app.sha256"
  echo "  (new build: re-allow Screen Recording; Keychain may ask once → Always Allow)"
fi
# Relay runs on this Mac, so loopback never breaks when Wi-Fi changes.
defaults write com.clipshare.mac serverURL "http://127.0.0.1:8080"

agent() { # label, keepalive-xml, program args...
  local label=$1 keep=$2; shift 2
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo "<plist version=\"1.0\"><dict>"
    echo "<key>Label</key><string>$label</string>"
    echo "<key>ProgramArguments</key><array>"
    for a in "$@"; do printf '<string>%s</string>\n' "$a"; done
    echo "</array>"
    echo "<key>RunAtLoad</key><true/>"
    echo "<key>KeepAlive</key>$keep"
    echo "<key>ThrottleInterval</key><integer>5</integer>"
    echo "<key>ProcessType</key><string>Interactive</string>"
    echo "<key>StandardOutPath</key><string>$LOGS/$label.log</string>"
    echo "<key>StandardErrorPath</key><string>$LOGS/$label.log</string>"
    echo "</dict></plist>"
  } > "$AGENTS/$label.plist"
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
}

echo "→ Loading launch agents"
# Secret is read from a 600 file at start, never written into the plist.
agent com.clipshare.relay '<true/>' /bin/sh -c \
  "JWT_SECRET=\"\$(cat '$SUPPORT/jwt_secret')\" exec '$SUPPORT/clipshare-server' -db 'postgres://$(whoami)@localhost/clipshare?sslmode=disable'"
agent com.clipshare.bonjour '<true/>' /usr/bin/dns-sd -R ClipShare _clipshare._tcp local 8080
# Quit from the menu (exit 0) stays quit; crashes restart.
# Launch through LaunchServices (`open`), not the raw binary: TCC only matches the
# app's Screen Recording grant to a LaunchServices-launched bundle.
agent com.clipshare.mac '<dict><key>SuccessfulExit</key><false/></dict>' \
  /usr/bin/open -W -a "$APP" --stdout "$LOGS/com.clipshare.mac.log" --stderr "$LOGS/com.clipshare.mac.log"

for _ in {1..20}; do curl -fs http://127.0.0.1:8080/healthz >/dev/null && break; sleep 0.5; done
curl -fs http://127.0.0.1:8080/healthz >/dev/null && echo "✓ Relay healthy on :8080" || echo "✗ Relay not healthy, see $LOGS/com.clipshare.relay.log"
echo "✓ Done. ⌘⇧I = silent screenshot → Android. Logs: $LOGS"
echo "  First run: allow Screen Recording for ClipboardMac (System Settings → Privacy & Security)."
