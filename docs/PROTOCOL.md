# Protocollo BLE del controller ISP-B0717F — ricerca

Fonti analizzate (codice sorgente e documentazione):

- [8none1/idealLED](https://github.com/8none1/idealLED) — integrazione Home Assistant, `att_protocol.md`, `idealled_controller.py`, `custom_components/ideal_led/*`.
- [KyleJamesWalker/glowmote](https://github.com/KyleJamesWalker/glowmote) — `docs/protocols/ideal-led.md`, `crates/glowmote-core/src/ideal.rs` (encoder con test sulle catture), analisi Ghidra del firmware `TR2309R002-02`.

Legenda usata in tutto il documento:

- **DOCUMENTATO** — byte catturati dall'app vendor su un controller reale e/o codice che li riproduce con test. I test di questo repository (`Tests/main.swift`) rigenerano byte per byte i testi cifrati pubblicati.
- **DEDOTTO** — conclusione ragionata dalle fonti, non osservata sul nostro controller.
- **DA VERIFICARE** — serve una prova fisica su ISP-B0717F.

## 0. Verificato su ISP-B0717F (22/11/2026, iPhone, Audi Light Studio 0.1.0)

| Dato | Valore osservato |
|---|---|
| Modello (descrittore 2901 su …9600) | `TR2309R012-01` |
| `VE 00` | `V023.09.12.1` |
| `VE 01` | `V122.12.02.1` |
| Max Write Without Response | **20 byte** (MTU 23, non alzata dal controller) |
| Max Write con risposta | 512 byte (scrittura lunga; supporto lato controller DA VERIFICARE) |
| Tabella GATT | identica a nRF Connect: FFF0 (…9600, …960A, …960B, …9601), FD00, AE00 |

Comandi **VERIFICATI SUL DISPOSITIVO** (byte inviati e ack ricevuto):

| Comando | Risposta decifrata | Latenza |
|---|---|---|
| `VE 00` / `VE 01` | `0D 'V023.09.12.1'`, `0D 'V122.12.02.1'` | 53 ms, 84 ms |
| `DEN 00` | nessun ack (come documentato) | — |
| `DOOD` indice 0 rosso, luminosità 50 | `06 'DOODOK' 00` + coda tabella | 65 ms |
| `DOOD` indice 0 blu | `06 'DOODOK'` | 45 ms |

Esito visivo riferito dall'utente: si accende solo il primo LED, rosso e poi blu.

Conseguenze:

- Chiave AES, formato `DOOD` e indice big-endian confermati: il LED fisico 1 è l'indice 0.
- Il firmware è della famiglia **TR2309**, la stessa dell'immagine `TR2309R002-02` analizzata da glowmote. Il limite di **400 LED per centralina** è quindi molto probabile anche qui (variante R012, non ancora disassemblata).
- Con MTU 23 i frame bulk `DOOT` su …960A devono stare in 20 byte (l'app vendor usa frame corti quando l'MTU non è alta): da implementare e verificare nella Milestone 2.
- Un `DOOD` per pixel con attesa dell'ack richiede ~50–65 ms: circa 15–20 pixel/s. Per i disegni completi serve `DOOT`.

## 1. Compatibilità con ISP-B0717F

| Punto | Stato | Note |
|---|---|---|
| Nome `ISP-*` gestito da entrambi i progetti | DOCUMENTATO | `NAME_ARRAY = ["ISP-", "IDL-"]` (idealLED), `NAME_PREFIXES` (glowmote). |
| Stessa tabella GATT (FFF0 con …9600/…9601/…960A/…960B, FD00, AE00) | DOCUMENTATO + osservato | La tabella rilevata con nRF Connect coincide con quella di glowmote per `ISP-50542B`. |
| Famiglia firmware | DEDOTTO | glowmote: le immagini `TR2202` in poi con nome `ISP-` usano questo protocollo; `IDL-` `TR2107/TR2110` usano un altro set di comandi. Le versioni rilevate dall'app iDeal LED (HW 22.12.02.1, FW 23.09.12.1) hanno lo stesso formato delle risposte `VE 00` = `V0…` e `VE 01` = `V1…` (es. `V024.11.03.7` / `V124.11.66.1`). FW 23.09.x è coetaneo dell'immagine `TR2309R002-02` analizzata da glowmote. |
| Stessa chiave AES | VERIFICATO (§0) | Il Bluetooth Lab invia `VE 00` (richiesta di sola lettura) e considera confermato il protocollo solo se la notifica decifrata è una stringa `V…`. |
| App iDeal LED 4.0.7 | DEDOTTO | Le fonti hanno decompilato `com.tech.idealled` (8none1) e `com.winkison.ledlight` 3.1.7 (glowmote): stessi tag e stessa chiave. La versione 4.0.7 non è stata analizzata. |

## 2. Caratteristiche

| UUID | Proprietà osservate | Uso | Stato |
|---|---|---|---|
| `…9600` | Write / WNR | Comandi, 1 blocco AES-128-ECB da 16 byte, Write Without Response | DOCUMENTATO |
| `…9600` descrittore `2901` | Read | Stringa modello, es. `TR2411R003-07` | DOCUMENTATO (lettura) |
| `…9601` | Notify | Ack cifrati `<len> <TAG>OK`, risposte `VE` | DOCUMENTATO |
| `…960A` | Write / WNR | Frame in chiaro dopo `MULT` / `DOOT` (fino a 100 byte) | DOCUMENTATO |
| `…960B` | Write / WNR | Livelli musica cifrati `02 effetto livello` | DOCUMENTATO solo da glowmote; non usato |
| `FD01`, `FD02` | Write, Write/Notify | Sconosciuto | **Mai scritto dall'app** |
| `AE01`, `AE02` | WNR, Notify | OTA JieLi (RCSP), autenticazione E1 | **Mai scritto dall'app** |

Le notifiche lette su `AE02` appartengono al canale OTA JieLi (glowmote): non sono cifrate con la chiave iDeal e non servono al controllo luci. Le notifiche su `…9601` si decifrano con la chiave AES; solo i primi `len + 1` byte sono significativi (il resto è la voce successiva della tabella risposte del firmware).

## 3. Cifratura

- AES-128-ECB, nessun padding, nessun IV, nessun contatore: lo stesso comando produce sempre gli stessi byte. DOCUMENTATO.
- Chiave `34 52 2A 5B 7A 6E 49 2C 08 09 0A 9D 8D 2A 23 F8` (da `libAES.so`). DOCUMENTATO.
- Nessuna procedura di inizializzazione è necessaria per i comandi luce: glowmote ha pilotato `ISP-50542B` senza handshake. L'handshake su AE01/AE02 è solo per l'OTA. DOCUMENTATO.
- Dopo la connessione il controller lampeggia 3 volte e riapplica il proprio stato in ~1,5–2 s: un comando inviato subito può essere annullato (idealLED, `settle`). L'app attende 3 s (configurabile).

## 4. Formato dei pacchetti

`<len> <TAG ASCII> <argomenti> <zeri fino a 16 byte>`; `len` conta tag + argomenti (eccezioni: `SGLS` 0x0F, `TIME` 0x15, `DSTOP` 0x05, `DOOD` 0x0D).

| Comando | In chiaro | Stato |
|---|---|---|
| Accendi | `05 54 55 52 4E 01` + zeri | DOCUMENTATO, ack `TURNOK` |
| Spegni | `05 54 55 52 4E 00` + zeri | DOCUMENTATO |
| Colore / luminosità | `0F 'SGLS' modo dir lum vel R G B R G B sat` | DOCUMENTATO; la luminosità si ottiene scalando RGB |
| Versione | `03 'VE' 00` / `03 'VE' 01` | DOCUMENTATO |
| Entra in DIY | `04 'DEN' 00` (azzera la tela) | DOCUMENTATO, nessun ack |
| Pixel DIY | `0D 'DOOD' 01 idxH idxL modo vel R G B lum 00 00` | DOCUMENTATO, ack `DOODOK` |
| Riempi DIY | `0D 'DOOD' 00 nH nL …` con n = numero LED | DOCUMENTATO |
| Esci da DIY | `05 'DSTOP' 01` (mantieni) / `00` (ripristina) | DOCUMENTATO |
| Disegno DIY in blocco | `04 'DOOT' nFrame` → frame su …960A → `06 'DOOTCP'` → `08 'DTARTCY' 01` | DOCUMENTATO |

### Trasferimento disegni (`DOOT`)

- Frame su `…960A` in chiaro: `<len dati + 1> <indice frame> <record…>`, fino a 100 byte; record da 7 byte `nH nL R G B modo vel` (run di LED consecutivi), 14 record per frame. DOCUMENTATO.
- Ogni frame riceve `DOOTREOK <indice>`, la chiusura `DOOTCPOK`. Il firmware conserva il disegno solo se l'ultimo indice è `nFrame − 1`. DOCUMENTATO (glowmote, firmware).
- Un upload interrotto prima di `DOOTCP` lascia l'offset di scrittura a metà striscia. DOCUMENTATO (firmware).

### MTU e segmentazione

- Comandi: sempre 16 byte, entro qualsiasi MTU.
- Frame bulk: 100 byte richiedono MTU negoziata alta; con MTU minima l'app vendor usa 19 byte di dati per frame. L'app mostra `maximumWriteValueLength` dopo la connessione. DA VERIFICARE su iPhone + ISP-B0717F.

## 5. Limiti di sicurezza (rischio di danni)

L'autore di idealLED ha reso inutilizzabile un controller inviando dati non validi. glowmote ha trovato nel firmware TR2309 scritture **senza controllo dei limiti, salvate in flash**:

| Campo | Limite sicuro | Fuori limite |
|---|---|---|
| `DOOD` indice pixel | < 400 | scrive oltre i buffer da 400 byte per canale |
| `CT` / `LAMPN` numero LED | ≤ 400 | scrive oltre i buffer di frame |
| `SGLS` modo | 0–9 | scrive fuori array |
| `MULT` effetto / colori | 0–11 / 1–7 | fuori array, divisione per zero |
| `LAMPT` tipo LED | 0–4 | luci "morte" a ogni riaccensione |
| `SPLAY` scene | 1–8 | sovrascrive chiavi flash fino al MAC |
| `TEST` | mai | test di fabbrica |

**Conseguenza per il progetto (DEDOTTO, DA VERIFICARE):** un singolo controller di questa famiglia gestisce al massimo 400 LED. 1600 LED richiedono quasi certamente più centraline (es. 4 × 400) oppure un firmware diverso, da dimostrare. L'app rifiuta indici ≥ 400 e non invia mai `CT`, `LAMPN`, `LAMPT`, `SPLAY`, `TEST`, `CHECKLINE`.

## 6. Primo obiettivo: LED 1 rosso → blu

Sequenza implementata nel Bluetooth Lab (scheda *Protocollo*), abilitata solo dopo la verifica:

1. Connessione, attesa 3 s, sottoscrizione manuale a `…9601`.
2. `VE 00` / `VE 01` → risposta decifrata `V…` = chiave e protocollo confermati.
3. `DEN 00` → entra in DIY e azzera la tela (gli altri LED restano spenti).
4. `DOOD 01 0000 02 64 FF 00 00 <lum>` → LED 1 rosso; atteso `DOODOK`.
5. `DOOD 01 0000 02 64 00 00 FF <lum>` → LED 1 blu; atteso `DOODOK`.
6. `DSTOP 01` → esce da DIY mantenendo il disegno (coerente con il disegno conservato dopo la disconnessione).

Byte con luminosità 100 (calcolati dall'encoder, verificato sulle catture):

| Passo | In chiaro | Cifrato |
|---|---|---|
| VE 00 | `03 56 45 00` + zeri | `263a91cc5f1bf003ce437b733478ada2` (presente anche nella cattura 8none1) |
| VE 01 | `03 56 45 01` + zeri | `d12e61ad95a00bd3c56bee6f9cb545fe` |
| DEN 00 | `04 44 45 4E 00` + zeri | `cbe9305dbde55cf3f8f13873f0920f2f` |
| LED 1 rosso | `0D 44 4F 4F 44 01 00 00 02 64 FF 00 00 64 00 00` | `d5ed404577c1cebe659eb1b8b181dfe9` |
| LED 1 blu | `0D 44 4F 4F 44 01 00 00 02 64 00 00 FF 64 00 00` | `77f06aa03e14bdefc90bf3674f227f44` |
| DSTOP 01 | `05 44 53 54 4F 50 01` + zeri | `5eb9c3c21f0457240f0c39e0d0953039` |

Ipotesi ancora aperte: stessa chiave (passo 2), stesso layout DOOD sul FW 23.09.12.1 (passo 4), indice 0 = primo LED fisico (coerente con il test DIY fatto in iDeal LED), effetto reale del byte luminosità (il firmware TR2309 lo ignora).

## 7. Se la verifica fallisce

Il Lab non abilita i pulsanti del pixel. Diagnostica da raccogliere (pulsante *Diagnostica* nel Log):

- Tabella GATT completa con proprietà e descrittore `2901`.
- Notifiche grezze su `…9601` e il loro tentativo di decifratura.
- MTU negoziata.

Il passo successivo sarebbe una cattura `btsnoop` da Android con l'app iDeal LED (procedura in glowmote `docs/protocols/ideal-led.md`, sezione *Capturing more*) mentre si accende il solo primo pixel.
