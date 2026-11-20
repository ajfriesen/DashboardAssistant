---
icon: lucide/rocket
---

# Erste Schritte

Vom übrigen Mini-PC oder Raspberry Pi zum fertigen Home-Assistant-Dashboard
sind es vier Schritte. Geh sie der Reihe nach durch.

## Wähle dein Image { #download }

Das aktuelle Release ist **1.3.0**
([Release Notes](https://github.com/ajfriesen/DashboardAssistant/releases/tag/v1.3.0)).
Für jedes Board gibt es ein eigenes Image. **Adresse kopieren** legt die Adresse
deines Images in die Zwischenablage; im nächsten Schritt fügst du sie in das
Flash-Programm ein.

| Board | Image | |
|---|---|---|
| x86_64 (Mini-PC, NUC) | [`dashboard-assistant-x86_64-1.3.0.raw.xz`](https://download.dashboardassistant.org/release/x86_64/dashboard-assistant-x86_64-1.3.0.raw.xz) | <button type="button" class="da-btn da-btn--ghost da-btn--compact" data-clipboard-text="https://download.dashboardassistant.org/release/x86_64/dashboard-assistant-x86_64-1.3.0.raw.xz">:lucide-copy: Adresse kopieren</button> |
| Raspberry Pi 4 | [`dashboard-assistant-rpi4-1.3.0.raw.xz`](https://download.dashboardassistant.org/release/rpi4/dashboard-assistant-rpi4-1.3.0.raw.xz) | <button type="button" class="da-btn da-btn--ghost da-btn--compact" data-clipboard-text="https://download.dashboardassistant.org/release/rpi4/dashboard-assistant-rpi4-1.3.0.raw.xz">:lucide-copy: Adresse kopieren</button> |
| Raspberry Pi 5 | [`dashboard-assistant-rpi5-1.3.0.raw.xz`](https://download.dashboardassistant.org/release/rpi5/dashboard-assistant-rpi5-1.3.0.raw.xz) | <button type="button" class="da-btn da-btn--ghost da-btn--compact" data-clipboard-text="https://download.dashboardassistant.org/release/rpi5/dashboard-assistant-rpi5-1.3.0.raw.xz">:lucide-copy: Adresse kopieren</button> |

Von Hand herunterladen musst du nichts: Das Flash-Programm holt sich das Image
selbst. Wenn du die Datei trotzdem behalten möchtest, folge dem Link in der
Tabelle. x86_64-Rechner müssen per **UEFI** booten; siehe die
[Anforderungen für x86_64](hardware-support/x86.md).

## 1. Image flashen { #flash }

Beim Flashen wird das Image auf den Datenträger geschrieben, von dem das Gerät
später bootet: bei einem Raspberry Pi eine SD-Karte, bei einem x86_64-Rechner
die SSD oder der interne Datenträger. Schließe diesen Datenträger mit einem
SD-Kartenleser, einem SATA-USB-Adapter oder einem NVMe-USB-Gehäuse an deinen
Computer an. Lässt sich der Datenträger nicht aus einem x86_64-Rechner
ausbauen, [flashe ihn stattdessen von einem Live-USB-Stick](hardware-support/x86.md#installing-onto-an-internal-disk).

!!! warning "Flashen löscht den Datenträger"
    Alles auf der SD-Karte oder dem Datenträger, den du auswählst, wird
    überschrieben. Zieh vorher andere USB-Laufwerke und Kartenleser ab, damit
    nur der richtige zur Auswahl steht.

Die Schritte sind unter Windows, macOS und Linux dieselben.

1. Lade [balenaEtcher](https://etcher.balena.io/) herunter und starte es.
2. Wähle **Flash from URL**.

    ![Startbildschirm von balenaEtcher, die Schaltfläche Flash from URL ist hervorgehoben](/img/etcher-flash-from-url.png){ width="640" loading=lazy }

3. Füge die Adresse des Images für dein Board ein und wähle **OK**.

    ![Dialog Use Image URL von balenaEtcher mit eingefügter Adresse eines Images](/img/etcher-image-url.png){ width="640" loading=lazy }

4. Wähle **Select target**, setze den Haken bei der SD-Karte oder dem
   Datenträger, auf den geschrieben werden soll, und bestätige mit **Select**.
   Etcher blendet den Datenträger aus, von dem dein Computer läuft. In der
   Liste steht also nur, was du angeschlossen hast.

    ![Zielliste von balenaEtcher, ein Wechseldatenträger ist angehakt](/img/etcher-select-target.png){ width="640" loading=lazy }

5. Prüfe, ob Image und Ziel die richtigen sind, und wähle dann **Flash!**.
   Etcher lädt das Image herunter, schreibt es und prüft das Ergebnis. Das
   Image ist mehrere GB groß, das dauert also eine Weile.

    ![balenaEtcher mit gewähltem Image und Ziel, die Schaltfläche Flash! ist aktiv](/img/etcher-flash.png){ width="640" loading=lazy }

Bricht das Flashen mittendrin ab, starte es einfach noch einmal.

Bei Ethernet baust du den Datenträger in den Zielrechner ein (oder lässt ihn,
wo er ist) und startest ihn. Für WLAN schreibst du vorher eine Seed-Datei.

??? info "Raspberry Pi 4: Bootloader-EEPROM prüfen"

    Pi-5-Boards brauchen nichts Besonderes. Ein **Raspberry Pi 4** schon: Diese
    Images nutzen eine GPT-Partitionstabelle, und die versteht der Bootloader
    des Pi 4 erst ab dem EEPROM vom September 2020. Jedes Board, das seit Ende
    2020 gekauft wurde oder auf dem schon einmal ein aktuelles Raspberry Pi OS
    lief, ist bereits auf dem nötigen Stand.

    Gibt ein Pi 4 nach dem Flashen kein Lebenszeichen von sich, prüfe seinen
    Bootloader von einer Karte mit Raspberry Pi OS aus:

    ```bash
    vcgencmd bootloader_version
    ```

    und aktualisiere ihn, wenn das Datum älter ist als `2020/09/14`:

    ```bash
    sudo rpi-eeprom-update -a && sudo reboot
    ```

    Das geht nur von einer Karte mit Raspberry Pi OS aus, nicht von unserer:
    Die EEPROM-Recovery-Datei wird von einem Teil des Chips gelesen, der noch
    aus der Zeit vor der GPT-Unterstützung stammt. Eine Dashboard-Assistant-Karte
    kann deshalb kein Board reparieren, das sie nicht booten kann.

## 2. Ins Netzwerk bringen { #seed-file }

Bei Ethernet ist nichts zu tun; mach direkt mit [Schritt 3](#integration)
weiter.

Für WLAN brauchst du eine **Seed-Datei**: Das Display kann die WLAN-Zugangsdaten
nicht auf dem Bildschirm abfragen, also kommen sie über die Seed-Datei auf das
Gerät. Sie enthält das WLAN und sonst nichts. Sobald das Gerät in deinem
Netzwerk ist, entdeckt Home Assistant es, und beim Hinzufügen dort wird der
Rest eingerichtet: die Home-Assistant-URL, die Anmeldung, das Dashboard und die
Seiten.

Lege eine Datei an, die genau `dashboard-assistant.yaml` heißt:

```yaml
wifi:
  ssid: "MyNetwork"
  psk: "supersecret"
```

| Schlüssel   | Beschreibung                                  |
| ----------- | --------------------------------------------- |
| `wifi.ssid` | Name des WLANs, mit dem sich das Gerät verbindet. |
| `wifi.psk`  | Pre-Shared Key (Passwort) des WLANs.          |

Jeder andere Schlüssel wird ignoriert.

Nach dem Flashen liegt auf der Karte oder dem Datenträger eine kleine
FAT-Partition, die jeder Computer lesen kann: die FIRMWARE-Partition, mit dem
Label **`ESP`** und auf dem Gerät als `/boot` eingehängt. Neben den Boot-Dateien
liegen dort schon eine **`README.txt`** und eine
**`dashboard-assistant.yaml.example`**. Du kannst also das Beispiel kopieren,
das `.example` entfernen und die Datei anpassen. Lege die Datei in das
Wurzelverzeichnis der Partition:

=== "Linux"

    Linux-Desktops hängen das btrfs-Root ein und lassen die FIRMWARE-Partition
    aus, weil sie eine EFI-Systempartition als Teil des Systems behandeln.
    Häng sie selbst ein; es ist die erste Partition, die mit 1 GiB:

    ```sh
    udisksctl mount -b /dev/sdX1
    ```

    Ersetze `sdX` durch die Karte oder den Datenträger (`lsblk` listet sie
    auf), kopiere die Datei in den Pfad, den `udisksctl` ausgegeben hat, und
    führe `udisksctl unmount -b /dev/sdX1` aus, bevor du den Datenträger
    abziehst.

=== "macOS"

    Der Finder zeigt die FIRMWARE-Partition als Laufwerk mit dem Namen
    **`ESP`** an; die andere Partition ist btrfs, das macOS nicht lesen kann.
    Kopiere die Datei in das Wurzelverzeichnis von `ESP` und wirf das Laufwerk
    aus, bevor du es abziehst.

=== "Windows"

    Der Explorer zeigt die FIRMWARE-Partition als Laufwerk mit dem Namen
    **`ESP`** an; die andere Partition ist btrfs, das Windows nicht lesen kann.
    Kopiere die Datei in das Wurzelverzeichnis von `ESP` und wirf das Laufwerk
    aus, bevor du es abziehst.

    !!! warning "Die Datei muss genau `dashboard-assistant.yaml` heißen"

        Mit „Erweiterungen bei bekannten Dateitypen ausblenden“ *sieht*
        `dashboard-assistant.yaml.example` aus wie `dashboard-assistant.yaml`.
        Blende die Erweiterungen vor dem Umbenennen ein, sonst findet das Gerät
        die Datei nicht.

**Die Datei wird neu gelesen, wenn du sie änderst.** Das Gerät merkt sich eine
Prüfsumme der zuletzt importierten Datei, also:

- **erster Start**: Die Datei wird angewendet.
- **du änderst sie und startest neu**: Das neue WLAN wird angewendet. So ziehst
  du ein Gerät in ein anderes Netzwerk um: ohne neu zu flashen, ohne Werksreset.
- **du lässt sie unverändert**: Es wird nichts angewendet, weder bei diesem
  noch bei einem späteren Start.
- **du löschst sie**: dasselbe. Das Löschen der Datei setzt nichts zurück.

!!! warning "Die Datei bleibt auf der Partition"
    Der Import löscht sie nicht, und sie enthält dein WLAN-Passwort im Klartext.
    Wer die Karte herauszieht, kann es also lesen. Lösch die Datei, sobald das
    Gerät eingerichtet ist, falls das am Standort des Geräts eine Rolle spielt.

Übernimmt ein Gerät die Datei nicht, liegt es meist an der YAML-Einrückung. Das
Gerät kann dir den Parse-Fehler nicht anzeigen. Vergleiche deine Datei also mit
dem Beispiel oben: zwei Leerzeichen pro Ebene, und jeder Schlüssel unter `wifi`
ist darunter eingerückt.

??? tip "Oder nimm einen USB-Stick"

    Lege `dashboard-assistant.yaml` in das Wurzelverzeichnis eines normalen
    USB-Sticks (jedes Dateisystem, das das Betriebssystem einhängen kann) und
    steck ihn in ein laufendes Gerät. Das Einstecken löst sofort einen Import
    aus. So ziehst du ein Gerät vor Ort in ein anderes Netzwerk um, ohne seine
    Karte herauszunehmen.

    Anders als bei der FIRMWARE-Partition gilt das **bei jedem Einstecken des
    Sticks**, ob geändert oder nicht. Eine Prüfsumme gibt es hier nicht.

    !!! warning "Physischer Zugriff = volles Vertrauen"
        Jeder USB-Stick mit einer `dashboard-assistant.yaml` wird automatisch
        angewendet, und die Datei enthält dein WLAN-Passwort im Klartext. Nutze
        Seed-Dateien nur auf Hardware und in Netzwerken, die du kontrollierst,
        und lösch den Stick danach.

Sobald die Datei angewendet ist, verbindet sich das Gerät mit deinem Netzwerk
und zeigt einen „Füg mich hinzu“-Bildschirm, bis Home Assistant es hinzufügt.

Ein Werksreset löscht die gespeicherte Prüfsumme. Ein zurückgesetztes Gerät
importiert die Seed-Datei, die noch auf seiner Karte liegt, also beim nächsten
Start erneut. Meist ist das genau richtig, wenn du ein Gerät neu einsetzt. Wenn
nicht, entferne die Datei vor dem Zurücksetzen von der Partition.

## 3. Zu Home Assistant hinzufügen { #integration }

Das Gerät wird aus Home Assistant heraus über die Integration **Dashboard
Assistant** verwaltet. Installiere sie einmal, und jedes Gerät in deinem
Netzwerk taucht mit eigenen Bedienelementen und Sensoren auf: Display an/aus,
Helligkeit, Seiten, Screenshots, OS-Updates und mehr (siehe die
[Entitätsübersicht](about/features.md#home-assistant-integration)).

Die Integration wird über den **Marketplace** installiert, der in Home
Assistant eingebaut ist (ab 2026.11).

[![Öffne deine Home-Assistant-Instanz und zeige das Dashboard-Assistant-Repository im Marketplace.](https://my.home-assistant.io/badges/marketplace_repository.svg)](https://my.home-assistant.io/redirect/marketplace_repository/?owner=ajfriesen&repository=dashboard-assistant-integration&category=integration)

1. Klick auf das Badge oben: Es öffnet **Dashboard Assistant** im Marketplace
   deines Home Assistant. Oder öffne **Einstellungen → Marketplace** und suche
   nach **Dashboard Assistant**.
2. Installiere **Dashboard Assistant**.
3. **Starte Home Assistant neu** (**Einstellungen → System → Neu starten**).
   Der Marketplace kopiert nur die Dateien; Home Assistant lädt die Integration
   beim Neustart.

Nach dem Neustart **entdeckt Home Assistant das Gerät von selbst** über mDNS:
Unter **Einstellungen → Geräte & Dienste → Entdeckt** erscheint eine Karte
„Dashboard Assistant“. Klick auf **Hinzufügen** und bestätige. Ein Gerät, das
noch nicht gekoppelt ist, übergibt sein API-Token von selbst. Es gibt also
keine PIN und nichts einzutippen. Ein Gerät, das mit einer Seed-Datei
eingerichtet wurde, wird genauso gekoppelt.

[![Öffne deine Home-Assistant-Instanz und zeige deine Integrationen.](https://my.home-assistant.io/badges/integrations.svg)](https://my.home-assistant.io/redirect/integrations/)

Die Erkennung ist der einzige Weg, ein Gerät hinzuzufügen. Erscheint die Karte
nicht, sieht Home Assistant die mDNS-Ankündigung des Geräts nicht, meist weil
beide in unterschiedlichen Netzwerken oder VLANs sind.

!!! note "Ein Gerät lässt sich nur einmal koppeln"
    Ein bereits gekoppeltes Gerät gibt sein Token nicht noch einmal heraus. Das
    verhindert, dass ein Fremder in deinem Netzwerk dein Gerät übernimmt. Um es
    mit einer neuen Home-Assistant-Instanz zu koppeln, drück zuerst seine
    Schaltfläche **Factory reset**; dabei wird auch sein Eintrag entfernt. Ein
    Gerät, dessen Eintrag ohne Reset gelöscht wurde, muss neu geflasht werden,
    bevor es sich wieder koppeln lässt. Siehe
    [Wiederherstellung](about/use-cases.md#recovery).

!!! info "Die Verbindung ist verschlüsselt"
    Home Assistant spricht per TLS mit dem Display und merkt sich dessen
    Zertifikat bei der ersten Verbindung. Nichts, was über die Leitung geht,
    kann jemand anderes in deinem Netzwerk mitlesen. Am wichtigsten ist das für
    die Home-Assistant-Anmeldung, die das Display bekommt, denn sie ist ein
    Zugang zu deinem Home Assistant.

    Das Zertifikat stammt vom Display selbst, du musst also nichts kaufen,
    installieren oder verlängern. Nach einem Werksreset erzeugt das Display ein
    neues, und sein Eintrag in Home Assistant bleibt mit einem Fehler stehen.
    Nach einem Reset ist das zu erwarten: Lösch den Eintrag, dann wird das
    Display wieder entdeckt und gekoppelt. Hast du es nicht gerade
    zurückgesetzt, schau lieber genauer hin.

Im Hintergrund legt die Integration für das Gerät einen eigenen **Home-Assistant-Benutzer
ohne Admin-Rechte** an (nach dem Gerät benannt, sichtbar unter
**Einstellungen → Personen**) und meldet den Browser des Geräts damit an.
Deshalb zeigt das Display nie einen Anmeldebildschirm. Der Benutzer wird wieder
entfernt, wenn du die Integration löschst. Ist das Add-on
[Music Assistant](about/use-cases.md#audio) installiert, kommt automatisch eine
Seite **Music Assistant** in die Seitenliste des Geräts, bereits angemeldet.

[![Öffne deine Home-Assistant-Instanz und zeige deine Personen.](https://my.home-assistant.io/badges/people.svg)](https://my.home-assistant.io/redirect/people/)

Erscheint ein neues Release der Integration, zeigt der Marketplace unter
**Installiert** ein Update für **Dashboard Assistant** an. Klick auf
**Aktualisieren** und starte Home Assistant danach neu.

[![Öffne deine Home-Assistant-Instanz und zeige, was du aus dem Marketplace installiert hast.](https://my.home-assistant.io/badges/marketplace_installed.svg)](https://my.home-assistant.io/redirect/marketplace_installed/)

## 4. Seiten auswählen { #pages }

Öffne **Einstellungen → Geräte & Dienste → Dashboard Assistant** und klick auf
**Configure**:

[![Öffne deine Home-Assistant-Instanz und zeige die Integration Dashboard Assistant.](https://my.home-assistant.io/badges/integration.svg)](https://my.home-assistant.io/redirect/integration/?domain=dashboard_assistant)

- **Pages**: die Seiten, die das Gerät zeigt, in dieser Reihenfolge. Jede Seite
  ist entweder eine **Home Assistant page**, ausgewählt aus deinen Dashboards
  und deren Tabs, oder eine **Website**, also die Adresse einer beliebigen
  Seite. Das Gerät meldet sich nur bei Home Assistant an, andere Websites
  werden daher unangemeldet angezeigt. Dashboards nur für Admins stehen nicht
  in der Liste, weil sich das Gerät als normaler Benutzer anmeldet.
- **Die erste Seite ist die Startseite des Geräts**: Dort startet es, und seine
  Schaltfläche **Home** führt dorthin zurück. Zieh eine Seite nach ganz oben,
  um sie zur Startseite zu machen.
- Die Auswahl **Page** und die Schaltflächen für vor und zurück wechseln
  zwischen den Seiten.

Beim Speichern geht die Liste sofort an das Gerät.

Das war's. [Anwendungsfälle](about/use-cases.md) beschreibt die Bedienung am
Gerät, die Entitäten der Integration, OS-Updates mit einem Tipp und das
Zurückrollen, falls ein Update einmal Ärger macht. Wenn etwas nicht stimmt,
erklärt [Wiederherstellung](about/use-cases.md#recovery), wie du das Gerät
zurückrollst und zurücksetzt.

[Zu den Anwendungsfällen&nbsp;→](about/use-cases.md){ .da-btn .da-btn--ghost }
