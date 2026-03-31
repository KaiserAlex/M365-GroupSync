# GroupSync – M365 Group Membership Sync

## Problem

Microsoft 365 Groups (Teams) unterstützen keine dynamische Mitgliedschaft basierend auf Security Groups oder Verteilerlisten. Änderungen in Quellgruppen werden nicht automatisch in die Zielgruppe (Teams/M365 Group) übernommen.

## Ziel

Ein Power Automate Flow, der zyklisch die Mitglieder einer **Security Group** oder **Verteilerliste** (Distribution List) mit einem **bestehenden Microsoft Teams Team** (M365 Group) synchronisiert. Dabei soll eine **App Registration** verwendet werden, damit kein persönlicher Benutzeraccount Mitglied/Owner des Teams sein muss.

## Getroffene Entscheidungen

| Thema | Entscheidung |
|---|---|
| Sync-Richtung | **One-Way** – Quellgruppe (Security Group / Verteilerliste) ist die einzige Source of Truth |
| Quellgruppen-Typen | **Security Groups** und **Exchange Verteilerlisten** (Distribution Lists) werden unterstützt |
| Teams erstellen? | **Nein** – es werden nur **bestehende Teams** synchronisiert |
| Owner-Handling | **Owner werden komplett ignoriert** – der Sync betrachtet ausschließlich Members |
| Manuell hinzugefügte Team-Members | Werden beim nächsten Sync **entfernt**, wenn sie nicht in der Quellgruppe sind |
| B2B-Gäste | **Werden mitgesynct** – Gast-User aus der Quellgruppe werden als Members ins Team übernommen |
| Sync-Methode | **Delta-Sync** – es wird nie das Team geleert und neu befüllt, sondern nur Differenzen verarbeitet |

## Lösungsansatz

### Architektur-Übersicht

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│  Security Group  │     │   Power Automate  │     │  Bestehendes Teams   │
│  oder Verteiler  │────▶│   (Scheduled)     │────▶│  Team (M365 Group)   │
│  (Quelle)        │     │   + HTTP Connector│     │  (Ziel)              │
└──────────────────┘     └──────────────────┘     └──────────────────────┘
                              │
                              ▼
                         Microsoft Graph API
                         (App-Only Auth via
                          App Registration)
```

---

## Phase 1: App Registration in Entra ID

### 1.1 App Registration erstellen
- Im Azure Portal → Entra ID → App Registrations → New Registration
- Name: z.B. `GroupSync-Automation`
- Supported account types: **Single tenant**
- Redirect URI: nicht erforderlich (Daemon/App-Only)

### 1.2 API-Berechtigungen konfigurieren (Application Permissions)
Folgende **Application Permissions** für Microsoft Graph hinzufügen:

| Permission | Typ | Zweck |
|---|---|---|
| `Group.Read.All` | Application | Mitglieder der Quellgruppe lesen (Security Group & Verteilerliste) |
| `GroupMember.ReadWrite.All` | Application | Mitglieder der Zielgruppe (Teams) lesen/schreiben |
| `User.Read.All` | Application | Benutzerinfos auflösen (optional, für Logging) |

- **Admin Consent** erteilen (durch Global Admin oder Privileged Role Admin)

> **Hinweis**: Dieselben Permissions funktionieren sowohl für Security Groups als auch für Verteilerlisten. Graph API behandelt beide als `group`-Objekte.

### 1.3 Client Secret erstellen
- Client Secret erstellen (Laufzeit max. 24 Monate beachten!)
- **Client ID**, **Tenant ID** und **Client Secret** notieren
- Secret-Rotation rechtzeitig vor Ablauf planen

---

## Phase 2: Power Automate Flow Design

### 2.1 Trigger
- **Recurrence** Trigger – läuft **stündlich** (Interval: 1, Frequency: Hour)

### 2.2 Token holen (OAuth2 Client Credentials Flow)
- **HTTP Action** an: `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token`
- Method: POST
- Body (x-www-form-urlencoded):
  ```
  grant_type=client_credentials
  client_id={app-client-id}
  client_secret={client-secret}
  scope=https://graph.microsoft.com/.default
  ```
- Access Token aus der Response parsen

### 2.3 Quell-Mitglieder abrufen (Security Group ODER Verteilerliste)

Der Graph-API-Call ist für beide Quellgruppen-Typen **identisch**:

- **HTTP Action** (GET):
  ```
  https://graph.microsoft.com/v1.0/groups/{source-group-id}/members?$select=id,userPrincipalName&$top=999
  ```
- Header: `Authorization: Bearer {access_token}`
- **Pagination beachten**: Falls `@odata.nextLink` vorhanden, weitere Seiten abrufen (Do-Until-Loop)
- **Wichtig**: Nur Objekte vom Typ `#microsoft.graph.user` filtern (dies schließt **B2B-Gäste** mit ein, da diese ebenfalls als User-Objekte in Entra ID existieren)
  - Security Groups können verschachtelte Gruppen enthalten → herausfiltern
  - Verteilerlisten können **Mail-Kontakte** (ohne Entra-Account) enthalten → herausfiltern (können nicht ins Team aufgenommen werden)
  - Mail-Kontakte (`#microsoft.graph.orgContact`) sind **keine** B2B-Gäste und werden nicht gesynct

