#!/usr/bin/env zsh
# configure-ollama-network.sh
# Configures Ollama for LAN access on macOS (Homebrew install).
# Run this script on your Mac: zsh configure-ollama-network.sh
#
# What it does:
#   1. Verifies the current plist has OLLAMA_HOST=0.0.0.0:11434
#   2. Adds OLLAMA_ORIGINS=* to the plist (needed for IDE cross-origin requests)
#   3. Confirms your gateway, then sets a static IP of 192.168.4.227
#   4. Checks/configures the macOS firewall for port 11434
#   5. Restarts the Homebrew launchd service and verifies port binding
#   6. End-to-end curl tests

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PLIST=/opt/homebrew/opt/ollama/homebrew.mxcl.ollama.plist
SERVICE=homebrew.mxcl.ollama
IFACE=en0
STATIC_IP=192.168.4.227
SUBNET_MASK=255.255.255.0
EXPECTED_GATEWAY=192.168.4.1
DNS_SERVERS=(8.8.8.8 8.8.4.4)
OLLAMA_PORT=11434
OLLAMA_BIN=/opt/homebrew/bin/ollama

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { print -P "%F{cyan}[INFO]%f  $*"; }
ok()    { print -P "%F{green}[ OK ]%f  $*"; }
warn()  { print -P "%F{yellow}[WARN]%f  $*"; }
die()   { print -P "%F{red}[FAIL]%f  $*" >&2; exit 1; }
hr()    { print -- "────────────────────────────────────────────────────────"; }

# ── Step 1: Verify plist exists and current env vars ─────────────────────────
hr
info "Step 1 — Verifying current plist"
[[ -f $PLIST ]] || die "Plist not found: $PLIST"
info "Current plist contents:"
cat "$PLIST"
echo

if grep -q "OLLAMA_HOST" "$PLIST"; then
    ok "OLLAMA_HOST is present in the plist."
else
    warn "OLLAMA_HOST not found! You may need to add it manually first."
fi

# ── Step 2: Add OLLAMA_ORIGINS=* if not already present ──────────────────────
hr
info "Step 2 — Adding OLLAMA_ORIGINS=* to plist"

if grep -q "OLLAMA_ORIGINS" "$PLIST"; then
    ok "OLLAMA_ORIGINS already present — no change needed."
else
    info "Diff preview (what will be added):"
    # Show the exact block we're inserting
    cat <<'DIFF'
--- before
+++ after
 <key>EnvironmentVariables</key>
 <dict>
     <key>OLLAMA_HOST</key>
     <string>0.0.0.0:11434</string>
+    <key>OLLAMA_ORIGINS</key>
+    <string>*</string>
     <key>OLLAMA_KEEP_ALIVE</key>
     <string>-1</string>
 </dict>
DIFF
    echo
    read -r "REPLY?Apply this change? [y/N] "
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Insert OLLAMA_ORIGINS key/string pair after the OLLAMA_HOST block
        # Uses Python for reliable plist XML editing without requiring sudo
        python3 - "$PLIST" <<'PYEOF'
import sys, plistlib, pathlib

path = pathlib.Path(sys.argv[1])
with open(path, "rb") as f:
    pl = plistlib.load(f)

env = pl.setdefault("EnvironmentVariables", {})
env["OLLAMA_ORIGINS"] = "*"

with open(path, "wb") as f:
    plistlib.dump(pl, f, fmt=plistlib.FMT_XML, sort_keys=False)

print("Plist updated successfully.")
PYEOF
        ok "OLLAMA_ORIGINS=* added."
        info "Updated plist:"
        cat "$PLIST"
        echo
    else
        warn "Skipped adding OLLAMA_ORIGINS."
    fi
fi

# ── Step 3: Confirm gateway, then set static IP ───────────────────────────────
hr
info "Step 3 — Static IP configuration"

# Find the interface that currently holds the default route (works for Wi-Fi or Ethernet)
ACTIVE_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
if [[ -z $ACTIVE_IFACE ]]; then
    ACTIVE_IFACE=$IFACE   # fallback to en0
