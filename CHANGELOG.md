# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.0] - 2026-04-23

### Added

- **Module version check** — warns at startup if Az.Accounts, Az.Resources, Az.Compute, or ImportExcel are below recommended versions; does not block execution
- **Subscription name support** — `-SourceSubscription` and `-TargetSubscription` now accept a friendly subscription name or GUID (renamed from `-SourceSubscriptionId` / `-TargetSubscriptionId`)
- **Auto-detect environment from target region** — if `-Environment` is not specified, the script infers the correct cloud (e.g., `usgovarizona` → `AzureUSGovernment`) instead of defaulting to `AzureCloud`

### Changed

- `-Environment` no longer defaults to `AzureCloud` — if omitted, the script uses the current session's environment or infers it from the target region; only reconnects when an explicit mismatch is detected

### Fixed

- **`NameSpace` property error** — resolved `The property 'NameSpace' cannot be found on this object` by dynamically detecting the correct property name (`ProviderNamespace` vs `NameSpace` vs `Namespace`) across Az module versions

## [1.0.0] - 2026-04-23

### Added

- **Resource inventory collection** — scans all ARM resources in a subscription or specific resource group
- **Availability Zone validation** — checks each resource type against target region provider data for AZ support
- **Source/Target subscription support** — separate `-SourceSubscriptionId` and `-TargetSubscriptionId` parameters to handle subscription-scoped AZ feature flags and provider registrations
- **Source/Target resource group support** — `-SourceResourceGroupName` to scope inventory, `-TargetResourceGroupName` for migration planning labels
- **Azure Government support** — `-Environment` parameter supporting `AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud`, and `AzureGermanCloud` endpoints with automatic session re-connection
- **Resiliency change tracking** — each resource tagged with `Gained`, `Maintained`, `Lost`, or `None` to show the directional impact on AZ resiliency when moving between regions
- **VM SKU-level zone capacity** — uses `Get-AzComputeResourceSku` to report per-VM SKU zone availability and restrictions (zone-restricted, region-restricted, or not available) in the target region
- **Excel export** — timestamped `.xlsx` output with five worksheets:
  - **All Resources** — full inventory with all columns
  - **AZ Gained** — resources gaining AZ protection
  - **AZ Lost** — resources losing AZ protection
  - **Summary** — resiliency change counts
  - **VM SKU Details** — VM-specific SKU zone availability and restrictions
- **Console reporting** — color-coded summaries including results summary, resiliency change summary, resource type breakdown, resiliency gain/loss highlights, and VM SKU availability warnings
- **Read-only operations only** — no write/mutate/delete calls against Azure; safe for production use