### 2.4 Ziel-Mitglieder und Owner abrufen

**Schritt A – Alle Mitglieder des Teams abrufen:**
- **HTTP Action** (GET):
  ```
  https://graph.microsoft.com/v1.0/groups/{target-group-id}/members?$select=id,userPrincipalName&$top=999
  ```
- Pagination beachten, nur User-Objekte filtern

**Schritt B – Owner des Teams abrufen:**
- **HTTP Action** (GET):
  ```
  https://graph.microsoft.com/v1.0/groups/{target-group-id}/owners?$select=id
  ```
- Owner-IDs in einem separaten Array speichern

**Schritt C – Owner aus den Ziel-Mitgliedern herausfiltern:**
```
Ziel-Members (für Delta) = Alle Team-Mitglieder − Owner
```
→ Owner werden vom Sync **komplett ignoriert**

### 2.5 Delta-Berechnung (Sync-Logik)

```
Zu Hinzufügen = Quell-Mitglieder − (Ziel-Members + Owner)
Zu Entfernen  = Ziel-Members (ohne Owner) − Quell-Mitglieder
```

**Wichtige Details:**
- Beim **Hinzufügen**: Prüfen ob der User bereits als Owner im Team ist → wenn ja, **nicht** als Member hinzufügen (ist schon drin)
- Beim **Entfernen**: Nur Members entfernen, **nie Owner** → Owner sind bereits herausgefiltert
- **Select-Actions** oder **Filter Array** verwenden, um die IDs zu vergleichen
- Zwei Arrays erstellen: `toAdd` und `toRemove`

### 2.6 Mitglieder hinzufügen
- Für jeden User in `toAdd`:
  - **HTTP Action** (POST):
    ```
    https://graph.microsoft.com/v1.0/groups/{target-group-id}/members/$ref
    ```
  - Body:
    ```json
    {
      "@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/{user-id}"
    }
    ```
- **Tipp**: Batch-API nutzen (`$batch`) um bis zu 20 Requests pro Call zu senden → Performance
- **Fehlerfall**: HTTP 400 "Member already exists" → überspringen (User könnte als Owner bereits vorhanden sein)

### 2.7 Mitglieder entfernen
- Für jeden User in `toRemove`:
  - **HTTP Action** (DELETE):
    ```
    https://graph.microsoft.com/v1.0/groups/{target-group-id}/members/{user-id}/$ref
    ```
- Owner können hier **nie** betroffen sein, da sie in Schritt 2.4C bereits herausgefiltert wurden

### 2.8 Fehlerbehandlung & Benachrichtigung
- **Configure Run After** auf den HTTP Actions für Fehlerbehandlung
- Bei 429 (Throttling): Retry-After Header beachten, Delay einbauen
- Bei 404: User existiert nicht mehr → überspringen
- Bei 400 "Member already exists": überspringen (Owner-Szenario)
- Scope-Actions nutzen für Try-Catch-Muster

**Fehler-Benachrichtigung per E-Mail:**
- Bei einem Fehler im Flow wird eine **E-Mail an eine konfigurierbare Adresse** gesendet
- Die Fehler-Mailadresse wird in der Konfigurationstabelle (SharePoint) oder als Flow-Variable hinterlegt
- E-Mail enthält:
  - Quellgruppe und Zielgruppe (Name/ID)
  - Fehlermeldung und HTTP-Statuscode
  - Zeitpunkt des Fehlers
- Umsetzung: **"Send an email (V2)"** Action (Office 365 Outlook Connector) im Catch-Block (Scope mit "Configure Run After: has failed")

---

## Phase 3: Konfiguration & Skalierung

### 3.1 Konfigurationstabelle (SharePoint-Liste)
- SharePoint-Liste mit folgenden Spalten:
  - `SourceGroupId` (Text – GUID der Quellgruppe, Security Group oder Verteilerliste)
  - `TargetGroupId` (Text – GUID des bestehenden Teams / M365 Group)
  - `SyncEnabled` (Ja/Nein)
  - `LastSyncTime` (Datetime)
  - `LastSyncStatus` (Text – Success/Error)
  - `MembersAdded` (Zahl – Anzahl letzter Lauf)
  - `MembersRemoved` (Zahl – Anzahl letzter Lauf)
- Flow iteriert über alle Einträge mit `SyncEnabled = Ja` → **mehrere Gruppen-Paare** syncbar

