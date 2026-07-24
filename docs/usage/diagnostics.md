# Diagnostics

When something goes wrong on a kiosk you can't SSH into, Dashboard Assistant can
show recent logs on a **local-network page** that the user opens from their own
phone or laptop, copies, and sends to you. It's **opt-in**, gated by a one-time
code shown on the device, and secrets are stripped out automatically.

!!! note "Off by default"
    The diagnostics page is disabled unless you enable it. When on, it opens a
    single port on the **local network only** (never the internet) and lets the
    daemon read its own logs.

## Enable it

Set the option in your configuration and redeploy:

```nix
dashboardAssistant.diagnostics.enable = true;
# dashboardAssistant.diagnostics.port = 8099;  # optional, this is the default
```

## Collect logs (what the user does)

1. On the device, tap **⚙ Config → Diagnostics**, then **Start diagnostics
   session**. The screen shows a URL (like `http://192.168.1.42:8099/diag`) and a
   6-digit code.
2. On a phone or laptop **on the same Wi-Fi**, open that URL.
3. Enter the code, tap **Load logs**, then **Copy to clipboard**.
4. Paste the logs into an email or a GitHub issue.

The code expires after 15 minutes; start a new session to get a fresh one.

## What's included — and what's removed

The page shows a device summary (hostname, IP, model, version, Home Assistant
URL, MQTT broker) and the recent journal for the daemon and kiosk session.

Secrets are redacted before anything is shown — the Home Assistant access token,
the MQTT password, and values that look like tokens or passwords are replaced
with `«redacted»`. Logs can still contain local IP addresses and entity names, so
glance over them before sharing.

## Security notes

- Only the diagnostics port is opened, and only on the LAN — the main control
  API stays reachable from the device itself (loopback) only.
- Access requires a fresh one-time code shown on the device; the page itself
  carries no data until a valid code is entered.
- Leave the feature **disabled** on untrusted networks.
