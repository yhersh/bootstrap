# Secretless Windows remote-access bootstrap — stage zero.
# Canonical invocation:
#   irm https://bootstrap.yaronhersh.xyz/windows | iex
#
# Optional components (download first when piping):
#   irm https://bootstrap.yaronhersh.xyz/windows -OutFile bootstrap-windows.ps1
#   .\bootstrap-windows.ps1 -With Sunshine

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $With = @()
)

$PSNativeCommandUseErrorActionPreference = $true
$ErrorActionPreference = 'Stop'

$TailscaleRemoteCidr = '100.64.0.0/10'
# Windows stores an inbound RemoteAddress CIDR but reads it back from
# Get-NetFirewallAddressFilter as the expanded range, so the acceptance
# check must recognise both spellings of the same Tailscale scope.
$TailscaleRemoteRange = '100.64.0.0-100.127.255.255'
$TailscaleSshRuleName = 'OpenSSH-Server-In-TCP-Tailscale'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-StageMessage {
    param([string] $Message)
    Write-Host $Message
}

function Assert-LastExitCode {
    param(
        [string] $CommandDescription
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Native command failed ($CommandDescription): exit code $LASTEXITCODE"
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)][string] $Description
    )

    & $ScriptBlock
    Assert-LastExitCode -CommandDescription $Description
}

function Ensure-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $DisplayName
    )

    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null |
        Select-String -Pattern $Id -Quiet

    if ($installed) {
        Write-StageMessage "$DisplayName already installed ($Id)."
        return
    }

    if ($WhatIfPreference) {
        Write-StageMessage "WhatIf: would install $DisplayName via winget ($Id)."
        return
    }

    Write-StageMessage "Installing $DisplayName ($Id)..."
    Invoke-NativeCommand -ScriptBlock {
        winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
    } -Description "winget install $Id"
}

function Resolve-PowerShellPath {
    $candidates = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'PowerShell executable not found at system paths for OpenSSH default shell.'
}

function Get-TailscaleNetAdapter {
    return Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -ne 'Disabled' -and (
                $_.Name -like 'Tailscale*' -or $_.InterfaceDescription -like '*Tailscale*'
            )
        } |
        Select-Object -First 1
}

function Get-SshInboundAllowRules {
    $rules = @()

    $candidateRules = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue
    foreach ($rule in $candidateRules) {
        $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        if (-not $portFilter) {
            continue
        }

        $localPorts = @($portFilter.LocalPort)
        if ($portFilter.Protocol -ne 'TCP' -or '22' -notin $localPorts) {
            continue
        }

        $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        $interfaceFilter = Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue

        $rules += [PSCustomObject]@{
            Rule              = $rule
            RemoteAddress     = $addressFilter.RemoteAddress
            InterfaceAlias    = $interfaceFilter.InterfaceAlias
        }
    }

    return $rules
}

function Test-IsAcceptableSshFirewallRule {
    param(
        [Parameter(Mandatory = $true)] $RuleInfo
    )

    # RemoteAddress may come back as an array, and Windows normalises a CIDR to
    # its expanded range on read-back; accept either canonical spelling.
    $acceptableRemotes = @($TailscaleRemoteCidr, $TailscaleRemoteRange)
    # Wrap the whole pipeline in @() — a single result would otherwise unwrap to
    # a scalar string, making $remoteValues[0] the first CHARACTER, not the address.
    $remoteValues = @(@($RuleInfo.RemoteAddress) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
    if ($remoteValues.Count -ne 1 -or $remoteValues[0] -notin $acceptableRemotes) {
        return $false
    }

    $tailscaleAdapter = Get-TailscaleNetAdapter
    if ($tailscaleAdapter) {
        $aliases = @($RuleInfo.InterfaceAlias)
        if ($aliases.Count -eq 0 -or $aliases -contains 'Any' -or $aliases -notcontains $tailscaleAdapter.Name) {
            return $false
        }
    }

    return $true
}

function Disable-NonManagedSshFirewallRules {
    foreach ($ruleInfo in Get-SshInboundAllowRules) {
        if ($ruleInfo.Rule.Name -eq $TailscaleSshRuleName) {
            continue
        }

        $ruleName = $ruleInfo.Rule.Name
        if ($WhatIfPreference) {
            Write-StageMessage "WhatIf: would disable non-managed SSH firewall rule $ruleName."
            continue
        }

        Write-StageMessage "Disabling non-managed SSH firewall rule $ruleName..."
        Disable-NetFirewallRule -Name $ruleName | Out-Null
    }
}

function Get-ManagedSshFirewallRuleInfo {
    $rule = Get-NetFirewallRule -Name $TailscaleSshRuleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        return $null
    }

    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    $interfaceFilter = Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        Rule           = $rule
        RemoteAddress  = $addressFilter.RemoteAddress
        InterfaceAlias = $interfaceFilter.InterfaceAlias
    }
}

