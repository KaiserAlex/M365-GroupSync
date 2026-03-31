# GroupSync - Microsoft 365 Group Membership Sync

> **⚠️ Disclaimer:** This solution is provided **"as is"** without warranty of any kind, express or implied. Use at your own risk. The authors assume no liability for any damages or issues arising from the use of this solution. Always test thoroughly in a non-production environment before deploying to production.

Automatically synchronize members from **Security Groups** and **Distribution Lists** into **Microsoft Teams** (M365 Groups).

## Problem

Microsoft 365 Groups (Teams) do not support dynamic membership based on Security Groups or Distribution Lists. Changes in source groups are not automatically reflected in the target team.

## Solution

This project provides **three interchangeable approaches** – choose the one that fits your environment:

| Approach | Description | Requires |
|---|---|---|
| **Option A: Power Automate Flow** | Cloud flow that runs hourly on the Power Platform | Power Automate **Premium** license |
| **Option B: PowerShell + Task Scheduler** | `GroupSync.ps1` runs on a schedule on a local PC or Windows Server | PowerShell 5.1+, always-on machine |
| **Option C: Azure Automation Runbook** | `GroupSync.ps1` runs as a cloud-hosted Runbook on a schedule | Azure Subscription (500 min/month free) |

All three options use the **same sync logic**, the **same App Registration**, and the **same SharePoint lists** for configuration and logging. You only need to set up **one** of them.

**What the sync does:**
- Members in the source group but not in the target team → **added**
- Members in the target team but not in the source group → **removed**
- Team owners are **never touched** (completely excluded from sync)
- Changes are logged to a SharePoint list

```
┌──────────────────┐     ┌──────────────────────────┐     ┌──────────────────────┐
│  Security Group  │     │  Power Automate Flow      │     │  Existing Teams      │
│  or Dist. List   │────▶│  OR                       │────▶│  Team (M365 Group)   │
│  (Source)        │     │  PowerShell Script (cron)  │     │  (Target)            │
└──────────────────┘     └──────────────────────────┘     └──────────────────────┘
                              │
                              ▼
                         Microsoft Graph API
                         (App Registration)
```

## Key Features

- **One-way sync** – Source group is the single source of truth
- **Delta sync** – Never clears and refills the team; only processes differences
- **Owner protection** – Team owners are completely ignored by the sync
- **B2B guest support** – External guests are synced as members
- **Multi-pair support** – Sync multiple source→target pairs via SharePoint config list
- **Conditional logging** – Log entries only created when members actually change
- **Error notifications** – Email alerts on sync failures
- **HTTP-only** – No Power Automate connectors needed; all auth via App Registration
- **Portable** – Deploy to any tenant by updating configuration values

## Prerequisites

- **Power Automate Premium** license (HTTP connector is a premium feature)
- **Entra ID App Registration** with the following Application Permissions (admin consent required):

| Permission | Purpose |
|---|---|
| `Group.Read.All` | Read source group members |
| `GroupMember.ReadWrite.All` | Add/remove target group members |
| `User.Read.All` | Resolve user information |
| `Sites.ReadWrite.All` | Read/write SharePoint list items |
| `Sites.Manage.All` | Create SharePoint list items |
| `Mail.Send` | Send error notification emails |

## Setup Guide

### 1. Create App Registration

1. Go to **Azure Portal** → **Entra ID** → **App Registrations** → **New Registration**
2. Name: `GroupSync-Automation`, Single tenant
3. Add the Application Permissions listed above
4. Grant **Admin Consent**
5. Create a **Client Secret** (note: max 24 months validity)

### 2. Create SharePoint Lists

Create two lists on a SharePoint site:

**GroupSync-Config:**

| Column | Type |
|---|---|
| SourceGroupId | Text |
| TargetGroupId | Text |
| SyncEnabled | Yes/No |
| LastSyncTime | Text |
| LastSyncStatus | Text |
| MembersAdded | Number |
| MembersRemoved | Number |

**GroupSync-Log:**

| Column | Type |
|---|---|
| SyncTimestamp | Text |
| SourceGroupId | Text |
| TargetGroupId | Text |
| MembersAdded | Number |
| MembersRemoved | Number |
| AddedUsers | Multi-line Text |
| RemovedUsers | Multi-line Text |

### 3. Deploy the Flow

Update the placeholders in `flow-definition/flow-definition.json` with your tenant-specific values:

