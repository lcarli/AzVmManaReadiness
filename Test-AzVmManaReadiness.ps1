<#
.SYNOPSIS
    Assess Azure VM readiness for the Microsoft Azure Network Adapter (MANA).

.DESCRIPTION
    Iterates over every accessible subscription in the Azure tenant (or only the ones
    provided) and evaluates each VM against the official MANA compatibility process:

      1. Is the VM size on the official "Applicable VM series" list?
         - If NO  -> Status = NotApplicable. The customer does not need to do anything;
                     the VM will not require any MANA-related action.
      2. If YES, is Accelerated Networking (AN) enabled on any of the VM NICs?
         - If NO  -> Status = NoActionRequired. Per Microsoft guidance, no action is
                     required; the VM keeps working normally (NetVSC fallback if it
                     ever lands on MANA-capable hardware).
      3. If YES, is the operating system on the MANA-supported list?
         - YES    -> Status = Ready.
         - NO     -> Status = ActionRequired. Recommend either resizing to an Intel v6+
                     series (which supports MANA regardless of OS) or updating the OS
                     (Linux kernel >= 6.14 / endorsed distro, Windows Server 2016+/Win 11).
         - UNKNOWN -> Status = Unknown. Likely a custom image; manual verification needed.

    Produces a consolidated report (pipeline objects and, optionally, a CSV file).

    Official references:
      - Applicable VM Sizes: https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes#applicable-vm-series
      - Compatibility steps: https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes#compatibility
      - Linux OS:            https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-linux
      - Windows OS:          https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows
      - Supported OS list:   https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview#supported-operating-systems

.PARAMETER TenantId
    (Required) Azure tenant ID. The script authenticates against this tenant and only
    evaluates subscriptions belonging to it.

.PARAMETER SubscriptionId
    One or more subscription IDs within the tenant. If omitted, every enabled subscription
    in the tenant is evaluated.

.PARAMETER OutputCsvPath
    (Optional) Path to a CSV file where the report will be written.

.PARAMETER IncludeStopped
    Include deallocated/stopped VMs in the report (enabled by default; use -IncludeStopped:$false
    to scan only running VMs).

.EXAMPLE
    .\Test-AzVmManaReadiness.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -OutputCsvPath .\mana-report.csv

.EXAMPLE
    .\Test-AzVmManaReadiness.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -SubscriptionId 11111111-1111-1111-1111-111111111111 -Verbose

.NOTES
    Requires an authenticated Azure CLI (az): run 'az login' first.
    Best practices:
      - Idempotent script (read-only).
      - No dependency on Azure PowerShell modules (Az.*).
      - Pipeline-friendly object output.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter()]
    [string[]] $SubscriptionId,

    [Parameter()]
    [string] $OutputCsvPath,

    [Parameter()]
    [switch] $IncludeStopped = $true
)

#region --- Constants / MANA support tables ---

