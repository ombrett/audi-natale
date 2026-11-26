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

## Versione 3.1 — Adaptive Y

- `Logic/AdaptiveY.swift`: per ogni preset calcola il colore ideale di ogni copia fisica sulla mappa reale (nessuna ipotesi di simmetria: serpentina, altezze e lati diversi), misura il conflitto cromatico tra le copie su tutta l'animazione in OKLab, confronta 6 strategie di colore condiviso (più luminosa, media percettiva, media che conserva i picchi, punto medio, segue copia 1, segue copia 2) e sceglie per ogni indirizzo quella con l'errore percepito minore sull'intera animazione.
- Punteggio di compatibilità 0–100 per preset; per i preset sotto 85 ottimizza direzione, frequenza spaziale, fase e ampiezza dell'onda e crea una variante "· Y" se guadagna almeno 5 punti.
- Anteprima e Live usano lo stesso fotogramma riproducibile (un RGB per indirizzo). Regolazioni › Colore condiviso: Adaptive Y o Classico (regola precedente).
- Mappa 3D › Gemelli a Y: copie per indirizzo, distanze reali, copie in zone diverse, analisi. Inspector: colore ideale delle due copie, ΔE e strategia usata.

## Versione 3.0 — redesign Studio

- Navigazione: **Studio · Mappa 3D · Centraline · Altro**. Tabella completa "funzione → nuova posizione" in `docs/REDESIGN.md`.
- Studio: A1 grande e ruotabile (campo visivo orizzontale fisso, griglia, gizmo assi), origine delle posizioni (progetto/scansione/dimostrativa), stato centraline, trasporto con play/pausa, preset a un tocco, **Anteprima** e **Invia all'auto** separati, modalità Mappa con zone.
- Inspector del LED toccato: indirizzo (`B / 057`), ramo, zona con origine (manuale/automatica), RGB corrente; cerchio pieno sul punto, anello sulla copia a Y; cambio zona del singolo punto senza fermare la riproduzione.
- Mappa 3D: confronto col progetto (corrispondenze, scarto in cm), cornice e targhetta fisse in modifica zone, collegamento alla scansione.
- Centraline: A B C D con stato reale, offline/parziale/Bluetooth spento/disconnessione durante il Live. Offline l'anteprima usa le centraline citate dalla mappa del profilo.
- Verifiche: test logici (`Tests/main.swift`) e verifiche nell'app sul simulatore (`ci/screenshots.sh`, argomento `-ALSSelfTest`), con screenshot pubblicati nella release.

## Versione 2.9 — layout S-Line corretto

- Layout rigenerato sulla carrozzeria S-Line: nessun LED né tratto di striscia su vetri, fari, stop, targa, griglia, specchi o ruote (striscia ad almeno 17 mm); ogni zona sta su un solo pannello (porte, cofano e portellone apribili hanno la loro sezione); passo massimo 10 cm tra LED consecutivi lungo la striscia; tagli con prolunga dichiarati nel file (`lead_before_m`).
- Import del layout: controllo del passo (tratti oltre 10,5 cm senza prolunga segnalati) e riepilogo delle prolunghe.
- Il .blend del progetto non è stato toccato: `aggiorna_LED_in_Blender.py` (consegnato a parte) sposta i LED alle nuove posizioni.

## Versione 2.8 — carrozzeria Audi A1 S-Line

- `Resources/Audi_A1_LED1600.glb` e `.json` sostituiti con la versione S-Line (4,03 m, 486 mila triangoli, 1600 marcatori LED esclusi dalla geometria; mappa di progetto 4 × 200 indirizzi × 2 rami).
- Lettore glTF: supporto KHR_materials_clearcoat (vernice), sorgenti geometriche senza copie intermedie; la vernice è riconosciuta dal materiale `…_Python_Yellow`.
- **Credito**: “2021 Audi A1 S-Line” di tonielpro520 — https://sketchfab.com/3d-models/2021-audi-a1-s-line-da2cde1fa3574308877060c0c2d71f1d — licenza CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Modifiche: scala e orientamento, vernice grafite, mappa di progetto a LED. Il credito è mostrato in Mappa 3D e in Impostazioni.

