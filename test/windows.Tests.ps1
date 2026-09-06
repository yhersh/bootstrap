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

    It 'documents optional Jump and Sunshine winget ids' {
        $script:ScriptContent | Should -Match 'Jump Desktop Connect'
        $script:ScriptContent | Should -Match 'LizardByte.Sunshine'
        $script:ScriptContent | Should -Match 'winget search'
    }

    It 'installs Tailscale, OpenSSH, and Python 3.12' {
        $script:ScriptContent | Should -Match 'Tailscale.Tailscale'
        $script:ScriptContent | Should -Match 'OpenSSH.Server~~~~0.0.1.0'
        $script:ScriptContent | Should -Match 'Python.Python.3.12'
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
