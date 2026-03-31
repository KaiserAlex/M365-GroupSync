# GroupSync - PowerShell Sync Script
# Reads sync pairs from SharePoint config list and syncs members from source groups to target teams.
# Same behavior as the Power Automate flow, but runs standalone.
#
# Usage:
#   .\GroupSync.ps1 -TenantId "xxxx" -ClientId "xxxx" -ClientSecret "xxxx" -SharePointSiteUrl "https://contoso.sharepoint.com/sites/MySite"
#
# The script automatically resolves the SharePoint Site ID and List IDs from the URL and list names.

param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [Parameter(Mandatory)][string]$SharePointSiteUrl,   # e.g. https://contoso.sharepoint.com/sites/MySite
    [string]$ConfigListName = "GroupSync-Config",
    [string]$LogListName = "GroupSync-Log"
)

# --- Step 1: Get Access Token ---
Write-Host "`n=== Step 1: Getting Access Token ===" -ForegroundColor Cyan
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://graph.microsoft.com/.default"
}
$tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody
$token = $tokenResponse.access_token
$authHeaders = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
Write-Host "Token obtained successfully" -ForegroundColor Green

# --- Step 2: Resolve SharePoint Site ID and List IDs ---
Write-Host "`n=== Step 2: Resolving SharePoint IDs ===" -ForegroundColor Cyan
$siteUri = [System.Uri]$SharePointSiteUrl
$hostname = $siteUri.Host
$sitePath = $siteUri.AbsolutePath.TrimStart('/')

$siteResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/${hostname}:/${sitePath}" -Headers $authHeaders -Method GET
$SiteId = $siteResponse.id
Write-Host "  Site ID: $SiteId"

$listsResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists" -Headers $authHeaders -Method GET
$ConfigListId = ($listsResponse.value | Where-Object { $_.displayName -eq $ConfigListName }).id
$LogListId = ($listsResponse.value | Where-Object { $_.displayName -eq $LogListName }).id

# Auto-create lists if they don't exist
if (-not $ConfigListId) {
    Write-Host "  List '$ConfigListName' not found - creating..." -ForegroundColor Yellow
    $configDef = @{
        displayName = $ConfigListName
        list = @{ template = "genericList" }
        columns = @(
            @{ name = "SourceGroupId"; text = @{} }
            @{ name = "TargetGroupId"; text = @{} }
            @{ name = "SyncEnabled"; boolean = @{} }
            @{ name = "LastSyncTime"; text = @{} }
            @{ name = "LastSyncStatus"; text = @{} }
            @{ name = "MembersAdded"; number = @{} }
            @{ name = "MembersRemoved"; number = @{} }
        )
    } | ConvertTo-Json -Depth 5
    $configList = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists" -Headers $authHeaders -Method POST -Body $configDef
    $ConfigListId = $configList.id
    Write-Host "  Created '$ConfigListName'" -ForegroundColor Green
}

if (-not $LogListId) {
    Write-Host "  List '$LogListName' not found - creating..." -ForegroundColor Yellow
    $logDef = @{
        displayName = $LogListName
        list = @{ template = "genericList" }
        columns = @(
            @{ name = "SyncTimestamp"; text = @{} }
            @{ name = "SourceGroupId"; text = @{} }
            @{ name = "TargetGroupId"; text = @{} }
            @{ name = "MembersAdded"; number = @{} }
            @{ name = "MembersRemoved"; number = @{} }
            @{ name = "AddedUsers"; text = @{ allowMultipleLines = $true } }
            @{ name = "RemovedUsers"; text = @{ allowMultipleLines = $true } }
        )
    } | ConvertTo-Json -Depth 5
    $logList = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists" -Headers $authHeaders -Method POST -Body $logDef
    $LogListId = $logList.id
    Write-Host "  Created '$LogListName'" -ForegroundColor Green
}

Write-Host "  Config List ID: $ConfigListId ($ConfigListName)"
Write-Host "  Log List ID: $LogListId ($LogListName)"

# --- Step 3: Reading Config from SharePoint ---
Write-Host "`n=== Step 3: Reading Config from SharePoint ===" -ForegroundColor Cyan
$configResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ConfigListId/items?`$expand=fields&`$top=100" -Headers $authHeaders -Method GET
$configItems = $configResponse.value | Where-Object { $_.fields.SyncEnabled -eq $true }
Write-Host "Found $($configItems.Count) enabled sync pair(s)"

if ($configItems.Count -eq 0) {
    Write-Host "No enabled sync pairs found. Exiting." -ForegroundColor Yellow
    exit 0
}

