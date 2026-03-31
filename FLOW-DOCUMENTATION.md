# GroupSync - Flow Documentation

## Overview

**Flow Name:** GroupSync - Member Sync  
**Trigger:** Recurrence (every 1 hour)  
**Type:** Automated Cloud Flow (HTTP-only, no connectors)  
**Authentication:** App Registration (OAuth2 Client Credentials Flow)

This flow synchronizes members from source groups (Security Groups or Distribution Lists) into target Microsoft 365 Groups (Teams). It reads sync configurations from a SharePoint list, performs a delta sync (add/remove only what changed), and logs changes to a separate SharePoint list. Owners of the target team are never touched.

---

## Flow Architecture

```
Recurrence (hourly)
│
├── Initialize Variables (5x)
├── HTTP_Get_Token ──► Set_AccessToken
├── HTTP_Get_Config ──► Filter_Enabled_Configs
│
└── For_Each_Config (sequential, 1 at a time)
    │
    ├── Reset Variables (4x)
    │
    ├── Scope_TrySync
    │   ├── HTTP_Get_Source_Members ──► Filter_Source_Users
    │   ├── HTTP_Get_Target_Members ──► Filter_Target_Users
    │   ├── HTTP_Get_Target_Owners
    │   ├── Select_OwnerIds / Select_AllTargetMemberIds / Select_SourceUserIds
    │   ├── Filter_ToAdd / Filter_ToRemove
    │   ├── For_Each_Add (add members via Graph API)
    │   ├── For_Each_Remove (remove members via Graph API)
    │   ├── Condition_HasChanges ──► HTTP_Create_Log (only if changes)
    │   └── HTTP_Update_Config_Success
    │
    └── Scope_CatchSync (runs only on failure)
        ├── HTTP_Update_Config_Error
        └── HTTP_Send_Error_Email
```

---

## Variables

| Variable | Type | Purpose |
|---|---|---|
| `varAddedCount` | Integer | Counter for members added in the current sync pair |
| `varRemovedCount` | Integer | Counter for members removed in the current sync pair |
| `varAddedUsers` | String | Comma-separated list of UPNs of added users |
| `varRemovedUsers` | String | Comma-separated list of UPNs of removed users |
| `varAccessToken` | String | OAuth2 access token for Microsoft Graph API |

---

## Action-by-Action Reference

### 1. Init_varAddedCount

| Property | Value |
|---|---|
| **Type** | InitializeVariable |
| **Runs after** | Trigger (start of flow) |

Initializes the `varAddedCount` integer variable to `0`. This variable tracks how many members were added to the target group during the current sync iteration.

---

### 2. Init_varRemovedCount

| Property | Value |
|---|---|
| **Type** | InitializeVariable |
| **Runs after** | Init_varAddedCount |

Initializes the `varRemovedCount` integer variable to `0`. Tracks how many members were removed from the target group.

---

### 3. Init_varAddedUsers

| Property | Value |
|---|---|
| **Type** | InitializeVariable |
| **Runs after** | Init_varRemovedCount |

Initializes the `varAddedUsers` string variable to `""`. Collects the UPNs (email addresses) of all users that were added, for logging purposes.

---

### 4. Init_varRemovedUsers

| Property | Value |
|---|---|
| **Type** | InitializeVariable |
| **Runs after** | Init_varAddedUsers |

Initializes the `varRemovedUsers` string variable to `""`. Collects the UPNs of all users that were removed, for logging purposes.

---

### 5. Init_varAccessToken

| Property | Value |
|---|---|
| **Type** | InitializeVariable |
| **Runs after** | Init_varRemovedUsers |

Initializes the `varAccessToken` string variable to `""`. Will hold the OAuth2 bearer token used to authenticate all Microsoft Graph API calls.

---

### 6. HTTP_Get_Token

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | POST |
| **URI** | `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token` |
| **Runs after** | Init_varAccessToken |
| **Secure Data** | Inputs and outputs are hidden in run history |

Acquires an OAuth2 access token using the **Client Credentials Flow**. The request body contains:
- `grant_type=client_credentials`
- `client_id={app-registration-client-id}`
- `client_secret={app-registration-secret}`
- `scope=https://graph.microsoft.com/.default`

