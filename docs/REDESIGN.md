# Redesign 3.0 — dove si trova ogni funzione

Navigazione nuova: **Studio · Mappa 3D · Centraline · Altro** (prima: Home, Centraline, Scansione, Mappa 3D, Effetti, Preset, Impostazioni).
Profili, mappe, scansioni, correzioni di zona, effetti e playlist salvati usano gli stessi file: nessuna migrazione.

| Funzione attuale (2.9) | Dove si trova dopo il redesign |
|---|---|
| Home › anteprima 3D con effetto | **Studio** (A1 a tutto schermo, ruotabile, gizmo assi) |
| Home › stato centraline, "Collega tutte" | Studio › stato in alto a destra (Offline / n/N collegate / Live n/N, tocco → Centraline); **Centraline** › Impianto |
| Home › copertura mappa, flusso a 4 passi | Altro › Panoramica e flusso |
| Badge "mappa dimostrativa / da progetto" | Studio › riga origine (Progetto · posizioni previste / Scansione / Dimostrativa) + conteggio punti e indirizzi; Mappa 3D › badge |
| Scansione 3D (scheda) | Mappa 3D › pulsante "Scansione" in alto a sinistra; Altro › Scansione 3D |
| Scansione 2D rapida (dentro Scansione) | invariata dentro Scansione 3D; Altro › Impostazioni › Scansione 2D |
| Mappa 3D › menu mappe (scegli, carica layout di progetto, importa JSON, dimostrativa, esporta, elimina) | Mappa 3D › menu in alto a destra (invariato) |
| Mappa 3D › viste camera (3/4, Davanti, Dietro, Sinistra, Destra, Alto) | Mappa 3D (invariato); Studio › pulsante camera sulla scena |
| Mappa 3D › tocco su un LED: dettagli, Accendi, riassegna, elimina | Mappa 3D › scheda selezione (invariata) + **anello** sulla copia a Y |
| Mappa 3D › Visualizzazione (Effetto/Centralina/Affidabilità/Zona, filtri) | Mappa 3D › Visualizzazione (invariata) |
| Mappa 3D › Modifica zone: selezione multipla, Completa striscia tra 2 punti, Assegna zona, Ripristina automatica | Mappa 3D › Modifica zone (invariata) + **cornice menta e targhetta "MODIFICA ZONE · n selezionati"** fisse sulla scena mentre si ruota |
| Mappa 3D › Allinea al modello (per progetto / per forma / inverti) | Mappa 3D › Mappa › Allinea al modello (invariato) |
| Esito allineamento automatico | Mappa 3D › Mappa: testo + **"Confronto col progetto: n/N corrispondenze" e "Scarto medio: x cm"** |
| Mappa 3D › modello (progetto S-Line, importa GLB/USDZ/SCN, rotazione, colore carrozzeria, crediti) | Mappa 3D › Modello (invariato) |
| Centraline › Impianto (Collega tutte, Scollega, Riconnessione automatica) | Centraline (invariato) + **riga A B C D con stato reale** e messaggi per 0 collegate, parziale, Bluetooth spento, disconnessione durante il Live |
| Centraline › scheda (Identifica, Collega/Scollega, modifica, rimuovi, associa segnaposto) | Centraline (invariato), con lettera A/B/C/D |
| Effetti › editor a livelli, zone, pittura, gradienti, salva | Altro › Editor effetti |
| Effetti › Anteprima / Live, Riproduci / Stop | Studio › trasporto: play/pausa, **Anteprima** e **Invia all'auto** separati; editor invariato |
| Preset › 60 animazioni adattive (libreria con 3D, velocità, intensità, colore unico) | Studio › nome del preset (un tocco → elenco dei 60) e regolazioni (icona cursori); Altro › 60 preset adattivi |
| Preset › effetti salvati e playlist | Altro › Effetti salvati e playlist (la modifica apre l'editor) |
| Impostazioni (luminosità, finestra di invio, Bluetooth Lab, editor 2D, mappe 2D, effetti interni, crediti) | Altro › Impostazioni e strumenti (invariato) |
| Effetti interni della centralina (SGLS/MULT) | Altro › Impostazioni › Effetti interni; Editor effetti › collegamento |
| Bluetooth Lab (diagnostica, HEX, log, esportazione) | Altro › Impostazioni › Bluetooth Lab |

Nuovo:
- **Inspector** del LED toccato (Studio): centralina e indirizzo (es. `B / 057`), ramo sinistro/destro, zona con origine (manuale · automatica dal progetto · stimata), RGB corrente (`#RRGGBB` e valori), cambio zona del singolo punto e ripristino. Punto toccato = cerchio pieno, copia sul ramo opposto = anello. Chiudere il pannello non tocca camera, preset né riproduzione.
- **Pausa/ripresa** (prima solo Stop): la posizione dell'animazione resta.
- **Offline**: senza centraline configurate o collegate, l'anteprima usa le centraline citate dalla mappa del profilo (numerazione invariata).
- Studio › **Mappa**: punti colorati per zona con legenda.