# VM size families/series on the official "Applicable VM series" list for MANA.
# Each entry is a regex matching size strings in 'Standard_<NAME>' format.
# Source: https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes#applicable-vm-series
#
# Important: AMD variants (e.g. Dasv4, Dasv5, Dadsv5, Easv4, Easv5) are intentionally
# excluded - they are not on the applicable list. Likewise Intel v6 series (Dsv6, Esv6)
# are NOT applicable because they are already MANA-optimized by design (the recommended
# resize target, not a series needing verification).
$Script:ManaApplicableSizeRegexes = @(
    # ---- A-family (Intel) ----
    '^Standard_A\d+m?_v2$',                                  # Av2 (incl. A2m_v2 / A4m_v2 / A8m_v2)

    # ---- B-family (Intel only; AMD variants like Basv2/Balsv2 are excluded) ----
    '^Standard_B\d+[mt]?s_v2$',                              # Bsv2, Bmsv2 (B*ms_v2), Btsv2 (B*ts_v2)

    # ---- D-family v1 / v2 (legacy Intel) ----
    '^Standard_D\d+(-\d+)?$',                                # Dv1
    '^Standard_DS\d+(-\d+)?$',                               # Dsv1
    '^Standard_D\d+(-\d+)?_v2$',                             # Dv2
    '^Standard_DS\d+(-\d+)?_v2$',                            # Dsv2

    # ---- D-family v3 (Intel) ----
    '^Standard_D\d+(-\d+)?s?_v3$',                           # Dv3, Dsv3

    # ---- D-family v4 (Intel) ----
    '^Standard_D\d+(-\d+)?d?s?_v4$',                         # Dv4, Dsv4, Ddv4, Ddsv4

    # ---- D-family v5 (Intel) ----
    '^Standard_D\d+(-\d+)?(s|d|ds|ls|lds)?_v5$',             # Dv5, Dsv5, Ddv5, Ddsv5, Dlsv5, Dldsv5

    # ---- D-family v6 (ARM Cobalt only - Intel/AMD v6 NOT in the applicable list) ----
    '^Standard_D\d+(-\d+)?p(s|ds|ls|lds)_v6$',               # Dpsv6, Dpdsv6, Dplsv6, Dpldsv6

    # ---- E-family v3 (Intel) ----
    '^Standard_E\d+(-\d+)?i?s?_v3$',                         # Ev3, Esv3 (incl. isolated 'i' and constrained-core)

    # ---- E-family v4 (Intel) ----
    '^Standard_E\d+(-\d+)?i?d?s?_v4$',                       # Ev4, Esv4, Edv4, Edsv4 (incl. isolated)

    # ---- E-family v5 (Intel) ----
    '^Standard_E\d+(-\d+)?i?d?s?_v5$',                       # Ev5, Esv5, Edv5, Edsv5 (incl. isolated)

    # ---- E-family v6 (ARM Cobalt only) ----
    '^Standard_E\d+(-\d+)?pd?s_v6$',                         # Epsv6, Epdsv6

    # ---- Eb-family v5 (Intel, block-storage performance) ----
    '^Standard_E\d+(-\d+)?bd?s_v5$',                         # Ebsv5, Ebdsv5

    # ---- F-family ----
    '^Standard_F\d+$',                                       # F (v1)
    '^Standard_F\d+s$',                                      # Fs (v1)
    '^Standard_F\d+s_v2$',                                   # Fsv2

    # ---- G-family ----
    '^Standard_G\d+(-\d+)?$',                                # G
    '^Standard_GS\d+(-\d+)?$',                               # Gs (incl. constrained-core)

    # ---- L-family (Ls*) ----
    '^Standard_L\d+s$',                                      # Ls (v1)
    '^Standard_L\d+s_v2$',                                   # Lsv2
    '^Standard_L\d+(d|a|da)?s_v3$'                           # Lsv3, Ldsv3, Lasv3, Ldasv3
)

# Operating systems supported by MANA - used as a heuristic match against
# the (publisher, offer, sku) of the VM image.
# Source: https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview#supported-operating-systems
$Script:SupportedWindowsSkuPatterns = @(
    '2016', '2019', '2022',          # Windows Server
    'win11', 'windows-11'             # Windows 11
)

# For Linux, we map (publisher => regex matching the minimum supported offer).
$Script:SupportedLinuxOffers = @(
    [pscustomobject]@{ Publisher='canonical';            OfferRegex='^(ubuntu-24_04-lts|ubuntu-22_04-lts|0001-com-ubuntu-server-(jammy|noble))'; MinDescription='Ubuntu 22.04 / 24.04 LTS' },
    [pscustomobject]@{ Publisher='redhat';               OfferRegex='^rhel';                  MinDescription='RHEL 9.6 / 10.0 (validate SKU)' },
    [pscustomobject]@{ Publisher='almalinux';            OfferRegex='^almalinux';              MinDescription='AlmaLinux 9.6 / 10.0 (validate SKU)' },
    [pscustomobject]@{ Publisher='resf';                 OfferRegex='^rockylinux';             MinDescription='Rocky Linux 9.6 / 10.0 (validate SKU)' },
    [pscustomobject]@{ Publisher='erockyenterprisesoftwarefoundationinc1653071250513'; OfferRegex='^rockylinux'; MinDescription='Rocky Linux (validate SKU)' },
    [pscustomobject]@{ Publisher='suse';                 OfferRegex='^sles';                  MinDescription='SLES 15 SP6 / SP7 / 16 (validate SKU)' },
    [pscustomobject]@{ Publisher='debian';               OfferRegex='^debian-1[23]';           MinDescription='Debian 12 / 13' },
    [pscustomobject]@{ Publisher='oracle';               OfferRegex='^oracle-linux';           MinDescription='Oracle Linux UEK R7 / R8 (validate SKU)' },
    [pscustomobject]@{ Publisher='microsoftcblmariner';  OfferRegex='^azure-linux-3';          MinDescription='Azure Linux 3' },
    [pscustomobject]@{ Publisher='microsoft-azurelinux'; OfferRegex='^azurelinux-3';           MinDescription='Azure Linux 3' }
)

