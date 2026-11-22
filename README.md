# Audi Light Studio — iOS

App iPhone (SwiftUI + CoreBluetooth) per controllare i LED indirizzabili installati su un'Audi A1 2020 tramite il controller BLE **ISP-B0717F** (app originale iDeal LED 4.0.7, HW 22.12.02.1, FW 23.09.12.1).

Ricerca sul protocollo, con distinzione documentato / dedotto / da verificare: **[docs/PROTOCOL.md](docs/PROTOCOL.md)**.

## Stato

| Milestone | Contenuto | Stato reale |
|---|---|---|
| 1 | Progetto SwiftUI, Bluetooth Lab, connessione, diagnostica, log, HEX, build CI | **Completata e provata** sull'auto il 22/11/2026 (build CI verde, 67 test). |
| 2 | Protocollo verificato, primo pixel, più pixel, disegni | Primo pixel **verificato**. Editor 200 LED **verificato**: invio `DOOD` a finestra 6, ~72 comandi/s (disegno completo ≈ 3 s), 0 errori. `DOOT` in blocco disattivato finché non è catturato con MTU 23. |
| 3 | Mappatura con fotocamera | Implementata: codici binari (18 fotogrammi), decodifica per pixel, filtro riflessi, mappe per sezione, correzione manuale. Prove sul pavimento (22/11): tratto disteso decodificato in ordine (0–30), groviglio non mappabile (LED sovrapposti). **Da provare con le strisce montate sull'auto.** |
| 4 | Animazioni ed editor avanzato | Implementati: effetti centralina `SGLS` (0–9), scene `MULT` (0–11, max 6 colori con MTU 23), disegni DIY animati (respiro/lampeggio), editor sulla forma reale della mappa, testo rasterizzato sui LED mappati, anteprima, preset, sequenze di disegni con tempo reale. **Da provare sull'impianto.** Più centraline: non necessario con l'impianto attuale (una centralina, cablaggio a Y). |

### Cosa fa la build attuale

- **Bluetooth Lab › Dispositivi** — scansione BLE, riconoscimento di `ISP-B0717F` (badge "ATTESO"), connessione, riconnessione automatica e "Ultimo dispositivo", RSSI, MTU, gestione permessi/stato Bluetooth.
- **GATT** — servizi, caratteristiche, proprietà (Read/Write/WNR/Notify…), descrittori (lettura automatica del solo `2901`), ultimo valore, sottoscrizione manuale alle notifiche, ruolo noto di ogni caratteristica.
- **Protocollo** — checklist di compatibilità; comandi documentati (`VE`, `TURN`); test "LED 1 rosso → blu" con conferma esplicita al primo invio; attesa degli ack `…OK` con tempi.
- **HEX** — editor con validazione, scelta esplicita della caratteristica e del tipo di scrittura (solo quelli supportati), cifratura AES in app o testo già cifrato, anteprima dei byte sul canale, classificazione **Documentato / Sperimentale / Bloccato**, conferma obbligatoria per i sperimentali.
- **Log** — timestamp al millisecondo, TX/RX/eventi/errori/rifiuti di sicurezza, notifiche decifrate, copia, esportazione `.txt`, report diagnostico (anche in app File › Audi Light Studio › Logs).

### Sicurezza (sempre attiva)

- Nessuna scrittura automatica alla connessione (neanche la sottoscrizione alle notifiche).
- Mai scritto: `AE01` (OTA JieLi), `FD01`, `FD02`, qualsiasi caratteristica non identificata.
- Bloccati: tag sconosciuti, `TEST`, `CT`, `LAMPN`, `LAMPT`, `SPLAY`, `CHECKLINE`…, indici pixel ≥ 400, valori fuori dai limiti trovati nel firmware.
- Nessuna funzione OTA, firmware o reset di fabbrica.

## Impianto reale

2 file da 20 m × 200 LED (WS2812B, 10 LED/m) collegate **a Y sulla stessa linea dati**: 200 indici, ogni indice accende lo stesso LED su entrambe le file. Verificato il 22/11/2026.

## ⚠️ Limite 400 LED

Il firmware più vicino analizzato (TR2309) ha buffer da **400 LED** e scrive fuori memoria, in modo persistente, oltre quel limite. Un solo controller da 1600 LED non è dimostrato: probabilmente servono più centraline (es. 4 × 400). L'app non supera 400 finché non sarà dimostrato il contrario. Dettagli in [docs/PROTOCOL.md §5](docs/PROTOCOL.md).

## Versione 2.0 — app completa

Flusso: **Centraline** → **Scansione** → **Mappa 3D** → **Effetti** (Anteprima, poi Live) → **Preset**.

