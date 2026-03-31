# GroupSync - Test Script
# Testet die Sync-Logik bevor sie in Power Automate implementiert wird

param(
    [string]$TenantId = "<YOUR-TENANT-ID>",
    [string]$ClientId = "<YOUR-CLIENT-ID>",
    [string]$ClientSecret = "<YOUR-CLIENT-SECRET>",
    [string]$SourceGroupId = "<YOUR-SOURCE-GROUP-ID>",  # GroupSync-TestSource
    [string]$TargetGroupId = "<YOUR-TARGET-GROUP-ID>"   # Demo Sven
)

$headers = @{ "Content-Type" = "application/x-www-form-urlencoded" }

# Step 1: Get Access Token
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

# Step 2: Get Source Group Members (only users)
Write-Host "`n=== Step 2: Getting Source Group Members ===" -ForegroundColor Cyan
$sourceMembers = @()
$uri = "https://graph.microsoft.com/v1.0/groups/$SourceGroupId/members?`$select=id,displayName,userPrincipalName&`$top=999"
do {
    $response = Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET
    $sourceMembers += $response.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }
    $uri = $response.'@odata.nextLink'
} while ($uri)
Write-Host "Source members: $($sourceMembers.Count)"
$sourceMembers | ForEach-Object { Write-Host "  - $($_.displayName) ($($_.userPrincipalName))" }

# Step 3: Get Target Group Members (all)
Write-Host "`n=== Step 3: Getting Target Group Members ===" -ForegroundColor Cyan
$targetMembers = @()
$uri = "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members?`$select=id,displayName,userPrincipalName&`$top=999"
do {
    $response = Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET
    $targetMembers += $response.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' }
    $uri = $response.'@odata.nextLink'
} while ($uri)
Write-Host "Target members (all): $($targetMembers.Count)"
$targetMembers | ForEach-Object { Write-Host "  - $($_.displayName) ($($_.userPrincipalName))" }

# Step 4: Get Target Group Owners
Write-Host "`n=== Step 4: Getting Target Group Owners ===" -ForegroundColor Cyan
$targetOwners = @()
$uri = "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/owners?`$select=id,displayName,userPrincipalName"
$response = Invoke-RestMethod -Uri $uri -Headers $authHeaders -Method GET
$targetOwners = $response.value
$ownerIds = $targetOwners | ForEach-Object { $_.id }
Write-Host "Owners: $($targetOwners.Count)"
$targetOwners | ForEach-Object { Write-Host "  - $($_.displayName) ($($_.userPrincipalName)) [OWNER - wird ignoriert]" -ForegroundColor Yellow }

# Step 5: Filter owners out of target members
Write-Host "`n=== Step 5: Delta Calculation ===" -ForegroundColor Cyan
$targetMembersOnly = $targetMembers | Where-Object { $_.id -notin $ownerIds }
Write-Host "Target members (ohne Owner): $($targetMembersOnly.Count)"

$sourceIds = $sourceMembers | ForEach-Object { $_.id }
$targetMemberIds = $targetMembersOnly | ForEach-Object { $_.id }

# Users to add: in source but not in target (and not an owner)
$toAdd = $sourceMembers | Where-Object { ($_.id -notin $targetMemberIds) -and ($_.id -notin $ownerIds) }
Write-Host "`nTo ADD ($($toAdd.Count)):" -ForegroundColor Green
$toAdd | ForEach-Object { Write-Host "  + $($_.displayName) ($($_.userPrincipalName))" -ForegroundColor Green }

# Users to remove: in target members (not owners) but not in source
$toRemove = $targetMembersOnly | Where-Object { $_.id -notin $sourceIds }
Write-Host "`nTo REMOVE ($($toRemove.Count)):" -ForegroundColor Red
$toRemove | ForEach-Object { Write-Host "  - $($_.displayName) ($($_.userPrincipalName))" -ForegroundColor Red }

# Step 6: Execute sync
Write-Host "`n=== Step 6: Executing Sync ===" -ForegroundColor Cyan

$addedCount = 0
foreach ($user in $toAdd) {
    try {
        $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)" } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members/`$ref" -Headers $authHeaders -Method POST -Body $body
        Write-Host "  Added: $($user.displayName)" -ForegroundColor Green
        $addedCount++
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 400) {
            Write-Host "  Skipped (already member): $($user.displayName)" -ForegroundColor Yellow
        } else {
            Write-Host "  ERROR adding $($user.displayName): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

$removedCount = 0
foreach ($user in $toRemove) {
    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members/$($user.id)/`$ref" -Headers $authHeaders -Method DELETE
        Write-Host "  Removed: $($user.displayName)" -ForegroundColor Red
        $removedCount++
    } catch {
        Write-Host "  ERROR removing $($user.displayName): $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Summary
Write-Host "`n=== SYNC COMPLETE ===" -ForegroundColor Cyan
Write-Host "Added:   $addedCount"
Write-Host "Removed: $removedCount"
Write-Host "Owners:  $($targetOwners.Count) (untouched)"

# Step 7: Verify final state
Write-Host "`n=== Final State ===" -ForegroundColor Cyan
$finalMembers = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members?`$select=id,displayName,userPrincipalName" -Headers $authHeaders -Method GET
$finalMembers.value | ForEach-Object { Write-Host "  $($_.displayName) ($($_.userPrincipalName))" }
