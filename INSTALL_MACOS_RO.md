# Instalare rapidă Contragenti + Demo CRM (macOS)

Ghid scurt pentru Mac (Apple Silicon, macOS 13+). Fără Python și fără Git —
totul este în pachet. Versiunea detaliată (rusă): [INSTALL_MACOS_ru.md](INSTALL_MACOS_ru.md).

## 1. O singură comandă în Terminal

```bash
curl -fsSL https://raw.githubusercontent.com/PavelTuhari/Contragenti/main/release/contragenti-macos-install.sh | bash
```

Scriptul descarcă versiunea curentă din github.com/PavelTuhari/Contragenti,
verifică suma de control (sha256), dezarhivează în `~/Applications/Contragenti`
(fără parolă de administrator), elimină carantina Gatekeeper, creează
scurtături în `~/Applications` (apar în Launchpad) și pornește asistentul de
configurare.

Cu instalare pentru toți utilizatorii: `… | bash -s -- --system --lang ro`.

## 2. Alternativă: pachet `.pkg` (fără internet)

[Contragenti-1.3.7-macos.pkg](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.7-macos.pkg) —
conține tot, instalează în `/Applications/Contragenti`, la final deschide
asistentul. Pachetul nu este semnat cu Apple Developer ID: dacă macOS nu îl
deschide — clic dreapta → **Open** → „Open”.

## 3. Asistentul de configurare

Se deschide automat. Alegeți limba (Română / English / Русский — se
memorează în UserDefaults), lăsați bifele și apăsați **Execută**. Asistentul:

- întocmește pașaportul tehnic al Mac-ului;
- verifică Google Chrome (`/Applications/Google Chrome.app`, necesar pentru
  portalul date.gov.md);
- verifică `python3` — necesar doar pentru SDK-ul Python; la nevoie instalează
  3.12 (Homebrew sau pachetul oficial python.org, cu verificarea semnăturii);
- descarcă din GitHub componentele actualizate și baza inițială de companii;
- configurează Demo CRM (`crm.ini`, limba), completează datele demonstrative,
  rulează autoverificarea ambelor programe.

Verde „Gata” = totul funcționează. La erori — raport în
`~/Library/Logs/Contragenti/` și butoanele **Raportează pe GitHub** /
**Trimite prin e-mail**.

Fără fereastră: `"…/Contragenti Setup.app/Contents/MacOS/Contragenti Setup" --check`.

## 4. Unde sunt datele

| Date | Unde |
|---|---|
| `companies.db`, `tms_config.json` | `~/Library/Application Support/Contragenti/` |
| `clients.db`, `crm.ini`, rapoarte Demo CRM | `~/Library/Application Support/Contragenti/DemoCRM/` |
| loguri și rapoarte ale asistentului | `~/Library/Logs/Contragenti/` |
| limba Demo CRM | `defaults read md.una.contragenti.democrm Language` |

Reinstalarea nu atinge datele.

## 5. Primul client din registru

1. **Demo CRM** → **Clienți** → **Creează din registru**.
2. Se deschide Contragenti cu filtrul; căutați după denumire sau IDNO —
   se deschide Chrome vizibil (rezolvați reCAPTCHA, dacă apare).
3. Alegeți compania — cardul XML ajunge în CRM; același IDNO nu se dublează.

## Dezinstalare

```bash
"~/Applications/Contragenti/Contragenti Setup.app/Contents/MacOS/Contragenti Setup" --uninstall
```

Datele din `~/Library/Application Support/Contragenti` rămân (întreabă în
fereastră; `--purge-data` le șterge).

## Probleme frecvente

| Simptom | Ce faceți |
|---|---|
| „Contragenti.app este deteriorat / nu poate fi deschis” | carantină: `xattr -dr com.apple.quarantine ~/Applications/Contragenti` sau clic dreapta → Open |
| `bad CPU type in executable` | pachetul este arm64; pe Intel rulați din surse (`INSTALL_MACOS_ru.md` §9) |
| Chrome nu este găsit | instalați Google Chrome în `/Applications` |
| Demo CRM: „Contragenti nu a fost găsit” | Setări → calea către `Contragenti.app/Contents/MacOS/Contragenti` → Salvează |