function Set-ManagedSshFirewallRuleFilters {
    param(
        [Parameter(Mandatory = $true)] $Rule
    )

    Set-NetFirewallRule -Name $TailscaleSshRuleName `
        -Enabled True `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 22 | Out-Null
    Set-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule -RemoteAddress $TailscaleRemoteCidr | Out-Null

    $tailscaleAdapter = Get-TailscaleNetAdapter
    if ($tailscaleAdapter) {
        Set-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $Rule -InterfaceAlias $tailscaleAdapter.Name | Out-Null
    }
}

function Ensure-TailscaleScopedSshFirewallRule {
    $existingRule = Get-NetFirewallRule -Name $TailscaleSshRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        if ($WhatIfPreference) {
            Write-StageMessage "WhatIf: would reconcile firewall rule $TailscaleSshRuleName."
            return
        }

        Write-StageMessage "Reconciling existing Tailscale-scoped SSH firewall rule..."
        try {
            Set-ManagedSshFirewallRuleFilters -Rule $existingRule
        }
        catch {
            Write-StageMessage "Managed SSH firewall rule could not be updated; recreating..."
            Remove-NetFirewallRule -Name $TailscaleSshRuleName -ErrorAction SilentlyContinue | Out-Null
            $existingRule = $null
        }
    }

    if ($existingRule) {
        return
    }

    if ($WhatIfPreference) {
        Write-StageMessage "WhatIf: would create firewall rule $TailscaleSshRuleName for $TailscaleRemoteCidr."
        return
    }

    Write-StageMessage "Creating Tailscale-scoped SSH firewall rule ($TailscaleRemoteCidr)..."
    $ruleParams = @{
        Name          = $TailscaleSshRuleName
        DisplayName   = 'OpenSSH Server (sshd) - Tailscale only'
        Enabled       = 'True'
        Direction     = 'Inbound'
        Protocol      = 'TCP'
        Action        = 'Allow'
        LocalPort     = 22
        RemoteAddress = $TailscaleRemoteCidr
    }

    $tailscaleAdapter = Get-TailscaleNetAdapter
    if ($tailscaleAdapter) {
        $ruleParams.InterfaceAlias = $tailscaleAdapter.Name
    }

    New-NetFirewallRule @ruleParams | Out-Null
}

function Assert-ManagedSshFirewallRuleReady {
    if ($WhatIfPreference) {
        return
    }

    $managedRule = Get-ManagedSshFirewallRuleInfo
    if (-not $managedRule) {
        throw 'Managed Tailscale-scoped SSH firewall rule is missing.'
    }

    if ($managedRule.Rule.Enabled -ne 'True') {
        throw 'Managed Tailscale-scoped SSH firewall rule is not enabled.'
    }

    if (-not (Test-IsAcceptableSshFirewallRule -RuleInfo $managedRule)) {
        throw 'Managed Tailscale-scoped SSH firewall rule has incorrect filters.'
    }
}