#endregion

#region --- Helpers ---

function Assert-AzCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId
    )
    $cmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Azure CLI (az) not found. Install it from: https://aka.ms/installazurecli"
    }

    $current = & az account show --only-show-errors -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

    if (-not $current -or $current.tenantId -ne $TenantId) {
        Write-Host "Authenticating to tenant $TenantId ..." -ForegroundColor Yellow
        & az login --tenant $TenantId --only-show-errors -o none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to authenticate to tenant $TenantId."
        }
    } else {
        Write-Verbose "Already authenticated to tenant $TenantId as $($current.user.name)."
    }
}

function Invoke-Az {
    <#
    .SYNOPSIS
        Runs an az command and returns the JSON output as a PowerShell object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Args
    )
    $raw = & az @Args --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "az $($Args -join ' ') failed (exit=$LASTEXITCODE)"
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json -Depth 100 } catch { return $null }
}

function Get-TargetSubscriptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $TenantId,
        [string[]] $SubscriptionId
    )
    $all = Invoke-Az -Args @('account','list','--all','--query', "[?tenantId=='$TenantId']")
    if (-not $all) { return @() }

    $enabled = $all | Where-Object { $_.state -eq 'Enabled' }
    if ($SubscriptionId) {
        return $enabled | Where-Object { $SubscriptionId -contains $_.id }
    }
    return $enabled
}

function Test-ManaApplicableSize {
    <#
    .SYNOPSIS
        Returns whether the VM size is on the MANA "Applicable VM series" list.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $VmSize)

    foreach ($pattern in $Script:ManaApplicableSizeRegexes) {
        if ($VmSize -match $pattern) {
            return [pscustomobject]@{
                Applicable     = $true
                MatchedPattern = $pattern
            }
        }
    }
    return [pscustomobject]@{
        Applicable     = $false
        MatchedPattern = $null
    }
}

function Test-ManaSupportedOs {
    <#
    .SYNOPSIS
        Heuristic check to determine whether the VM image/OS is supported by MANA.
        Returns Supported = $true / $false / $null (unknown - e.g. custom image).
    #>
    [CmdletBinding()]
    param(
        [string] $OsType,        # 'Windows' | 'Linux'
        [string] $Publisher,
        [string] $Offer,
        [string] $Sku
    )

    if ([string]::IsNullOrWhiteSpace($Publisher) -and [string]::IsNullOrWhiteSpace($Offer)) {
        return [pscustomobject]@{ Supported = $null; Reason = 'Unknown OS - no marketplace image metadata (likely a custom image).' }
    }

    $pub   = ($Publisher ?? '').ToLowerInvariant()
    $off   = ($Offer    ?? '').ToLowerInvariant()
    $sku2  = ($Sku      ?? '').ToLowerInvariant()
    $combo = "$pub|$off|$sku2"

    if ($OsType -eq 'Windows') {
        foreach ($p in $Script:SupportedWindowsSkuPatterns) {
            if ($combo -match $p) {
                return [pscustomobject]@{ Supported=$true;  Reason="Supported Windows (match '$p')" }
            }
        }
        return [pscustomobject]@{ Supported=$false; Reason='Windows image not in the supported list (WS2016/2019/2022, Win11).' }
    }
    elseif ($OsType -eq 'Linux') {
        foreach ($entry in $Script:SupportedLinuxOffers) {
            if ($pub -like "*$($entry.Publisher)*" -and $off -match $entry.OfferRegex) {
                return [pscustomobject]@{ Supported=$true; Reason="Compatible Linux: $($entry.MinDescription) (validate SKU '$Sku')." }
            }
        }
        return [pscustomobject]@{ Supported=$false; Reason='Linux distribution/version not in the supported list. Requires kernel >= 6.14 or an endorsed image.' }
    }
    else {
        return [pscustomobject]@{ Supported = $null; Reason = "Unknown OsType ('$OsType') - possibly a custom image." }
    }
}

