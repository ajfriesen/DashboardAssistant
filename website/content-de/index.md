---
icon: lucide/rocket
hide:
  - navigation
  - toc
---

<section class="da-hero" markdown>

<div class="da-hero__text" markdown>

<span class="da-hero__eyebrow">Für Home Assistant</span>

# Ein Dashboard-OS, <span class="da-accent">kein Wochenendprojekt</span> {: .da-hero__title }

<p class="da-hero__lead">
Ein Image flashen, einschalten, fertig. Es meldet sich selbst an und startet
direkt in dein Dashboard – ganz ohne Anmeldebildschirm.
</p>

<div class="da-hero__cta" markdown>
[Loslegen&nbsp;→](getting-started.md){ .da-btn .da-btn--primary }
[In Aktion ansehen](in-action.md){ .da-btn .da-btn--ghost }
</div>

<p class="da-hero__hardware">x86 mit Mainline-Linux-Unterstützung · Raspberry Pi 4 und 5</p>

</div>

<!--
  Tablet mockup. The screen crossfades through the <img> slides below — swap
  these for your own screenshots any time. The crossfade is tuned for THREE
  slides; if you add/remove images, update `--da-slides` and the `:nth-child`
  delays in website/content/stylesheets/extra.css.
-->
<div class="da-tablet">
  <div class="da-tablet__screen">
    <img class="da-slide" src="/img/home-assistant-light.jpeg" alt="Home Assistant im hellen Modus">
    <img class="da-slide" src="/img/home-assistant-dark.jpeg" alt="Home Assistant im dunklen Modus">
    <img class="da-slide" src="/img/keyboard.jpeg" alt="Bei Bedarf mit Bildschirmtastatur">
    <img class="da-slide" src="/img/random-website.jpeg" alt="Zeigt jede beliebige Website">
  </div>
</div>

</section>

## Flashen. Starten. Nutzen. {: .da-section-title #flash-boot-use }

<p class="da-section-lead">Rund fünf Minuten, die meiste Zeit davon braucht das Flashen.</p>

<div class="da-cards da-cards--steps" markdown>

<div class="da-card" markdown>
<div class="da-card__icon">1</div>
### Flashen { #flash }
Schreib ein Image auf eine SD-Karte oder SSD und steck sie in dein Tablet,
deinen Mini-PC oder Raspberry Pi. Nichts zu partitionieren, kein Installer zum
Durchklicken.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">2</div>
### Starten { #boot }
Einschalten. Per Ethernet ist es sofort im Netz, im WLAN nutzt es die
Zugangsdaten aus deiner Seed-Datei. Danach koppelt es sich selbst mit Home
Assistant.
</div>

<div class="da-card" markdown>
<div class="da-card__icon">3</div>
### Nutzen { #use }
Es öffnet dein Dashboard und bleibt dort. Keine Anmeldung nötig, und in Home
Assistant erscheint es als Gerät, das du automatisieren kannst.
</div>

</div>

## Nicht nur für dich {: .da-section-title #its-not-just-for-you }

<p class="da-section-lead">Einen Bildschirm an der Wand benutzt jeder, der daran vorbeigeht.</p>

<div class="da-scenes" markdown>

<div class="da-scene" markdown>

<div class="da-scene__text" markdown>
### Keine App, kein Konto, keine Anmeldung { #no-app-no-account-no-login }
<p>
Es startet in dein Dashboard und bleibt dort – ganz ohne Anmeldebildschirm.
Gäste, Kinder und Mitbewohner tippen an die Wand, um eine Lampe einzuschalten
oder die Heizung hochzudrehen, ohne App auf dem Handy und ohne eigenes Konto.
Nichts auf diesem Bildschirm kann das Gerät auf ein anderes Ziel umstellen oder
zurückrollen; das geht nur aus Home Assistant.
</p>
</div>

<div class="da-scene__media">
  <div class="da-tablet">
    <div class="da-tablet__screen">
      <img class="da-shot" src="/img/home-assistant-light.jpeg" alt="Ein Home-Assistant-Dashboard füllt das ganze Panel, ohne Anmeldebildschirm oder Desktop drumherum">
    </div>
  </div>
</div>

</div>

<div class="da-scene da-scene--text" markdown>

<div class="da-scene__text" markdown>
### Album an der Wand aussuchen, überall hören { #pick-an-album-on-the-wall-hear-it-everywhere }
<p>
Das Panel ist ein Sendspin-Player in deiner Music-Assistant-Gruppe und spielt
deshalb synchron mit deinen anderen Lautsprechern. Läuft Music Assistant als
Home-Assistant-Add-on, hast du dessen komplette Oberfläche direkt auf dem
Bildschirm: Bibliothek durchstöbern und die Auswahl in jeden Raum schicken.
Niemand muss sich anmelden.
</p>
</div>

<!-- To make this scene image-led, see .da-scene--text in stylesheets/extra.css. -->

</div>

</div>

## Das Langweilige ist erledigt {: .da-section-title #the-boring-parts-handled }

<p class="da-section-lead">Gemacht für einen Bildschirm, den du ansiehst – nicht für einen Computer, um den du dich kümmern musst.</p>

<div class="da-cards" markdown>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-package-check:</div>
### Kein Linux-Wissen nötig { #no-linux-knowledge }
Kein Desktop zu konfigurieren, kein Sperrbildschirm abzuschalten, kein Autostart
einzurichten. Das Image ist das fertige Produkt.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-key-round:</div>
### Meldet sich selbst an { #signs-itself-in }
Es meldet sich für dich bei Home Assistant an und startet direkt in dein
Dashboard – kein Anmeldebildschirm, durch den du dich jedes Mal tippen musst.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-house:</div>
### Teil von Home Assistant { #part-of-home-assistant }
Der Bildschirm erscheint in Home Assistant wie jedes andere Gerät. Schalte ihn
ein oder aus, dimme ihn oder überlass das deinen Automatisierungen.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-globe:</div>
### Jede Seite anzeigen { #show-any-page }
Füge beliebig viele Dashboards oder Websites hinzu und wechsle zwischen ihnen –
aus Home Assistant oder per Tipp auf den Bildschirm.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-pointer:</div>
### Für Touch gemacht { #made-for-touch }
Ein Tipp weckt den Bildschirm, geschrieben wird mit der Bildschirmtastatur. Maus
und Tastatur musst du nicht anschließen.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-audio-lines:</div>
### Auch ein Lautsprecher { #also-a-speaker }
Der eingebaute Sendspin-Player spielt synchron in einer Gruppe mit deinen
anderen Lautsprechern. Gesteuert wird er von Music Assistant, und der Ton
verlässt nie dein Netzwerk.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-refresh-cw:</div>
### Updates aus Home Assistant { #updates-from-home-assistant }
Ist eine neue Version da, installierst du sie mit einem Tipp aus Home Assistant.
Kein Terminal, kein erneutes Flashen.
</div>

<div class="da-card" markdown>
<div class="da-card__icon" markdown="span">:lucide-history:</div>
### Leicht rückgängig zu machen { #easy-to-undo }
Macht ein Update doch einmal Ärger, kehrst du mit einem Button in Home Assistant
zu einer Version zurück, die funktioniert hat – ohne neu zu flashen, ohne
Vor-Ort-Termin.
</div>

</div>

<div class="da-hero__cta" markdown>
[Loslegen&nbsp;→](getting-started.md){ .da-btn .da-btn--primary }
</div>
