---
icon: lucide/cpu
---

# Stack für Nerds

Die technischen Details, für Neugierige. Wenn du einfach nur ein Dashboard an der
Wand willst, reichen dir die [Startseite](../index.md) und die Anleitung
[Erste Schritte](../getting-started.md) – auf dieser Seite geht es darum, *wie* es
unter der Haube funktioniert.

## Gebaut auf NixOS { #built-on-nixos }

Dashboard Assistant OS ist ein minimales, **deklaratives NixOS**-System.

- **Reproduzierbar.** Das ganze System ist in Code definiert. Das Image, das du
  flashst, ist das System, das läuft – es gibt keine Handkonfiguration, die mit der
  Zeit abdriftet.
- **Atomare Updates, geliefert über Home Assistant.** Neue Versionen erscheinen als
  `update`-Entität – Installation per Fingertipp, kein Terminal und nichts neu zu
  flashen. Ein Update wird entweder ganz angewendet oder gar nicht, und jede Version
  bleibt als NixOS-*Generation* erhalten.
- **Startet direkt in einen Kiosk.** Kein Desktop, kein Display-Manager, kein
  Anmeldebildschirm – nur Chromium im Vollbild, fest auf deine Dashboards eingestellt.

## Wiederherstellung & Rollback { #recovery-rollback }

Weil jede Version als Generation erhalten bleibt, kannst du immer zurück.

