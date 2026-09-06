# Secretless Windows remote-access bootstrap — stage zero.
# Canonical invocation:
#   irm https://bootstrap.yaronhersh.xyz/windows | iex
#
# Optional components (download first when piping):
#   irm https://bootstrap.yaronhersh.xyz/windows -OutFile bootstrap-windows.ps1
#   .\bootstrap-windows.ps1 -With Jump,Sunshine

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]] $With = @()
)

$ErrorActionPreference = 'Stop'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-StageMessage {
    param([string] $Message)
    Write-Host $Message
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
    winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
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

    if ($service.StartType -ne 'Automatic') {
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would set sshd startup type to Automatic.'
        }
        else {
            Set-Service -Name sshd -StartupType Automatic
        }
    }

    if ($service.Status -ne 'Running') {
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would start sshd service.'
        }
        else {
            Start-Service sshd
        }
    }
    else {
        Write-StageMessage 'sshd service already running.'
    }

    $ruleName = 'OpenSSH-Server-In-TCP'
    $existingRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if (-not $existingRule) {
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would create firewall rule OpenSSH-Server-In-TCP.'
        }
        else {
            New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        }
    }
    else {
        Write-StageMessage 'OpenSSH firewall rule already present.'
    }

    $defaultShellKey = 'HKLM:\SOFTWARE\OpenSSH'
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) {
        $pwshPath = (Get-Command powershell -ErrorAction SilentlyContinue).Source
    }

    if (-not $pwshPath) {
        throw 'PowerShell executable not found for OpenSSH default shell.'
    }

    if (-not (Test-Path $defaultShellKey)) {
        if ($WhatIfPreference) {
            Write-StageMessage "WhatIf: would create $defaultShellKey and set DefaultShell to $pwshPath."
        }
        else {
            New-Item -Path $defaultShellKey -Force | Out-Null
            New-ItemProperty -Path $defaultShellKey -Name DefaultShell -Value $pwshPath -PropertyType String -Force | Out-Null
        }
    }
    else {
        $currentShell = (Get-ItemProperty -Path $defaultShellKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
        if ($currentShell -ne $pwshPath) {
            if ($WhatIfPreference) {
                Write-StageMessage "WhatIf: would set OpenSSH DefaultShell to $pwshPath."
            }
            else {
                Set-ItemProperty -Path $defaultShellKey -Name DefaultShell -Value $pwshPath
            }
        }
        else {
            Write-StageMessage 'OpenSSH DefaultShell already set to PowerShell.'
        }
    }
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

    $statusJson = & tailscale status --json 2>$null
    $connected = $false
    if ($statusJson) {
        try {
            $parsed = $statusJson | ConvertFrom-Json
            $connected = ($parsed.BackendState -eq 'Running')
        }
        catch {
            $connected = $false
        }
    }

    if ($connected) {
        Write-StageMessage 'Tailscale already connected; enabling SSH without reauthentication...'
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would run tailscale set --ssh=true.'
        }
        else {
            & tailscale set --ssh=true
        }
    }
    else {
        Write-StageMessage 'Starting Tailscale authentication (browser approval required)...'
        if ($WhatIfPreference) {
            Write-StageMessage 'WhatIf: would run tailscale up --ssh and print the auth URL.'
        }
        else {
            & tailscale up --ssh
        }
    }
}

function Resolve-OptionalComponent {
    param([Parameter(Mandatory = $true)][string] $Name)

    switch ($Name.ToLowerInvariant()) {
        'jump' {
            return @{
                Id          = '9NBLGGH4Z1SP'
                DisplayName = 'Jump Desktop Connect'
            }
        }
        'sunshine' {
            return @{
                Id          = 'LizardByte.Sunshine'
                DisplayName = 'Sunshine'
            }
        }
        default {
            throw "Unknown optional component: $Name. Supported values: Jump, Sunshine."
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
        if (-not $search -or ($search -notmatch [regex]::Escape($resolved.Id))) {
            throw "winget package id not found: $($resolved.Id) ($($resolved.DisplayName))"
        }

        Ensure-WingetPackage -Id $resolved.Id -DisplayName $resolved.DisplayName
    }
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

Write-StageMessage ''
Write-StageMessage 'Remote access bootstrap complete.'
Write-StageMessage 'Next: approve Tailscale in the browser if prompted, then tell the operator "done".'
