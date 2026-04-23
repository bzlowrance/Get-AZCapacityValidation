<#
.SYNOPSIS
    Collects Azure resource inventory from a source subscription/RG and validates Availability Zone
    capacity for those resource types in a target subscription and region.

.DESCRIPTION
    Scans a source subscription (or resource group) for deployed resources, then switches context to
    the target subscription to check whether those resource types support Availability Zones in the
    target region. AZ availability can differ per subscription due to feature flags and registrations,
    so separate source/target subscriptions are supported.

.PARAMETER SourceSubscription
    The source subscription (name or ID). Defaults to the current context.

.PARAMETER SourceResourceGroupName
    Optional. Limit the source inventory scan to a specific resource group.

.PARAMETER TargetSubscription
    The target subscription (name or ID) to check AZ provider support against. Defaults to the source.
    Use a different value when the target subscription has different provider registrations or
    feature flags that affect AZ availability.

.PARAMETER TargetRegion
    The Azure region to validate AZ capacity against (e.g., "eastus2", "usgovvirginia").

.PARAMETER TargetResourceGroupName
    Optional. Included in output for planning purposes (does not affect AZ capability checks,
    which are subscription-scoped).

.PARAMETER Environment
    Azure cloud environment. Valid values: AzureCloud, AzureUSGovernment, AzureChinaCloud, AzureGermanCloud.
    If not specified, uses the environment from your current Azure session. Only specify this to
    force a switch to a different cloud (e.g., you're logged into commercial but want to target Gov).

.PARAMETER OutputPath
    Optional. Path to export results as an Excel file (.xlsx). Defaults to current directory.

.EXAMPLE
    .\Get-AZCapacityValidation.ps1 -TargetRegion "eastus2"
    # Uses current subscription as both source and target.

.EXAMPLE
    .\Get-AZCapacityValidation.ps1 -SourceSubscription "aaaa" -SourceResourceGroupName "prodRG" `
        -TargetSubscription "bbbb" -TargetRegion "westus3"
    # Inventory from sub aaaa/prodRG, AZ check against sub bbbb in westus3.

.EXAMPLE
    .\Get-AZCapacityValidation.ps1 -TargetRegion "usgovvirginia" -Environment AzureUSGovernment

.EXAMPLE
    .\Get-AZCapacityValidation.ps1 -SourceSubscription "aaaa" -TargetSubscription "bbbb" `
        -TargetRegion "usgovarizona" -Environment AzureUSGovernment -OutputPath "C:\reports"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SourceSubscription,

    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TargetSubscription,

    [Parameter(Mandatory = $true)]
    [string]$TargetRegion,

    [Parameter(Mandatory = $false)]
    [string]$TargetResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("AzureCloud", "AzureUSGovernment", "AzureChinaCloud", "AzureGermanCloud")]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, ImportExcel

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helper: Infer environment from a region name ─────────────────────────────
function Get-EnvironmentFromRegion {
    param([string]$Region)

    $r = $Region.ToLower()
    if ($r -match '^usgov|^usdod') { return "AzureUSGovernment" }
    if ($r -match '^china')        { return "AzureChinaCloud" }
    if ($r -match '^germany')      { return "AzureGermanCloud" }
    return "AzureCloud"
}

# ── Helper: Ensure logged in to the correct environment ──────────────────────
function Ensure-AzContext {
    param([string]$RequiredEnvironment)

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        # No session — connect to the requested environment (default AzureCloud if none specified)
        if (-not $RequiredEnvironment) { $RequiredEnvironment = "AzureCloud" }
        Write-Host "No active Azure session. Connecting to '$RequiredEnvironment'..." -ForegroundColor Yellow
        Connect-AzAccount -Environment $RequiredEnvironment | Out-Null
        $ctx = Get-AzContext
    }
    elseif ($RequiredEnvironment -and $ctx.Environment.Name -ne $RequiredEnvironment) {
        # Session exists but targets a different environment than explicitly requested
        Write-Host "Current session targets '$($ctx.Environment.Name)' but '$RequiredEnvironment' was requested." -ForegroundColor Yellow
        Write-Host "Reconnecting to '$RequiredEnvironment'..." -ForegroundColor Yellow
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
        Connect-AzAccount -Environment $RequiredEnvironment | Out-Null
        $ctx = Get-AzContext
    }
    # If no environment was specified, just use the existing session as-is
    return $ctx
}

