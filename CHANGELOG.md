# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
