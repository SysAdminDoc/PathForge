#Requires -Modules Pester

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot "PathForge.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    $functionNames = @(
        'Test-SafePath', 'Get-ValidatedPath', 'Get-VolumeFileSystem',
        'Get-FileLockProcess', 'Invoke-ConsoleOutputTrim',
        'Test-ReparsePoint', 'Remove-ReparsePointSafe',
        'Remove-ItemStandard', 'Remove-ItemDotNet',
        'Initialize-Logging', 'Write-Log', 'Write-Console',
        'Set-Status', 'Set-Progress',
        'Enter-Operation', 'Exit-Operation', 'Stop-ActiveOperation'
    )

    foreach ($funcAst in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($funcAst.Name -in $functionNames) {
            Invoke-Expression $funcAst.Extent.Text
        }
    }

    $hashAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.VariablePath.UserPath -match '^Script:' }, $true)
    foreach ($ha in $hashAsts) {
        try { Invoke-Expression $ha.Extent.Text } catch { }
    }
}

Describe "Test-SafePath" {
    It "Rejects empty path" {
        $result = Test-SafePath -Path ""
        $result.Valid | Should -Be $false
    }

    It "Rejects whitespace-only path" {
        $result = Test-SafePath -Path "   "
        $result.Valid | Should -Be $false
    }

    It "Rejects path with semicolon" {
        $result = Test-SafePath -Path "C:\temp; Remove-Item C:\"
        $result.Valid | Should -Be $false
        $result.Reason | Should -Match "dangerous"
    }

    It "Rejects path with pipe" {
        $result = Test-SafePath -Path "C:\temp | Get-Process"
        $result.Valid | Should -Be $false
    }

    It "Rejects path with dollar-sign subexpression" {
        $result = Test-SafePath -Path 'C:\$(whoami)'
        $result.Valid | Should -Be $false
    }

    It "Rejects path with ampersand" {
        $result = Test-SafePath -Path "C:\temp & calc.exe"
        $result.Valid | Should -Be $false
    }

    It "Accepts valid simple path" {
        $result = Test-SafePath -Path "C:\Windows\System32"
        $result.Valid | Should -Be $true
    }

    It "Accepts path with spaces" {
        $result = Test-SafePath -Path "C:\Program Files\Some App"
        $result.Valid | Should -Be $true
    }

    It "Accepts path with hyphens and dots" {
        $result = Test-SafePath -Path "C:\my-folder\file.name.txt"
        $result.Valid | Should -Be $true
    }

    It "Accepts UNC path" {
        $result = Test-SafePath -Path "\\server\share\folder"
        $result.Valid | Should -Be $true
    }
}

Describe "Test-ReparsePoint" {
    It "Returns false for non-existent path" {
        $result = Test-ReparsePoint -Path "C:\PathForge_NonExistent_$(Get-Random)"
        $result | Should -Be $false
    }

    It "Returns false for regular file" {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            $result = Test-ReparsePoint -Path $tmp
            $result | Should -Be $false
        }
        finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Get-FileLockProcess" {
    It "Returns no lock information for an invalid path" {
        @(Get-FileLockProcess -Path 'C:\bad; Get-Process').Count | Should -Be 0
    }
}

Describe "Invoke-ConsoleOutputTrim" {
    It "Trims old lines and inserts the marker" {
        $originalBox = $Script:OutputBox
        $originalLimit = $Script:MaxOutputChars
        try {
            $fakeBox = [PSCustomObject]@{
                Text            = (("old line`r`n" * 20) + "new line`r`n")
                SelectionStart  = 0
                SelectionLength = 0
            }
            $fakeBox | Add-Member -MemberType ScriptProperty -Name TextLength -Value { $this.Text.Length }
            $fakeBox | Add-Member -MemberType ScriptMethod -Name Select -Value {
                param($start, $length)
                $this.SelectionStart = $start
                $this.SelectionLength = $length
            }
            $fakeBox | Add-Member -MemberType ScriptProperty -Name SelectedText -Value { "" } -SecondValue {
                param($value)
                $before = $this.Text.Substring(0, $this.SelectionStart)
                $after = $this.Text.Substring($this.SelectionStart + $this.SelectionLength)
                $this.Text = $before + $value + $after
            }

            $Script:OutputBox = $fakeBox
            $Script:MaxOutputChars = 80
            Invoke-ConsoleOutputTrim

            $fakeBox.Text | Should -Match '^\[Output trimmed -- oldest entries removed\]'
            $fakeBox.TextLength | Should -BeLessOrEqual $Script:MaxOutputChars
            $fakeBox.Text | Should -Match 'new line'
        }
        finally {
            $Script:OutputBox = $originalBox
            $Script:MaxOutputChars = $originalLimit
        }
    }
}