The App Registration must have the following **Application Permissions** (with admin consent):
- `Group.Read.All` – read group members
- `GroupMember.ReadWrite.All` – add/remove group members
- `User.Read.All` – resolve user information
- `Sites.ReadWrite.All` – read/write SharePoint list items
- `Sites.Manage.All` – create SharePoint list items
- `Mail.Send` – send error notification emails

> **Security Note:** The client secret is stored in plain text in this action. For production environments, use Azure Key Vault or Power Platform Environment Variables (Secret type) to protect it.

---

### 7. Set_AccessToken

| Property | Value |
|---|---|
| **Type** | SetVariable |
| **Runs after** | HTTP_Get_Token |

Extracts the `access_token` from the token response and stores it in the `varAccessToken` variable for use in all subsequent Graph API calls.

**Expression:** `@{body('HTTP_Get_Token')?['access_token']}`

---

### 8. HTTP_Get_Config

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | GET |
| **URI** | `https://graph.microsoft.com/v1.0/sites/{site-id}/lists/{config-list-id}/items?$expand=fields&$top=100` |
| **Runs after** | Set_AccessToken |

Reads all items from the **GroupSync-Config** SharePoint list via the Microsoft Graph API. The `$expand=fields` parameter ensures all custom columns are included in the response.

Each config item contains:
- `SourceGroupId` – GUID of the source Security Group or Distribution List
- `TargetGroupId` – GUID of the target M365 Group / Teams team
- `SyncEnabled` – Boolean flag to enable/disable sync for this pair
- `LastSyncTime`, `LastSyncStatus`, `MembersAdded`, `MembersRemoved` – updated after each run

---

### 9. Filter_Enabled_Configs

| Property | Value |
|---|---|
| **Type** | Filter Array (Query) |
| **Runs after** | HTTP_Get_Config |

Filters the config items to only those where `SyncEnabled` is `true`. Disabled entries are skipped entirely.

**Expression:** `@equals(item()?['fields']?['SyncEnabled'], true)`

---

### 10. For_Each_Config

| Property | Value |
|---|---|
| **Type** | Foreach |
| **Concurrency** | 1 (sequential) |
| **Runs after** | Filter_Enabled_Configs |

Iterates over each enabled sync configuration. Concurrency is set to 1 to prevent race conditions on the shared variables (`varAddedCount`, `varRemovedCount`, etc.).

All subsequent actions (11–33) run **inside this loop**.

---

### 11–14. Reset_AddedCount / Reset_RemovedCount / Reset_AddedUsers / Reset_RemovedUsers

| Property | Value |
|---|---|
| **Type** | SetVariable |
| **Runs after** | Each other (sequential) |

Resets all four tracking variables to their initial values (`0` for counters, `""` for strings) at the start of each sync pair iteration. This ensures that each sync pair gets its own clean counters.

---

### 15. Scope_TrySync

| Property | Value |
|---|---|
| **Type** | Scope |
| **Runs after** | Reset_RemovedUsers |

Contains all sync logic. Acts as a **try block** – if any action inside this scope fails, the `Scope_CatchSync` scope runs instead. This implements the try/catch error handling pattern in Power Automate.

---

### 16. HTTP_Get_Source_Members

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | GET |
| **URI** | `https://graph.microsoft.com/v1.0/groups/{SourceGroupId}/members?$select=id,displayName,userPrincipalName&$top=999` |
| **Runs after** | Start of Scope_TrySync |

Retrieves all members of the **source group** (Security Group or Distribution List) via Graph API. The response includes users, nested groups, contacts, and other directory objects.

- `$select=id,displayName,userPrincipalName` – only returns needed fields
- `$top=999` – retrieves up to 999 members in a single call

> **Limitation:** Groups with more than 999 members require pagination (`@odata.nextLink`). This is not implemented in the current version.

---

### 17. Filter_Source_Users

| Property | Value |
|---|---|
| **Type** | Filter Array (Query) |
| **Runs after** | HTTP_Get_Source_Members |

Filters the source group members to **only user objects**. This excludes:
- Nested groups (no `userPrincipalName`)
- Mail contacts / orgContacts (no `userPrincipalName`)
- Service principals or other non-user objects

B2B guest users **are** included because they have a `userPrincipalName`.

**Expression:** `@not(equals(item()?['userPrincipalName'], null))`