function Get-NicAcceleratedNetworkingMap {
    <#
    .SYNOPSIS
        Returns a hashtable mapping NIC ID (lower-cased) -> bool for AcceleratedNetworking.
        Returns $null if the underlying az call failed (so the caller can treat AN as Unknown).
    #>
    [CmdletBinding()]
    param()

    $nics = Invoke-Az -Args @('network','nic','list','--query','[].{id:id, enableAcceleratedNetworking:enableAcceleratedNetworking}')
    if ($null -eq $nics) {
        return $null
    }
    $map = @{}
    foreach ($nic in $nics) {
        if ($nic.id) {
            $map[$nic.id.ToLowerInvariant()] = [bool]$nic.enableAcceleratedNetworking
        }
    }
    return $map
}

function Get-VmAcceleratedNetworkingStatus {
    <#
    .SYNOPSIS
        Computes per-VM Accelerated Networking status from the NIC map.

        Enabled = $true   -> at least one NIC has AN enabled
                = $false  -> all NICs reported and none have AN enabled
                = $null   -> at least one NIC could not be looked up (status partially unknown)
                             AND no NIC was found to have AN enabled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Vm,
        [hashtable] $NicMap
    )

    $nicRefs = @($Vm.networkProfile.networkInterfaces)
    if ($nicRefs.Count -eq 0) {
        return [pscustomobject]@{
            Enabled          = $null
            NicCount         = 0
            AcceleratedCount = 0
        }
    }

    $accel   = 0
    $missing = 0
    foreach ($ref in $nicRefs) {
        $key = if ($ref.id) { $ref.id.ToLowerInvariant() } else { $null }
        if ($null -ne $NicMap -and $key -and $NicMap.ContainsKey($key)) {
            if ($NicMap[$key]) { $accel++ }
        } else {
            $missing++
        }
    }

    $enabled =
        if ($accel -gt 0)    { $true }
        elseif ($missing -gt 0) { $null }    # some NICs unknown; can't claim disabled
        else                  { $false }

    return [pscustomobject]@{
        Enabled          = $enabled
        NicCount         = $nicRefs.Count
        AcceleratedCount = $accel
    }
}