# ── Helper: Resolve subscription name or ID to a subscription object ────────
function Resolve-Subscription {
    param([string]$NameOrId)

    # Try as GUID first
    $guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    if ($NameOrId -match $guidPattern) {
        $sub = Get-AzSubscription -SubscriptionId $NameOrId -ErrorAction SilentlyContinue
        if ($sub) { return $sub }
    }

    # Try as name
    $sub = Get-AzSubscription -SubscriptionName $NameOrId -ErrorAction SilentlyContinue
    if ($sub) { return $sub }

    Write-Error "Could not find subscription '$NameOrId'. Verify the name or ID and ensure you have access."
    exit 1
}

# ── Helper: Get AZ-capable resource types for a region ────────────────────────
function Get-AZCapableTypes {
    param([string]$Region)

    Write-Host "Fetching providers with Availability Zone support in '$Region'..." -ForegroundColor Cyan

    $azCapable = @{}
    $providers = Get-AzResourceProvider -ListAvailable

    foreach ($provider in $providers) {
        foreach ($rt in $provider.ResourceTypes) {
            $fullType = "$($provider.NameSpace)/$($rt.ResourceTypeName)"

            # Check if this resource type is available in the target region with zone support
            $locationInfo = $rt.ZoneMappings | Where-Object { $_.Location -eq $Region }
            if ($locationInfo) {
                $zones = $locationInfo.Zones -join ","
                $azCapable[$fullType.ToLower()] = @{
                    Zones    = $zones
                    Supported = $true
                }
            }
            else {
                # Check if the type is at least available in the region (without zone info)
                $availableLocations = $rt.Locations | ForEach-Object { $_.ToLower().Replace(" ", "") }
                $normalizedTarget = $Region.ToLower().Replace(" ", "")

                if ($availableLocations -contains $normalizedTarget) {
                    if (-not $azCapable.ContainsKey($fullType.ToLower())) {
                        $azCapable[$fullType.ToLower()] = @{
                            Zones    = ""
                            Supported = $false
                        }
                    }
                }
            }
        }
    }

    return $azCapable
}

# ── Helper: Collect resource inventory ────────────────────────────────────────
function Get-ResourceInventory {
    param(
        [string]$SubId,
        [string]$RGName
    )

    $params = @{}
    if ($RGName) {
        Write-Host "Collecting inventory for resource group '$RGName'..." -ForegroundColor Cyan
        $params["ResourceGroupName"] = $RGName
    }
    else {
        Write-Host "Collecting inventory for subscription '$SubId'..." -ForegroundColor Cyan
    }

    $resources = Get-AzResource @params

    Write-Host "  Found $($resources.Count) resources." -ForegroundColor Green
    return $resources
}

# ── Helper: Enrich with zone info from actual resource ────────────────────────
function Get-ResourceZoneInfo {
    param($Resource)

    # Some resource types expose Zones directly on the resource object
    try {
        $detail = Get-AzResource -ResourceId $Resource.ResourceId -ExpandProperties -ErrorAction SilentlyContinue
        if ($detail.Zones) {
            return ($detail.Zones -join ",")
        }
    }
    catch {
        # Silently continue if we can't get details
    }
    return ""
}

