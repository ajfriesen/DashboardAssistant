# Remote access (VNC)

Some things are hard to do on a wall-mounted touchscreen, like signing in to
Google Calendar so a calendar page can show your events. For those, the
dashboard can run a VNC server. You see its screen on your computer and use
your own keyboard and mouse, and whatever you do happens on the device.

VNC is **off** until you switch it on in Home Assistant. It switches itself off
again after a timeout, and it is always off after the device restarts.

## Switching it on

The device has two entities in Home Assistant:

- **VNC**: a switch that starts and stops the server.
- **VNC timeout**: how many minutes VNC stays on before it closes by itself,
  15 by default. Set it to 0 to keep VNC on until you switch it off.

Turn on the **VNC** switch and open its details. The attributes show
everything you need to connect:

| Attribute   | What it is                                     |
|-------------|------------------------------------------------|
| `address`   | Where to connect, e.g. `192.168.1.50:5900`     |
| `username`  | Always `dashboard`                             |
| `password`  | A new random password, made for this session   |
| `closes_at` | When VNC switches itself off                   |

Every time VNC is switched on, the device makes a new password. Once the
session ends, the old password stops working. Home Assistant keeps the password
out of its history and out of diagnostics downloads.

While VNC is on, the device shows a red **● Remote access** marker on its
bottom bar, so anyone in front of it knows the screen may be watched. Switching
VNC on also turns the screen on and closes the screen saver. Otherwise you
would be looking at a dark panel.

## Which VNC app to use

The connection is always encrypted, and the device refuses VNC apps that can't
encrypt it. These apps work:

- [TigerVNC](https://tigervnc.org/) 1.13 or newer (Windows, macOS, Linux)
- [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/) (all platforms, including phones)
- [Remmina](https://remmina.org/) (Linux)

The **Screen Sharing** app built into macOS does not work, because it can't
encrypt the connection the way the device requires. Use TigerVNC or RealVNC
Viewer on a Mac.

The first time you connect, your VNC app may ask you to confirm the device's
key or certificate. Accept it. The key stays the same from one session to the
next, so the app only asks again after a factory reset.

## Good to know

- Your mouse and keyboard work, but the device doesn't count them as touches.
  If a Home Assistant automation turns the screen off some time after the last
  touch, it may do so while you're connected. Pause it, or raise its delay,
  while you work.
- VNC only answers on your local network, like the rest of the device.
- If you don't want remote access at all, leave the switch off. Nothing listens
  for VNC connections while it is off.
