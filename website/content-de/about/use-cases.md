# Anwendungsfälle

Sobald es provisioniert ist, startet das Gerät direkt in dein Home-Assistant-Dashboard
und bleibt dort. Im Alltag steuerst du es an zwei Stellen: **am Bildschirm selbst**
und **aus Home Assistant** über die native Integration.

## Am Gerät { #on-the-device }

Eine kleine Leiste gibt dir Touch-Bedienelemente, ohne den Kiosk zu verlassen:

- **Nächste / Vorherige Seite** – blättert durch deine eingerichteten Dashboard-URLs.
- **⌨ Tastatur** – blendet die Bildschirmtastatur für Textfelder ein oder aus, auf
  Geräten, die nur einen Touchscreen haben *(experimentell)*.
- **Aufwecken per Berührung** – ein Tippen auf den Bildschirm weckt das Display, wenn
  es geschlafen hat.

Schalte in Home Assistant den Schalter **Button bar** aus, um die Leiste
auszublenden und dem Dashboard den ganzen Bildschirm zu geben. Ihre Knöpfe
verschwinden mit ihr, die Bildschirmtastatur lässt sich dann also nicht öffnen.

## Aus Home Assistant { #from-home-assistant }

Installiere die **Dashboard Assistant**-Integration
([aus dem Marketplace](../getting-started.md#integration)), und Home Assistant entdeckt das Gerät über mDNS
als ein einzelnes Gerät und koppelt sich selbst. Ein Gerät, das noch nicht hinzugefügt
wurde, übergibt sein API-Token automatisch – es gibt also nichts einzutippen. Danach
kannst du:

- Das **Display** ein-/ausschalten und die **Helligkeit** einstellen.
- Den **Zoom** anpassen und den **Dark Mode** umschalten.
- Die **Leiste** ein- oder ausblenden.
- Das Display um 0, 90, 180 oder 270° **drehen**.
- Den **Bildschirmschoner** jetzt zeigen, seinen Stil wählen oder einstellen, wie lange
  das Panel ohne Berührung wartet, bevor er startet (standardmäßig 10 Minuten; 0
  schaltet ihn ab). Ein Tippen beendet ihn. Gib ihm eine eigene **Helligkeit**, um
  das Panel zu dimmen, solange er läuft – siehe [Bildschirmschoner dimmen](#dimming-the-screen-saver).
- Auf Abruf einen **Screenshot** der aktuellen Ansicht aufnehmen.
- Die aktive **Seite** wechseln und unter **Configure** auf der Karte der Integration
  das Dashboard und die Seiten (beliebige Websites) auswählen.
- Den **Sendspin-Player** ein- oder ausschalten – siehe [Multiroom-Audio](#audio).
- Das Gerät **neu starten** oder **herunterfahren**.
- Ein **OS-Update** installieren, wenn eines verfügbar ist.

Außerdem meldet es Sensoren – CPU, Arbeitsspeicher, Speicherplatz, Temperatur,
Laufzeit, Akku (falls vorhanden) und Leerlaufzeit –, sodass du Automationen bauen
kannst (zum Beispiel das Panel nachts dimmen oder bei Bewegung aufwecken).

Die vollständige Liste der Entitäten findest du in der Referenz zur
[Home-Assistant-Integration](features.md#home-assistant-integration).

### Bildschirmschoner dimmen { #dimming-the-screen-saver }

**Screen saver brightness** legt fest, wie hell das Panel ist, solange der
Bildschirmschoner läuft. Das Gerät regelt das Panel herunter, wenn der
Bildschirmschoner startet, und zurück auf die Helligkeit des **Display**, wenn er
endet – durch ein Tippen oder aus Home Assistant. Bei 0, dem Standard, lässt der
Bildschirmschoner die Helligkeit, wie sie ist.

Die Helligkeit des Display bleibt der Wert, zu dem das Panel zurückkehrt: Verstellst
du sie, während der Bildschirmschoner läuft, änderst du diesen Wert, ohne dass der
Bildschirmschoner heller wird.

Für unterschiedliche Werte je nach Tageszeit stellst du beide aus einer Automation
ein. Diese hält den Bildschirmschoner bei 10 % und lässt das Panel tagsüber mit
100 % und nachts mit 50 % laufen:

```yaml
automation:
  - alias: "Kitchen panel: day and night brightness"
    triggers:
      - trigger: time
        at: "07:00:00"
        id: day
      - trigger: time
        at: "20:00:00"
        id: night
    actions:
      - action: number.set_value
        target:
          entity_id: number.kitchen_panel_screen_saver_brightness
        data:
          value: 10
      - action: light.turn_on
        target:
          entity_id: light.kitchen_panel_display
        data:
          brightness_pct: "{{ 100 if trigger.id == 'day' else 50 }}"
```

## Updates { #updates }

OS-Updates sind atomar und erscheinen in Home Assistant als `update`-Entität: Sie
vergleicht die installierte Version mit dem neuesten Release und bietet die
Installation per Fingertipp an. Jede Version bleibt als NixOS-Generation erhalten.
Macht ein Update Ärger, kannst du also zurückrollen (siehe [Wiederherstellung](#recovery)).

Das Gerät startet neu, um ein Update abzuschließen. **Beim Update von 1.3.0 oder
älter** tut es das noch nicht von selbst: Drück **Reboot**, sobald das Update
installiert ist. Bis dahin schlägt der Schalter **Button bar** mit einer Meldung
fehl, die dich bittet, das Gerät neu zu starten.

Das Gerät sucht stündlich nach neuen Releases. Um sofort nachzusehen, nutze in Home
Assistant **Einstellungen → Updates → ⋮ → Nach Updates suchen** (braucht die
Integration 1.2.1 oder neuer).

## Multiroom-Audio { #audio }

Das Dashboard ist auch ein Lautsprecher. Es bringt einen [Sendspin][sendspin]-Player
mit, sodass jedes Gerät mit Tonausgabe synchron in einer Multiroom-Gruppe mit deinen
anderen Lautsprechern spielen kann – dieselbe Musik, im Takt auf deutlich unter eine
Millisekunde genau.

[sendspin]: https://www.sendspin-audio.com/

### Was du brauchst { #what-you-need }

Sendspin besteht aus einem **Server**, der die Musik liefert, und **Playern**, die
sie empfangen. Das Dashboard ist nur ein Player. Der Server ist [Music
Assistant][ma] – installiere ihn in Home Assistant, falls du ihn noch nicht nutzt.
Auf der Seite des Dashboards gibt es sonst nichts zu konfigurieren: Der Player kündigt
sich über mDNS in deinem lokalen Netzwerk an, und Music Assistant findet ihn und
verbindet sich mit ihm.

[ma]: https://www.music-assistant.io/

Der Ton verlässt nie dein Netzwerk, und nirgends auf dem Weg gibt es ein
Cloud-Konto.

Die Verbindung ist verschlüsselt. Sendspin kann einen Server sich mit einem Player
**koppeln** lassen, bevor er spielt, mit einem Code, den der Player anzeigt. Das
Dashboard verlangt das noch nicht: Jedes Music Assistant in deinem Netzwerk kann
darauf spielen, ohne dass du etwas eintippen musst.

### Benutzung { #using-it }

Sobald das Gerät im Netzwerk ist, erscheint es in Music Assistant als Player, der
nach dem Gerät benannt ist – **Dashboard Assistant (ab12cd)**, passend zu dem Namen,
den die Home-Assistant-Integration verwendet. Schick Musik darauf wie auf jeden
anderen Lautsprecher, oder füge es einer Gruppe hinzu, dann bleibt es mit dem Rest
synchron.

Die Lautstärke regelst du in Music Assistant, nicht am Gerät.

### Musik vom Dashboard aus steuern { #controlling-music-from-the-dashboard }

Ist Music Assistant als Home-Assistant-**Add-on** installiert, fügt die Integration
dem Gerät automatisch eine Seite **Music Assistant** hinzu. Wähle sie über die
`Page`-Select-Entität aus oder wische am Gerät dorthin, und die vollständige
Oberfläche von Music Assistant erscheint auf dem Bildschirm – stöbere in der
Bibliothek und schick deine Auswahl an den eigenen Player des Geräts oder an jeden
anderen Lautsprecher im Haus.

Niemand muss sich anmelden. Seit Music Assistant 2.7 ist eine Anmeldung Pflicht, und
es führt eigene Konten, getrennt von denen in Home Assistant. Das Add-on wird aber
über Ingress von Home Assistant erreicht: Es erfährt, wer angemeldet ist, und legt
ein passendes Music-Assistant-Konto ohne Passwort an. Das Gerät ist bereits bei Home
Assistant angemeldet, also ist es auch schon bei Music Assistant angemeldet.

Zwei Dinge solltest du wissen:

- Dieses Konto ist ein normales Konto ohne Admin-Rechte. Zeigt das Dashboard keine
  Lautsprecher oder keine Musik, muss ihm ein Admin eventuell unter **Settings → User
  Management** in Music Assistant Zugriff geben.
- Wird der Browser einmal von Home Assistant abgemeldet, landet er wieder auf dem
  Home-Assistant-Dashboard und nicht auf dieser Seite – wie nach einem frischen Start.
  Wisch einfach zurück.

Ein **eigenständiger** Music-Assistant-Server – einer, der kein Home-Assistant-Add-on
ist – bekommt keine Seite, denn ohne Ingress gibt es nichts, womit sich das Gerät
anmelden ließe. Füge seine URL von Hand als Seite hinzu (unter **Configure**, siehe
[Seiten auswählen](../getting-started.md#pages))
und melde dich einmal am Gerät an.

### Ausschalten { #turning-it-off }

Die Integration stellt einen Schalter **Sendspin player** bereit. Ausschalten stoppt
den Player, und das Gerät verschwindet aus Music Assistant; Einschalten bringt es
sofort zurück. Die Einstellung übersteht einen Neustart.

Der Schalter trägt außerdem ein `status`-Attribut, das meldet, was der zugrunde
liegende Dienst tatsächlich tut (`active`, `inactive`, `failed`) – nützlich, wenn ein
Gerät eingeschaltet ist, aber keine funktionierende Tonausgabe hat.

### Eine andere Ausgabe wählen { #picking-a-different-output }

Geräte mit mehr als einer Ausgabe, etwa HDMI plus ein USB-DAC oder ein
Lautsprecher-HAT, spielen vielleicht auf der falschen. Wähle die richtige mit dem
Select **Audio output** am Gerät in Home Assistant. Es listet jede Ausgabe des
Geräts auf, und ein USB-Lautsprecher erscheint dort, sobald er eingesteckt ist.

Die Wahl verlegt den gesamten Ton des Geräts: Musik über Sendspin und Ton vom
Dashboard selbst, etwa TTS oder eine Media-Karte. Sie übersteht einen Neustart.

### Ein Mikrofon wählen { #picking-a-microphone }

Das Select **Audio input** daneben wählt das Mikrofon, etwa ein USB-Mikrofon, eine
Freisprecheinrichtung oder den Eingang einer Soundkarte. Es bleibt nicht verfügbar,
bis das Gerät eines hat, und füllt sich, sobald eines eingesteckt ist. Noch nimmt
nichts auf dem Gerät davon auf; es ist für einen Sprachassistenten da. Wie bei der
Ausgabe übersteht die Wahl einen Neustart.

### Build-Optionen { #build-options }

`dashboardAssistant.sendspin.name` überschreibt den Namen des Players, `server` lässt
den Player sich mit einem bestimmten Server verbinden, statt darauf zu warten,
gefunden zu werden (nützlich, wo Multicast blockiert ist), `bufferMs` tauscht Latenz
gegen gleichmäßigere Wiedergabe, und `output` legt den Player auf ein Gerät fest,
statt das Select Audio output zu nutzen (`sendspin-cli -l` listet sie auf).
`dashboardAssistant.sendspin.enable = false` lässt den Audio-Stack ganz aus dem Image
heraus.

## Fernzugriff (VNC) { #remote-access }

Manches ist an einem wandmontierten Touchscreen mühsam, etwa die Anmeldung bei Google
Kalender, damit eine Kalenderseite deine Termine zeigen kann. Dafür kann das
Dashboard einen VNC-Server starten. Du siehst seinen Bildschirm auf deinem Computer
und benutzt deine eigene Tastatur und Maus, und alles, was du tust, passiert auf dem
Gerät.

VNC ist **aus**, bis du es in Home Assistant einschaltest. Nach einer Zeitspanne
schaltet es sich von selbst wieder aus, und nach einem Neustart des Geräts ist es
immer aus.

### Einschalten { #switching-it-on }

Das Gerät hat in Home Assistant zwei Entitäten:

- **VNC**: ein Schalter, der den Server startet und stoppt.
- **VNC timeout**: wie viele Minuten VNC an bleibt, bevor es sich von selbst
  schließt, standardmäßig 15. Stell 0 ein, damit VNC an bleibt, bis du es ausschaltest.

Schalte den Schalter **VNC** ein und öffne seine Details. Die Attribute zeigen
alles, was du zum Verbinden brauchst:

| Attribut    | Was es ist                                              |
|-------------|---------------------------------------------------------|
| `address`   | Wohin du dich verbindest, z. B. `192.168.1.50:5900`     |
| `username`  | Immer `dashboard`                                       |
| `password`  | Ein neues Zufallspasswort, erzeugt für diese Sitzung    |
| `closes_at` | Wann VNC sich selbst ausschaltet                        |

Jedes Mal, wenn VNC eingeschaltet wird, erzeugt das Gerät ein neues Passwort. Sobald
die Sitzung endet, funktioniert das alte Passwort nicht mehr. Home Assistant hält
das Passwort aus seinem Verlauf und aus Diagnose-Downloads heraus.

Solange VNC an ist, zeigt das Gerät in seiner unteren Leiste eine rote Markierung
**● Remote access**, damit jeder davor weiß, dass der Bildschirm gerade beobachtet
werden kann. Hast du die Leiste mit dem Schalter **Button bar** ausgeblendet, ist
auch die Markierung ausgeblendet. Das Einschalten von VNC schaltet außerdem den Bildschirm ein und beendet
den Bildschirmschoner. Sonst würdest du auf ein dunkles Panel schauen.

### Welche VNC-App du nimmst { #which-vnc-app-to-use }

Die Verbindung ist immer verschlüsselt, und das Gerät lehnt VNC-Apps ab, die sie
nicht verschlüsseln können. Diese Apps funktionieren:

- [TigerVNC](https://tigervnc.org/) 1.13 oder neuer (Windows, macOS, Linux)
- [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/) (alle Plattformen, auch Smartphones)
- [Remmina](https://remmina.org/) (Linux)

Die in macOS eingebaute App **Bildschirmfreigabe** funktioniert nicht, weil sie die
Verbindung nicht so verschlüsseln kann, wie das Gerät es verlangt. Nimm auf einem
Mac TigerVNC oder RealVNC Viewer.

Beim ersten Verbinden bittet dich deine VNC-App vielleicht, den Schlüssel oder das
Zertifikat des Geräts zu bestätigen. Akzeptiere es. Der Schlüssel bleibt von Sitzung
zu Sitzung gleich, die App fragt also erst nach einem Werksreset wieder.

### Gut zu wissen { #good-to-know }

- Deine Maus und Tastatur funktionieren, aber das Gerät zählt sie nicht als
  Berührungen. Schaltet eine Home-Assistant-Automation den Bildschirm einige Zeit nach
  der letzten Berührung aus, kann das passieren, während du verbunden bist. Pausiere
  sie oder verlängere ihre Verzögerung, solange du arbeitest.
- VNC antwortet nur in deinem lokalen Netzwerk, wie der Rest des Geräts.
- Wenn du gar keinen Fernzugriff willst, lass den Schalter aus. Solange er aus ist,
  lauscht nichts auf VNC-Verbindungen.

## Wiederherstellung { #recovery }

Der Bildschirm des Geräts ist absichtlich langweilig. Er zeigt dein Dashboard, eine
Navigationsleiste und eine schreibgeschützte Info-Ansicht, und nichts darauf kann
ändern, wie das Gerät konfiguriert ist. Ein gemeinsam genutzter Bildschirm wird von
Gästen, Mitbewohnern und Kindern angefasst, und keiner von ihnen soll ihn
zurückrollen oder zurücksetzen können.

Deshalb läuft die Wiederherstellung über Home Assistant, auf der Seite des Geräts
unter **Einstellungen → Geräte & Dienste → Dashboard Assistant**. Jede Anfrage trägt
das Token, das das Gerät Home Assistant bei der Kopplung übergeben hat, und nichts
anderes in deinem Netzwerk kann das Gerät zurückrollen oder zurücksetzen.

[![Öffne deine Home-Assistant-Instanz und zeige die Dashboard-Assistant-Integration an.](https://my.home-assistant.io/badges/integration.svg)](https://my.home-assistant.io/redirect/integration/?domain=dashboard_assistant)

### Ein Update zurückrollen { #roll-back-an-update }

Jedes Update bleibt als NixOS-Generation erhalten, die vorherige Version liegt also
noch auf dem Gerät. Hat ein Update etwas kaputt gemacht, drück **Roll back**. Das
Gerät wechselt auf die Generation vor der aktuellen, startet neu und startet so
lange diese, bis es wieder ein Update einspielt.

Auf einem Gerät mit nur einer Generation, etwa einem frisch geflashten, wird der
Druck abgelehnt: Es gibt nichts, wohin es zurückgehen könnte.

!!! note "Der automatische Rollback ist noch nicht eingeschaltet"
    Ein Update, nach dem das Gerät das Netzwerk nicht mehr erreicht, lässt sich nicht
    aus Home Assistant zurückrollen, weil Home Assistant es dann auch nicht erreicht.
    Diesen Fall wird der automatische Start der vorherigen Generation nach einem
    fehlgeschlagenen Start abdecken; bis er eingeschaltet ist, flashe das Gerät neu
    oder schließ eine Tastatur an und wähle im Boot-Menü eine frühere Generation.

### Werksreset { #factory-reset }

**Factory reset** löscht die Kopplung des Geräts, seine Display-Einstellungen, seine
Seitenliste **und seine gespeicherten WLAN-Netzwerke** und startet dann neu. Home
Assistant entfernt gleichzeitig den Eintrag des Geräts, denn das Gerät kommt mit
einem neuen Token zurück, das der alte Eintrag nie verwenden könnte.

Mit einem Reset ziehst du ein Gerät zu einem anderen Home Assistant um oder in ein
anderes Haus:

- **Am Ethernet** kommt es von selbst zurück, und Home Assistant entdeckt es
  wieder.
- **Im WLAN** liest es die [Seed-Datei](../getting-started.md#seed-file) erneut, falls noch eine
  auf seinem Boot-Medium liegt, und verbindet sich mit diesem Netzwerk. Hast du sie
  gelöscht oder zieht das Gerät in ein anderes Netzwerk um, schreib zuerst eine neue.

Sobald es wieder im Netzwerk ist, füge es über die entdeckte Karte erneut hinzu, so
wie [Home-Assistant-Integration](../getting-started.md#integration) es beschreibt.

### Wenn der Eintrag schon weg ist { #if-the-entry-is-already-gone }

Ein Gerät koppelt sich einmal. Wurde sein Eintrag ohne vorherigen Werksreset
gelöscht oder das Home Assistant, zu dem es gehörte, ohne Backup neu installiert,
hält das Gerät noch seine alte Kopplung und weigert sich, sich erneut zu koppeln.
Nichts im Netzwerk kann das rückgängig machen, und das ist Absicht: Sonst könnte
jeder in deinem Netzwerk dein Gerät übernehmen. [Flashe es neu](../getting-started.md#flash)
und richte es wieder per Seed-Datei ein.

### Wenn das Netzwerk weg ist { #if-the-network-is-gone }

Home Assistant muss das Gerät erreichen können, es kann also keinem helfen, das sich
nicht mit dem Netzwerk verbindet.

- Leg eine [Seed-Datei](../getting-started.md#seed-file) auf einen USB-Stick und steck ihn ein. Das
  Gerät wendet sie an – das ist der Weg zurück ins WLAN.
- Schließ Ethernet an, das braucht überhaupt keine Konfiguration.
- Zieh die Karte oder die Disk heraus und lies das Journal direkt aus, oder flashe sie neu.
