# FAQ

Häufig gestellte Fragen:

## Wird Android unterstützt? { #does-it-support-android }

Nein.

## Kann ich mich per SSH auf dem Gerät anmelden? { #can-i-ssh-into-the-device }

Nein. Dashboard Assistant ist eine Appliance, also ein fertiges Gerät, und kein
weiterer PC, um den du dich kümmern musst. Das Image hat überhaupt keinen
SSH-Server; alles, was du mit dem Gerät tun musst, erledigst du aus Home Assistant.

## Kann ich Musik abspielen? { #can-i-play-music }

Ja. Jedes Gerät bringt einen [Sendspin](https://www.sendspin-audio.com/)-Player
mit. Damit taucht es in Music Assistant als Lautsprecher auf, auf dem du Musik
abspielen kannst – allein oder synchron mit deinen anderen Lautsprechern. Siehe
[Multiroom-Audio](use-cases.md#audio).

## Warum noch ein Kiosk-OS? { #why-another-kiosk-os }

Die meisten „Wandtablet“-Aufbauten sind ein Stapel aus Handgriffen: Sperrbildschirm
abschalten, einen Kiosk-Browser per Sideload installieren, mit dem OS-Updater kämpfen
und hoffen, dass nach einem Neustart noch alles läuft. Dashboard Assistant geht den
umgekehrten Weg:

- **Deklarativ und reproduzierbar.** Das ganze System ist in NixOS definiert. Das
  Image, das du flashst, ist das System, das läuft – es gibt keine Handkonfiguration,
  die mit der Zeit abdriftet.
- **Wiederherstellbar von Haus aus.** Updates sind atomar, und jede Version bleibt als
  NixOS-Generation erhalten. Macht eine davon Ärger, startet der Button **Roll back** in
  Home Assistant die vorherige – der Touchscreen selbst bleibt schreibgeschützt.
  Siehe [Wiederherstellung](use-cases.md#recovery). (Der automatische Rollback nach einem fehlgeschlagenen Start ist noch nicht eingeschaltet,
  obwohl inzwischen jedes Image über systemd-boot startet, das ihn bereitstellt.)
- **Ein vollwertiger Teil von Home Assistant.** Das Panel *zeigt* Home Assistant nicht
  nur an – eine native Integration (installierbar
  [aus dem Marketplace](../getting-started.md#integration)) meldet es als Gerät mit eigenen
  Steuerelementen und Sensoren zurück (Display, Helligkeit, Zoom, Screenshots, CPU,
  Temperatur und mehr).

## Warum gibt es Dashboard Assistant? { #why }

Ich wollte Home Assistant an der Wand haben. Was ich *nicht* wollte: das Ding
bemuttern, das es anzeigt. Jede Lösung, die ich ausprobiert habe, hatte einen
Haken – also habe ich die gebaut, die ich mir gewünscht hätte.

### Das Problem mit den üblichen Lösungen { #the-problem-with-the-usual-options }

- **Android-Tablets veralten schnell.** Die meisten günstigen Tablets bekommen nach
  ein, zwei Jahren keine Updates mehr. Die Sicherheitspatches versiegen, der Browser
  fällt zurück – und schon hängt ein ungepatchter Bildschirm direkt an deinem Smart
  Home.
- **Der Selbstbau verlangt echtes Linux-Können.** Einen eigenen Kiosk zu bauen heißt:
  Sperrbildschirm abschalten, einen Browser im richtigen Modus automatisch starten,
  das Display am Einschlafen hindern und dafür sorgen, dass das alles nach jedem
  Neustart noch funktioniert. Das ist viel verlangt von jemandem, der einfach nur ein
  Dashboard will.
- **Jedes Update bleibt an dir hängen.** Bei einem selbst gebauten Aufbau heißt
  aktualisieren: einloggen, Befehle ausführen und hoffen, dass nichts kaputtgeht. Lass
  es ein paar Mal aus, und das Gerät verrottet still vor sich hin.
- **Ein einziges schlechtes Update kann alles lahmlegen.** Geht auf einer Selbstbau-Kiste
  ein Update schief, gibt es oft keinen einfachen Weg zurück – nur einen toten
  Bildschirm und einen Abend Fehlersuche.

### Was ich stattdessen wollte { #what-i-wanted-instead }

- **Eine schlüsselfertige Lösung.** Flashen, auf Home Assistant zeigen lassen, fertig.
  Kein Terminal, keine Bastelei, nichts von Hand zu konfigurieren.
- **Updates, die zu mir kommen.** Neue Versionen tauchen direkt in Home Assistant auf –
  ein Fingertipp zum Installieren, kein Einloggen, nichts neu zu flashen.
- **Ein echter Teil von Home Assistant.** Das Panel soll sich in HA als Gerät
  zurückmelden, das ich sehen, steuern und automatisieren kann – keine Blackbox, die an
  der Wand hängt.
- **Etwas, das ein Update nicht zerschießen kann.** Wenn eine neue Version Ärger macht,
  will ich direkt auf dem Gerät zurückrollen und weitermachen.
- **Hardware weiterverwenden, die ich schon habe.** Ein übriger Mini-PC, ein alter
  Einplatinencomputer, was eben in der Schublade liegt – kein abgeschottetes,
  proprietäres Panel.
- **Zuverlässigkeit zum Einrichten und Vergessen.** Es soll Stromausfälle und Neustarts
  überstehen und einfach von selbst wieder hochkommen, unbeaufsichtigt, über Jahre.
- **Wiederholbar von Haus aus.** Ein zweites oder drittes Panel zu flashen soll jedes
  Mal exakt dasselbe Ergebnis liefern, ohne fummelige Einrichtung pro Gerät.

Das ist Dashboard Assistant: ein Bildschirm, den du einmal flashst und dann vergisst,
der aktuell bleibt und der in Home Assistant lebt, als gehöre er dorthin.

Neugierig, wie das alles funktioniert? Wirf einen Blick auf den [Stack für Nerds](stack-for-nerds.md).
