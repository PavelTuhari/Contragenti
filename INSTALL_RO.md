# Instalare rapidă Contragenti + Demo CRM (Windows)

Ghid scurt: cinci pași, fără Python și fără Git. Verificat pe Windows 10/11
și Windows Server 2022.

## 1. Descărcați instalatorul

**[Contragenti-1.3.3-setup.exe](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.3-setup.exe)**
(≈50 MB, fără Windows Installer — funcționează și acolo unde MSI este
interzis prin politică).

Dacă browserul afișează „isn't commonly downloaded”: fișierul nu este semnat
cu certificat de dezvoltator. Apăsați „⋯” → **Keep / Păstrează**. Suma de
control se poate verifica cu `Get-FileHash` față de `release.json` din
repozitoriu.

Alternativă pentru medii cu MSI obligatoriu:
[Contragenti-1.3.3-win64.msi](https://github.com/PavelTuhari/Contragenti/raw/main/release/Contragenti-1.3.3-win64.msi)
(rulați `msiexec` ca administrator).

## 2. Rulați instalatorul

Confirmați cererea UAC — programul se instalează în
`C:\Program Files\Contragenti` pentru toți utilizatorii. Fără drepturi de
administrator apăsați „Nu”: instalarea continuă în profilul curent
(`%LOCALAPPDATA%\Contragenti`).

Se creează scurtăturile **Contragenti** și **Demo CRM (SDK Contragenti)** pe
desktop și dosarul **Contragenti** în meniul Start.

Instalare silențioasă:

```powershell
.\Contragenti-1.3.3-setup.exe /S
.\Contragenti-1.3.3-setup.exe /S /D=D:\Contragenti --no-wizard
```

## 3. Asistentul de configurare

Se deschide automat după instalare (și după `msiexec … /qn`). Alegeți limba
sus (Română / English / Русский — se ține minte în registru), lăsați bifele și
apăsați **Execută**. Asistentul:

- întocmește pașaportul tehnic al calculatorului;
- verifică Google Chrome (necesar pentru portalul date.gov.md — dacă lipsește,
  buton „Descarcă Chrome”);
- instalează Python doar dacă lipsește și doar pentru SDK-ul Python: pe
  Windows modern prin winget / Microsoft Store, pe Windows vechi și pe
  Windows Server prin instalatorul oficial python.org cu verificarea
  semnăturii;
- descarcă din GitHub componentele actualizate și baza inițială de companii;
- configurează Demo CRM (`crm.ini`, limba), completează datele demonstrative,
  rulează autoverificarea ambelor programe.

Verde „Gata” = totul funcționează. La erori, asistentul salvează un raport
(pașaport + log) și oferă butoanele **Raportează pe GitHub** / **Trimite prin
e-mail** — trimite doar utilizatorul.

Asistentul poate fi pornit oricând: Start → **Contragenti — настройка и
обновление** (`ContragentiSetup.exe`), fără fereastră:
`ContragentiSetup.exe --check`.

## 4. Ce este deja înăuntru

Instalarea conține baze cu date: `companies.db` (≈200 companii din
date.gov.md) și `DemoCRM\clients.db` (firmă demonstrativă completă: clienți,
oportunități, comenzi, proiecte cu licitații și avansuri, sarcini). La prima
pornire programele copiază bazele în profil și lucrează cu copiile:

| Date | Unde |
|---|---|
| `companies.db`, `tms_config.json` | `%LOCALAPPDATA%\Contragenti\` |
| `clients.db`, `crm.ini`, rapoarte Demo CRM | `%LOCALAPPDATA%\Contragenti\DemoCRM\` |
| loguri și rapoarte ale asistentului | `%LOCALAPPDATA%\Contragenti\logs\` |

Reinstalarea nu atinge datele dumneavoastră.

## 5. Primul client din registru

1. Deschideți **Demo CRM** → **Clienți** → **Creează din registru**.
2. Se deschide Contragenti cu filtrul; introduceți denumirea sau IDNO și
   apăsați **Căutare** — se deschide Chrome vizibil.
3. Dacă Google arată reCAPTCHA, rezolvați-o în fereastra Chrome (utilitarul
   nu o ocolește).
4. Alegeți compania — cardul XML (IDNO, adresă, administrator, fondatori,
   datorii) ajunge în CRM; același IDNO nu se dublează.

## Dezinstalare

**Programe și caracteristici → Contragenti** sau Start → Contragenti →
**Удалить Contragenti**. Datele din `%LOCALAPPDATA%\Contragenti` se șterg
odată cu programul — salvați bazele înainte, dacă sunt necesare.

## Probleme frecvente

| Simptom | Ce faceți |
|---|---|
| „The system administrator has set policies to prevent this installation” | Este politica MSI (cod 1625). Folosiți `Contragenti-1.3.3-setup.exe` |
| Chrome nu este găsit | Instalați Google Chrome; fără el portalul nu este accesibil |
| `CERTIFICATE_VERIFY_FAILED` în log | Depozitul de certificate Windows este vechi; asistentul trece automat pe setul de certificate din instalare, iar la nevoie descarcă fișierele individual |
| Căutarea se blochează | Nu folosiți „browser ascuns”; rezolvați captcha în Chrome; nu lansați multe căutări la rând |

Documentație detaliată (rusă): [INSTALL_MSI_ru.md](INSTALL_MSI_ru.md),
[INSTALL_WINDOWS_ru.md](INSTALL_WINDOWS_ru.md), integrare —
[INTEGRATION.md](INTEGRATION.md).