function Get-VmManaReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Subscription,
        [switch] $IncludeStopped,
        [int]    $SubscriptionIndex = 1,
        [int]    $SubscriptionTotal = 1
    )

    Write-Host ""
    Write-Host ("[{0}/{1}] Subscription: " -f $SubscriptionIndex, $SubscriptionTotal) -ForegroundColor Cyan -NoNewline
    Write-Host ("{0} " -f $Subscription.name) -ForegroundColor White -NoNewline
    Write-Host ("({0})" -f $Subscription.id) -ForegroundColor DarkGray

    Write-Verbose "Selecting subscription '$($Subscription.name)' ($($Subscription.id))"
    $null = az account set --subscription $Subscription.id --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to select subscription $($Subscription.id)."
        return
    }

    Write-Host "  -> Listing VMs..." -ForegroundColor DarkGray
    $vms = Invoke-Az -Args @('vm','list','--show-details')
    if (-not $vms) {
        Write-Host "     No VMs found." -ForegroundColor DarkGray
        return
    }

    $vmCount = @($vms).Count
    Write-Host ("     Found {0} VM(s)." -f $vmCount) -ForegroundColor Gray

    Write-Host "  -> Fetching NIC Accelerated Networking status..." -ForegroundColor DarkGray
    $nicMap = Get-NicAcceleratedNetworkingMap
    if ($null -eq $nicMap) {
        Write-Warning "     Could not list NICs in this subscription; AN status will be reported as Unknown."
    } else {
        Write-Host ("     Found {0} NIC(s)." -f $nicMap.Count) -ForegroundColor Gray
    }

    $i = 0
    foreach ($vm in $vms) {
        $i++
        Write-Progress -Activity ("Subscription {0}/{1}: {2}" -f $SubscriptionIndex, $SubscriptionTotal, $Subscription.name) `
                       -Status   ("Checking VM {0}/{1}: {2}" -f $i, $vmCount, $vm.name) `
                       -PercentComplete ([int](($i / [Math]::Max($vmCount,1)) * 100))

        if (-not $IncludeStopped -and $vm.powerState -ne 'VM running') {
            Write-Host ("  - {0} [skipped: {1}]" -f $vm.name, $vm.powerState) -ForegroundColor DarkGray
            continue
        }

        $size       = $vm.hardwareProfile.vmSize
        $osType     = $vm.storageProfile.osDisk.osType
        $imgRef     = $vm.storageProfile.imageReference
        $publisher  = $imgRef.publisher
        $offer      = $imgRef.offer
        $sku        = $imgRef.sku
        $exactImg   = $imgRef.exactVersion

        $sizeCheck = Test-ManaApplicableSize -VmSize $size

        # Defaults (overwritten by the decision tree below).
        $anStatus       = [pscustomobject]@{ Enabled = $null; NicCount = 0; AcceleratedCount = 0 }
        $osCheck        = [pscustomobject]@{ Supported = $null; Reason = 'Not evaluated (VM size not applicable).' }
        $status         = $null
        $recommendation = $null
        $actionRequired = $false

        if (-not $sizeCheck.Applicable) {
            # Step 1: VM size is not on the MANA-applicable list -> nothing to do.
            $status         = 'NotApplicable'
            $recommendation = "VM size '$size' is not on the MANA 'Applicable VM series' list. No action required."
        }
        else {
            # The size IS applicable - apply steps 2 and 3 from the official compatibility flow.
            $anStatus = Get-VmAcceleratedNetworkingStatus -Vm $vm -NicMap $nicMap
            $osCheck  = Test-ManaSupportedOs -OsType $osType -Publisher $publisher -Offer $offer -Sku $sku

            if ($anStatus.Enabled -eq $false) {
                # Step 2: AN disabled -> per Microsoft Learn, no action required.
                $status         = 'NoActionRequired'
                $recommendation = 'Accelerated Networking is disabled on all NICs. Per Microsoft guidance, no action is required; the VM will keep working normally (NetVSC fallback if it ever lands on MANA-capable hardware).'
            }
            elseif ($anStatus.Enabled -eq $true) {
                # Step 3: AN enabled -> OS must support MANA.
                if ($osCheck.Supported -eq $true) {
                    $status         = 'Ready'
                    $recommendation = 'MANA-ready: VM size is applicable, Accelerated Networking is enabled, and the OS is on the supported list.'
                }
                elseif ($osCheck.Supported -eq $false) {
                    $status         = 'ActionRequired'
                    $actionRequired = $true
                    $recommendation = "Action required: OS is not on the MANA-supported list. Resize to an Intel v6+ VM series (supports MANA regardless of OS) OR update the OS (Linux kernel >= 6.14 / endorsed distro, Windows Server 2016+/Windows 11). Reason: $($osCheck.Reason)"
                }
                else {
                    $status         = 'Unknown'
                    $recommendation = 'OS support could not be determined (likely a custom image). Verify manually that the OS supports MANA, or resize to an Intel v6+ VM series.'
                }
            }
            else {
                # AN status itself is unknown.
                $status         = 'Unknown'
                $recommendation = 'Accelerated Networking status could not be determined for one or more NICs. Re-run with sufficient NIC read permissions, or verify manually in the Azure portal.'
            }
        }

        switch ($status) {
            'NotApplicable'    { $icon = '[N/A]'; $color = 'DarkGray'    }
            'NoActionRequired' { $icon = '[OK] '; $color = 'Green'       }
            'Ready'            { $icon = '[OK] '; $color = 'Green'       }
            'ActionRequired'   { $icon = '[!!] '; $color = 'Yellow'      }
            'Unknown'          { $icon = '[??] '; $color = 'DarkYellow'  }
            default            { $icon = '[?? ]'; $color = 'Gray'        }
        }
        Write-Host ("  {0} {1,-40} {2,-22} {3}" -f $icon, $vm.name, $size, $status) -ForegroundColor $color

        $manaReady = ($status -eq 'Ready')

        [pscustomobject][ordered]@{
            SubscriptionName             = $Subscription.name
            SubscriptionId               = $Subscription.id
            ResourceGroup                = $vm.resourceGroup
            VmName                       = $vm.name
            Location                     = $vm.location
            PowerState                   = $vm.powerState
            VmSize                       = $size
            SizeApplicable               = $sizeCheck.Applicable
            SizePattern                  = $sizeCheck.MatchedPattern
            AcceleratedNetworkingEnabled = $anStatus.Enabled
            NicCount                     = $anStatus.NicCount
            AcceleratedNicCount          = $anStatus.AcceleratedCount
            OsType                       = $osType
            ImagePublisher               = $publisher
            ImageOffer                   = $offer
            ImageSku                     = $sku
            ImageVersion                 = $exactImg
            OsSupported                  = $osCheck.Supported
            OsReason                     = $osCheck.Reason
            Status                       = $status
            ActionRequired               = $actionRequired
            Recommendation               = $recommendation
            ManaReady                    = $manaReady
        }
    }
    Write-Progress -Activity ("Subscription {0}/{1}: {2}" -f $SubscriptionIndex, $SubscriptionTotal, $Subscription.name) -Completed
}

