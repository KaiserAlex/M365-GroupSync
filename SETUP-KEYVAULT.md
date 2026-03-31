# Securing Secrets with Azure Key Vault

> **Recommended for production environments.** This guide explains how to store the App Registration Client Secret in Azure Key Vault instead of plain text, for each of the three deployment options.

## Why Key Vault?

Without Key Vault, the Client Secret is stored in **plain text** in:
- **Option A:** The Power Automate flow definition (visible to anyone who can edit the flow)
- **Option B:** The scheduled task arguments or script parameters
- **Option C:** The Azure Automation variables (encrypted, but Key Vault is the enterprise standard)

With Azure Key Vault:
- Secrets are **centrally managed** and **encrypted at rest**
- Access is controlled via **Azure RBAC** or **Key Vault access policies**
- **Secret rotation** is easy – update the secret in one place, all consumers pick it up
- **Audit logging** tracks who accessed which secret and when

---

## 1. Set Up Azure Key Vault

These steps are the same for all three options:

1. Go to **Azure Portal** → **Create a resource** → search for **Key Vault**
2. Click **Create** and fill in:
   - **Name:** `kv-groupsync` (must be globally unique)
   - **Resource Group:** Create new or use existing
   - **Region:** Choose your preferred region
   - **Pricing tier:** Standard
3. Click **Create**

### Add the Client Secret to Key Vault

1. Open the Key Vault → **Objects** → **Secrets** → **Generate/Import**
2. Fill in:
   - **Name:** `GroupSync-ClientSecret`
   - **Secret value:** Paste your App Registration client secret
3. Click **Create**

Optionally, also store these values as secrets:
- `GroupSync-ClientId`
- `GroupSync-TenantId`

---

## 2A. Key Vault with Power Automate Flow (Option A)

### Grant Access

1. In the Key Vault → **Access configuration** → ensure **Azure role-based access control** is selected
2. Go to **Access control (IAM)** → **Add role assignment**
3. Role: **Key Vault Secrets User**
4. Assign to: The **user account** that runs the Power Automate flow (the flow connection owner)

### Modify the Flow

Replace the hardcoded token request with two steps:

**Step 1: Add an Azure Key Vault connector action** (before `HTTP_Get_Token`):
- Action: **Get secret** (Azure Key Vault connector)
- Vault name: `kv-groupsync`
- Secret name: `GroupSync-ClientSecret`

> Note: The Azure Key Vault connector is also a **Premium** connector, but since you already need Premium for the HTTP connector, there is no additional cost.

**Step 2: Update `HTTP_Get_Token`** to use the Key Vault output:
- Replace the hardcoded client secret in the body with the dynamic content from the Key Vault action:
  ```
  grant_type=client_credentials&client_id=<YOUR-CLIENT-ID>&client_secret=@{body('Get_secret')?['value']}&scope=https://graph.microsoft.com/.default
  ```

The `secureData` runtime configuration on `HTTP_Get_Token` ensures the secret is not visible in the flow run history.

---

## 2B. Key Vault with PowerShell + Task Scheduler (Option B)

### Grant Access

1. In the Key Vault → **Access control (IAM)** → **Add role assignment**
2. Role: **Key Vault Secrets User**
3. Assign to: The **App Registration** service principal (`GroupSync-Automation`)

### Modify the Script

Replace the `param()` block at the top of `GroupSync.ps1`:

```powershell
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$SharePointSiteUrl,
    [string]$SecretName = "GroupSync-ClientSecret",
    [string]$ConfigListName = "GroupSync-Config",
    [string]$LogListName = "GroupSync-Log"
)

# Get the client secret from Key Vault using the App Registration
$kvTokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $ClientId
    client_secret = $env:GROUPSYNC_BOOTSTRAP_SECRET  # temporary, see below
    scope         = "https://vault.azure.net/.default"
}
$kvToken = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $kvTokenBody).access_token
$kvHeaders = @{ "Authorization" = "Bearer $kvToken" }
$ClientSecret = (Invoke-RestMethod -Uri "https://$KeyVaultName.vault.azure.net/secrets/$SecretName`?api-version=7.4" -Headers $kvHeaders).value
```

### Set the Bootstrap Secret as Environment Variable

Instead of passing the secret as a parameter, set it as an environment variable:

```powershell
# Set once (persists across reboots)
[System.Environment]::SetEnvironmentVariable('GROUPSYNC_BOOTSTRAP_SECRET', '<YOUR-CLIENT-SECRET>', 'Machine')
```

Then run:
```powershell
.\GroupSync.ps1 -TenantId "..." -ClientId "..." -KeyVaultName "kv-groupsync" -SharePointSiteUrl "https://contoso.sharepoint.com/sites/MySite"
```

> **Alternative:** Use a **certificate** instead of a client secret for the App Registration. Certificates can be stored in the Windows Certificate Store and don't need a bootstrap secret at all.

---

## 2C. Key Vault with Azure Automation Runbook (Option C)

### Grant Access

Azure Automation can access Key Vault via its **Managed Identity**:

1. In the Automation Account → **Account Settings** → **Identity** → enable **System assigned** managed identity
2. Copy the **Object ID** of the managed identity
3. In the Key Vault → **Access control (IAM)** → **Add role assignment**
4. Role: **Key Vault Secrets User**
5. Assign to: The managed identity (search by Object ID)

### Modify the Runbook

Replace the credential retrieval in the runbook with Key Vault access via the managed identity:

```powershell
# Authenticate as Managed Identity (no secrets needed!)
$miToken = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net' -Headers @{Metadata="true"}).access_token

# Get the client secret from Key Vault
$kvHeaders = @{ "Authorization" = "Bearer $miToken" }
$ClientSecret = (Invoke-RestMethod -Uri "https://kv-groupsync.vault.azure.net/secrets/GroupSync-ClientSecret?api-version=7.4" -Headers $kvHeaders).value

# Get other config from Key Vault or Automation Variables
$TenantId          = Get-AutomationVariable -Name 'GroupSync-TenantId'
$ClientId          = Get-AutomationVariable -Name 'GroupSync-ClientId'
$SharePointSiteUrl = Get-AutomationVariable -Name 'GroupSync-SharePointSiteUrl'
```

### Why This Is the Best Option

- **No secrets stored anywhere** – the Managed Identity authenticates without credentials
- **Key Vault** stores the App Registration secret securely
- Non-sensitive config (Tenant ID, Client ID, URL) stays in Automation Variables
- **Audit trail** in Key Vault shows every secret access
- **Secret rotation** – update the secret in Key Vault, no runbook changes needed

---

## Summary

| Option | Without Key Vault | With Key Vault |
|---|---|---|
| **A: Power Automate** | Secret in flow definition (plain text) | Key Vault connector retrieves secret at runtime |
| **B: Task Scheduler** | Secret in task arguments or env var | Script reads secret from Key Vault via API |
| **C: Azure Automation** | Secret in encrypted Automation Variable | Managed Identity reads from Key Vault (zero secrets) |
