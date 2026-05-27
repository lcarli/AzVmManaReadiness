# Azure VM MANA Readiness Check

A small, reusable PowerShell script that scans your entire Azure tenant and tells you which VMs are ready for the **Microsoft Azure Network Adapter (MANA)** — checking both the **VM size family** and the **operating system**.

## What it checks

For every VM in every accessible subscription:

1. **VM size family** — is the VM SKU on the list of series eligible to land on MANA-capable hardware?
   (Av2, Bsv2, D/Ds v1‑v6, E/Es v3‑v6, Ebsv5/Ebdsv5, F/Fs/Fsv2, G/Gs, Ls*)
2. **Operating system** — does the image (publisher / offer / sku) match a MANA-supported OS?
   - **Windows:** Windows Server 2016, 2019, 2022, Windows 11
   - **Linux:** Azure Linux 3, Ubuntu 22.04/24.04, RHEL 9.6/10, AlmaLinux 9.6/10, Rocky 9.6/10, SLES 15 SP6+/16, Debian 12/13, Oracle Linux UEK R7/R8

A VM is flagged **ManaReady = true** only if both checks pass.

## Requirements

- [Azure CLI](https://aka.ms/installazurecli) (`az`) installed and signed in (`az login`).
- PowerShell 7+ recommended.
- Read access (`Reader` role) on the subscriptions you want to scan.

## Usage

```powershell
# Scan every enabled subscription in the tenant
.\Test-AzVmManaReadiness.ps1 -Verbose

# Export the full report to CSV
.\Test-AzVmManaReadiness.ps1 -OutputCsvPath .\mana-report.csv

# Limit to specific subscriptions
.\Test-AzVmManaReadiness.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

# Pipe results: list only VMs that are NOT ready
.\Test-AzVmManaReadiness.ps1 | Where-Object { -not $_.ManaReady } | Format-Table
```

### Parameters

| Parameter         | Description                                                                 |
|-------------------|-----------------------------------------------------------------------------|
| `-SubscriptionId` | One or more subscription IDs. Omit to scan all enabled subscriptions.       |
| `-TenantId`       | Target tenant (useful for multi-tenant accounts).                           |
| `-OutputCsvPath`  | Path to write the report as CSV.                                            |
| `-IncludeStopped` | Include deallocated/stopped VMs (default: on).                              |

## Output

Each VM is returned as an object with these fields:

`SubscriptionName, SubscriptionId, ResourceGroup, VmName, Location, PowerState, VmSize, SizeEligible, SizePattern, OsType, ImagePublisher, ImageOffer, ImageSku, ImageVersion, OsSupported, OsReason, ManaReady`

A summary is also printed at the end:

```
=== Summary MANA Readiness ===
Total VMs evaluated   : 42
VMs ready (MANA OK)   : 30
VMs with size issue   : 5
VMs with OS issue     : 9
```

## Notes & limitations

- The OS check is a heuristic based on `publisher / offer / sku` of the marketplace image. **Custom images** cannot be reliably classified and are reported as not supported — review them manually.
- The script is **read-only and idempotent**. It does not modify any resource.
- Networking limits in Azure are tied to the VM size, not to the underlying NIC. A VM may still run fine on MANA hardware even if its OS isn't on the supported list, but performance/reliability improvements are not guaranteed.

## References

- [MANA support for existing VM Sizes](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes)
- [Linux VMs with MANA](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-linux)
- [Windows VMs with MANA](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows)
- [Accelerated Networking overview](https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview)
