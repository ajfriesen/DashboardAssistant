---
status: accepted
---

# VNC is encrypted only, with a password per session

A device can run a VNC server (wayvnc) so its owner can use the kiosk from a computer, for jobs a touchscreen is bad at, like signing in to Google Calendar. Home Assistant switches it on and off through the device API. It is never on after a boot or a daemon restart, and it closes itself after a timeout (15 minutes by default, 0 = never).

What travels over that connection is the screen and every key typed, so a Google password would cross the network in whatever form VNC uses. That decides two things.

**Only encrypted security types are offered.** wayvnc is given an RSA key for RSA-AES and a certificate for VeNCrypt/TLS, and never `relax_encryption` or `allow_broken_crypto`. The VM test (`tests/vnc.nix`) asserts on the wire that the server offers RSA-AES, RSA-AES-256 and VeNCrypt X509Plain, and nothing else. This shuts out macOS's built-in Screen Sharing, which only speaks VNC authentication or Apple Diffie-Hellman. Apple DH protects the password exchange but leaves the session itself unencrypted, so turning it on would bring back exactly the exposure this avoids.

**The password is random and made per session.** The seed file carries Wi-Fi only ([0001](0001-seed-file-is-the-only-way-to-configure-a-device.md)), so a password could only be set from Home Assistant or made on the device. The device makes it each time VNC goes on, and Home Assistant shows it as an attribute of the switch. Nothing has to be set up, and a password that leaks stops working when the session ends. The integration excludes it from the recorder and redacts it in diagnostics. A daemon restart stops any running wayvnc, because the new daemon would have no timer for it and no record of its password.

## Considered Options

- **A fixed password set from Home Assistant** (a text entity). Easier to keep in a password manager, but it lives forever and anyone who once saw it keeps access. Declined.
- **Allow Apple Diffie-Hellman for macOS Screen Sharing.** Declined for the reason above. TigerVNC and RealVNC Viewer both run on macOS.
- **No network listener at all, VNC only through an SSH tunnel.** Release images have no SSH, and adding it would be a larger surface than one encrypted, temporary listener.

## Consequences

- Port 5900 is open in the firewall permanently. Nothing listens on it while VNC is off.
- The VNC keys are kept between sessions, so a client that pinned the key doesn't warn every time. They are 0640 because wayvnc runs as the kiosk user. That is the same trust level as the kiosk token the kiosk user already reads. A factory reset deletes them.
- Input over VNC is not a touch. The screen saver is held off during a session, but a Home Assistant automation keyed on the last-touch sensor can still turn the screen off under someone working remotely.
- While VNC is on, the kiosk's bottom bar shows a red "Remote access" marker, so people at the device know the screen may be watched.