function Assert-SshFirewallPolicy {
    if ($WhatIfPreference) {
        return
    }

    $allowRules = Get-SshInboundAllowRules

    if ($allowRules.Count -ne 1) {
        throw "Expected exactly one enabled SSH allow rule; found $($allowRules.Count)."
    }

    $managedRule = $allowRules[0]
    if ($managedRule.Rule.Name -ne $TailscaleSshRuleName) {
        throw "Unexpected SSH allow rule name: $($managedRule.Rule.Name)."
    }

    if (-not (Test-IsAcceptableSshFirewallRule -RuleInfo $managedRule)) {
        throw 'Managed SSH allow rule does not match the required Tailscale scope.'
    }
}

function Ensure-OpenSshDefaultShell {
    param(
        [Parameter(Mandatory = $true)][string] $PowerShellPath
    )

    $defaultShellKey = 'HKLM:\SOFTWARE\OpenSSH'

    if (-not (Test-Path $defaultShellKey)) {
        if ($WhatIfPreference) {
            Write-StageMessage "WhatIf: would create $defaultShellKey and set DefaultShell to $PowerShellPath."
            return
        }

        New-Item -Path $defaultShellKey -Force | Out-Null
        New-ItemProperty -Path $defaultShellKey -Name DefaultShell -Value $PowerShellPath -PropertyType String -Force | Out-Null
        return
    }

    $currentShell = (Get-ItemProperty -Path $defaultShellKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
    if ($currentShell -ne $PowerShellPath) {
        if ($WhatIfPreference) {
            Write-StageMessage "WhatIf: would set OpenSSH DefaultShell to $PowerShellPath."
            return
        }

        Set-ItemProperty -Path $defaultShellKey -Name DefaultShell -Value $PowerShellPath
        return
    }

    Write-StageMessage 'OpenSSH DefaultShell already set to PowerShell.'
}

function Ensure-OpenSshServer {
    $capability = Get-WindowsCapability -Online |
        Where-Object { $_.Name -eq 'OpenSSH.Server~~~~0.0.1.0' }

    if (-not $capability) {
        throw 'OpenSSH Server capability not found on this system.'
    }

    if ($capability.State -ne 'Installed') {
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would install OpenSSH Server capability.'
        }
        else {
            Write-StageMessage 'Installing OpenSSH Server...'
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
        }
    }
    else {
        Write-StageMessage 'OpenSSH Server already installed.'
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        throw 'sshd service not found after OpenSSH Server installation.'
    }

    $powerShellPath = Resolve-PowerShellPath
    Ensure-OpenSshDefaultShell -PowerShellPath $powerShellPath

    if ($service.StartType -ne 'Automatic') {
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would set sshd startup type to Automatic.'
        }
        else {
            Set-Service -Name sshd -StartupType Automatic
        }
    }

    try {
        Ensure-TailscaleScopedSshFirewallRule
        Assert-ManagedSshFirewallRuleReady
        Disable-NonManagedSshFirewallRules
        Assert-SshFirewallPolicy
    }
    catch {
        throw "SSH firewall migration failed before disabling existing access: $($_.Exception.Message)"
    }

    if ($service.Status -ne 'Running') {
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would start sshd service.'
        }
        else {
            Write-StageMessage 'Starting sshd service...'
            Start-Service sshd
        }
    }
    else {
        Write-StageMessage 'sshd service already running.'
    }
}

function Get-TailscaleBackendState {
    $statusJson = & tailscale status --json 2>$null
    Assert-LastExitCode -CommandDescription 'tailscale status --json'

    if (-not $statusJson) {
        throw 'tailscale status --json returned no output.'
    }

    try {
        $parsed = $statusJson | ConvertFrom-Json
    }
    catch {
        throw 'tailscale status --json returned invalid JSON.'
    }

    return [string]$parsed.BackendState
}

