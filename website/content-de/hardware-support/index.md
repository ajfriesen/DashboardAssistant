---
icon: lucide/cpu
hide:
  - toc
---

# Hardware-Unterstützung

Dashboard Assistant liefert aktuell flashbare Images für `x86_64` sowie für
Raspberry Pi 4 und 5.
Die Tabelle unten zeigt den aktuellen Stand, und zu jedem Ziel gibt es eine eigene Seite mit den Details.

| Ziel | Status | Hinweise |
|---|---|---|
| x86_64 (Mini-PC, Laptop, Tablet) | :lucide-circle-check: Unterstützt | Primäres, getestetes Ziel. Wird als flashbares Image ausgeliefert. |
| Raspberry Pi 5 (aarch64) | :lucide-circle-check: Unterstützt | Getestet und funktioniert. Wird als SD-Karten-Image ausgeliefert. |
| Raspberry Pi 4 (aarch64) | :lucide-circle-check: Unterstützt | Getestet und funktioniert. Wird als SD-Karten-Image ausgeliefert. |

## x86_64 { #x86_64 }

Die meisten Mini-PCs, alten Laptops und x86-Tablets eignen sich. Das Image
bringt breite Hardware- und Firmware-Unterstützung mit und ist nicht auf ein
einzelnes Board zugeschnitten. Dieselbe Datei bootet deshalb auf sehr vielen
verschiedenen Geräten.

[Details zu x86_64&nbsp;→](x86.md){ .da-btn .da-btn--primary }

## Raspberry Pi { #raspberry-pi }

Raspberry Pi 4 und Raspberry Pi 5 sind beide getestet und funktionieren; für
jeden gibt es ein eigenes SD-Karten-Image.

[Details zum Raspberry Pi&nbsp;→](raspberry-pi.md){ .da-btn .da-btn--primary }

## Touchscreens { #touchscreens }

Wenn du den Bildschirm fest montierst, ist ein Touchscreen empfehlenswert. Die offiziellen
Touch-Displays von Raspberry Pi sind getestet und funktionieren.

[Getestete Touchscreens&nbsp;→](touchscreens.md){ .da-btn .da-btn--ghost }

## Monitor dimmen { #monitor-dimming }

Echtes Dimmen hängt davon ab, was dein Display unterstützt. Dashboard Assistant
wählt automatisch die beste von drei Methoden: Hardware-Hintergrundbeleuchtung,
DDC/CI oder eine Software-Lösung als Rückfallebene.

[So funktioniert das Dimmen&nbsp;→](dimming.md){ .da-btn .da-btn--ghost }