fi
info "Active interface (from default route): $ACTIVE_IFACE"

CURRENT_IP=$(ipconfig getifaddr "$ACTIVE_IFACE" 2>/dev/null || echo "unknown")
CURRENT_GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}' || echo "unknown")

info "Current interface $ACTIVE_IFACE address : $CURRENT_IP"
info "Current default gateway                  : $CURRENT_GW"

# Map interface → network service name using networksetup -listnetworkserviceorder
# Output looks like: (Hardware Port: Wi-Fi, Device: en1)
NETWORK_SERVICE=$(networksetup -listnetworkserviceorder 2>/dev/null \
    | awk -v iface="$ACTIVE_IFACE" '
        /^\([0-9]/ { svc = substr($0, index($0,$2)); gsub(/^[0-9]+\) /, "", svc) }
        /Device: / { dev = $NF; gsub(/\)$/, "", dev); if (dev == iface) print svc }
    ')

info "Mapped network service name: '${NETWORK_SERVICE:-not detected}'"

if [[ -z $NETWORK_SERVICE ]]; then
    warn "Could not auto-detect service name. Available services:"
    networksetup -listallnetworkservices | grep -v "^\*"
    read -r "NETWORK_SERVICE?Enter exact service name shown above (e.g. 'Wi-Fi'): "
fi

if [[ $CURRENT_IP == "$STATIC_IP" ]]; then
    ok "Interface is already on $STATIC_IP."
    info "networksetup -getinfo '$NETWORK_SERVICE':"
    networksetup -getinfo "$NETWORK_SERVICE" 2>/dev/null || true
else
    warn "Current IP ($CURRENT_IP) differs from target ($STATIC_IP)."
fi

# Confirm gateway matches expectation
if [[ $CURRENT_GW != "$EXPECTED_GATEWAY" ]]; then
    warn "Detected gateway ($CURRENT_GW) differs from expected ($EXPECTED_GATEWAY)."
    warn "Verify your router's gateway before proceeding."
    read -r "REPLY?Continue with detected gateway $CURRENT_GW instead of $EXPECTED_GATEWAY? [y/N] "
    [[ $REPLY =~ ^[Yy]$ ]] || die "Aborted — please re-run and confirm the correct gateway."
    ROUTER_GW=$CURRENT_GW
else
    ok "Gateway confirmed: $CURRENT_GW"
    ROUTER_GW=$CURRENT_GW
fi

info "Will configure: service='$NETWORK_SERVICE'  IP=$STATIC_IP  mask=$SUBNET_MASK  gw=$ROUTER_GW"
read -r "REPLY?Set static IP now? This will briefly drop your network. [y/N] "
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # networksetup does NOT require sudo for the current user's own network service
    networksetup -setmanual "$NETWORK_SERVICE" "$STATIC_IP" "$SUBNET_MASK" "$ROUTER_GW"
    networksetup -setdnsservers "$NETWORK_SERVICE" "${DNS_SERVERS[@]}"
    ok "Static IP set to $STATIC_IP via networksetup."
    sleep 2
    NEW_IP=$(ipconfig getifaddr $IFACE 2>/dev/null || echo "not yet assigned")
    info "Interface now reports: $NEW_IP"
    [[ $NEW_IP == "$STATIC_IP" ]] && ok "IP confirmed: $NEW_IP" \
        || warn "IP not yet showing ($NEW_IP) — may take a moment to propagate."
else
    warn "Skipped static IP configuration."
fi

# ── Step 4: Firewall check ────────────────────────────────────────────────────
hr
info "Step 4 — macOS Application Firewall"
FW_BIN=/usr/libexec/ApplicationFirewall/socketfilterfw

FW_STATE=$("$FW_BIN" --getglobalstate 2>&1)
info "Firewall state: $FW_STATE"

if echo "$FW_STATE" | grep -qi "disabled"; then
    ok "Firewall is disabled — port 11434 is unblocked."