| Area | Cosa fa | Stato |
|---|---|---|
| Centraline | Più centraline insieme (testato a codice fino a 4+), nome, colore, pixel, LED per pixel (a Y), attivazione, riconnessione automatica, verifica `VE` a ogni connessione, configurazione persistente | Logica testata in CI; **verificato sull'hardware solo con 1 centralina** |
| Identità LED | Ogni pixel = (centralina, indice). I LED a Y sono due posizioni fisiche dello stesso pixel e hanno sempre lo stesso colore | Testato in CI |
| Scansione 3D | Procedura guidata con ARKit: codici binari su tutte le centraline insieme (1600 pixel = 11 bit, 24 fotogrammi per vista), profondità LiDAR o triangolazione da più viste, scarto delle viste mosse, copertura per centralina, salvataggio e ripresa | Ricostruzione testata in CI su dati sintetici; **da provare sull'auto** |
| Mappa 3D | SceneKit: rotazione 360°, zoom, viste predefinite, colore carrozzeria, LED come punti, selezione con centralina/pixel/posizione/affidabilità/LED gemelli, filtri per centralina e zona, colorazione per effetto/centralina/affidabilità, correzione e allineamento | Compila; **da provare** |
| Modello dell'auto | **Provvisorio**: forme semplici con le misure dell'A1 Sportback 2020, sempre indicato come tale. Importazione di un file USDZ/SCN reale | Il modello fedele richiede un asset con licenza (non incluso) |
| Motore effetti | 9 effetti calcolati sulle coordinate spaziali (statico, arcobaleno, onde, scansione avanti/dietro e sinistra/destra, meteora, pulsazione, scintillio, accensione progressiva), livelli per zona o selezione, pittura, gradienti | Testato in CI |
| Anteprima / Live | Anteprima a 30 fps senza Bluetooth; Live invia ogni fotogramma a tutte le centraline e misura i fotogrammi/s reali | Live **da provare**: con il protocollo attuale gli effetti che cambiano tutti i LED scorrono a scatti (circa 72 comandi/s per centralina) |
| Preset | Effetti salvati e playlist | Compila; da provare |
| Strumenti avanzati | Bluetooth Lab, editor e scansione 2D, effetti interni della centralina (versione 1) | Verificati in parte sull'hardware (vedi sotto) |

Mappa dimostrativa: dalla Mappa 3D si può generare una disposizione di prova per esplorare l'interfaccia prima della scansione; è sempre etichettata "MAPPA DIMOSTRATIVA".

### Blocchi reali

1. **Modello 3D fedele dell'Audi A1:** serve un file USDZ/SCN con licenza d'uso; l'app lo importa, ma non posso fornirlo.
2. **Più centraline:** codice e test pronti, ma verificati sull'hardware con una sola centralina.
3. **Live fluido:** il protocollo verificato aggiorna un pixel per comando; l'invio in blocco `DOOT` sarebbe più veloce ma non è catturato con pacchetti da 20 byte.

## Struttura

```
App/          entry point, barra a 7 sezioni, tema
Hub/          ControllerHub + ControllerLink (più centraline)
Scan3D/       scansione AR guidata
Studio3D/     SceneKit: modello, nuvola di LED, Mappa 3D
Effects/      riproduzione Anteprima/Live, Studio Effetti, Preset
BLE/          BLEManager (CoreBluetooth), IdealController (protocollo + ack), PacketLog
Logic/        Hex, AES (CommonCrypto), encoder/decoder iDeal, policy di sicurezza — senza UI
Persistence/  AppSettings (UserDefaults)
Views/        Dashboard, Bluetooth Lab (5 sezioni), Settings, schermate milestone 3–4
Tests/        test della logica eseguiti in CI con swiftc
ci/sign.sh    firma opzionale con secret
project.yml   progetto XcodeGen (l'.xcodeproj viene generato)
```

## Build

### GitHub Actions (nessun Mac necessario)

Il workflow `.github/workflows/build.yml` su `macos-latest`:

1. compila ed esegue i test della logica (`Logic/*.swift` + `Tests/main.swift`) — vettori AES delle catture pubblicate e policy di sicurezza;
2. genera il progetto con XcodeGen;
3. crea l'archivio iOS **non firmato** (`AudiLightStudio.xcarchive.zip`);
4. impacchetta `AudiLightStudio-unsigned.ipa`;
5. se configurati i secret, produce anche `AudiLightStudio-signed.ipa`;
6. su `main` pubblica gli IPA nella release `latest`.

Gli IPA si scaricano da *Actions › run › Artifacts* o dalla release `latest`.

### Installazione con Sideloadly

L'IPA non firmato basta: **Sideloadly lo firma con il tuo Apple ID** (anche gratuito; con account gratuito l'app scade dopo 7 giorni e va reinstallata). Apri Sideloadly, collega l'iPhone, trascina `AudiLightStudio-unsigned.ipa`, inserisci l'Apple ID, avvia. Su iOS 16+ attiva *Impostazioni › Privacy e sicurezza › Modalità sviluppatore*.

### IPA firmato in CI (facoltativo)

Non ci sono certificati nel repository. Per farlo generare al workflow servono questi secret (*Settings › Secrets and variables › Actions*):

| Secret | Contenuto |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | certificato Apple Development `.p12` in base64 |
| `P12_PASSWORD` | password del `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | profilo `.mobileprovision` in base64, con l'UDID dell'iPhone |
| `KEYCHAIN_PASSWORD` | password qualsiasi per il portachiavi temporaneo |
| `TEAM_ID` | Team ID Apple |
| `EXPORT_METHOD` | facoltativo, default `development` |

Richiede un account Apple Developer a pagamento (i profili gratuiti di Xcode non sono esportabili per la CI). Senza questi secret il passo viene saltato.

### In locale (Mac)

```sh
brew install xcodegen
xcodegen generate
open AudiLightStudio.xcodeproj
```

## Prova sull'auto (Milestone 1 → 2)

1. Chiudi l'app iDeal LED (il controller accetta una sola connessione).
2. Bluetooth Lab › Dispositivi › Scansiona › Connetti su `ISP-B0717F`.
3. GATT: verifica che compaiano FFF0, FD00, AE00 come in nRF Connect.
4. Protocollo: *Iscriviti a …9601*, poi *Leggi versione*. Atteso: `V022.12.02.1` / `V123.09.12.1` o simili.
5. Se la checklist è tutta verde: *Rosso*, poi *Blu*, poi *Esci, mantieni*.
6. Log › Diagnostica ed esporta il file: serve per la Milestone 2.
