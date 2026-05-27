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
# Scan every enabled subscription in the given tenant
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> -Verbose

# Export the full report to CSV
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> -OutputCsvPath .\mana-report.csv

# Limit to specific subscriptions inside the tenant
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> -SubscriptionId 00000000-0000-0000-0000-000000000000

# Pipe results: list only VMs that are NOT ready
.\Test-AzVmManaReadiness.ps1 -TenantId <tenant-guid> | Where-Object { -not $_.ManaReady } | Format-Table
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
     Found 1 VM(s).
  [OK] Kami-Vm                                  Standard_DS1_v2        size:OK  os:OK

=== MANA Readiness Summary ===
Total VMs evaluated   : 1
VMs ready (MANA OK)   : 1
VMs with size issue   : 0
VMs with OS issue     : 0
```

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