---

### 18. HTTP_Get_Target_Members

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | GET |
| **URI** | `https://graph.microsoft.com/v1.0/groups/{TargetGroupId}/members?$select=id,displayName,userPrincipalName&$top=999` |
| **Runs after** | Filter_Source_Users |

Retrieves all members of the **target M365 Group / Teams team**. This includes both regular members AND users who are also owners (since the `/members` endpoint returns all members regardless of role).

---

### 19. Filter_Target_Users

| Property | Value |
|---|---|
| **Type** | Filter Array (Query) |
| **Runs after** | HTTP_Get_Target_Members |

Same filter as `Filter_Source_Users` – keeps only user objects from the target group members.

**Expression:** `@not(equals(item()?['userPrincipalName'], null))`

---

### 20. HTTP_Get_Target_Owners

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | GET |
| **URI** | `https://graph.microsoft.com/v1.0/groups/{TargetGroupId}/owners?$select=id` |
| **Runs after** | Filter_Target_Users |

Retrieves the **owners** of the target team. Owner IDs are used to:
1. **Exclude owners from removal** – owners are never removed, even if they are not in the source group
2. **Exclude owners from addition** – if a source user is already an owner, they won't be added as a member (they're already in the team)

This is a critical safety mechanism that ensures team owners are **completely untouched** by the sync process.

---

### 21. Select_OwnerIds

| Property | Value |
|---|---|
| **Type** | Select |
| **Runs after** | HTTP_Get_Target_Owners |

Extracts a flat array of owner user IDs from the owners response. Used by `Filter_ToRemove` to exclude owners from removal.

**Expression:** `@item()?['id']` (maps each owner object to just its ID string)

---

### 22. Select_AllTargetMemberIds

| Property | Value |
|---|---|
| **Type** | Select |
| **Runs after** | Select_OwnerIds |

Extracts a flat array of all target member user IDs (including owners who are also members). Used by `Filter_ToAdd` to determine which source users are already in the target group.

**Expression:** `@item()?['id']`

---

### 23. Select_SourceUserIds

| Property | Value |
|---|---|
| **Type** | Select |
| **Runs after** | Select_AllTargetMemberIds |

Extracts a flat array of all source user IDs. Used by `Filter_ToRemove` to determine which target members should be kept.

**Expression:** `@item()?['id']`

---

### 24. Filter_ToAdd

| Property | Value |
|---|---|
| **Type** | Filter Array (Query) |
| **Runs after** | Select_SourceUserIds |

Determines which users need to be **added** to the target group. A user is added if:
- They are in the source group
- AND they are **not** already in the target group (not in `Select_AllTargetMemberIds`)

Note: This also implicitly handles owners – if a source user is already an owner in the target team, they are already in the `/members` response and therefore already in `Select_AllTargetMemberIds`, so they won't appear in `Filter_ToAdd`.

**Expression:** `@not(contains(body('Select_AllTargetMemberIds'), item()?['id']))`

---

### 25. Filter_ToRemove

| Property | Value |
|---|---|
| **Type** | Filter Array (Query) |
| **Runs after** | Filter_ToAdd |

Determines which users need to be **removed** from the target group. A user is removed if:
- They are in the target group
- AND they are **not** in the source group (not in `Select_SourceUserIds`)
- AND they are **not** an owner (not in `Select_OwnerIds`)

The owner check is the critical safety mechanism – it ensures that team owners are **never** removed by the sync, regardless of whether they are in the source group.

**Expression:** `@and(not(contains(body('Select_SourceUserIds'), item()?['id'])), not(contains(body('Select_OwnerIds'), item()?['id'])))`

---

### 26. For_Each_Add

| Property | Value |
|---|---|
| **Type** | Foreach |
| **Concurrency** | 1 (sequential) |
| **Runs after** | Filter_ToRemove |

Iterates over each user in the `Filter_ToAdd` result and adds them to the target group. Sequential execution prevents Graph API throttling.

Contains 3 actions per user: `HTTP_Add_Member`, `Increment_AddedCount`, `Append_AddedUser`.

---

### 27. HTTP_Add_Member

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | POST |
| **URI** | `https://graph.microsoft.com/v1.0/groups/{TargetGroupId}/members/$ref` |
| **Runs after** | Start of For_Each_Add iteration |

