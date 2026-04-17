# Option B: Setup Guide – PowerShell + Task Scheduler

> No Power Automate license needed. Requires PowerShell 5.1+ and an always-on Windows machine.

## 1. Create App Registration

1. Go to **Azure Portal** → **Entra ID** → **App Registrations** → **New Registration**
2. Name: `GroupSync-Automation`, Single tenant
3. Add the following **Application Permissions** for Microsoft Graph:
   - `Group.Read.All`
   - `GroupMember.ReadWrite.All`
   - `User.Read.All`
   - `Sites.Selected`
4. Grant **Admin Consent**
5. Create a **Client Secret** (note: max 24 months validity)
6. Note down: **Client ID**, **Tenant ID**, **Client Secret**
7. **Grant the app access to your SharePoint site** (required for `Sites.Selected`):

   Run the following in **Microsoft Graph Explorer** or via PowerShell (requires **Sites.FullControl.All** delegated permission or **SharePoint Admin** role):

   ```http
   POST https://graph.microsoft.com/v1.0/sites/{site-id}/permissions
   Content-Type: application/json

   {
     "roles": ["write"],
     "grantedToIdentities": [
       {
         "application": {
           "id": "<YOUR-CLIENT-ID>",
           "displayName": "GroupSync-Automation"
         }
       }
     ]
   }
   ```

   Replace `{site-id}` with your SharePoint site ID and `<YOUR-CLIENT-ID>` with your App Registration's Client ID. You can find the site ID by calling `GET https://graph.microsoft.com/v1.0/sites/{hostname}:/{site-path}`.

> `Mail.Send` is not required for this option. Error notifications are logged to the SharePoint config list (status = "Error").

## 2. Run the Script

```powershell
.\GroupSync.ps1 `
  -TenantId "<YOUR-TENANT-ID>" `
  -ClientId "<YOUR-CLIENT-ID>" `
  -ClientSecret "<YOUR-CLIENT-SECRET>" `
  -SharePointSiteUrl "https://contoso.sharepoint.com/sites/MySite"
```

The script automatically resolves the SharePoint Site ID and List IDs from the URL and list names.

## 3. Create SharePoint Lists

Before the first run, create two lists on your SharePoint site:

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

## 4. Add Sync Pairs

Go to the **GroupSync-Config** SharePoint list and add entries:
- **Title:** Descriptive name (e.g. "Engineering Team Sync")
- **SourceGroupId:** GUID of the Security Group or Distribution List
- **TargetGroupId:** GUID of the existing Teams team
- **SyncEnabled:** Yes

Then run the script again – it will sync all enabled pairs.

## 5. Set Up Scheduled Task

Create a Windows Scheduled Task that runs the script every hour:

```powershell
$params = '-TenantId "<YOUR-TENANT-ID>" -ClientId "<YOUR-CLIENT-ID>" -ClientSecret "<YOUR-CLIENT-SECRET>" -SharePointSiteUrl "https://contoso.sharepoint.com/sites/MySite"'

$action = New-ScheduledTaskAction `
  -Execute "pwsh.exe" `
  -Argument "-NonInteractive -File `"C:\GroupSync\GroupSync.ps1`" $params"

$trigger = New-ScheduledTaskTrigger `
  -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Hours 1)

$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -DontStopIfGoingOnBatteries

Register-ScheduledTask `
  -TaskName "GroupSync" `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -RunLevel Highest `
  -User "SYSTEM"
```

> **Tip:** Use `pwsh.exe` for PowerShell 7+ or `powershell.exe` for Windows PowerShell 5.1.

## 6. Verify

- Check **Task Scheduler** → the task should appear under "GroupSync"
- After the next scheduled run, check the **GroupSync-Config** list for `LastSyncTime` and `LastSyncStatus`
- If members were changed, check the **GroupSync-Log** list for details

## Security Tip

Avoid storing the Client Secret in plain text in the scheduled task arguments. Consider:
- Storing the secret in a **Windows Credential Manager** entry and reading it in the script
- Using a **certificate** instead of a client secret for the App Registration