else
    info "Firewall is enabled. Checking if Ollama binary has an exception..."
    FW_LIST=$("$FW_BIN" --listapps 2>&1)
    if echo "$FW_LIST" | grep -qi "ollama"; then
        ok "Ollama already has a firewall exception."
    else
        warn "No firewall exception found for Ollama."
        info "Will add an allow rule for: $OLLAMA_BIN"
        info "(This requires sudo to modify the firewall rule list.)"
        read -r "REPLY?Add firewall exception for Ollama? [y/N] "
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo "$FW_BIN" --add "$OLLAMA_BIN"
            sudo "$FW_BIN" --unblockapp "$OLLAMA_BIN"
            ok "Firewall exception added for $OLLAMA_BIN"
            info "Current firewall app list:"
            "$FW_BIN" --listapps 2>&1 | grep -i ollama || warn "Entry not showing yet — try: $FW_BIN --listapps"
        else
            warn "Skipped firewall exception. Port 11434 may be blocked for remote clients."
        fi
    fi
fi

# ── Step 5: Restart service and verify port binding ──────────────────────────
hr
info "Step 5 — Restarting Ollama service and verifying port binding"

brew services restart ollama
info "Waiting 5 seconds for service to start..."
sleep 5

# Verify the port is actually bound
info "Checking lsof for port $OLLAMA_PORT..."
LSOF_OUT=$(lsof -iTCP:$OLLAMA_PORT -sTCP:LISTEN 2>/dev/null || echo "")
if [[ -n $LSOF_OUT ]]; then
    ok "Port $OLLAMA_PORT is bound:"
    echo "$LSOF_OUT"
    # Check it's binding on 0.0.0.0 (not just 127.0.0.1)
    if echo "$LSOF_OUT" | grep -q "\*:$OLLAMA_PORT\|0\.0\.0\.0\|:::"; then
        ok "Listening on all interfaces (0.0.0.0) — good."
    elif echo "$LSOF_OUT" | grep -q "127\.0\.0\.1\|localhost"; then
        die "Still bound to localhost only! Check OLLAMA_HOST in plist and restart again."
    fi
else
    warn "Port not yet bound — waiting another 5 seconds..."
    sleep 5
    LSOF_OUT=$(lsof -iTCP:$OLLAMA_PORT -sTCP:LISTEN 2>/dev/null || echo "")
    if [[ -n $LSOF_OUT ]]; then
        ok "Port $OLLAMA_PORT is now bound:"
        echo "$LSOF_OUT"
    else
        die "Port $OLLAMA_PORT still not listening after 10s. Check: brew services list && brew services log ollama"
    fi
fi

# ── Step 6: End-to-end curl tests ─────────────────────────────────────────────
hr
info "Step 6 — End-to-end tests"

test_url() {
    local url=$1
    local label=$2
    info "Testing: $url"
    HTTP_CODE=$(curl -s -o /tmp/ollama_test_out -w "%{http_code}" --connect-timeout 5 "$url" 2>&1)
    BODY=$(cat /tmp/ollama_test_out 2>/dev/null || echo "")
    if [[ $HTTP_CODE == "200" ]]; then
        ok "$label → HTTP 200"
        echo "$BODY" | python3 -m json.tool 2>/dev/null | head -20 || echo "$BODY" | head -5
    else
        warn "$label → HTTP $HTTP_CODE  (body: ${BODY:0:120})"
    fi
    echo
}

test_url "http://127.0.0.1:$OLLAMA_PORT/api/tags"       "localhost /api/tags"
test_url "http://$STATIC_IP:$OLLAMA_PORT/api/tags"      "LAN IP /api/tags"
test_url "http://$STATIC_IP:$OLLAMA_PORT/v1/models"     "LAN IP /v1/models"

hr
ok "All steps complete."
info "To test from another machine on your LAN:"
info "  curl http://$STATIC_IP:$OLLAMA_PORT/api/tags"
info ""
info "If you still can't reach Ollama from another device, check:"
info "  1. The other device is on the same subnet (192.168.4.x)"
info "  2. brew services list | grep ollama  →  should show 'started'"
info "  3. lsof -iTCP:$OLLAMA_PORT -sTCP:LISTEN  →  should show '*:11434' not '127.0.0.1'"