| Placeholder | Description |
|---|---|
| `<YOUR-TENANT-ID>` | Entra ID tenant ID |
| `<YOUR-CLIENT-ID>` | App Registration client ID |
| `<YOUR-CLIENT-SECRET>` | App Registration client secret |
| `<YOUR-SHAREPOINT-SITE-ID>` | Graph API site ID (format: `domain,site-guid,web-guid`) |
| `<YOUR-CONFIG-LIST-ID>` | Graph API list ID for GroupSync-Config |
| `<YOUR-LOG-LIST-ID>` | Graph API list ID for GroupSync-Log |
| `<YOUR-SENDER-UPN>` | Email address of the sender mailbox for error notifications |
| `<YOUR-ERROR-EMAIL>` | Recipient email for error notifications |

Then deploy via the **Dataverse API** or import as a **Power Platform Solution**.

### 4. Add Sync Pairs

Add entries to the **GroupSync-Config** SharePoint list:
- **Title:** Descriptive name
- **SourceGroupId:** GUID of the Security Group or Distribution List
- **TargetGroupId:** GUID of the existing Teams team
- **SyncEnabled:** Yes

## Behavior Reference

| Scenario | Result |
|---|---|
| User in source, not in team | → **Added** as member |
| User not in source, is member in team | → **Removed** |
| User manually added to team, not in source | → **Removed** on next sync |
| User is team owner AND in source | → **Nothing** – owner is ignored |
| User is team owner, NOT in source | → **Nothing** – owner is ignored |
| User in source AND already member | → **Nothing** – no delta |
| Distribution List contains mail contact (no Entra account) | → **Filtered out** |

## Files

| File | Description |
|---|---|
| `README.md` | This file |
| `FLOW-DOCUMENTATION.md` | Detailed action-by-action flow documentation |
| `plan.md` | Project plan and architecture decisions |
| `IMPORT-ANLEITUNG.md` | Import guide (German) |
| `GroupSync.ps1` | Standalone PowerShell sync script |
| `flow-definition/flow-definition.json` | Power Automate flow definition (JSON) |

## Option B: Run as PowerShell Script (Task Scheduler)

Instead of Power Automate, you can run `GroupSync.ps1` on a schedule with the **same sync behavior**. This avoids the need for a Power Automate Premium license.

```powershell
# Run manually
.\GroupSync.ps1 -TenantId "..." -ClientId "..." -ClientSecret "..." -SharePointSiteUrl "https://contoso.sharepoint.com/sites/MySite"
```

On the first run, the script **automatically creates** the SharePoint lists (`GroupSync-Config` and `GroupSync-Log`) if they don't exist yet.

**Set up as scheduled task (runs every hour):**
```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument '-File "C:\path\to\GroupSync.ps1" -TenantId "..." -ClientId "..." -ClientSecret "..." -SharePointSiteUrl "https://contoso.sharepoint.com/sites/MySite"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName "GroupSync" -Action $action -Trigger $trigger -RunLevel Highest
```

## Option C: Run as Azure Automation Runbook

Host the script in Azure – no local machine required, runs reliably in the cloud.

**Setup:**
1. Create an **Azure Automation Account** in the Azure Portal
2. Go to **Runbooks** → **Create a runbook**
   - Name: `GroupSync`
   - Type: **PowerShell**
   - Runtime version: **7.2** (or higher)
3. Paste the contents of `GroupSync.ps1` into the editor
4. Replace the `param()` default values with your tenant-specific values (or use Azure Automation variables/encrypted credentials)
5. **Publish** the runbook
6. Go to **Schedules** → **Add a schedule**
   - Recurrence: **Every 1 hour**
   - Link the schedule to the runbook

**Cost:** Azure Automation includes **500 minutes/month free**. A typical GroupSync run takes a few seconds, so the free tier is more than sufficient.

**Tip:** For better security, store the Client Secret as an **Azure Automation Encrypted Variable** instead of hardcoding it in the runbook:
```powershell
# In the runbook, replace the param with:
$ClientSecret = Get-AutomationVariable -Name 'GroupSyncClientSecret'
```

## Security Considerations

- The client secret is stored **in plain text** in the flow definition
- For production, use **Azure Key Vault** or **Power Platform Environment Variables (Secret type)**
- The App Registration has broad permissions – review and restrict as needed
- Plan for **secret rotation** before expiry (max 24 months)
- Only sync specific groups (configured in the SharePoint list)

## License

MIT