# --- Step 4: Process each sync pair ---
foreach ($config in $configItems) {
    $SourceGroupId = $config.fields.SourceGroupId
    $TargetGroupId = $config.fields.TargetGroupId
    $configItemId = $config.id
    $configTitle = $config.fields.Title

    Write-Host "`n============================================" -ForegroundColor Magenta
    Write-Host "Sync Pair: $configTitle" -ForegroundColor Magenta
    Write-Host "  Source: $SourceGroupId" -ForegroundColor Magenta
    Write-Host "  Target: $TargetGroupId" -ForegroundColor Magenta
    Write-Host "============================================" -ForegroundColor Magenta

    try {
        # Get Source Group Members (only users, with pagination)
        Write-Host "`n  Getting source members..." -ForegroundColor Cyan
        $sourceMembers = @()
        $uri = "https://graph.microsoft.com/v1.0/groups/$SourceGroupId/members?`$select=id,displayName,userPrincipalName&`$top=999"
        do {
            $response = Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET
            $sourceMembers += $response.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }
            $uri = $response.'@odata.nextLink'
        } while ($uri)
        Write-Host "  Source members: $($sourceMembers.Count)"

        # Get Target Group Members (with pagination)
        Write-Host "  Getting target members..." -ForegroundColor Cyan
        $targetMembers = @()
        $uri = "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members?`$select=id,displayName,userPrincipalName&`$top=999"
        do {
            $response = Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET
            $targetMembers += $response.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }
            $uri = $response.'@odata.nextLink'
        } while ($uri)
        Write-Host "  Target members: $($targetMembers.Count)"

        # Get Target Group Owners
        Write-Host "  Getting target owners..." -ForegroundColor Cyan
        $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/owners?`$select=id,displayName,userPrincipalName" -Headers $authHeaders -Method GET
        $targetOwners = $response.value
        $ownerIds = $targetOwners | ForEach-Object { $_.id }
        Write-Host "  Owners: $($targetOwners.Count) (ignored by sync)"

        # Delta Calculation
        $targetMembersOnly = $targetMembers | Where-Object { $_.id -notin $ownerIds }
        $sourceIds = $sourceMembers | ForEach-Object { $_.id }
        $targetMemberIds = $targetMembersOnly | ForEach-Object { $_.id }

        $toAdd = $sourceMembers | Where-Object { ($_.id -notin $targetMemberIds) -and ($_.id -notin $ownerIds) }
        $toRemove = $targetMembersOnly | Where-Object { $_.id -notin $sourceIds }

        Write-Host "`n  To ADD: $($toAdd.Count)" -ForegroundColor Green
        Write-Host "  To REMOVE: $($toRemove.Count)" -ForegroundColor Red

        # Execute: Add members
        $addedCount = 0
        $addedUsers = @()
        foreach ($user in $toAdd) {
            try {
                $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)" } | ConvertTo-Json
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members/`$ref" -Headers $authHeaders -Method POST -Body $body
                Write-Host "    + Added: $($user.displayName)" -ForegroundColor Green
                $addedCount++
                $addedUsers += $user.userPrincipalName
            } catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                if ($statusCode -eq 400) {
                    Write-Host "    ~ Skipped (already member): $($user.displayName)" -ForegroundColor Yellow
                } else {
                    Write-Host "    ! ERROR adding $($user.displayName): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }

        # Execute: Remove members
        $removedCount = 0
        $removedUsers = @()
        foreach ($user in $toRemove) {
            try {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members/$($user.id)/`$ref" -Headers $authHeaders -Method DELETE
                Write-Host "    - Removed: $($user.displayName)" -ForegroundColor Red
                $removedCount++
                $removedUsers += $user.userPrincipalName
            } catch {
                Write-Host "    ! ERROR removing $($user.displayName): $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        # Update config item in SharePoint
        $updateBody = @{
            LastSyncTime = (Get-Date -Format "o")
            LastSyncStatus = "Success"
            MembersAdded = $addedCount
            MembersRemoved = $removedCount
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ConfigListId/items/$configItemId/fields" -Headers $authHeaders -Method PATCH -Body $updateBody | Out-Null

        # Create log entry (only if changes occurred)
        if ($addedCount -gt 0 -or $removedCount -gt 0) {
            $logBody = @{
                fields = @{
                    Title = "Sync $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                    SyncTimestamp = (Get-Date -Format "o")
                    SourceGroupId = $SourceGroupId
                    TargetGroupId = $TargetGroupId
                    MembersAdded = $addedCount
                    MembersRemoved = $removedCount
                    AddedUsers = ($addedUsers -join ", ")
                    RemovedUsers = ($removedUsers -join ", ")
                }
            } | ConvertTo-Json -Depth 3
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$LogListId/items" -Headers $authHeaders -Method POST -Body $logBody | Out-Null
            Write-Host "`n  Log entry created" -ForegroundColor Cyan
        }

        Write-Host "`n  RESULT: Added=$addedCount, Removed=$removedCount, Owners=$($targetOwners.Count) (untouched)" -ForegroundColor Cyan

    } catch {
        Write-Host "`n  SYNC FAILED: $($_.Exception.Message)" -ForegroundColor Red

        # Update config with error status
        try {
            $errorBody = @{ LastSyncTime = (Get-Date -Format "o"); LastSyncStatus = "Error" } | ConvertTo-Json
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ConfigListId/items/$configItemId/fields" -Headers $authHeaders -Method PATCH -Body $errorBody | Out-Null
        } catch {}
    }
}

Write-Host "`n=== ALL SYNC PAIRS COMPLETE ===" -ForegroundColor Cyan