## Versione 2.7 — correzione manuale delle zone

- Mappa 3D → Visualizzazione → **Modifica zone**: tocchi uno o più punti (evidenziati in bianco, con il conteggio), "Assegna zona…" con le 9 zone degli effetti adattivi, "Ripristina zona automatica", "Completa la striscia tra i 2 punti" (segue il ramo della Y più vicino).
- La correzione è salvata sul singolo punto fisico (`PhysicalLED.zoneOverride`) nel profilo `carmaps.json`: le due copie a Y dello stesso indirizzo possono avere zone diverse, ma l'indirizzo riceve sempre un solo RGB e le due copie mostrano lo stesso colore. Coordinate, indirizzi e zona di progetto non cambiano.
- Gli effetti adattivi usano subito la zona corretta. Test di regressione: scenario B/57 Cofano → Fiancata, riapertura del profilo, Blueprint fotogramma per fotogramma, ripristino.

## Versione 2.6 — 60 animazioni adattive

- `Logic/AdaptiveEffects.swift`: porting in Swift di `Effetti_Adattivi.py` (60 preset come funzioni di tempo, posizione e zona). Le animazioni si calcolano sui punti della mappa attiva: layout di progetto oppure scansione reale allineata. Con due punti a Y vince il colore col canale più luminoso; un indirizzo senza punti resta spento.
- Zona di ogni LED: quella del layout se presente, altrimenti quella del punto di progetto più vicino.
- I test confrontano l'uscita Swift con valori calcolati dal riferimento Python (tolleranza 1 per arrotondamenti di libm) e verificano i test di accettazione della specifica.
- Il vecchio pacchetto di fotogrammi pre-calcolati (25 MB) non è più incluso.

## Versione 2.5 — scansione reale sul modello

- **Allineamento al progetto**: quando salvi una scansione, ogni pixel scansionato viene confrontato con la sua posizione nel layout di progetto (stessa centralina, stesso indirizzo). Rotazione, posizione e scala vengono stimate con minimi quadrati robusti, verso dell'auto compreso; i LED montati diversamente dal progetto non falsano il calcolo e restano dove li ha misurati la scansione. Esito mostrato nella Mappa 3D; rifacibile da "Allinea al modello".

## Versione 2.4 — pacchetto 60 animazioni (sostituito dalla 2.6)

- Lettore di pacchetti di fotogrammi pre-calcolati (`Logic/FramePack.swift`), ancora disponibile nel codice; il Live invia l'ultimo fotogramma disponibile, la fluidità reale dipende dal BLE (~72 comandi/s per centralina).

## Versione 2.3 — progetto Blender A1 (1600 LED)

- **Modello 3D**: `Resources/Audi_A1_LED1600.glb` è incluso e usato come modello predefinito. Lettore glTF binario proprio (mesh, nodi, materiali PBR senza texture); i 1600 nodi `LED_*` vengono esclusi perché i LED li disegna l'app. Nessuna scalatura: stesse coordinate del layout.
- **Layout LED**: `Resources/Audi_A1_LED1600.json` (4 pacchi A–D × 200 pixel × 2 rami a Y = 1600 LED fisici, 800 pixel) si carica da Mappa 3D → menu mappa → "Carica layout A1 di progetto". Pacco A → 1ª centralina della lista, B → 2ª, …; quelle che mancano diventano centraline **da associare** (si associano da Aggiungi centralina).
- La mappa è etichettata **"posizioni da progetto — non misurate"**: vale solo se le strisce sono montate come nel progetto. Va verificata con "Accendi" sui LED; una scansione misura le posizioni vere.
- **Convenzione assi corretta**: x avanti, y alto, **sinistra = −z** (terna destrorsa come glTF/SceneKit). Prima l'app chiamava "sinistra" il lato +z, cioè il destro reale: zone, viste "Sinistra/Destra" ed effetto sinistra→destra ora corrispondono ai lati veri.
- Da verificare sull'hardware: che l'ordine dei pacchi e degli indirizzi sull'auto montata corrisponda al file.

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
