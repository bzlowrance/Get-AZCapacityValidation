# Get-AZCapacityValidation

Collects Azure resource inventory from a source subscription or resource group and validates whether those resource types support Availability Zones in a target subscription and region. Includes VM SKU-level zone capacity and restriction checks, resiliency change tracking, and Excel reporting.

AZ availability can vary per subscription (feature flags, provider registrations), so the script supports separate source and target subscriptions.

## Prerequisites

- PowerShell 7+
- Azure PowerShell modules:
  ```powershell
  Install-Module Az.Accounts -Scope CurrentUser
  Install-Module Az.Resources -Scope CurrentUser
  Install-Module Az.Compute -Scope CurrentUser
  Install-Module ImportExcel -Scope CurrentUser
  ```
- An active Azure session (`Connect-AzAccount`)

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `SourceSubscription` | No | Current context | Source subscription — name or ID |
| `SourceResourceGroupName` | No | *(all RGs)* | Limit source inventory to a specific resource group |
| `TargetSubscription` | No | Same as source | Target subscription — name or ID — to check AZ provider support against |
| `TargetRegion` | **Yes** | — | Azure region to validate AZ capacity in |
| `TargetResourceGroupName` | No | — | Included in output for planning; does not affect AZ checks |
| `Environment` | No | `AzureCloud` | Azure cloud: `AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud`, `AzureGermanCloud` |
| `OutputPath` | No | `.` (current dir) | Directory to write the Excel report (.xlsx) |

## Examples

### Basic — current subscription, commercial cloud

```powershell
.\Get-AZCapacityValidation.ps1 -TargetRegion "eastus2"
```

Uses the current Azure context subscription as both source and target.

### Specific source resource group (by name)

```powershell
.\Get-AZCapacityValidation.ps1 `
    -SourceSubscription "My Production Sub" `
    -SourceResourceGroupName "prodRG" `
    -TargetRegion "westus3"
```

Inventories only resources in `prodRG`, then checks AZ support in `westus3` against the same subscription.

### Specific source resource group (by ID)

```powershell
.\Get-AZCapacityValidation.ps1 `
    -SourceSubscription "aaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
    -SourceResourceGroupName "prodRG" `
    -TargetRegion "westus3"
```

Same as above using the subscription GUID instead of the name.

### Different source and target subscriptions

```powershell
.\Get-AZCapacityValidation.ps1 `
    -SourceSubscription "My Production Sub" `
    -SourceResourceGroupName "prodRG" `
    -TargetSubscription "My DR Sub" `
    -TargetRegion "westus3"
```

Collects inventory from one subscription and validates AZ availability against a different subscription (useful when AZ features are enabled per-subscription). You can mix names and IDs:

```powershell
.\Get-AZCapacityValidation.ps1 `
    -SourceSubscription "My Production Sub" `
    -TargetSubscription "eeee-ffff-1111-2222-aaaaaaaaaaaa" `
    -TargetRegion "westus3"
```

### Azure Government (GCC-High / DoD)

```powershell
.\Get-AZCapacityValidation.ps1 `
    -TargetRegion "usgovvirginia" `
    -Environment AzureUSGovernment
```

Connects to the Azure Government endpoint and validates AZ support in `usgovvirginia`.

### Azure Government with separate subscriptions and output path

```powershell
.\Get-AZCapacityValidation.ps1 `
    -SourceSubscription "GCC-High Prod" `
    -TargetSubscription "GCC-High DR" `
    -TargetRegion "usgovarizona" `
    -Environment AzureUSGovernment `
    -OutputPath "C:\reports"
```

### Full cross-subscription migration planning

```powershell
.\Get-AZCapacityValidation.ps1 `
    -SourceSubscription "My Production Sub" `
    -SourceResourceGroupName "webapp-prod" `
    -TargetSubscription "My DR Sub" `
    -TargetRegion "eastus2" `
    -TargetResourceGroupName "webapp-dr" `
    -OutputPath "C:\migration-reports"
```

Inventories `webapp-prod` in the source subscription, checks AZ capacity in `eastus2` against the target subscription, tags output rows with the planned target resource group, and writes a timestamped Excel file to `C:\migration-reports`.

## Output

### Console

- **Results Summary** — count of resources by AZ status (`AZ Supported`, `Available (No AZ)`, `Not Available`)
- **Resiliency Change Summary** — counts of resources by resiliency impact (`Gained`, `Maintained`, `Lost`, `None`)
- **Resource Type Breakdown** — distinct resource types with their AZ status, available zones, and resiliency change
- **Resiliency Gain** — resources not currently using AZs that *can* use them in the target (green)
- **Resiliency Loss** — resources currently using AZs whose type does not support AZs in the target (red)
- **VM SKU Availability per Zone** — per-VM SKU zone availability, restrictions, and warnings for unavailable/restricted SKUs

### Excel (.xlsx)

A timestamped Excel file (`AZ-Validation-YYYYMMDD-HHmmss.xlsx`) with the following worksheets:

| Sheet | Description |
|---|---|
| **All Resources** | Full inventory with all columns |
| **AZ Gained** | Resources gaining AZ protection in the target |
| **AZ Lost** | Resources losing AZ protection in the target |
| **Summary** | Resiliency change counts |
| **VM SKU Details** | VM-specific SKU zone availability and restrictions |

All sheets include auto-sized columns, filters, frozen header row, and table formatting.

### Columns

| Column | Description |
|---|---|
| ResourceName | Name of the source resource |
| SourceSubscription | Source subscription display name |
| SourceResourceGroup | Source resource group |
| ResourceType | ARM resource type (e.g., `Microsoft.Compute/virtualMachines`) |
| SourceRegion | Current deployed region |
| CurrentZones | AZ zones the resource currently uses (or `None`) |
| VMSize | VM SKU size (e.g., `Standard_D4s_v5`) — `N/A` for non-VM resources |
| TargetSubscription | Target subscription display name |
| TargetRegion | Target region evaluated |
| TargetResourceGroup | Planned target RG (if specified) |
| TargetAZStatus | `AZ Supported`, `Available (No AZ)`, or `Not Available` |
| TargetZones | Available zones in the target region (or `N/A`) |
| SKUTargetZones | Zones the specific VM SKU is available in (VM only) |
| SKURestrictions | Zone/region restrictions on the VM SKU (e.g., `ZoneRestricted(3)`) |
| SKUAvailability | `Available`, `Restricted`, or `Not Available` (VM only) |
| ResiliencyChange | `Gained`, `Maintained`, `Lost`, or `None` |

## How It Works

1. Connects to Azure (or re-connects if the current session targets a different cloud environment)
2. Sets context to the **source** subscription and collects all resources (or those in a specific RG)
3. Switches context to the **target** subscription and queries `Get-AzResourceProvider -ListAvailable` to build a map of resource types with their zone mappings for the target region
4. Queries `Get-AzComputeResourceSku` for VM SKU-level zone availability and restrictions in the target region
5. Cross-references each inventoried resource against the zone map; enriches VMs with SKU-level details
6. Calculates resiliency change (Gained / Maintained / Lost / None) for each resource
7. Restores context to the source subscription
8. Outputs results to console and Excel (.xlsx)
