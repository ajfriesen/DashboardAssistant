<!-- ---
icon: lucide/sparkles
--- -->

# Funktionen

**Der Kiosk**

- Chromium im Vollbild, fest auf dein Home-Assistant-Dashboard eingestellt.
- Mehrere Dashboard-URLs oder beliebige Websites einrichten und zwischen ihnen wechseln (von HA aus oder am Bildschirm).
- Das Display per Berührung aufwecken.
- Bildschirmschoner nach einer Weile ohne Berührung (standardmäßig 10 Minuten):
  eine wandernde Uhr oder das hüpfende Logo über dem Dashboard, ein Tippen beendet ihn.
- Bildschirmtastatur für Textfelder auf Geräten, die nur einen Touchscreen haben. (Experimentell)
- Automatische Anmeldung mit einem langlebigen HA-Token – kein Durchtippen durch den Anmeldebildschirm.

**Multiroom-Audio** – siehe [Multiroom-Audio](use-cases.md#audio).

- Das Dashboard ist auch ein Lautsprecher: Ein eingebauter [Sendspin](https://www.sendspin-audio.com/)-Player
  spielt synchron in einer Gruppe mit deinen anderen Lautsprechern.
- Music Assistant gibt den Ton an. Als Home-Assistant-Add-on installiert, bekommt es
  automatisch eine Seite auf dem Dashboard – bereits angemeldet, weil Ingress die
  Home-Assistant-Identität des Geräts weiterreicht.
- Der Ton verlässt nie dein Netzwerk, und nirgends auf dem Weg gibt es ein Cloud-Konto.

**Fernzugriff** – siehe [Fernzugriff (VNC)](use-cases.md#remote-access).

- Schalte von Home Assistant aus einen VNC-Server ein, um das Dashboard von deinem
  Computer aus zu bedienen, zum Beispiel um dich bei Google Kalender anzumelden.
- Nur verschlüsselt, mit einem neuen Passwort für jede Sitzung. Er schließt sich nach
  einer Zeitspanne von selbst, und solange er läuft, zeigt der Bildschirm eine Markierung.

**Steuerung aus Home Assistant** – siehe die [Entitäten-Referenz](#home-assistant-integration).

**Bleibt am Leben**

- Atomare OS-Updates, die in Home Assistant als `update`-Entität erscheinen.
- Wiederherstellung eingebaut: Wenn ein Update Ärger macht, rollst du mit einem Button
  in Home Assistant auf die vorherige Generation zurück – nicht am Touchscreen, und
  geschützt durch das Geräte-Token ([Wiederherstellung](use-cases.md#recovery)). (Der automatische Rollback nach einem fehlgeschlagenen Start ist noch nicht eingeschaltet,
  obwohl inzwischen jedes Image über systemd-boot startet, das ihn bereitstellt.)

**Einrichtung ohne Handarbeit**

- Am Ethernet richtet sich ein Gerät ganz ohne Eingabe ein: Es geht online, und
  Home Assistant entdeckt es von dort aus.
- Im WLAN bringt eine kleine YAML-Seed-Datei mit den Zugangsdaten, abgelegt auf einem
  USB-Stick oder der Boot-Partition, das Gerät online, noch bevor es zum ersten Mal startet –
  ganz ohne Bildschirm. Alles Weitere richtet Home Assistant bei der Kopplung ein.
- Nichts auf dem Bildschirm des Geräts ändert seine Konfiguration. Die Leiste enthält
  nur die Navigation und die Tastatur, und die ⓘ-Ansicht ist schreibgeschützt. Die
  Wiederherstellung (Rollback, Werksreset) läuft über Home Assistant.

## Home-Assistant-Integration { #home-assistant-integration }

Installiere die offizielle **Dashboard Assistant**-Integration
([aus dem Marketplace](../getting-started.md#integration)), und Home Assistant entdeckt das Gerät
über mDNS. Ein Gerät, das noch nicht hinzugefügt wurde,
übergibt sein API-Token automatisch – es gibt also nichts einzutippen und nichts am
Gerät zu drücken. Es erscheint als ein einzelnes Gerät mit diesen Entitäten:

### Steuerung { #controls }

| Entität | Typ | Was sie tut |
|---|---|---|
| Display | `light` | Das Panel ein-/ausschalten (DPMS) und die Helligkeit einstellen |
| Zoom | `number` | Browser-Zoom, 25–400 % |
| Dark mode | `switch` | Das Home-Assistant-Frontend zwischen dunkel und hell umschalten |
| Rotation | `select` | Das Display um 0 / 90 / 180 / 270° drehen |
| Button bar | `switch` | Die untere Leiste ein- oder ausblenden. Ausgeblendet bekommt das Dashboard den ganzen Bildschirm, und die Bildschirmtastatur lässt sich nicht öffnen |
| Screen saver | `switch` | Den Bildschirmschoner jetzt zeigen oder beenden. Schaltet sich nach der Leerlaufzeit auch von selbst ein und bei einer Berührung wieder aus |
| Screen saver style | `select` | Welcher Bildschirmschoner gezeigt wird (Uhr, Logo) |
| Screen saver timeout | `number` | Minuten ohne Berührung, bis der Bildschirmschoner startet, 0–240; 0 schaltet den Leerlauf-Auslöser ab |
| Screenshot | `button` + `image` | Die aktuelle Webansicht auf Abruf aufnehmen; die neueste Aufnahme erscheint als Bild, das du zum Vergrößern anklicken kannst |
| Page | `select` | Zu einer deiner Seiten springen (die Liste bearbeitest du unter **Configure**, siehe [Home-Assistant-Integration](../getting-started.md#pages)) |
| Next / Previous page | `button` | Durch die Dashboard-URLs blättern |
| Sendspin player | `switch` | Den Multiroom-Audio-Player des Geräts ein-/ausschalten; trägt ein `status`-Attribut. Nur bei Builds mit Audio-Stack |
| VNC | `switch` | Den Fernzugriff über VNC starten oder stoppen. Solange er läuft, tragen die Attribute die Adresse, den Benutzernamen, das Passwort dieser Sitzung und den Zeitpunkt, zu dem er sich schließt |
| VNC timeout | `number` | Minuten, bis VNC sich selbst ausschaltet, 0–240; bei 0 bleibt es an, bis du es ausschaltest |
| Reboot / Shut down | `button` | Das Gerät neu starten oder herunterfahren |
| Roll back | `button` | Die vorherige System-Generation starten. Wird abgelehnt, wenn es nur eine gibt |
| Factory reset | `button` | Die Kopplung, die Einstellungen und das WLAN vergessen, neu starten und den Eintrag entfernen. Siehe [Wiederherstellung](use-cases.md#recovery) |
| System update | `update` | Installierte Version gegenüber dem neuesten Release, mit Installation per Fingertipp |

### Sensoren { #sensors }

| Entität | Typ | Hinweise |
|---|---|---|
| Battery / Battery charging | `sensor` / `binary_sensor` | Nur wenn das Gerät einen Akku hat |
| Temperature | `sensor` | CPU-/Board-Temperatur, wenn es einen Temperatursensor gibt |
| CPU usage | `sensor` | |
| Memory total / used | `sensor` | |
| Storage total / used | `sensor` | |
| Generations | `sensor` | Anzahl der startbaren NixOS-Generationen |
| Seconds since last touch | `sensor` | Für Anwesenheits- und Leerlauf-Automationen |
| Hostname | `sensor` | Geräteinfo / Diagnose |
| IP address | `sensor` | Geräteinfo / Diagnose |
| Uptime | `sensor` | Geräteinfo / Diagnose |
| Model | `sensor` | Geräteinfo / Diagnose |
| Serial | `sensor` | Geräteinfo / Diagnose |
