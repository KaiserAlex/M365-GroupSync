# Copilot Instructions for GroupSync

## Project Overview

GroupSync synchronizes members from Entra ID **Security Groups** and **Distribution Lists** into **Microsoft Teams** (M365 Groups) using the Microsoft Graph API. It performs **one-way delta sync**: source group is the single source of truth, only differences are applied, and team owners are never touched.

Three interchangeable deployment options share the same sync logic, App Registration, and SharePoint lists:

- **Option A** – Power Automate Flow (hourly cloud flow using HTTP actions, no connectors)
- **Option B** – `GroupSync.ps1` on a Windows machine via Task Scheduler
- **Option C** – `GroupSync.ps1` as an Azure Automation Runbook

## Architecture

```
Source Group (Security Group / Dist. List)
    │
    ▼
Power Automate Flow  OR  GroupSync.ps1
    │
    ├── OAuth2 Client Credentials → Access Token
    ├── Read config from SharePoint list "GroupSync-Config"
    ├── For each enabled sync pair:
    │   ├── GET /groups/{source}/members (paginated, filter to users only)
    │   ├── GET /groups/{target}/members + /owners
    │   ├── Delta: toAdd = source − (targetMembers + owners)
    │   │         toRemove = targetMembers (excl. owners) − source
    │   ├── POST .../members/$ref  (add)
    │   ├── DELETE .../members/{id}/$ref  (remove)
    │   ├── PATCH config item (LastSyncTime, status, counts)
    │   └── POST log item (only if changes occurred)
    └── On failure: update config with error status, send email (Option A)
```

**SharePoint lists:**
- `GroupSync-Config` – sync pair definitions (SourceGroupId, TargetGroupId, SyncEnabled, status fields)
- `GroupSync-Log` – change log entries (only written when members actually change)

## Key Sync Rules

- **Owners are completely excluded** from all sync operations (never added, never removed)
- Users already present as owners are not re-added as members
- Only `#microsoft.graph.user` objects are synced; nested groups and mail contacts are filtered out
- B2B guest users are included in the sync
- HTTP 400 "already exists" errors during add are silently skipped
- Pagination (`@odata.nextLink`) must be followed for all member listings

## Code Structure

| File | Description |
|---|---|
| `GroupSync.ps1` | PowerShell sync script (Options B & C). Self-contained, auto-creates SharePoint lists if missing. |
| `flow-definition/flow-definition.json` | Power Automate flow definition (Option A). Uses HTTP actions with raw Graph API calls. |
| `solutions/GroupSync-Solution.zip` | Power Platform Solution package for import |
| `SETUP-OPTION-{A,B,C}.md` | Step-by-step setup guides for each deployment option |
| `SETUP-KEYVAULT.md` | Guide for securing secrets with Azure Key Vault (covers all options) |
| `FLOW-DOCUMENTATION.md` | Action-by-action documentation of the Power Automate flow |

## Conventions

- All Graph API calls use **app-only auth** (client credentials flow) — never delegated permissions
- The PowerShell script parameters `TenantId`, `ClientId`, `ClientSecret`, and `SharePointSiteUrl` are mandatory. `ConfigListName` and `LogListName` default to `"GroupSync-Config"` and `"GroupSync-Log"`.
- The flow definition JSON uses HTTP actions exclusively (no Power Automate connectors except Outlook for error emails)
- Documentation in the root folder is in **German**; documentation in `github-release/` (the published repo) is in **English**
- Config and log SharePoint lists are auto-created by the PowerShell script if they don't exist

## Graph API Permissions Required

| Permission | Type | Purpose |
|---|---|---|
| `Group.Read.All` | Application | Read source group members |
| `GroupMember.ReadWrite.All` | Application | Add/remove target group members |
| `User.Read.All` | Application | Resolve user information |
| `Sites.ReadWrite.All` | Application | Read/write SharePoint config and log lists |
| `Mail.Send` | Application | Error notification emails (Option A only) |

## Security Notes

- Client secrets are stored in plain text by default — production deployments should use Azure Key Vault (see `SETUP-KEYVAULT.md`)
- Never commit real tenant IDs, client IDs, or client secrets to the repository
- App Registration secret expiry is max 24 months — plan rotation ahead of time
