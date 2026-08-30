# Connect to Home Assistant

The device is managed from Home Assistant through the first-party **Dashboard
Assistant** integration. Install it once and every kiosk on your network shows
up as a device with its own controls and sensors — display power, brightness,
pages, screenshots, OS updates and more (see the
[entity reference](../about/features.md#home-assistant-integration)).

The integration is distributed through [HACS](https://hacs.xyz/) as a **custom
repository** — it is not in the default HACS store, so searching HACS alone
won't find it. Adding the repository is a one-time step; after that, updates
show up in HACS like any other integration.

## Prerequisites

- A running Home Assistant instance you can reach in a browser.
- [HACS](https://hacs.xyz/) installed and set up. If you don't have it yet,
  follow the official [HACS installation guide](https://hacs.xyz/docs/use/download/download/).

## 1. Add the custom repository

1. In Home Assistant, open **HACS** from the sidebar.
2. Click the **⋮** menu in the top-right corner and choose **Custom
   repositories**.
3. In the **Repository** field, paste:
   ```
   https://github.com/ajfriesen/dashboard-assistant-integration
   ```
4. Set **Type** (or **Category**) to **Integration**.
5. Click **Add**, then close the dialog.

## 2. Install the integration

1. Back in HACS, search for **Dashboard Assistant** and open it.
2. Click **Download** and pick the latest version.
3. **Restart Home Assistant** when prompted (**Settings → System → Restart**).
   HACS only copies the files; Home Assistant loads the integration on restart.

!!! warning "No version to download? Enable beta versions"
    Current releases are release candidates, which are published as
    **pre-releases** — and HACS hides pre-releases by default, so the download
    dialog can appear empty. On the integration's page in HACS, open the **⋮**
    menu, choose **Redownload**, and enable the **beta versions** toggle to see
    them.

## 3. Add the device

After the restart, Home Assistant **discovers the kiosk on its own** over
mDNS — a "Dashboard Assistant" discovered card appears under **Settings →
Devices & services**. Click **Configure** and choose **Pair automatically
(recommended)**: a device that has not been paired yet hands over its API
token by itself, so there is no PIN and nothing to type.

If the card doesn't appear, or you preset a token, add it manually:

1. Go to **Settings → Devices & services → Add integration**.
2. Search for **Dashboard Assistant** and select it.
3. Enter the connection details:
    - **Host / port** — the device's IP or hostname; the API defaults to port
      **8081**.
    - **API token** — the `api_token` from the device's
      [seed file](../flash/seed.md). The device never displays its token, so
      if you did not preset one, use the automatic discovery path instead and
      let it pair.

!!! note "A device only pairs once"
    An already-paired device refuses to hand out its token again — that is what
    keeps a stranger on your network from adopting your panel. To pair it with
    a new Home Assistant instance, factory-reset it from its
    [admin page](admin.md) first.

## What you get

The kiosk appears as a **single device** with all its entities — the complete
list is in the [entity reference](../about/features.md#home-assistant-integration),
and the [Usage](usage.md#from-home-assistant) guide shows what day-to-day
control looks like.

Two things happen behind the scenes that are worth knowing about:

- The integration creates a dedicated **non-admin Home Assistant user** for the
  kiosk (named after the device, visible under **Settings → People**) and logs
  the device's browser in with it — that is why the panel never shows a login
  screen. The user is removed again if you delete the integration.
- If the [Music Assistant](audio.md) add-on is installed, a **Music Assistant**
  page is added to the device's page list automatically, already signed in.

## Updating

When a new release is published, HACS shows an update on the **Dashboard
Assistant** card. Click **Update**, then restart Home Assistant.
