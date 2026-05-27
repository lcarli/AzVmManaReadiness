<#
.SYNOPSIS
    Assess Azure VM readiness for the Microsoft Azure Network Adapter (MANA).

.DESCRIPTION
    Iterates over every accessible subscription in the Azure tenant (or only the ones
    provided), enumerates the VMs and validates:
      - Whether the VM size family/series is eligible for MANA-capable hardware.
      - Whether the operating system (image) is supported by MANA.
    Produces a consolidated report (pipeline objects and, optionally, a CSV file).

    Official references:
      - VM Sizes:   https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-existing-sizes
      - Linux OS:   https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-linux
      - Windows OS: https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows
      - Overview:   https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview

.PARAMETER TenantId
    (Required) Azure tenant ID. The script authenticates against this tenant and only
    evaluates subscriptions belonging to it.

.PARAMETER SubscriptionId
    One or more subscription IDs within the tenant. If omitted, every enabled subscription
    in the tenant is evaluated.

.PARAMETER OutputCsvPath
    (Optional) Path to a CSV file where the report will be written.

.PARAMETER IncludeStopped
    Include deallocated/stopped VMs in the report (enabled by default; use -IncludeStopped:$false to scan only running VMs).

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

# VM size families/series eligible for MANA-capable hardware (matched against the VM "size" string).
# Each entry is a regex matching sizes in the 'Standard_<NAME>' format.
# Source: Microsoft Learn - MANA support for existing VM Sizes.
$Script:ManaEligibleSizeRegexes = @(
    # A-family
    '^Standard_A\d+_v2$',                                                 # Av2
    # B-family
    '^Standard_B\d+[a-z]*_v2$',                                           # Bsv2 (and variants like Basv2/Balsv2)
    # D-family v1/v2 (legacy)
    '^Standard_D\d+(_v2)?$',                                              # Dv1 / Dv2
    '^Standard_DS\d+(_v2)?$',                                             # Dsv1 / Dsv2
    # D-family v3..v6
    '^Standard_D\d+[a-z]*_v[3-6]$',                                       # Dv3..Dv6 + variants (Ddsv5, Dlsv5, Dpsv6, etc.)
    '^Standard_DS\d+[a-z]*_v[3-6]$',
    # E-family v3..v6
    '^Standard_E\d+[a-z]*_v[3-6]$',                                       # Ev3..Ev6 + variants (Edsv5, Epsv6, etc.)
    '^Standard_ES\d+[a-z]*_v[3-6]$',
    # Eb-family (E "boosted" storage)
    '^Standard_E\d+b[a-z]*_v5$',                                          # Ebsv5 / Ebdsv5
    # F-family
    '^Standard_F\d+$',                                                    # F
    '^Standard_F\d+s$',                                                   # Fs
    '^Standard_F\d+s_v2$',                                                # Fsv2
    # G-family
    '^Standard_G\d+$',                                                    # G
    '^Standard_GS\d+$',                                                   # Gs
    # L-family
    '^Standard_L\d+[a-z]*(_v\d+)?$'                                       # Ls / Lsv2 / Lsv3 ...
)

# Operating systems supported by MANA. Used as a heuristic match against
# the (publisher, offer, sku) of the VM image.
# Source: Accelerated Networking Overview - Supported operating systems.
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

function Test-ManaEligibleSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $VmSize)

    foreach ($pattern in $Script:ManaEligibleSizeRegexes) {
        if ($VmSize -match $pattern) {
            return [pscustomobject]@{
                Eligible       = $true
                MatchedPattern = $pattern
            }
        }
    }
    return [pscustomobject]@{
        Eligible       = $false
        MatchedPattern = $null
    }
}

function Test-ManaSupportedOs {
    <#
    .SYNOPSIS
        Heuristic check to determine whether the VM image/OS is supported by MANA.
    #>
    [CmdletBinding()]
    param(
        [string] $OsType,        # 'Windows' | 'Linux'
        [string] $Publisher,
        [string] $Offer,
        [string] $Sku
    )

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
        return [pscustomobject]@{ Supported=$false; Reason="Unknown OsType ('$OsType'). Possibly a custom image." }
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

        $sizeCheck = Test-ManaEligibleSize -VmSize $size
        $osCheck   = Test-ManaSupportedOs -OsType $osType -Publisher $publisher -Offer $offer -Sku $sku

        $manaReady = $sizeCheck.Eligible -and $osCheck.Supported

        $icon  = if ($manaReady) { '[OK]' } else { '[--]' }
        $color = if ($manaReady) { 'Green' } else { 'Yellow' }
        $sizeTag = if ($sizeCheck.Eligible) { 'size:OK' } else { 'size:NO' }
        $osTag   = if ($osCheck.Supported)  { 'os:OK'   } else { 'os:NO'   }
        Write-Host ("  {0} {1,-40} {2,-22} {3}  {4}" -f $icon, $vm.name, $size, $sizeTag, $osTag) -ForegroundColor $color

        [pscustomobject][ordered]@{
            SubscriptionName = $Subscription.name
            SubscriptionId   = $Subscription.id
            ResourceGroup    = $vm.resourceGroup
            VmName           = $vm.name
            Location         = $vm.location
            PowerState       = $vm.powerState
            VmSize           = $size
            SizeEligible     = $sizeCheck.Eligible
            SizePattern      = $sizeCheck.MatchedPattern
            OsType           = $osType
            ImagePublisher   = $publisher
            ImageOffer       = $offer
            ImageSku         = $sku
            ImageVersion     = $exactImg
            OsSupported      = $osCheck.Supported
            OsReason         = $osCheck.Reason
            ManaReady        = $manaReady
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
    $total       = ($report | Measure-Object).Count
    $ready       = ($report | Where-Object ManaReady).Count
    $sizeIssues  = ($report | Where-Object { -not $_.SizeEligible }).Count
    $osIssues    = ($report | Where-Object { -not $_.OsSupported }).Count

    Write-Host ''
    Write-Host '=== MANA Readiness Summary ===' -ForegroundColor Cyan
    Write-Host ("Total VMs evaluated   : {0}" -f $total)
    Write-Host ("VMs ready (MANA OK)   : {0}" -f $ready)        -ForegroundColor Green
    Write-Host ("VMs with size issue   : {0}" -f $sizeIssues)   -ForegroundColor Yellow
    Write-Host ("VMs with OS issue     : {0}" -f $osIssues)     -ForegroundColor Yellow
    Write-Host ''

    # Emit objects to the pipeline for downstream use.
    $report
}
catch {
    Write-Error $_
    exit 1
}

#endregion
