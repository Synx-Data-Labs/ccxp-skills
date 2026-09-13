#!/usr/bin/env bash
# help-net probe — non-intrusive macOS network diagnostic for travelers.
# Outputs structured KEY: VALUE lines under [SECTION] headings.
# All checks have hard timeouts. Target wall-clock: ~30s on a bad network.

set -u

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: help-net/probe.sh is macOS-only" >&2
  exit 2
fi

echo "=== help-net probe ==="
echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host: $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"

# ---------- Primary interface ----------
primary_if=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
primary_gw=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')

echo ""
echo "[INTERFACE]"
if [[ -z "${primary_if:-}" ]]; then
  echo "primary.name: NONE"
  echo "primary.status: no_default_route"
  echo ""
  echo "[META]"
  echo "probe.ok: partial_no_route"
  exit 0
fi

mtu=$(ifconfig "$primary_if" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1); exit}')
constrained=false
ifconfig "$primary_if" 2>/dev/null | grep -q constrained && constrained=true
primary_ip=$(ifconfig "$primary_if" 2>/dev/null | awk '/inet / {print $2; exit}')

# Service name (iPhone USB, Wi-Fi, etc.)
svc_name=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="Device: $primary_if" '
  /^\(Hardware Port:/ { if ($0 ~ dev) print prev }
  { prev = $0 }
' | sed 's/^([0-9]*) //' | head -1)

# Tether heuristic
is_tether=false
tether_type="none"
case "${primary_gw:-}" in
  172.20.10.*)            is_tether=true; tether_type="iphone_personal_hotspot" ;;
  192.168.43.*|192.168.42.*) is_tether=true; tether_type="android_hotspot" ;;
esac
[[ "$svc_name" == *iPhone* || "$svc_name" == *Android* ]] && is_tether=true

echo "primary.name: $primary_if"
echo "primary.service: ${svc_name:-unknown}"
echo "primary.ip: ${primary_ip:-none}"
echo "primary.gateway: ${primary_gw:-none}"
echo "primary.mtu: ${mtu:-unknown}"
echo "primary.constrained: $constrained"
echo "primary.is_tether: $is_tether"
echo "primary.tether_type: $tether_type"

# ---------- DNS ----------
echo ""
echo "[DNS]"
dns_resolvers=$(scutil --dns 2>/dev/null | awk '/nameserver\[/ {print $NF}' | awk '!seen[$0]++' | paste -sd, -)
echo "dns.resolvers: ${dns_resolvers:-none}"

google_sys=$(dig +short +time=3 +tries=2 google.com A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
echo "dns.google_via_system: ${google_sys:-FAIL}"

google_cf=$(dig +short +time=3 +tries=1 @1.1.1.1 google.com A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
echo "dns.google_via_1_1_1_1: ${google_cf:-FAIL}"

# Poisoning heuristic: Google's real AS15169 ranges
case "${google_sys:-}" in
  142.250.*|142.251.*|172.217.*|216.58.*|74.125.*|64.233.*|8.8.*|209.85.*)
    echo "dns.google_range_ok: true" ;;
  "")
    echo "dns.google_range_ok: unknown" ;;
  *)
    echo "dns.google_range_ok: false_POSSIBLE_POISONING" ;;
esac

# ---------- Ping ----------
echo ""
echo "[PING]"
# 3 targets: gateway, Cloudflare, Google. Alibaba 223.5.5.5 as a "should always work in CN" control.
for target in "${primary_gw:-}" "1.1.1.1" "8.8.8.8" "223.5.5.5"; do
  [[ -z "$target" ]] && continue
  res=$(ping -c 3 -W 1500 -q "$target" 2>&1)
  loss=$(printf '%s\n' "$res" | sed -nE 's/.*, ([0-9.]+)% packet loss.*/\1%/p' | head -1)
  rtt=$(printf '%s\n' "$res" | awk -F/ '/min\/avg\/max/ {print $5}')
  key=$(printf '%s' "$target" | tr '.' '_')
  echo "ping.${key}.loss: ${loss:-100%_or_unreachable}"
  echo "ping.${key}.rtt_avg_ms: ${rtt:-FAIL}"
