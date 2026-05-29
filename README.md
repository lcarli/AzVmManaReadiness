# Azure VM MANA Readiness Check

A small, reusable PowerShell script that scans your entire Azure tenant and reports — per VM — whether any action is required for the **Microsoft Azure Network Adapter (MANA)**, following the [official Microsoft compatibility flow](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes#compatibility).

## What it checks

For every VM in every accessible subscription, the script applies the official 3-step decision flow:

1. **Is the VM size on the [Applicable VM series](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes#applicable-vm-series) list?**
   - **No →** `Status = NotApplicable`. The VM is **not on the MANA-applicable list** (it might be a newer MANA-optimized series like Dsv6/Esv6, an AMD variant, GPU/HPC, etc.). **No action required.**
   - **Yes →** continue.
2. **Is Accelerated Networking enabled on any NIC?**
   - **No →** `Status = NoActionRequired`. Per Microsoft guidance, **no action is required** — if the VM ever lands on MANA-capable hardware, networking falls back to NetVSC.
   - **Yes →** continue.
3. **Is the operating system on the [MANA-supported list](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview#supported-operating-systems)?**
   - **Yes →** `Status = Ready`.
   - **No  →** `Status = ActionRequired`. Recommended fix: resize to an **Intel v6+** VM series (MANA support regardless of OS) **or** update the OS (Linux kernel ≥ 6.14 / endorsed distro; Windows Server 2016+/Windows 11).
   - **Unknown (custom image, missing metadata) →** `Status = Unknown`. Verify manually.

### Applicable VM series (per Microsoft Learn)

| Family | Series |
|--------|--------|
| A      | Av2 (Intel) |
| B      | Bsv2 (Intel; AMD `Basv2`/`Balsv2` **not** applicable) |
| D      | Dv1, Dsv1, Dv2, Dsv2, Dv3, Dsv3, Dv4, Dsv4, Ddv4, Ddsv4, Dv5, Dsv5, Ddv5, Ddsv5, Dlsv5, Dldsv5, Dpsv6, Dpdsv6, Dplsv6, Dpldsv6 |
| E      | Ev3, Esv3, Ev4, Esv4, Edv4, Edsv4, Ev5, Esv5, Edv5, Edsv5, Epsv6, Epdsv6 |
| Eb     | Ebsv5, Ebdsv5 |
| F      | F, Fs, Fsv2 |
| G      | G, Gs |
| L      | Ls, Lsv2, Lsv3, Ldsv3, Lasv3, Ldasv3 |

AMD variants (`Dasv4`, `Dasv5`, `Dadsv5`, `Easv4`, `Easv5`, ...) and Intel v6 (`Dsv6`, `Esv6`, ...) are intentionally **NOT** in the applicable list — Intel v6 is already MANA-optimized by design.

### Supported operating systems

- **Windows:** Windows Server 2016, 2019, 2022, Windows 11
- **Linux:** Azure Linux 3, Ubuntu 22.04/24.04 LTS, RHEL 9.6/10.0, AlmaLinux 9.6/10.0, Rocky Linux 9.6/10.0, SLES 15 SP6/SP7/16, Debian 12/13, Oracle Linux UEK R7/R8

## Requirements

- [Azure CLI](https://aka.ms/installazurecli) (`az`) installed and signed in (`az login`).
- PowerShell 7+ recommended (uses the `??` null-coalescing operator).
- Read access on the subscriptions you want to scan. The role needs to be able to read both VMs and NICs (`Reader` on the subscription works).

## Usage

```powershell
# Scan every enabled subscription in the given tenant
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> -Verbose

# Export the full report to CSV
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> -OutputCsvPath .\mana-report.csv

# Limit to specific subscriptions inside the tenant
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> -SubscriptionId 00000000-0000-0000-0000-000000000000

# Pipe results: show only VMs that actually need attention
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> | Where-Object ActionRequired | Format-Table

# Or filter by Status
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> | Where-Object { $_.Status -eq 'ActionRequired' }
```

> The script validates that `az` is signed in to the specified tenant. If not, it runs
> `az login --tenant <TenantId>` automatically.

### Parameters

| Parameter         | Required | Description                                                       |
|-------------------|----------|-------------------------------------------------------------------|
| `-TenantId`       | Yes      | Azure tenant to authenticate against and scope subscriptions to.  |
| `-SubscriptionId` | No       | One or more subscription IDs within the tenant.                   |
| `-OutputCsvPath`  | No       | Path to write the report as CSV.                                  |
| `-IncludeStopped` | No       | Include deallocated/stopped VMs (default: on).                    |

## Sample run

```
PS> .\Test-AzVmManaReadiness.ps1 -TenantId 1d70d939-06d2-4348-b658-58cb38886348

Starting MANA readiness scan...
Subscriptions to evaluate: 4

[1/4] Subscription: ME-MngEnvMCAP266581-lramoscostah-3 (4e4f76f7-bfb7-4163-84bd-2a19561451b5)
  -> Listing VMs...
     No VMs found.
[2/4] Subscription: ME-MngEnvMCAP266581-lramoscostah-2 (1c164742-2e07-4d88-a81c-7b1d48d62d38)
  -> Listing VMs...
     No VMs found.
[3/4] Subscription: ME-MngEnvMCAP266581-lramoscostah-1 (97bed3f6-adf3-4c44-a29b-65e148c38d07)
  -> Listing VMs...
     No VMs found.
[4/4] Subscription: ME-MngEnvMCAP266581-lramoscostah-4 (3dc8ff32-42e4-4152-b194-46b704ed70f2)
  -> Listing VMs...
     Found 3 VM(s).
  -> Fetching NIC Accelerated Networking status...
     Found 3 NIC(s).
  [OK]  Kami-Vm                                  Standard_DS1_v2        Ready
  [N/A] AmdWorkload                              Standard_D2as_v5       NotApplicable
  [!!]  LegacyUbuntu                             Standard_D2s_v5        ActionRequired

=== MANA Readiness Summary ===
Total VMs scanned          : 3
  Not applicable           : 1
  Applicable               : 2
    Ready (MANA OK)        : 1
    No action (AN off)     : 0
    Action required        : 1
    Unknown (verify)       : 0
```

## Output

Each VM is returned as an object with these fields:

| Field | Description |
|-------|-------------|
| `SubscriptionName`, `SubscriptionId`, `ResourceGroup`, `VmName`, `Location`, `PowerState` | VM identity & state |
| `VmSize` | Azure size string (e.g. `Standard_D2s_v5`) |
| `SizeApplicable` (bool) | Whether the size is on the official MANA-applicable list |
| `SizePattern` | The regex pattern that matched (empty when not applicable) |
| `AcceleratedNetworkingEnabled` | `true` / `false` / `$null` (unknown) — `true` if **any** NIC has AN enabled |
| `NicCount`, `AcceleratedNicCount` | NIC totals for the VM |
| `OsType`, `ImagePublisher`, `ImageOffer`, `ImageSku`, `ImageVersion` | Marketplace image metadata |
| `OsSupported` | `true` / `false` / `$null` (unknown / custom image) |
| `OsReason` | Why the OS was classified that way |
| `Status` | `NotApplicable` \| `NoActionRequired` \| `Ready` \| `ActionRequired` \| `Unknown` |
| `ActionRequired` (bool) | `true` only when the customer must take action |
| `Recommendation` | Plain-English next step (or "no action required") |
| `ManaReady` (bool) | Kept for backward compatibility — `true` only when `Status = Ready` |

> **Filter on `ActionRequired` or `Status` to find the VMs that actually need attention.** `ManaReady` is intentionally `false` for `NotApplicable` and `NoActionRequired` VMs too, so don't use it as a "this VM has a problem" signal.

## Notes & limitations

- The OS check is a **heuristic** based on `publisher / offer / sku` of the marketplace image. **Custom images** cannot be reliably classified and are reported as `OsSupported = $null` / `Status = Unknown` — review them manually.
- **VMs marked `NotApplicable` are not a problem** — they are simply not on the "Applicable VM series" list (either newer MANA-optimized hardware like Dsv6/Esv6, AMD variants, GPU/HPC, etc.). They appear in the CSV for completeness; you do not need to act on them.
- **`Status = NoActionRequired`** means the VM size *would* require verification, but Accelerated Networking is disabled on all NICs — per Microsoft, no action is needed.
- The script is **read-only and idempotent**. It does not modify any resource.
- Networking limits in Azure are tied to the VM size, not to the underlying NIC. A VM may still run fine on MANA hardware even when its OS isn't on the supported list (falling back to NetVSC); performance/reliability improvements just won't be guaranteed.

## References

- [MANA support for existing VM Sizes](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes)
- [Linux VMs with MANA](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-linux)
- [Windows VMs with MANA](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows)
- [Accelerated Networking overview](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview)