Describe "Defensive path validation coverage" {
    BeforeAll {
        $source = Get-Content -LiteralPath $scriptPath -Raw
    }

    It "Validates paths before ADS and unblock operations" -ForEach @(
        'Invoke-ADSScanner', 'Remove-AllADS', 'Invoke-UnblockFile', 'Invoke-UnblockRecursive'
    ) {
        $functionAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq $_
        }, $true) | Select-Object -First 1

        $functionAst | Should -Not -BeNullOrEmpty
        $functionAst.Extent.Text | Should -Match 'Test-SafePath\s+-Path\s+\$Path'
    }
}

Describe "Active operation form-close safety" {
    It "prompts before closing and can cancel the close" {
        $mainFormAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-MainForm'
        }, $true) | Select-Object -First 1

        $mainFormAst.Extent.Text | Should -Match 'Add_FormClosing'
        $mainFormAst.Extent.Text | Should -Match 'An operation is running\. Cancel it and close\?'
        $mainFormAst.Extent.Text | Should -Match 'Stop-ActiveOperation'
        $mainFormAst.Extent.Text | Should -Match '\$closingEvent\.Cancel\s*=\s*\$true'
    }
}

Describe "Initialize-Logging" {
    It "Creates log directory and log file" {
        $testPath = Join-Path $env:TEMP "PathForge_Test_$(Get-Random)"
        $originalPath = $Script:Config.LogPath
        try {
            $Script:Config.LogPath = $testPath
            Initialize-Logging
            Test-Path $testPath | Should -Be $true
            $Script:LogFile | Should -Not -BeNullOrEmpty
        }
        finally {
            $Script:Config.LogPath = $originalPath
            Remove-Item $testPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Write-Log" {
    It "Writes a log entry to the log file" {
        $testPath = Join-Path $env:TEMP "PathForge_LogTest_$(Get-Random)"
        $originalPath = $Script:Config.LogPath
        try {
            $Script:Config.LogPath = $testPath
            Initialize-Logging
            Write-Log -Message "Test message" -Level "INFO"
            $content = Get-Content $Script:LogFile -Raw
            $content | Should -Match "Test message"
            $content | Should -Match "\[INFO\]"
        }
        finally {
            $Script:Config.LogPath = $originalPath
            Remove-Item $testPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Enter-Operation / Exit-Operation" {
    BeforeEach {
        $Script:OperationRunning = $false
    }

    It "Enter-Operation returns true when idle" {
        Enter-Operation "Test" | Should -Be $true
        $Script:OperationRunning | Should -Be $true
    }

    It "Enter-Operation returns false when busy" {
        $Script:OperationRunning = $true
        Enter-Operation "Test" | Should -Be $false
    }

    It "Exit-Operation clears running flag" {
        $Script:OperationRunning = $true
        Exit-Operation
        $Script:OperationRunning | Should -Be $false
    }
}

Describe "Remove-ItemStandard" {
    It "Deletes a temp file" {
        $tmp = Join-Path $env:TEMP "PathForge_DeleteTest_$(Get-Random).txt"
        Set-Content -Path $tmp -Value "test"
        $result = Remove-ItemStandard -Path $tmp
        $result.Success | Should -Be $true
        Test-Path $tmp | Should -Be $false
    }

    It "Fails on non-existent path" {
        $result = Remove-ItemStandard -Path "C:\PathForge_NonExistent_$(Get-Random).txt"
        $result.Success | Should -Be $false
    }
}

Describe "Remove-ItemDotNet" {
    It "Deletes a temp file via .NET" {
        $tmp = Join-Path $env:TEMP "PathForge_DotNetTest_$(Get-Random).txt"
        Set-Content -Path $tmp -Value "test"
        $result = Remove-ItemDotNet -Path $tmp
        $result.Success | Should -Be $true
        Test-Path $tmp | Should -Be $false
    }
}

Describe "Get-VolumeFileSystem" {
    It "Returns NTFS for C: drive" {
        $fs = Get-VolumeFileSystem -Path "C:\Windows"
        $fs | Should -Be "NTFS"
    }

    It "Returns Unknown for UNC paths" {
        $fs = Get-VolumeFileSystem -Path "\\server\share\folder"
        $fs | Should -Be "Unknown"
    }

    It "Returns Unknown for empty path" {
        $fs = Get-VolumeFileSystem -Path ""
        $fs | Should -Be "Unknown"
    }

    It "Returns Unknown for invalid drive letter" {
        $fs = Get-VolumeFileSystem -Path "9:\invalid"
        $fs | Should -Be "Unknown"
    }
}

Describe "Test-SafePath edge cases" {
    It "Rejects path with parentheses" {
        $result = Test-SafePath -Path 'C:\test$(calc)'
        $result.Valid | Should -Be $false
    }

    It "Accepts path with square brackets" {
        $result = Test-SafePath -Path "C:\test[1]\file.txt"
        $result.Valid | Should -Be $true
    }

    It "Accepts root drive path" {
        $result = Test-SafePath -Path "C:\"
        $result.Valid | Should -Be $true
    }
}
