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

- **Entra ID App Registration** with the following **Application Permissions** for Microsoft Graph (admin consent required):

| Permission | Used by | API Calls | Why |
|---|---|---|---|
| `Group.Read.All` | All options | `GET /groups/{source}/members` | Read members of the **source group** (Security Group or Distribution List). Without this, the sync cannot read the source of truth. |
| `GroupMember.ReadWrite.All` | All options | `GET /groups/{target}/members`, `GET /groups/{target}/owners`, `POST /groups/{target}/members/$ref`, `DELETE /groups/{target}/members/{id}/$ref` | Read **and write** members of the **target team**. Covers: listing current members, listing owners (to exclude them), adding new members, and removing former members. |
| `User.Read.All` | All options | `$select=id,displayName,userPrincipalName` on member queries | Allows querying user properties (`displayName`, `userPrincipalName`) when listing group members. Without this, Graph API only returns `id` — the sync log and console output would have no user names. |
| `Sites.ReadWrite.All` | All options | `GET /sites/{host}:/{path}`, `GET /sites/{id}/lists`, `GET .../items`, `PATCH .../items/{id}/fields`, `POST .../items` | Full SharePoint access: resolve site by URL, discover lists, read sync config, update config (status, timestamps, counts), and write log entries. |
| `Mail.Send` | **Option A only** | `POST /users/{sender}/sendMail` | Send error notification emails when a sync pair fails. **Not needed** for Options B and C (they log errors to the SharePoint config list instead). |

> **Note:** All permissions are **Application** type (not Delegated) because the sync runs unattended with client credentials — no user is signed in. A **Global Admin** or **Privileged Role Admin** must grant admin consent.

**Additional prerequisites per option:**

| Option | Additional Requirement |
|---|---|
| **A: Power Automate Flow** | Power Automate **Premium** license (for the flow owner – the HTTP connector is a premium feature) |
| **B: PowerShell + Task Scheduler** | PowerShell 5.1+, always-on Windows machine |
| **C: Azure Automation Runbook** | Azure Subscription (500 min/month free tier) |

## Setup Guides

All options require an **Entra ID App Registration** first. Each guide includes the full setup steps:

| Option | Guide | Requires |
|---|---|---|
| **A: Power Automate Flow** | [SETUP-OPTION-A.md](SETUP-OPTION-A.md) | Power Automate Premium license |
| **B: PowerShell + Task Scheduler** | [SETUP-OPTION-B.md](SETUP-OPTION-B.md) | PowerShell 5.1+, always-on Windows machine |
| **C: Azure Automation Runbook** | [SETUP-OPTION-C.md](SETUP-OPTION-C.md) | Azure Subscription (500 min/month free) |

### 🔐 Securing Secrets (Recommended)

By default, the Client Secret is stored in plain text. For production environments, follow the **[Azure Key Vault Setup Guide](SETUP-KEYVAULT.md)** to secure your secrets. The guide covers Key Vault integration for all three options.

## Add Sync Pairs

After setup, add entries to the **GroupSync-Config** SharePoint list:
- **Title:** Descriptive name (e.g. "Engineering Team Sync")
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
| `SETUP-OPTION-A.md` | Setup guide: Power Automate Flow |
| `SETUP-OPTION-B.md` | Setup guide: PowerShell + Task Scheduler |
| `SETUP-OPTION-C.md` | Setup guide: Azure Automation Runbook |
| `SETUP-KEYVAULT.md` | Setup guide: Securing secrets with Azure Key Vault |
| `FLOW-DOCUMENTATION.md` | Detailed action-by-action flow documentation (Option A) |
| `GroupSync.ps1` | PowerShell sync script (Option B & C) |
| `flow-definition/flow-definition.json` | Power Automate flow definition JSON (Option A) |
| `solutions/GroupSync-Solution.zip` | Power Platform Solution for import (Option A) |

## Security Considerations

- The client secret is stored **in plain text** in the flow definition
- For production, use **Azure Key Vault** or **Power Platform Environment Variables (Secret type)**
- The App Registration has broad permissions – review and restrict as needed
- Plan for **secret rotation** before expiry (max 24 months)
- Only sync specific groups (configured in the SharePoint list)

## License

MIT