- **Manueller Rollback (heute verfügbar).** Der Button **Roll back** in Home
  Assistant startet die vorherige Generation – nützlich, wenn ein Update Ärger macht,
  das System aber noch startet und das Netzwerk erreicht. Er ist durch das
  Geräte-Token geschützt; der Touchscreen selbst ist schreibgeschützt, sodass niemand
  am Panel das Gerät zurückrollen kann. Siehe [Wiederherstellung](use-cases.md#recovery).
- **Automatischer Rollback (in Arbeit).** Nach einem fehlgeschlagenen Start
  *automatisch* in die vorherige Generation zu starten, setzt Boot-Counting voraus,
  und das kommt von **systemd-boot**. Inzwischen startet jedes Ziel darüber – auf dem
  Raspberry Pi bleibt U-Boot nur in der Kette, um die UEFI-Umgebung bereitzustellen,
  in der es läuft –, der Mechanismus ist also endlich verfügbar; das Einschalten wird
  separat verfolgt. Bis dahin läuft die Wiederherstellung von Hand.

## Speicher & Flash-Verschleiß { #storage-flash-wear }

Jedes Gerät startet von Flash-Speicher – einer SD-Karte auf dem Raspberry Pi, eMMC
oder einer SSD auf x86. Auf einer SD-Karte ist das Schreibbudget die knappste
Ressource auf dem Board, und ein Dashboard, das über Jahre rund um die Uhr läuft,
stößt an diese Grenze. Deshalb ist das OS so gebaut, dass alles, was ständig
schreibt, *nicht* auf der Karte landet.

**Was im RAM liegt**

- **Das System-Journal.** Logs werden in ein tmpfs geschrieben und einmal pro Stunde
  auf die Karte kopiert, außerdem bei einem sauberen Herunterfahren. Ein einzelner
  fehlerhafter Dienst hat einmal in einem einzigen Start 2,87 GB auf eine SD-Karte
  geschrieben; das ist nicht mehr möglich.
- **Die Caches von Chromium.** Der HTTP-Cache des Browsers und der Cache für
  kompiliertes JavaScript sind nach dem Logging die fleißigsten Dauerschreiber, und
  beide holen sich ihren Inhalt in deutlich unter einer Sekunde wieder von deinem Home
  Assistant. Sie sind auf 64 MiB im RAM begrenzt. Die GPU-Shader-Caches sind
  abgeschaltet: Sie wurden beim Zeichnen der Seite ständig neu geschrieben und
  kosteten ein Panel im Leerlauf rund 100 MiB Kartenschreibzugriffe pro Stunde.
- **`/tmp`,** damit nichts Temporäres je die Karte erreicht.
- **Screenshots.** Das Bild hinter der Screenshot-Entität in Home Assistant wird über
  den RAM zwischen Prozessen weitergereicht. Wie oft es aufgenommen wird, bestimmt
  deine Automation – vorher gab es dafür überhaupt keine Obergrenze.

**Was dich das kostet.** Bei einem Stromausfall gehen bis zu eine Stunde Logs
verloren – die Stunde seit der letzten Synchronisierung. Bei einem Panel, dem Leute
den Stecker ziehen, ist das ein echter Kompromiss, und er ist bewusst gewählt: Die
Alternative wäre, dass jede Logzeile für immer auf die Karte geschrieben wird.
Sind dir Logs vom Absturzzeitpunkt wichtiger als die Lebensdauer der Karte, bringt
dich eine Zeile zurück zum Standardverhalten:

```nix
services.journald.storage = "persistent";
```

**Was auf der Karte liegt und dafür abgestimmt ist.** Das Root-Dateisystem ist
**btrfs** mit `zstd`-Kompression und `noatime`, sodass Lesezugriffe nie
Schreibzugriffe auslösen und alles Geschriebene zuerst komprimiert wird. Swap ist
zuerst **komprimierter RAM** (zram), normales Swappen kostet also gar keine
Schreibzugriffe; eine Swap-Datei auf einem eigenen btrfs-Subvolume übernimmt erst,
wenn zram voll ist, sodass ein Gerät mit knappem Speicher langsamer wird, statt
seinen Browser neu zu starten. Home Assistant zeigt, wie viel von beidem belegt ist. Die Partitionen sind auf 1 MiB ausgerichtet, und das
Root-Dateisystem wächst beim ersten Start auf die volle Kartengröße – das vermeidet
die Write Amplification, die durch falsch ausgerichtete Partitionen entsteht. TRIM
läuft wöchentlich.

!!! tip "Prüf nach, was dein Gerät tatsächlich schreibt"

    Wenn du eine sterbende Karte vermutest, miss nach, bevor du sie austauschst.
    Feld 10 in `/proc/diskstats` sind die seit dem Start geschriebenen Sektoren, in
    Einheiten von 512 Byte:

    ```bash
    w() { awk -v d="$1" '$3==d{print $10}' /proc/diskstats; }
    dev=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
    a=$(w "$dev"); sleep 3600; b=$(w "$dev")
    echo "$(( (b-a)*512/1024 )) KiB in 1 h  ($(( (b-a)*512/1024*24/1024 )) MiB/day)"
    ```

    Um zu sehen, *welcher* Dienst dafür verantwortlich ist:

    ```bash
    systemd-cgtop --order=io -b -n 3
    ```

    Beachte, dass btrfs Metadaten und verzögerte Schreibzugriffe nicht dem Dienst
    zuordnet, der sie verursacht hat. Betrachte `systemd-cgtop` also als Rangliste
    und nicht als Messung – `/proc/diskstats` ist die ehrliche Gesamtsumme.

    SD-Karten haben keinen standardisierten Verschleißzähler, deshalb gibt es keinen
    Sensor für den „Zustand der Karte“. eMMC und NVMe haben einen:

    ```bash
    mmc extcsd read /dev/mmcblk0 | grep -iE 'life time|pre.?eol'   # eMMC
    nvme smart-log /dev/nvme0 | grep -E 'data_units_written|percentage_used'
    ```

## Home-Assistant-Integration { #home-assistant-integration }

Das Panel *zeigt* Home Assistant nicht nur an – es meldet sich dort als Gerät
zurück.

- Eine **offizielle Integration**, installierbar
  [aus dem Marketplace](../getting-started.md#integration).
- Home Assistant **entdeckt das Gerät über mDNS** und holt sich das API-Token
  selbst, solange das Gerät noch nicht provisioniert ist – es gibt also keinen Code
  einzutippen.
- **Kein MQTT-Broker nötig** – es spricht direkt mit Home Assistant.
- Stellt Steuerelemente und Sensoren bereit: Display an/aus, Helligkeit, Zoom, Dark
  Mode, Drehung, Screenshot, Neustart / Herunterfahren, Updates sowie Akku,
  Temperatur, CPU, Arbeitsspeicher und Speicherplatz.

Die vollständige Liste findest du in der
[Entitäten-Referenz](features.md#home-assistant-integration).

## Provisionierung { #provisioning }

Am Ethernet geht ein Gerät von selbst online, und Home Assistant entdeckt es von
dort aus. Im WLAN bringt eine kleine **YAML-Seed-Datei** mit den Zugangsdaten,
abgelegt auf einem USB-Stick oder der Boot-Partition, es auf demselben Weg online,
noch bevor es zum ersten Mal startet. Alles Weitere (die Home-Assistant-URL, die
Kiosk-Anmeldung, die Seiten) kommt an, wenn Home Assistant sich mit dem Gerät koppelt. So oder so kann nichts auf dem laufenden Panel
das Gerät umlenken: Der Bildschirm zeigt eine schreibgeschützte Info-Ansicht und
sonst nichts; Rollback und Werksreset laufen über Home Assistant.

## Hardware { #hardware }

x86_64 ist heute das primäre, getestete Ziel. Raspberry Pi und andere
aarch64-Boards sind in Arbeit – den aktuellen Stand findest du unter
[Hardware-Unterstützung](../hardware-support/index.md).

## Entwicklung { #development }

Dashboard Assistant wird aktiv auf
[GitHub](https://github.com/ajfriesen/DashboardAssistant) entwickelt – Issues und
Pull Requests sind willkommen.
