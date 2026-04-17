# Option C: Setup Guide – Azure Automation Runbook

> No local machine required. Runs reliably in the Azure cloud.
> Azure Automation includes **500 minutes/month free** – more than enough for hourly GroupSync runs.

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

## 2. Create Azure Automation Account

1. Go to **Azure Portal** → **Create a resource** → search for **Automation**
2. Select **Automation Account** → **Create**
3. Fill in:
   - **Name:** `GroupSync-Automation`
   - **Resource Group:** Create new or use existing
   - **Region:** Choose your preferred region
4. Click **Create**

## 3. Store Credentials Securely

Instead of hardcoding secrets in the runbook, use **Encrypted Variables**:

1. In the Automation Account → **Shared Resources** → **Variables**
2. Create the following variables (set **Encrypted** = Yes for secrets):

| Variable Name | Value | Encrypted |
|---|---|---|
| `GroupSync-TenantId` | Your tenant ID | No |
| `GroupSync-ClientId` | Your client ID | No |
| `GroupSync-ClientSecret` | Your client secret | **Yes** |
| `GroupSync-SharePointSiteUrl` | Your SharePoint site URL | No |

## 4. Create the Runbook

1. In the Automation Account → **Process Automation** → **Runbooks** → **Create a runbook**
2. Fill in:
   - **Name:** `GroupSync`
   - **Runbook type:** **PowerShell**
   - **Runtime version:** **7.2** (or higher)
3. Click **Create**
4. In the editor, paste the following modified version of `GroupSync.ps1`:

```powershell
# GroupSync - Azure Automation Runbook
# Reads credentials from Azure Automation Variables

$TenantId          = Get-AutomationVariable -Name 'GroupSync-TenantId'
$ClientId          = Get-AutomationVariable -Name 'GroupSync-ClientId'
$ClientSecret      = Get-AutomationVariable -Name 'GroupSync-ClientSecret'
$SharePointSiteUrl = Get-AutomationVariable -Name 'GroupSync-SharePointSiteUrl'
$ConfigListName    = "GroupSync-Config"
$LogListName       = "GroupSync-Log"

# --- Paste the rest of GroupSync.ps1 below (everything after the param() block) ---
```

5. Copy everything from `GroupSync.ps1` starting **after** the `param(...)` block and paste it below the variables
6. Click **Save** → **Publish**

## 5. Test the Runbook

1. Open the published runbook
2. Click **Start** → **OK**
3. Wait for the job to complete
4. Check the **Output** tab for sync results
5. Verify the **GroupSync-Config** SharePoint list was updated with `LastSyncTime` and `LastSyncStatus`

## 6. Create a Schedule

1. In the runbook → **Schedules** → **Add a schedule**
2. Click **Link a schedule to your runbook** → **Create a new schedule**
3. Fill in:
   - **Name:** `GroupSync-Hourly`
   - **Starts:** Now
   - **Recurrence:** **Recurring**
   - **Recur every:** **1 Hour**
   - **Set expiration:** No
4. Click **Create** → **OK**

The runbook will now run every hour automatically.

## Cost Estimate

| Metric | Value |
|---|---|
| Free tier | 500 job minutes/month |
| Typical GroupSync run | 5–15 seconds |
| Hourly runs per month | ~720 |
| Estimated usage | ~90–180 minutes/month |
| **Cost** | **Free** (well within free tier) |

## Monitoring

- **Azure Portal** → Automation Account → **Jobs** shows all past runs with status
- Each job shows **Output**, **Errors**, and **Warnings** tabs
- For alerts: Go to **Monitoring** → **Alerts** → create an alert rule for failed jobs