function Ensure-Tailscale {
    Ensure-WingetPackage -Id 'Tailscale.Tailscale' -DisplayName 'Tailscale'

    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        $candidatePaths = @(
            "$env:ProgramFiles\Tailscale\tailscale.exe",
            "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
        )
        foreach ($path in $candidatePaths) {
            if (Test-Path $path) {
                $env:Path = "$(Split-Path $path);$env:Path"
                break
            }
        }
    }

    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        throw 'tailscale CLI not found after installation.'
    }

    $backendState = $null
    try {
        $backendState = Get-TailscaleBackendState
    }
    catch {
        $backendState = $null
    }

    if ($backendState -eq 'Running') {
        Write-StageMessage 'Tailscale already connected.'
        return
    }

    Write-StageMessage 'Starting Tailscale authentication (browser approval required)...'
    if ($WhatIfPreference) {
        Write-StageMessage 'WhatIf: would run tailscale up and print the auth URL.'
        return
    }

    # `tailscale up` on a fresh node authenticates and connects. On a REUSED
    # node that carries any stale non-default preference (e.g. it was brought
    # up unattended before), `up` aborts with "must mention all non-default
    # flags" and, on Windows, that throw took the whole bootstrap down before
    # OpenSSH was set up. Fall back to `tailscale login`, which authenticates a
    # logged-out node WITHOUT touching its stored preferences (so advertised
    # routes / exit-node settings survive) and without that guardrail. Tailscale
    # runs its own SSH server only on Linux and open-source macOS, never here;
    # OpenSSH provides remote access over the tailnet.
    $connected = $false
    try {
        Invoke-NativeCommand -ScriptBlock { tailscale up } -Description 'tailscale up'
        $connected = $true
    }
    catch {
        Write-StageMessage 'tailscale up could not change the existing configuration; authenticating without resetting preferences...'
    }
    if (-not $connected) {
        Invoke-NativeCommand -ScriptBlock { tailscale login } -Description 'tailscale login'
    }
}

function Resolve-OptionalComponent {
    param([Parameter(Mandatory = $true)][string] $Name)

    switch ($Name.ToLowerInvariant()) {
        'sunshine' {
            return @{
                Id          = 'LizardByte.Sunshine'
                DisplayName = 'Sunshine'
            }
        }
        default {
            throw "Unknown optional component: $Name. Supported values: Sunshine."
        }
    }
}

function Ensure-OptionalComponents {
    $flatWith = @()
    foreach ($item in $With) {
        $flatWith += $item -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    if ($flatWith.Count -eq 0) {
        return
    }

    foreach ($componentName in $flatWith) {
        $resolved = Resolve-OptionalComponent -Name $componentName

        $search = winget search --id $resolved.Id --exact --accept-source-agreements 2>$null
        Assert-LastExitCode -CommandDescription "winget search $($resolved.Id)"
        if (-not $search -or ($search -notmatch [regex]::Escape($resolved.Id))) {
            throw "winget package id not found: $($resolved.Id) ($($resolved.DisplayName))"
        }

        Ensure-WingetPackage -Id $resolved.Id -DisplayName $resolved.DisplayName
    }
}

function Verify-BootstrapState {
    if ($WhatIfPreference) {
        return
    }

    $backendState = Get-TailscaleBackendState
    if ($backendState -ne 'Running') {
        throw "Verification failed: Tailscale backend state is '$backendState' (expected Running)."
    }

    $service = Get-Service -Name sshd -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        throw 'Verification failed: sshd is not running.'
    }

    Assert-SshFirewallPolicy
}

if (-not (Test-IsElevated)) {
    Write-Error 'This script must be run as Administrator. Right-click PowerShell and choose "Run as administrator".'
    exit 1
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required but was not found. Install App Installer from the Microsoft Store.'
}

Write-StageMessage 'Windows bootstrap starting...'

Ensure-Tailscale
Ensure-OpenSshServer
Ensure-WingetPackage -Id 'Python.Python.3.12' -DisplayName 'Python 3.12'
Ensure-OptionalComponents
Verify-BootstrapState

Write-StageMessage ''
Write-StageMessage 'Remote access bootstrap complete.'
Write-StageMessage 'Next: approve Tailscale in the browser if prompted, then tell the operator "done".'
