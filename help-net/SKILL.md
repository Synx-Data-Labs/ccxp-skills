---
name: help-net
description: Use when on macOS and network is degraded in a travel or cross-border context (GFW, carrier throttle, MTU black hole, DNS poisoning, VPN) — also pre/post-trip checklists; not for routine home/office Wi-Fi
disable-model-invocation: false
argument-hint: "[pre-trip | post-trip]  (no args = live diagnostic)"
---

Triage a traveler's "the internet is slow/broken" problem on macOS. Produce a report with **primary classification**, evidence cited from probe output, concrete fixes, and explicit rule-outs (what is NOT the problem). Default mode runs live diagnostics; `pre-trip` and `post-trip` surface the relevant checklist.

## Known pattern: a company VPN-gated internal resource

**A company-internal site (e.g. a self-hosted GitLab/Git server) that only resolves/loads with a work VPN connected** is often reachable at a private (RFC 1918) address via an OpenVPN-style tunnel. Symptom: the page hangs or times out (`curl`/`nc` never connect, or times out even though DNS resolves) — looks like a generic network problem but the fix is simply **turn the VPN on** and confirm the tunnel interface is actually routing that subnet (a second, unrelated VPN/tunnel taking the default route can shadow it — check `route get <the private IP>` lands on the VPN's tunnel interface, not another `utun*`). If DNS resolves but the private answer gets silently replaced by your home router (a DNS-rebind-protection false positive), that's a related but distinct symptom — same fix (VPN on), different root cause.

## Mode selection

- `$ARGUMENTS` is empty → **live diagnostic** (default — the most common case).
- `$ARGUMENTS` is `pre-trip` → walk the user through the pre-trip checklist.
- `$ARGUMENTS` is `post-trip` → help undo travel-specific tweaks.

---

## Live diagnostic workflow

### Step 1 — Run the probe

```bash
bash ~/.claude/skills/help-net/scripts/probe.sh
```

~30 s, read-only, never hangs. Outputs `KEY: VALUE` under `[INTERFACE]`, `[DNS]`, `[PING]`, `[HTTP]`, `[EXIT]`, `[IPV6]`, `[VPN]`, `[META]`.

If `[META] probe.ok: true` is missing, interpret with whatever partial data came back and note gaps.

### Step 2 — Classify

Walk the decision tree in order. First matching set wins. If signals conflict, report **primary + secondary** and say which fixes address which.

**A. GFW active (real censorship)**

- `exit.country: CN` OR `exit.org` contains "China Telecom/Unicom/Mobile"
- ≥1 of: `dns.google_range_ok: false_POSSIBLE_POISONING` • `http.google_com.code: 0` with `http.baidu_com.code: 200` • `http.twitter_com.code: 0` with `http.baidu_com.code: 200` • `http.google_com.tls_s: 0`

**B. Carrier tether throttle / hotspot cap** ← most common "suddenly slow"

- `primary.is_tether: true`
- `exit.country` is home country (NOT `CN` — means roaming tunnel, GFW bypassed)
- Small responses OK (`http.cloudflare_trace.code: 200`, `http.gstatic_204.code: 204`)
- Large responses stall (`http.google_com.size < 50000` AND `http.google_com.total_s ≥ 10`)
- `ping.8_8_8_8.loss ≥ 10%`

**C. iOS Low Data Mode on hotspot**

- `primary.constrained: true`

**D. PMTU black hole**

- `primary.mtu < 1400`, OR
- Tiny HTTP OK but medium/large HTTP stalls with `*.tls_s > 0` (TLS completes, body doesn't)

**E. DNS poisoning / local resolver broken**

- `dns.google_via_system: FAIL` OR `dns.google_range_ok: false_POSSIBLE_POISONING`
- AND `dns.google_via_1_1_1_1` returns a Google IP

**F. VPN interference (stale software)**

- `vpn.active_services > 0` OR any `vpn.running.*` entry
- AND user says the phone works fine on the same network

**G. Path loss (bad cellular pipe, no software fix)**

- `ping.8_8_8_8.rtt_avg_ms > 200` AND `loss > 10%`
- `exit.country` is home country
- TLS completes everywhere, bodies arrive slowly but eventually

**H. Healthy**

- `ping.8_8_8_8.loss: 0%` AND `http.google_com.code: 200` AND `http.google_com.total_s < 3`

### Step 3 — Output the report

```
## Network diagnosis

**Primary classification**: <A–H name>

**Key evidence** (cite probe values):
- <key: value>
- <key: value>

**What's NOT the problem** (rule-outs):
- <e.g. "Not GFW: exit IP is AT&T Phoenix — traffic tunnels to US, GFW bypassed.">

**Recommended actions** (priority order):
1. <concrete command or setting change>
2. <...>

**Won't help** (save time and money):
- <e.g. "Buying more VPNs — throttle hits before traffic reaches VPN.">
```

The single highest-value output of this skill is the rule-out section. **Always call out what isn't the problem** — the top failure mode for teammates is spending money on VPNs or rebuilding macOS when the real fix is a $15 hotspot top-up.

---

## Pre-trip mode (`/help-net pre-trip`)

Ask destination + trip length, then walk through this checklist with the user. Confirm each item before moving on.

### Carrier / connectivity

**TL;DR for China (as of April 2026): don't fight AT&T, use Nomad.** Hard-won numbers below.

- [ ] **Default recommendation: Nomad unlimited eSIM** — no throttle, no cap, no cliff. Pays for itself on any trip >2 days vs AT&T Day Pass math below. Install BEFORE leaving (needs a working non-China connection to activate).
- [ ] **If using AT&T roaming instead**, know the trap:
  - International Day Pass: **$10/day, caps at 12 days per cycle = $120 max**
  - Hotspot bucket is **separate and tiny** — basically one $15 / 10 GB add-on per cycle (can't stack multiple top-ups)
  - **Throughput is limited even before you hit the cap** — it's tunneled back to US (~330 ms RTT, lossy)
  - **macOS auto-updates will drain 10 GB in minutes** — System Settings → General → Software Update → turn OFF auto-update BEFORE you leave. Same for App Store app updates.
  - Once the 10 GB is gone, you're effectively offline until next cycle
- [ ] Install the carrier app (myAT&T etc.) — lets you buy the one top-up while abroad, check remaining GB
- [ ] `*611` saved as a contact — free from your line even while roaming
- [ ] Alternative eSIMs if Nomad isn't available: Airalo, Ubigi, or a direct HK operator — all bill via non-mainland gateways → also route around GFW as a side effect

### VPN

**Lesson from 2026-04 trip: don't reflexively buy a VPN.** If you're on Nomad (or any non-mainland-billed eSIM) you don't need one — traffic already exits outside GFW. $200 spent stacking VPN subscriptions did nothing; Nomad unlimited solved it.

- [ ] Only set up a VPN if you expect to be on a **mainland-billed local SIM** or **untrusted hotel Wi-Fi** (i.e., actually inside Chinese internet — then GFW is real)
- [ ] If needed: sign up + install ≥2 VPNs BEFORE leaving — vendor sites and app stores are routinely blocked from inside China
- [ ] Generally-working picks: Mullvad, ProtonVPN, NordVPN (Obfuscated/NordLynx), ExpressVPN
- [ ] Test the app works on laptop + phone at home first
- [ ] Pre-configure HK / Tokyo / Singapore exits (lowest RTT from China)
- [ ] Download WireGuard or OpenVPN `.conf` as a fallback in case the app breaks

### Google / Apple / work

- [ ] Save Google Authenticator backup codes — Google challenges sign-in from CN IPs
- [ ] Warn employer IT you'll sign in from China so SSO doesn't block you
- [ ] Cache offline copies of docs/tickets you'll need (Notion, Linear, GitHub intermittently blocked)

### Laptop

- [ ] **Turn OFF macOS auto-updates before leaving** — System Settings → General → Software Update → Automatic Updates → OFF for *both* downloads and installs. Background OS downloads will silently drain a 10 GB hotspot add-on in minutes and leave you offline. Do the same for App Store app updates and Time Machine backups.
- [ ] Update macOS at home first — do NOT let a 12 GB OS update fire over a throttled/capped hotspot abroad
- [ ] Disable Chrome QUIC: `chrome://flags/#enable-quic` → Disabled → relaunch
- [ ] `brew install mosh` — SSH replacement that handles loss gracefully
- [ ] Bookmark carrier app, Nomad/eSIM login, and this `/help-net` skill

### Communication

- [ ] Set up WeChat while US payment method still works (if meeting locals)
- [ ] Messaging fallbacks: iMessage ✓, Signal usually ✓, WhatsApp ✗, Telegram ✗
- [ ] Share itinerary somewhere that isn't Google/Slack-only

---

## Post-trip mode (`/help-net post-trip`)

Help the user undo travel-specific tweaks. Print commands; user runs sudo themselves.

- Revert MTU: `sudo ifconfig <iface> mtu 1500`
- Re-enable IPv6: `sudo networksetup -setv6automatic "<service>"`
- Revert DNS: `sudo networksetup -setdnsservers "<service>" empty`
- Full VPN removal (trashing the app leaves these behind):
  - `sudo launchctl bootout system /Library/LaunchDaemons/<vendor>.helper.plist`
  - `sudo rm /Library/LaunchDaemons/<vendor>.helper.plist`
  - `sudo rm /Library/PrivilegedHelperTools/<vendor>.helper`
- Remove any Chrome flag overrides (`chrome://flags` → reset all)
- If hotspot top-ups were added, confirm auto-renew is OFF in the carrier app

Run `probe.sh` again afterward to confirm clean state (`vpn.running_total: 0`, `vpn.active_services: 0`, MTU 1500, `constrained: false`).

---

## Reference: common causes and fixes

### 1. Hotspot cap / tether throttle (case B)

Most common. Carrier detects tethered traffic via TTL/DPI and throttles it to a separate, smaller allowance. Hits abruptly — often at midnight (daily cycle reset) or after a GB threshold.

**AT&T specifics (as of 2026-04):**

- International Day Pass: **$10/day, maxes at 12 days per cycle = $120**
- Hotspot add-on: **one $15 / 10 GB top-up per cycle** (cannot stack — once 10 GB is gone, you're done until the cycle rolls)
- Throughput is **also limited** even before the cap — roaming tunnels back to US, ~330 ms RTT, lossy
- **macOS auto-updates will eat the 10 GB in minutes** if you didn't disable them pre-trip

**Fix (triage-time)**: myAT&T app → check remaining hotspot GB → buy the top-up. Or `*611`. Disable macOS auto-updates, App Store updates, and Time Machine immediately.
**Better fix (root cause)**: switch to a **Nomad unlimited eSIM** (or equivalent non-mainland-billed eSIM). No cap, no cliff, typically faster path. For a trip >2 days it's cheaper than Day Pass math anyway.
**Don't**: buy a VPN (throttle is applied before traffic leaves the carrier). Don't stack multiple $15 top-ups — AT&T doesn't let you.

### 2. GFW active (case A)

You're actually on Chinese internet (local SIM, hotel Wi-Fi, unrouted corporate network). Characteristic: domain-specific failures. Baidu works, Google/Twitter/Wikipedia don't. DNS returns poisoned IPs; TLS RSTs on blocked SNIs.

**Fix**: VPN with HK/JP/SG exit. If VPN app blocked, switch protocol (WireGuard → OpenVPN → Obfuscated). Last resort: `ssh -D` to a home server and SOCKS-proxy the browser.
**Don't**: retry DNS endlessly, tweak MTU, or announce VPN use on monitored networks.

### 3. Low Data Mode (case C)

iOS Personal Hotspot in Low Data Mode marks the macOS interface as `constrained`, restricting background and throughput.

**Fix**: iPhone → Settings → Personal Hotspot → Maximize Compatibility ON. Replug USB.

### 4. PMTU black hole (case D)

Long-haul cellular paths often have a path MTU below the nominal 1500. TLS handshakes (small) succeed; bulk transfers (≥few segments) black-hole on a fragment drop.

**Fix**: `sudo ifconfig <iface> mtu 1200`. Confirm improvement, then tune back toward 1500.

### 5. DNS poisoning / broken resolver (case E)

GFW's DNS poisoning returns wrong A records for blocked domains. Local captive portals sometimes do similar. Symptom: system `dig` returns junk; `dig @1.1.1.1` works.

**Fix**: `sudo networksetup -setdnsservers "<service>" 1.1.1.1 8.8.8.8`. For stronger protection, DoH via browser or `cloudflared`.

### 6. VPN interference (case F)

Even disconnected/trashed VPN apps can leave privileged helpers running that add routes, filter packets, or break DNS. "Trashing the app" only moves the `.app` bundle; the helper in `/Library/PrivilegedHelperTools/` persists.

**Fix**: see Post-trip commands above.

### 7. Path loss — pure physics (case G)

Roaming traffic is tunneled back to the home carrier: China → AT&T Phoenix = ~330 ms RTT with 10–30 % loss. TCP's congestion control collapses on lossy long-haul paths. No macOS setting fixes this.

**Fix**: a VPN that exits *closer* to you (HK/JP/SG from China). Counterintuitive, but dropping RTT to ~50 ms lets TCP recover from loss much faster than the direct roaming tunnel. Use Mosh for SSH. Use Safari (more loss-tolerant than Chrome).

---

## Important notes

- **Always run the probe fresh.** Cellular path quality changes by the minute.
- **Cite numbers, not vibes.** Every claim in the report should reference a specific `KEY: VALUE` line.
- **Rule out explicitly.** The point of this skill is to stop teammates from spending money on VPNs when the real fix is a hotspot top-up. Call out what ISN'T the problem.
- **Never run sudo non-interactively.** Print the exact command for the user to run themselves in their terminal.
- **macOS only.** The probe exits with a `macOS-only` error on other platforms. Don't fake cross-platform support.
- **Don't recommend destructive actions** (reinstalling OS, wiping profiles, `rm -rf`). This is a diagnostic skill, not a rebuild script.
- **Respect local laws.** VPN use is legal for foreigners in most jurisdictions but enforcement varies. Don't recommend VPN circumvention on managed corporate/government networks where the user lacks authorization.
