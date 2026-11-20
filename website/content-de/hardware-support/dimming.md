---
icon: lucide/sun-dim
---

# Monitor dimmen

Echtes Dimmen hängt davon ab, was dein Display unterstützt. Dashboard Assistant
ermittelt einmal pro Sitzung die beste verfügbare Methode und nutzt eine von
dreien:

1. **Hintergrundbeleuchtung.** Interne Panels, die `/sys/class/backlight`
   bereitstellen (der eDP-Bildschirm eines Laptops oder Tablets), werden direkt
   über die Hardware-Hintergrundbeleuchtung gedimmt. Das ist der Idealfall und
   ergibt eine echte Helligkeitsregelung.
2. **DDC/CI.** Externe Monitore, die DDC/CI sprechen, werden über diesen Kanal
   gedimmt (`ddcutil`). Dein Monitor muss DDC/CI unterstützen und es in seinem
   Bildschirmmenü aktiviert haben, und er muss über die Videoverbindung
   erreichbar sein.
3. **Software-Gamma.** Steht keines von beiden zur Verfügung, dimmt eine
   Software-Lösung das gerenderte Bild statt der physischen
   Hintergrundbeleuchtung. Das funktioniert auf jedem Display und in jeder VM,
   aber das Panel selbst läuft weiter mit voller Hintergrundbeleuchtung und
   wird deshalb nie ganz dunkel.

Standardmäßig wird die Methode automatisch gewählt (Hintergrundbeleuchtung,
dann DDC/CI, dann Software). Unterstützt dein Monitor Hardware-Dimmen, wird
aber nicht erkannt, prüfe, ob DDC/CI in den Einstellungen des Displays
eingeschaltet ist.