# ── Helper: Get VM SKU to zone/restriction map for a region ───────────────────
function Get-VMSkuZoneMap {
    param([string]$Region)

    Write-Host "Fetching VM SKU capacity per Availability Zone in '$Region'..." -ForegroundColor Cyan

    $skuMap = @{}
    $skus = Get-AzComputeResourceSku -Location $Region | Where-Object {
        $_.ResourceType -eq "virtualMachines"
    }

    foreach ($sku in $skus) {
        $name = $sku.Name

        # Get zone details from LocationInfo
        $locInfo = $sku.LocationInfo | Where-Object { $_.Location -eq $Region }
        $zones = if ($locInfo -and $locInfo.Zones) { $locInfo.Zones -join "," } else { "None" }

        # Check restrictions
        $restrictions = @()
        foreach ($r in $sku.Restrictions) {
            if ($r.Type -eq "Location" -and $r.Values -contains $Region) {
                $restrictions += "NotAvailableInRegion"
            }
            elseif ($r.Type -eq "Zone") {
                $restrictedZones = ($r.RestrictionInfo.Zones -join ",")
                $restrictions += "ZoneRestricted($restrictedZones)"
            }
        }

        $skuMap[$name.ToLower()] = @{
            SkuName      = $name
            Zones        = $zones
            Restrictions = if ($restrictions.Count -gt 0) { $restrictions -join "; " } else { "None" }
            IsRestricted = ($restrictions.Count -gt 0)
        }
    }

    Write-Host "  Found $($skuMap.Count) VM SKUs." -ForegroundColor Green
    return $skuMap
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

# Infer environment from target region if -Environment not explicitly provided
if (-not $Environment) {
    $Environment = Get-EnvironmentFromRegion -Region $TargetRegion
    Write-Host "Inferred environment '$Environment' from target region '$TargetRegion'." -ForegroundColor Cyan
}

$ctx = Ensure-AzContext -RequiredEnvironment $Environment
$Environment = $ctx.Environment.Name

# Resolve source subscription
if ($SourceSubscription) {
    $sourceSub = Resolve-Subscription -NameOrId $SourceSubscription
    $SourceSubscriptionId = $sourceSub.Id
    Write-Host "Setting context to source subscription '$($sourceSub.Name)' ($SourceSubscriptionId)..." -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
}
else {
    $SourceSubscriptionId = $ctx.Subscription.Id
}
$sourceSubName = (Get-AzContext).Subscription.Name

# Resolve target subscription
if ($TargetSubscription) {
    $targetSub = Resolve-Subscription -NameOrId $TargetSubscription
    $TargetSubscriptionId = $targetSub.Id
}
else {
    $TargetSubscriptionId = $SourceSubscriptionId
}

Write-Host "`n=== AZ Capacity Validation ===" -ForegroundColor Yellow
Write-Host "Environment           : $Environment"
Write-Host "Source Subscription   : $sourceSubName ($SourceSubscriptionId)"
if ($SourceResourceGroupName) { Write-Host "Source Resource Group  : $SourceResourceGroupName" }
Write-Host "Target Subscription   : $TargetSubscriptionId"
Write-Host "Target Region         : $TargetRegion"
if ($TargetResourceGroupName) { Write-Host "Target Resource Group  : $TargetResourceGroupName" }
Write-Host ""

# 1. Collect inventory from the SOURCE subscription
$resources = Get-ResourceInventory -SubId $SourceSubscriptionId -RGName $SourceResourceGroupName

# 2. Switch to TARGET subscription to query provider AZ support
if ($TargetSubscriptionId -ne $SourceSubscriptionId) {
    Write-Host "Switching context to target subscription '$TargetSubscriptionId'..." -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $TargetSubscriptionId | Out-Null
}
$targetSubName = (Get-AzContext).Subscription.Name
Write-Host "Target Subscription   : $targetSubName ($TargetSubscriptionId)" -ForegroundColor Cyan

# 3. Get AZ-capable types in the target region (scoped to target subscription)
$azCapable = Get-AZCapableTypes -Region $TargetRegion

# 3b. Get VM SKU zone/capacity map for the target region
$vmSkuMap = Get-VMSkuZoneMap -Region $TargetRegion

# 4. Validate each resource
Write-Host "`nValidating resources against target region..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($res in $resources) {
    $typeKey = $res.ResourceType.ToLower()
    $currentZones = Get-ResourceZoneInfo -Resource $res

    $targetInfo = $azCapable[$typeKey]

    if ($targetInfo -and $targetInfo.Supported) {
        $azStatus = "AZ Supported"
        $targetZones = $targetInfo.Zones
    }
    elseif ($targetInfo -and -not $targetInfo.Supported) {
        $azStatus = "Available (No AZ)"
        $targetZones = "N/A"
    }
    else {
        $azStatus = "Not Available"
        $targetZones = "N/A"
    }

    # Determine resiliency change
    $hasSourceAZ = ($currentZones -and $currentZones.Length -gt 0)
    $hasTargetAZ = ($targetInfo -and $targetInfo.Supported)

    $resiliencyChange = if ($hasSourceAZ -and $hasTargetAZ) {
        "Maintained"
    }
    elseif (-not $hasSourceAZ -and $hasTargetAZ) {
        "Gained"
    }
    elseif ($hasSourceAZ -and -not $hasTargetAZ) {
        "Lost"
    }
    else {
        "None"
    }

    # VM SKU enrichment
    $vmSize         = "N/A"
    $skuTargetZones = "N/A"
    $skuRestrictions = "N/A"
    $skuAvailable   = "N/A"

    if ($typeKey -eq "microsoft.compute/virtualmachines") {
        try {
            $vmDetail = Get-AzResource -ResourceId $res.ResourceId -ExpandProperties -ErrorAction SilentlyContinue
            $vmSize = $vmDetail.Properties.hardwareProfile.vmSize
        }
        catch { }

        if ($vmSize -and $vmSize -ne "N/A") {
            $skuInfo = $vmSkuMap[$vmSize.ToLower()]
            if ($skuInfo) {
                $skuTargetZones  = $skuInfo.Zones
                $skuRestrictions = $skuInfo.Restrictions
                $skuAvailable    = if ($skuInfo.IsRestricted) { "Restricted" } else { "Available" }
            }
            else {
                $skuTargetZones  = "Not Found"
                $skuRestrictions = "SKU not available in region"
                $skuAvailable    = "Not Available"
            }
        }
    }

    $results.Add([PSCustomObject]@{
        ResourceName          = $res.Name
        SourceSubscription    = $sourceSubName
        SourceResourceGroup   = $res.ResourceGroupName
        ResourceType          = $res.ResourceType
        SourceRegion          = $res.Location
        CurrentZones          = if ($currentZones) { $currentZones } else { "None" }
        VMSize                = $vmSize
        TargetSubscription    = $targetSubName
        TargetRegion          = $TargetRegion
        TargetResourceGroup   = if ($TargetResourceGroupName) { $TargetResourceGroupName } else { "N/A" }
        TargetAZStatus        = $azStatus
        TargetZones           = $targetZones
        SKUTargetZones        = $skuTargetZones
        SKURestrictions       = $skuRestrictions
        SKUAvailability       = $skuAvailable
        ResiliencyChange      = $resiliencyChange
    })
}

