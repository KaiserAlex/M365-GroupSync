# Option A: Setup Guide – Power Automate Flow

> Requires a **Power Automate Premium** license for the **flow owner** (the user who creates and owns the flow in Power Automate). The HTTP connector used in this flow is a premium feature. The App Registration itself does not require any license.

## 1. Create App Registration

1. Go to **Azure Portal** → **Entra ID** → **App Registrations** → **New Registration**
2. Name: `GroupSync-Automation`, Single tenant
3. Add the following **Application Permissions** for Microsoft Graph:
   - `Group.Read.All`
   - `GroupMember.ReadWrite.All`
   - `User.Read.All`
   - `Sites.ReadWrite.All`
   - `Mail.Send`
4. Grant **Admin Consent**
5. Create a **Client Secret** (note: max 24 months validity)
6. Note down: **Client ID**, **Tenant ID**, **Client Secret**

## 2. Create SharePoint Lists

Create two lists on a SharePoint site of your choice:

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

## 3. Configure the Flow Definition

Open `flow-definition/flow-definition.json` and replace all placeholders with your tenant-specific values:

| Placeholder | Description | How to find it |
|---|---|---|
| `<YOUR-TENANT-ID>` | Entra ID tenant ID | Azure Portal → Entra ID → Overview |
| `<YOUR-CLIENT-ID>` | App Registration client ID | Azure Portal → App Registrations → your app → Overview |
| `<YOUR-CLIENT-SECRET>` | App Registration client secret | Created in step 1.5 |
| `<YOUR-SHAREPOINT-SITE-ID>` | Graph API site ID | See [How to find SharePoint IDs](#how-to-find-sharepoint-ids) below |
| `<YOUR-CONFIG-LIST-ID>` | Graph API list ID for GroupSync-Config | See below |
| `<YOUR-LOG-LIST-ID>` | Graph API list ID for GroupSync-Log | See below |
| `<YOUR-SENDER-UPN>` | Sender mailbox for error emails | e.g. `admin@contoso.onmicrosoft.com` |
| `<YOUR-ERROR-EMAIL>` | Recipient for error notifications | e.g. `alerts@contoso.com` |

## 4. Deploy the Flow

A ready-to-import **Power Platform Solution** is provided in `solutions/GroupSync-Solution.zip`.

**Import steps:**
1. Go to **https://make.powerautomate.com** → **Solutions**
2. Click **Import solution** → **Browse** → select `solutions/GroupSync-Solution.zip`
3. Click **Next** → **Import**
4. Open the solution → open the flow **GroupSync - Member Sync**
5. Edit the flow and replace all placeholder values (`<YOUR-TENANT-ID>`, `<YOUR-CLIENT-ID>`, etc.) with your actual values (see table in step 3 above)
6. **Save** and **Turn on** the flow
3. Import the flow definition, or create a new cloud flow and paste the definition via code view

> For detailed flow action documentation, see [FLOW-DOCUMENTATION.md](FLOW-DOCUMENTATION.md).

## 5. Add Sync Pairs

Add entries to the **GroupSync-Config** SharePoint list:
- **Title:** Descriptive name (e.g. "Engineering Team Sync")
- **SourceGroupId:** GUID of the Security Group or Distribution List
- **TargetGroupId:** GUID of the existing Teams team
- **SyncEnabled:** Yes

The flow runs every hour and processes all enabled entries.

---

## How to find SharePoint IDs

Run these commands in PowerShell (requires [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)):

```powershell
# Login first
az login --tenant <YOUR-TENANT-ID> --allow-no-subscriptions

# Get Site ID
az rest --method GET --uri "https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com:/sites/YourSiteName" --query "id" -o tsv

# List all lists on the site (use the Site ID from above)
az rest --method GET --uri "https://graph.microsoft.com/v1.0/sites/<SITE-ID>/lists" --query "value[].{name:displayName, id:id}" -o table
```

Find the IDs for `GroupSync-Config` and `GroupSync-Log` in the output.