Adds a user as a **member** to the target M365 Group via the Graph API directory object reference endpoint.

**Request body:**
```json
{
  "@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/{user-id}"
}
```

Possible responses:
- `204 No Content` – member added successfully
- `400 Bad Request` ("already exists") – user is already a member (e.g., as an owner)
- `404 Not Found` – user no longer exists in the directory

---

### 28. Increment_AddedCount

| Property | Value |
|---|---|
| **Type** | IncrementVariable |
| **Runs after** | HTTP_Add_Member (Succeeded) |

Increments `varAddedCount` by 1. Only runs if the HTTP call succeeded, ensuring the counter accurately reflects successful additions.

---

### 29. Append_AddedUser

| Property | Value |
|---|---|
| **Type** | AppendToStringVariable |
| **Runs after** | Increment_AddedCount |

Appends the UPN of the added user to `varAddedUsers` (comma-separated). This list is later written to the SharePoint log for audit purposes.

**Value:** `@{items('For_Each_Add')?['userPrincipalName']}, `

---

### 30. For_Each_Remove

| Property | Value |
|---|---|
| **Type** | Foreach |
| **Concurrency** | 1 (sequential) |
| **Runs after** | For_Each_Add |

Iterates over each user in the `Filter_ToRemove` result and removes them from the target group. Contains 3 actions per user: `HTTP_Remove_Member`, `Increment_RemovedCount`, `Append_RemovedUser`.

---

### 31. HTTP_Remove_Member

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | DELETE |
| **URI** | `https://graph.microsoft.com/v1.0/groups/{TargetGroupId}/members/{user-id}/$ref` |
| **Runs after** | Start of For_Each_Remove iteration |

Removes a user from the target M365 Group. The `/$ref` suffix indicates this removes the membership reference, not the user object itself.

**Important:** Owners can never reach this action because they were already filtered out in `Filter_ToRemove` (step 25).

---

### 32. Increment_RemovedCount / 33. Append_RemovedUser

Same pattern as steps 28–29, but for removed users. Increments `varRemovedCount` and appends the UPN to `varRemovedUsers`.

---

### 34. Condition_HasChanges

| Property | Value |
|---|---|
| **Type** | If (Condition) |
| **Runs after** | For_Each_Remove |

Checks whether any members were added or removed during this sync iteration.

**Condition:** `varAddedCount > 0 OR varRemovedCount > 0`

- **True branch:** Creates a log entry in SharePoint (step 35)
- **False branch:** No action (no log entry for "no changes" runs – keeps the log clean)

---

### 35. HTTP_Create_Log (inside True branch)

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | POST |
| **URI** | `https://graph.microsoft.com/v1.0/sites/{site-id}/lists/{log-list-id}/items` |
| **Runs after** | Condition is true |

Creates a new item in the **GroupSync-Log** SharePoint list via Graph API. Only runs when at least one member was added or removed.

**Request body:**
```json
{
  "fields": {
    "Title": "Sync {timestamp}",
    "SyncTimestamp": "{utcNow}",
    "SourceGroupId": "{source-group-id}",
    "TargetGroupId": "{target-group-id}",
    "MembersAdded": {count},
    "MembersRemoved": {count},
    "AddedUsers": "{comma-separated UPNs}",
    "RemovedUsers": "{comma-separated UPNs}"
  }
}
```

---

### 36. HTTP_Update_Config_Success

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | PATCH |
| **URI** | `https://graph.microsoft.com/v1.0/sites/{site-id}/lists/{config-list-id}/items/{item-id}/fields` |
| **Runs after** | Condition_HasChanges |

Updates the config item in the **GroupSync-Config** SharePoint list with the results of the sync run:
- `LastSyncTime` → current UTC timestamp
- `LastSyncStatus` → `"Success"`
- `MembersAdded` → number of members added
- `MembersRemoved` → number of members removed

This runs regardless of whether changes were made (always updates the timestamp and status).

---

### 37. Scope_CatchSync

| Property | Value |
|---|---|
| **Type** | Scope |
| **Runs after** | Scope_TrySync → **Failed** or **TimedOut** |

Error handler scope. Only runs if `Scope_TrySync` failed or timed out. Acts as the **catch block** of the try/catch pattern. Contains error logging and notification actions.