# 5. Display summary
Write-Host "`n=== Results Summary ===" -ForegroundColor Yellow

$grouped = $results | Group-Object TargetAZStatus
foreach ($g in $grouped) {
    $color = switch ($g.Name) {
        "AZ Supported"      { "Green" }
        "Available (No AZ)" { "Yellow" }
        "Not Available"      { "Red" }
    }
    Write-Host "  $($g.Name): $($g.Count) resources" -ForegroundColor $color
}

# 6. Resiliency change summary
Write-Host "`n=== Resiliency Change Summary ===" -ForegroundColor Yellow
$resiliencyGrouped = $results | Group-Object ResiliencyChange
foreach ($g in $resiliencyGrouped) {
    $color = switch ($g.Name) {
        "Gained"     { "Green" }
        "Maintained" { "Cyan" }
        "Lost"       { "Red" }
        "None"       { "DarkGray" }
    }
    $label = switch ($g.Name) {
        "Gained"     { "AZ Gained    (source has no AZ -> target supports AZ)" }
        "Maintained" { "AZ Maintained (source has AZ -> target supports AZ)" }
        "Lost"       { "AZ Lost       (source has AZ -> target has no AZ)" }
        "None"       { "No AZ Change  (no AZ on either side)" }
    }
    Write-Host "  $($label): $($g.Count) resources" -ForegroundColor $color
}

# 7. Show distinct resource types and their status
Write-Host "`n=== Resource Type Breakdown ===" -ForegroundColor Yellow
$results | Select-Object ResourceType, TargetAZStatus, TargetZones, ResiliencyChange |
    Sort-Object ResourceType -Unique |
    Format-Table -AutoSize