### 3.2 Logging (SharePoint-Liste)
- Separate **SharePoint-Liste "GroupSync-Log"** mit folgenden Spalten:
  - `SyncTimestamp` (Datetime – Zeitpunkt des Sync-Laufs)
  - `SourceGroupId` (Text – GUID der Quellgruppe)
  - `TargetGroupId` (Text – GUID des Ziel-Teams)
  - `MembersAdded` (Zahl – Anzahl hinzugefügter Mitglieder)
  - `MembersRemoved` (Zahl – Anzahl entfernter Mitglieder)
  - `AddedUsers` (Mehrzeiliger Text – UPNs der hinzugefügten User)
  - `RemovedUsers` (Mehrzeiliger Text – UPNs der entfernten User)
- **Ein Log-Eintrag wird nur erstellt, wenn mindestens ein Mitglied hinzugefügt oder entfernt wurde**
- Wenn keine Änderungen → kein Eintrag, kein Rauschen im Log

### 3.3 Sicherheitsüberlegungen
- App Registration hat weitreichende Rechte → **Least Privilege** prüfen
- Conditional Access Policies für Service Principals prüfen
- Secret-Rotation planen (vor Ablauf neues Secret erstellen)
- Nur bestimmte Gruppen syncen (nicht wildcard)

### 3.4 ⚠️ Secret-Absicherung (TODO für Produktion)
- Das Client Secret steht aktuell **im Klartext** in der Flow-Definition (HTTP Action Body)
- Jeder, der den Flow editieren kann (Owner, Co-Owner, Environment Admin), kann das Secret sehen
- **Vor Produktionseinsatz** muss das Secret geschützt werden:
  - **Option A: Azure Key Vault** – Secret im Key Vault speichern, Flow liest es per Key Vault Connector zur Laufzeit
  - **Option B: Power Platform Environment Variable (Secret-Typ)** – verschlüsselte Variable, nur zur Laufzeit verfügbar
- Im **Demo-Tenant** ist dies akzeptabel, für **Produktions-Tenants** zwingend erforderlich

---

## Phase 4: Testing & Rollout

### 4.1 Test-Szenario
1. Kleine Security Group mit 3-5 Test-Usern erstellen
2. **Bestehendes** Test-Team mit mindestens einem Owner verwenden
3. Flow manuell starten → prüfen ob Sync funktioniert
4. User zur Security Group hinzufügen → nächster Flow-Lauf → User im Team?
5. User aus Security Group entfernen → nächster Flow-Lauf → User aus Team entfernt?
6. User manuell ins Team hinzufügen (ohne Quellgruppe) → nächster Flow-Lauf → User wieder entfernt?
7. Team-Owner prüfen → bleibt unverändert, egal ob in Quellgruppe oder nicht?
8. Gleichen Test mit einer Verteilerliste als Quelle wiederholen

### 4.2 Rollout
- Flow auf produktive Gruppen umstellen
- Recurrence-Intervall auf gewünschte Frequenz setzen
- Monitoring aktivieren

---

## Verhaltens-Szenarien (Referenz)

| Szenario | Ergebnis |
|---|---|
| User in Quellgruppe, nicht im Team | → Wird als **Member** hinzugefügt |
| User nicht in Quellgruppe, ist Member im Team | → Wird **entfernt** |
| User manuell ins Team hinzugefügt, nicht in Quellgruppe | → Wird beim nächsten Sync **entfernt** |
| User ist Owner im Team UND in der Quellgruppe | → **Nichts passiert** – Owner wird ignoriert |
| User ist Owner im Team, NICHT in der Quellgruppe | → **Nichts passiert** – Owner wird ignoriert |
| User in Quellgruppe UND bereits Member im Team | → **Nichts passiert** – kein Delta |
| Verteilerliste enthält Mail-Kontakt (kein Entra-User) | → Wird **herausgefiltert**, nicht ins Team aufgenommen |

---

## Noch offene Fragen

1. **Verschachtelte Gruppen**: Sollen Mitglieder aus verschachtelten Gruppen (transitive members) aufgelöst werden?
   → Falls ja: `/transitiveMembers` statt `/members` verwenden

2. **Lizenzierung Power Automate**: Der HTTP Connector benötigt einen **Premium-Connector** (Power Automate Premium Lizenz oder per-flow Plan)

3. **Alternative**: Azure Logic Apps oder Azure Function als Alternative zu Power Automate, falls keine Premium-Lizenz vorhanden

---

## Zusammenfassung der benötigten Ressourcen

| Ressource | Zweck |
|---|---|
| Entra ID App Registration | App-Only Auth für Graph API |
| Power Automate Premium | HTTP Connector (Premium erforderlich) |
| Microsoft Graph API | Mitglieder lesen/schreiben |
| SharePoint-Liste "GroupSync-Config" | Konfiguration der Gruppen-Paare |
| SharePoint-Liste "GroupSync-Log" | Logging (nur bei Änderungen) |
