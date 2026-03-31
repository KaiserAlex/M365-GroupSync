# GroupSync - Import-Anleitung

## Was wurde erstellt?

### 1. App Registration (Entra ID)
- **Name**: GroupSync-Automation
- **Client ID**: `<YOUR-CLIENT-ID>`
- **Tenant ID**: `<YOUR-TENANT-ID>`
- **Client Secret**: `<YOUR-CLIENT-SECRET>`
- **Permissions**: Group.Read.All, GroupMember.ReadWrite.All, User.Read.All, Sites.ReadWrite.All

### 2. SharePoint-Listen (auf der SharePoint Demo Site)
- **GroupSync-Config** – Konfiguration der Sync-Paare
- **GroupSync-Log** – Protokoll der Änderungen (nur bei Änderungen)

### 3. Security Group (Test)
- **Name**: GroupSync-TestSource
- **ID**: `<YOUR-SOURCE-GROUP-ID>`
- **Members**: Adil Eli, Amber Rodriguez, Billie Vester

### 4. Ziel-Team (Test)
- **Name**: Demo Team
- **ID**: `<YOUR-TARGET-GROUP-ID>`
- **Owner**: MOD Administrator (wird vom Sync ignoriert)

---

## Power Automate Flow importieren

### Schritt 1: Power Automate öffnen
1. Gehe zu https://make.powerautomate.com
2. Stelle sicher, dass du im richtigen Environment bist

### Schritt 2: Import starten
1. Klicke links auf **"Meine Flows"** (My Flows)
2. Klicke auf **"Importieren"** → **"Paket importieren (Legacy)"**
3. Lade die Datei **`GroupSync-Flow.zip`** hoch

### Schritt 3: Verbindungen konfigurieren
Beim Import werden zwei Verbindungen benötigt:

| Connector | Aktion |
|---|---|
| **SharePoint** | Wähle eine bestehende SharePoint-Verbindung oder erstelle eine neue (mit deinem Admin-Account) |
| **Office 365 Outlook** | Wähle eine bestehende Outlook-Verbindung oder erstelle eine neue (für Fehler-E-Mails) |

### Schritt 4: Import bestätigen
- Klicke auf **"Importieren"**
- Der Flow wird als **"GroupSync - Member Sync"** erstellt

### Schritt 5: Flow aktivieren
1. Öffne den importierten Flow
2. Prüfe ob der Flow aktiviert ist (Status: "Ein")
3. Klicke auf **"Testlauf"** um den Flow manuell zu starten

---

## Weitere Sync-Paare hinzufügen

1. Gehe zur SharePoint-Liste **"GroupSync-Config"** auf der SharePoint Demo Site
2. Füge einen neuen Eintrag hinzu:
   - **Title**: Beschreibender Name
   - **SourceGroupId**: GUID der Security Group oder Verteilerliste
   - **TargetGroupId**: GUID des Teams / M365 Group
   - **SyncEnabled**: Ja
3. Beim nächsten Flow-Lauf wird das neue Paar automatisch synchronisiert

---

## Dateien in diesem Ordner

| Datei | Beschreibung |
|---|---|
| `plan.md` | Vollständige Projektdokumentation |
| `IMPORT-ANLEITUNG.md` | Diese Anleitung |
| `Test-GroupSync.ps1` | PowerShell Test-Script (standalone, ohne Power Automate) |
| `GroupSync-Flow.zip` | Power Automate Import-Paket |
| `flow-package/` | Quellcode des Flow-Pakets (JSON) |