# 8. Highlight resiliency gains — resources that CAN gain AZ in target
$gained = $results | Where-Object { $_.ResiliencyChange -eq "Gained" }
if ($gained) {
    Write-Host "`n✓  RESILIENCY GAIN: The following resources do NOT currently use Availability Zones but CAN use them in the target region:" -ForegroundColor Green
    $gained | Format-Table ResourceName, ResourceType, SourceRegion, CurrentZones, TargetRegion, TargetZones -AutoSize
}

# 9. Flag resiliency losses — resources that LOSE AZ in target
$lost = $results | Where-Object { $_.ResiliencyChange -eq "Lost" }
if ($lost) {
    Write-Host "`n⚠  RESILIENCY LOSS: The following resources currently use Availability Zones but the target region does NOT support AZs for their type:" -ForegroundColor Red
    $lost | Format-Table ResourceName, ResourceType, SourceRegion, CurrentZones, TargetAZStatus -AutoSize
}

# 9b. VM SKU capacity per AZ
$vmResults = $results | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }
if ($vmResults) {
    Write-Host "`n=== VM SKU Availability per Zone ===" -ForegroundColor Yellow
    $vmResults | Format-Table ResourceName, VMSize, SourceRegion, CurrentZones, TargetRegion, SKUTargetZones, SKURestrictions, SKUAvailability -AutoSize

    $restricted = $vmResults | Where-Object { $_.SKUAvailability -eq "Restricted" }
    if ($restricted) {
        Write-Host "⚠  The following VM SKUs have restrictions in the target region:" -ForegroundColor Red
        $restricted | Format-Table ResourceName, VMSize, SKUTargetZones, SKURestrictions -AutoSize
    }

    $notAvail = $vmResults | Where-Object { $_.SKUAvailability -eq "Not Available" }
    if ($notAvail) {
        Write-Host "✗  The following VM SKUs are NOT available in the target region — resize required:" -ForegroundColor Red
        $notAvail | Format-Table ResourceName, VMSize -AutoSize
    }
}

# 10. Restore context to source subscription if we switched
if ($TargetSubscriptionId -ne $SourceSubscriptionId) {
    Write-Host "`nRestoring context to source subscription..." -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
}

# 11. Export to Excel
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$xlsxPath = Join-Path $OutputPath "AZ-Validation-$timestamp.xlsx"

# All resources sheet
$results | Export-Excel -Path $xlsxPath -WorksheetName "All Resources" -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -TableStyle Medium6

# Resiliency Gained sheet
$gained = $results | Where-Object { $_.ResiliencyChange -eq "Gained" }
if ($gained) {
    $gained | Export-Excel -Path $xlsxPath -WorksheetName "AZ Gained" -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -TableStyle Medium4 -Append
}

# Resiliency Lost sheet
$lost = $results | Where-Object { $_.ResiliencyChange -eq "Lost" }
if ($lost) {
    $lost | Export-Excel -Path $xlsxPath -WorksheetName "AZ Lost" -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -TableStyle Medium3 -Append
}

# Summary sheet
$summaryData = $results | Group-Object ResiliencyChange | Select-Object @{N='ResiliencyChange';E={$_.Name}}, @{N='ResourceCount';E={$_.Count}}
$summaryData | Export-Excel -Path $xlsxPath -WorksheetName "Summary" -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -TableStyle Medium6 -Append

# VM SKU Details sheet
$vmResults = $results | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }
if ($vmResults) {
    $vmResults | Select-Object ResourceName, SourceSubscription, SourceResourceGroup, SourceRegion, VMSize, CurrentZones,
        TargetSubscription, TargetRegion, SKUTargetZones, SKURestrictions, SKUAvailability, ResiliencyChange |
        Export-Excel -Path $xlsxPath -WorksheetName "VM SKU Details" -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -TableStyle Medium2 -Append
}

Write-Host "`nResults exported to: $xlsxPath" -ForegroundColor Green

# Return results for pipeline use
return $results