---

### 38. HTTP_Update_Config_Error

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | PATCH |
| **URI** | Same as step 36 |
| **Runs after** | Start of Scope_CatchSync |

Updates the config item with error status:
- `LastSyncTime` → current UTC timestamp
- `LastSyncStatus` → `"Error"`

---

### 39. HTTP_Send_Error_Email

| Property | Value |
|---|---|
| **Type** | HTTP |
| **Method** | POST |
| **URI** | `https://graph.microsoft.com/v1.0/users/{sender-upn}/sendMail` |
| **Runs after** | HTTP_Update_Config_Error |

Sends an error notification email via the Graph API `sendMail` endpoint. The email is sent from a designated sender mailbox (configured as the admin account).

**Email contents:**
- **To:** Configured error notification address
- **Subject:** "GroupSync FEHLER - Sync fehlgeschlagen"
- **Body (HTML):** Timestamp, source group ID, target group ID, and instructions to check the flow run history

**Required permission:** `Mail.Send` (Application) on the App Registration.

---

## Tenant-Specific Configuration

When deploying this flow to a different tenant, the following values must be updated:

| Value | Location in Flow | Description |
|---|---|---|
| Tenant ID | `HTTP_Get_Token` URI | Azure AD / Entra ID tenant ID |
| Client ID | `HTTP_Get_Token` body | App Registration client ID |
| Client Secret | `HTTP_Get_Token` body | App Registration client secret |
| SharePoint Site ID | `HTTP_Get_Config`, `HTTP_Create_Log`, `HTTP_Update_Config_*` URIs | Graph API site ID for the SharePoint site |
| Config List ID | `HTTP_Get_Config`, `HTTP_Update_Config_*` URIs | Graph API list ID for GroupSync-Config |
| Log List ID | `HTTP_Create_Log` URI | Graph API list ID for GroupSync-Log |
| Sender UPN | `HTTP_Send_Error_Email` URI | Email address of the sender mailbox |
| Error Email | `HTTP_Send_Error_Email` body | Recipient address for error notifications |

---

## SharePoint Lists

### GroupSync-Config

| Column | Type | Description |
|---|---|---|
| Title | Text | Descriptive name for the sync pair |
| SourceGroupId | Text | GUID of the source Security Group or Distribution List |
| TargetGroupId | Text | GUID of the target M365 Group / Teams team |
| SyncEnabled | Boolean | Enable/disable sync for this pair |
| LastSyncTime | Text | UTC timestamp of the last sync run |
| LastSyncStatus | Text | "Success" or "Error" |
| MembersAdded | Number | Number of members added in the last run |
| MembersRemoved | Number | Number of members removed in the last run |

### GroupSync-Log

| Column | Type | Description |
|---|---|---|
| Title | Text | Auto-generated: "Sync {timestamp}" |
| SyncTimestamp | Text | UTC timestamp of the sync run |
| SourceGroupId | Text | GUID of the source group |
| TargetGroupId | Text | GUID of the target group |
| MembersAdded | Number | Number of members added |
| MembersRemoved | Number | Number of members removed |
| AddedUsers | Multi-line Text | Comma-separated UPNs of added users |
| RemovedUsers | Multi-line Text | Comma-separated UPNs of removed users |

> **Note:** Log entries are only created when at least one member was added or removed.

---

## Known Limitations

1. **Pagination:** Groups with more than 999 members are not fully supported. The Graph API returns a maximum of 999 members per request. For larger groups, pagination via `@odata.nextLink` must be implemented.

2. **Nested Groups:** Nested group members are not resolved. Only direct members of the source group are synced. To include nested members, change the API endpoint from `/members` to `/transitiveMembers`.

3. **Throttling:** The flow does not handle Graph API throttling (HTTP 429). For environments with many sync pairs or large groups, consider adding retry logic with `Retry-After` header support.

4. **Secret Storage:** The client secret is stored in plain text in the flow definition. For production use, implement Azure Key Vault or Power Platform Environment Variables (Secret type).

5. **Token Lifetime:** The OAuth2 token is acquired once per flow run. For flows with many sync pairs, the token may expire (default lifetime: 1 hour). Consider refreshing the token if many pairs are configured.
