BeforeAll {
    $script:ProjectRoot = Split-Path $PSScriptRoot -Parent
    $script:BootstrapScript = Join-Path $script:ProjectRoot 'scripts/windows.ps1'
    $script:ScriptContent = Get-Content -Raw $script:BootstrapScript
}

Describe 'windows.ps1 static guarantees' {
    It 'requires elevation' {
        $script:ScriptContent | Should -Match 'Test-IsElevated'
        $script:ScriptContent | Should -Match 'Run as administrator'
    }

    It 'supports -WhatIf via SupportsShouldProcess' {
        $script:ScriptContent | Should -Match 'SupportsShouldProcess'
        $script:ScriptContent | Should -Match 'WhatIfPreference'
    }

    It 'documents optional Sunshine winget id and asserts package identity' {
        $script:ScriptContent | Should -Match "Id\s*=\s*'LizardByte\.Sunshine'"
        $script:ScriptContent | Should -Match "DisplayName\s*=\s*'Sunshine'"
        $script:ScriptContent | Should -Match 'winget search'
        $script:ScriptContent | Should -Not -Match 'Jump Desktop Connect'
        $script:ScriptContent | Should -Not -Match '9NBLGGH4Z1SP'
    }

    It 'installs Tailscale, OpenSSH, and Python 3.12' {
        $script:ScriptContent | Should -Match 'Tailscale.Tailscale'
        $script:ScriptContent | Should -Match 'OpenSSH.Server~~~~0.0.1.0'
        $script:ScriptContent | Should -Match 'Python.Python.3.12'
    }

    It 'uses OpenSSH over the tailnet instead of Tailscale SSH' {
        $script:ScriptContent | Should -Match 'tailscale up'
        $script:ScriptContent | Should -Not -Match '--ssh'
    }

    It 'restricts SSH firewall access to the Tailscale CIDR' {
        $script:ScriptContent | Should -Match '100\.64\.0\.0/10'
        $script:ScriptContent | Should -Match 'Assert-SshFirewallPolicy'
        $script:ScriptContent | Should -Match 'Disable-NonManagedSshFirewallRules'
        $script:ScriptContent | Should -Match 'Assert-ManagedSshFirewallRuleReady'
    }

    It 'resolves PowerShell from fixed system paths' {
        $script:ScriptContent | Should -Match '\$env:ProgramFiles\\PowerShell\\7\\pwsh\.exe'
        $script:ScriptContent | Should -Match '\$env:SystemRoot\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'
        $script:ScriptContent | Should -Not -Match 'Get-Command pwsh'
    }

    It 'checks native command exit codes and verifies final state' {
        $script:ScriptContent | Should -Match '\$PSNativeCommandUseErrorActionPreference = \$true'
        $script:ScriptContent | Should -Match 'Assert-LastExitCode'
        $script:ScriptContent | Should -Match 'Verify-BootstrapState'
    }

    It 'sets ErrorActionPreference to Stop' {
        $script:ScriptContent | Should -Match "\`$ErrorActionPreference = 'Stop'"
    }

    It 'never embeds credentials' {
        $script:ScriptContent | Should -Not -Match 'authkey'
        $script:ScriptContent | Should -Not -Match 'tskey-'
        $script:ScriptContent | Should -Not -Match 'password\s*='
    }
}

Describe 'windows.ps1 syntax' {
    It 'parses without syntax errors' {
        { [scriptblock]::Create($script:ScriptContent) } | Should -Not -Throw
    }
}