done

# ---------- HTTP ----------
echo ""
echo "[HTTP]"
# Mixed bag: captive portal (tiny), small 200/204 (should always work),
# medium (github, google — often stall on bad paths),
# censored-in-CN (twitter, wikipedia — GFW signal),
# allowed-in-CN (baidu — control).
tests='captive_apple http://captive.apple.com/ 4
cloudflare_trace https://1.1.1.1/cdn-cgi/trace 5
gstatic_204 https://www.gstatic.com/generate_204 5
google_com https://www.google.com/ 12
github_com https://github.com/ 12
twitter_com https://x.com/ 8
wikipedia https://www.wikipedia.org/ 8
baidu_com https://www.baidu.com/ 8
aws_checkip https://checkip.amazonaws.com/ 5
anthropic_api https://api.anthropic.com/ 5
slack_api https://slack.com/api/api.test 5
zoom https://zoom.us/ 8'

while read -r name url maxtime; do
  [[ -z "$name" ]] && continue
  out=$(curl -sS -o /dev/null \
    --connect-timeout 5 --max-time "$maxtime" \
    -w 'code=%{http_code} total=%{time_total} tls=%{time_appconnect} size=%{size_download}' \
    "$url" 2>/dev/null)
  code=$(printf '%s' "$out"   | sed -n 's/.*code=\([^ ]*\).*/\1/p')
  total=$(printf '%s' "$out"  | sed -n 's/.*total=\([^ ]*\).*/\1/p')
  tls=$(printf '%s' "$out"    | sed -n 's/.*tls=\([^ ]*\).*/\1/p')
  size=$(printf '%s' "$out"   | sed -n 's/.*size=\([^ ]*\).*/\1/p')
  echo "http.${name}.code: ${code:-0}"
  echo "http.${name}.total_s: ${total:-0}"
  echo "http.${name}.tls_s: ${tls:-0}"
  echo "http.${name}.size: ${size:-0}"
done <<< "$tests"

# ---------- Exit IP / geo ----------
echo ""
echo "[EXIT]"
trace=$(curl -sS --connect-timeout 5 --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
exit_ip=$(printf '%s\n' "$trace" | awk -F= '/^ip=/ {print $2}')
exit_loc=$(printf '%s\n' "$trace" | awk -F= '/^loc=/ {print $2}')
echo "exit.ip: ${exit_ip:-FAIL}"
echo "exit.country: ${exit_loc:-FAIL}"

if [[ -n "${exit_ip:-}" ]]; then
  geo=$(curl -sS --connect-timeout 5 --max-time 6 "https://ipinfo.io/${exit_ip}/json" 2>/dev/null)
  city=$(printf '%s' "$geo" | sed -n 's/.*"city":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  org=$(printf '%s' "$geo"  | sed -n 's/.*"org":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  echo "exit.city: ${city:-unknown}"
  echo "exit.org: ${org:-unknown}"
fi

# ---------- IPv6 ----------
echo ""
echo "[IPV6]"
v6_reachable=false
scutil --nwi 2>/dev/null | awk '/IPv6 network interface information/,/^$/' | grep -q "address" && v6_reachable=true
echo "ipv6.reachable: $v6_reachable"
stale_utun=$(netstat -nr -f inet6 2>/dev/null | awk '/^default.*utun/ {c++} END {print c+0}')
echo "ipv6.utun_default_routes: $stale_utun"

# ---------- VPN / helpers ----------
echo ""
echo "[VPN]"
nc_active=$(scutil --nc list 2>/dev/null | grep -c "^\*" || true)
echo "vpn.active_services: $nc_active"
vpn_total=0
for p in wireguard openvpn nordvpn mullvad expressvpn protonvpn cisco anyconnect viscosity tunnelblick outline v2ray clash shadowsocks tailscale warp cloudflared zerotier; do
  pids=$(pgrep -fi "$p" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$pids" -gt 0 ]]; then
    echo "vpn.running.${p}: $pids"
    vpn_total=$((vpn_total+1))
  fi
done
echo "vpn.running_total: $vpn_total"

# ---------- Done ----------
echo ""
echo "[META]"
echo "probe.ok: true"
