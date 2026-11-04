# Kompakte Quellensteuerung ohne Auf-/Zuklappen

Designvorschlag für ein neues Umsetzungsticket. Ausgangspunkt: `origin/main` bei
`265d47b` (inklusive virtueller Eingänge per Opt-in aus PR #76). Ergänzt #59 und
bezieht die Anforderung aus [#77](https://github.com/moreaki/recscribe/issues/77)
ein. #77 kann unabhängig als kleiner bestehender UI-Fix umgesetzt werden.

## Entwurf ansehen

- [Interaktiver Prototyp](source-strip.html): herunterladen und lokal im Browser öffnen;
  eine einzelne HTML-Datei ohne externe Abhängigkeiten oder Netzwerkzugriffe.
- [Übersicht](overview.png), [Mute](muted.png), [32 Kanäle](multichannel.png),
  [schmale Ansicht](narrow.png), [Wiederanbindung](reconnecting.png).
- [Ausgangszustand aus dem Nutzer-Screenshot](before.png).

Die HTML-Datei simuliert Pegel und Zustände. Sie greift auf keine Audiogeräte zu.
Navigation und Sound-Settings-Verknüpfung sind Kontext für den Entwurf; die
Quellenregler, Kanalauswahl, Kanalnavigation, Aufnahmeauswahl virtueller Inputs,
Mute und Testzustand sind bedienbar. Kein Swift-Code und kein installierter Build
werden durch diesen Vorschlag geändert.

## Layout

Eine Quellenkarte hat zwei feste Zeilen:

1. Gerätename, Typ, Kanalzahl, Samplerate und Status; rechts ein Mute/Unmute-Button.
   Virtuelle Eingänge haben zusätzlich die direkt sichtbare Checkbox **Record**.
2. Vier klar getrennte Gruppen: **Mix gain**, **Device · system-wide**,
   **Channels · L / R · trim dB**, **dBFS** mit Input- und Mixpegel.

Kein Disclosure-Pfeil, keine verschachtelten Disclosure-Gruppen, kein „Done“ und
kein Menü als Zugang zu einem wesentlichen Quellenregler. Ein normaler Picker
für App-/Systemauswahl oder Kanalbezug ist weiterhin sinnvoll.

Der Mock verwendet **112 logische CSS-Pixel** Kartenhöhe bei 620, 760 und 1040 px
Pane-Breite. Das ist ein prüfbarer Layoutvorschlag, keine gemessene Gleichheit
zwischen CSS und nativer SwiftUI-Karte. Die native Umsetzung soll bei gleicher
Schrift und Breite höchstens so hoch sein wie die bisherige zugeklappte Karte
mit Pegelanzeige. Bei größerer Bedienungshilfen-Schrift geht Lesbarkeit vor einer
starren Pixelvorgabe. Bedienelemente nicht zur Einhaltung der Höhe abschneiden.

## Funktionsumfang und Bedeutung

| Bereich | Direkt erreichbare Funktionen |
| --- | --- |
| Identität | Vollständiger Quellenname zugänglich, Typ, Kanalzahl, Rate; bei langen Namen Ellipse und vollständiger Tooltip/Accessibility-Name. Bei fehlender Rate kein erfundener Wert. |
| Aufnahmeauswahl | Physische Eingänge gemäß bestehender automatischer Auswahl; virtuelle Eingänge nur per explizitem **Record**-Opt-in. Vorhandene Limits (acht Inputs) und interne Gerätefilter beibehalten. |
| Mute | Ein Button mit festem Platzbedarf; sichtbarer Text plus orangefarbener Rand/Status. „Mute im Mix“ deaktiviert die Quelle nicht für die Aufnahme. |
| Software-Gain | Slider und editierbarer dB-Wert, Bereich −60 bis +24 dB; vorhandenes native Snap-/Feinsteuerungsverhalten erhalten. **0 dB ↺** setzt nur den Quellen-Gain zurück, ohne Mute, Routing, Kanaltrims oder Hardware zu ändern. |
| Kanalrouting | Pro Kanal unabhängige L/R-Tasten, also links, rechts, beide oder weder noch; Kanaltrim direkt als dB-Wert editierbar. Kanalbezeichnungen statt ausschließlich Nummern zugänglich machen. |
| Hardwarepegel | Klar als **system-wide** getrennt vom Mix. Nur tatsächlich vorhandene schreibbare Master-/Kanalregler anbieten. Bei Kanalreglern direkt sichtbarer Kanalpicker mit dem Wert des gewählten Kanals. Sound-Settings-Verknüpfung bleibt erreichbar. |
| Nicht unterstützte Hardware | „No writable control“ statt eines wirkungslosen Sliders; manuelle Hardwarebedienung/Sound Settings nennen. Keine erfundenen Masterregler. |
| Playbackquelle | System-/App-Auswahl direkt in der Quellenzeile. Browser-App-Capture nicht als Capture eines einzelnen Webex-Tabs darstellen. Vorhandene Quellenoptionen einschließlich ausgeschaltetem Playback erhalten. |
| Signal | Input vor Gain und gerouteter Mixbeitrag, jeweils numerisch in dBFS und als Balken. Direkt sichtbarer Picker für Gesamtansicht oder einzelnen Kanal, Mini-Inputpegel an den Kanalzellen. |

Die Bezeichnung von Mute und der Hinweis auf Originalspuren müssen zum aktiven
Aufnahmemodus passen. Der Mock zeigt den normalen Mix mit getrennten
Originalspuren. Ein Modus, dessen Mute auch gespeichertes Audio betrifft, darf
nicht fälschlich mit „Original bleibt erhalten“ beschriftet werden. Das Redesign
ändert keine Capture- oder Datenschutzentscheidung.

## Viele Kanäle ohne große Karten

32 vollständige Kanalregler passen bei 620 px nicht gleichzeitig lesbar in eine
kleine Karte. Die Lösung ist eine **horizontal scrollbare Kanalspur innerhalb
der festen Höhe**, mit sichtbarem Kanalbereich und Vor/Zurück-Tasten. Die
übrigen Gruppen bleiben stehen. Alle Kanäle bleiben per Tastatur erreichbar;
Fokus scrollt den jeweiligen Kanal ins Sichtfeld. Nativer VoiceOver-Fokus benennt
Quelle, Kanal, L/R-Status und Trim. Die Input-/Mixmeter können direkt auf jeden
Kanal umgeschaltet werden; dafür wird die Karte ebenfalls nicht aufgeklappt.

Die Kanalzellen im Mock zeigen bewusst nur Nummern als kurze Beispiele. In der
App müssen vorhandene Kanalnamen vollständig zugänglich sein. Der Mock nutzt
vereinfachte synthetische Peak-Werte und keine Nachbildung des echten
Stereo-Summing-/Averaging-Verfahrens.

## Zustände und Kontinuität

- **Idle:** alle zulässigen Regler verfügbar; keine erfundene Live-Aktivität.
- **Test / Aufnahme:** Mute, Software-Gain und Trims bleiben bedienbar. Capture-
  Auswahl und Kanalverbindungen bleiben gemäß bestehendem Verhalten gesperrt;
  Grund sichtbar nennen. Hardwarepegel nur bei tatsächlicher Schreibbarkeit.
- **Muted:** Inputpegel läuft weiter, Mixbeitrag ist null; Status/Rand wechseln,
  Höhe und Reglerpositionen bleiben gleich. Einstellungen der Quelle bleiben erhalten.
- **Virtueller Eingang nicht ausgewählt:** steht in „Available virtual inputs“;
  **Record** direkt erreichbar, Mixregler als gespeicherte Werte sichtbar und
  deaktiviert. Opt-out/Opt-in erhält Gain, Mute und Kanalrouting.
- **Unterbrochen:** Quelle mit stabilem Namen und Einstellungen behalten,
  „Reconnecting“ zeigen und Hardware-/Livezugriff sperren. Software-Mute/Gain
  für die nächste Wiederanbindung weiterhin setzen können. Eine Unterbrechung
  nicht als erfolgreiches oder nur stilles Signal darstellen. Die tatsächlichen
  bestehenden Wiederanbindungsregeln unverändert erhalten.
- **Clipping / keine Daten / Fehler:** kompakter reservierter Statusplatz mit
  Text und Symbol, nicht nur Farbe. Original- und Mix-Clipping unterscheiden;
  Peak-Hold, Wartestatus, Fehler und echte Messwerte aus dem Engine-Modell
  erhalten. Längere Fehler bei Bedarf in einem gemeinsamen Statusbereich unter
  der Quellenliste zeigen, ohne eine einzelne Karte aufzuziehen. Der Mock
  demonstriert Mute, Preview und Reconnecting; keine vollständige Fehlermatrix.

## Akzeptanzkriterien für die native Umsetzung

- [ ] Alle bisherigen Quellenfunktionen haben einen direkten Zugang innerhalb
  der kompakten Karte; keine Auf-/Zuklapp-Interaktion erforderlich.
- [ ] Kartenhöhe bei Standard-Schrift höchstens wie die bisherige zugeklappte
  Karte mit Pegeln, anhand derselben Pane-Breite vergleichen.
- [ ] Kein Größensprung durch Mute, Test, Aufnahme, Unterbrechung oder Wiederanbindung.
- [ ] Mono, Stereo und bis zu 32 Kanäle vollständig bedienbar, auch bei 620 px
  Pane-Breite; kein horizontaler Scroll der gesamten Ansicht.
- [ ] Mute, Aufnahmeauswahl, Software-Gain, Kanaltrims und Hardwarepegel bleiben
  semantisch unabhängig. Keine bewusste Nutzereinstellung wird überschrieben.
- [ ] #77: Aufnahme-Checkbox auch bei ausgewählten virtuellen Eingängen direkt
  sichtbar; Opt-out verschiebt in die unbenutzte Gruppe, Opt-in stellt Werte wieder her.
- [ ] Meter und Status bleiben ohne Aufklappen während Tests/Aufnahmen sichtbar;
  Raw-Signal, Nullbeitrag durch Mute, echte Stille und fehlende Daten unterscheidbar.
- [ ] Vorhandene Quellennamen, Kanalnamen, Playback-Optionen, Hardwarekanalregler,
  Peak-Hold und Fehlerhinweise gehen nicht verloren.
- [ ] Aufnahme-/Test-Sperren, Wiederanbindung, Originalspuren und virtuelle Opt-ins
  entsprechen dem aktuellen Capture-Modell; Redesign erzeugt keine neue Quelle.
- [ ] Tastatur und VoiceOver prüfen: benannte Regler, sichtbarer Fokus,
  Kanal-Scroll folgt Fokus, Mute/Record getrennt aktivierbar, Zustände nicht nur Farbe.
- [ ] Native Screenshots für Normal, Muted, Test, Recording, Offline, schmale
  Pane, langen Namen, fehlende Hardwaresteuerung und 32 Kanäle dokumentieren.

## Verifikation dieses Artefakts

`verify.cjs` verwendet Playwright mit lokal installiertem Chrome. Es prüft feste
112-px-Höhe und die Grenzen aller nicht scrollenden Regler bei 620/760/1040 px
für fünf Zustände, Gain-Synchronisation/Reset, Mute bei weiter vorhandenem
Inputsignal, unabhängige L/R-Tasten, gespeicherte virtuelle Opt-ins, Capture-
Sperren und Erreichbarkeit von Kanal 32 samt Hardware-Kanalwahl. Es erzeugt die
fünf PNGs und meldet Scriptfehler. Das ersetzt keinen nativen Funktionstest.

```sh
# Playwright außerhalb des Repos installieren, sofern noch nicht vorhanden:
npm install --prefix /tmp/recscribe-source-design-tools playwright --no-audit --no-fund
NODE_PATH=/tmp/recscribe-source-design-tools/node_modules \
  node docs/design-proposals/compact-source-strip/verify.cjs
```

Ein anderer Chrome-Pfad kann über `CHROME_PATH` gesetzt werden.