#endregion

#region --- Main ---

try {
    Assert-AzCli -TenantId $TenantId

    $subs = Get-TargetSubscriptions -TenantId $TenantId -SubscriptionId $SubscriptionId
    if (-not $subs -or $subs.Count -eq 0) {
        Write-Warning "No enabled subscription found in tenant $TenantId for evaluation."
        return
    }

    Write-Host ""
    Write-Host "Starting MANA readiness scan..." -ForegroundColor Cyan
    Write-Host ("Subscriptions to evaluate: {0}" -f $subs.Count) -ForegroundColor Gray
    Write-Verbose "Subscriptions to evaluate: $($subs.Count)"

    $report = @()
    $idx = 0
    foreach ($sub in $subs) {
        $idx++
        $report += Get-VmManaReport -Subscription $sub -IncludeStopped:$IncludeStopped `
                                    -SubscriptionIndex $idx -SubscriptionTotal $subs.Count
    }

    if ($OutputCsvPath) {
        $report | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Report saved to: $OutputCsvPath" -ForegroundColor Green
    }

    # Aggregated summary
    $total          = ($report | Measure-Object).Count
    $notApplicable  = ($report | Where-Object { $_.Status -eq 'NotApplicable'   }).Count
    $applicable     = $total - $notApplicable
    $ready          = ($report | Where-Object { $_.Status -eq 'Ready'           }).Count
    $noAction       = ($report | Where-Object { $_.Status -eq 'NoActionRequired'}).Count
    $actionRequired = ($report | Where-Object { $_.Status -eq 'ActionRequired'  }).Count
    $unknown        = ($report | Where-Object { $_.Status -eq 'Unknown'         }).Count

    Write-Host ''
    Write-Host '=== MANA Readiness Summary ===' -ForegroundColor Cyan
    Write-Host ("Total VMs scanned          : {0}" -f $total)
    Write-Host ("  Not applicable           : {0}" -f $notApplicable)   -ForegroundColor DarkGray
    Write-Host ("  Applicable               : {0}" -f $applicable)
    Write-Host ("    Ready (MANA OK)        : {0}" -f $ready)           -ForegroundColor Green
    Write-Host ("    No action (AN off)     : {0}" -f $noAction)        -ForegroundColor Green
    Write-Host ("    Action required        : {0}" -f $actionRequired)  -ForegroundColor Yellow
    Write-Host ("    Unknown (verify)       : {0}" -f $unknown)         -ForegroundColor DarkYellow
    Write-Host ''

    # Emit objects to the pipeline for downstream use.
    $report
}
catch {
    Write-Error $_
    exit 1
}

#endregion
