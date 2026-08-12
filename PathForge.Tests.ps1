#Requires -Modules Pester

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot "PathForge.ps1"
    $coreModulePath = Join-Path $PSScriptRoot "PathForge.Core.psm1"
    $manifestPath = Join-Path $PSScriptRoot "pathforge.json"
    Import-Module $coreModulePath -Force
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    $functionNames = @(
        'Get-ValidatedPath', 'Receive-PathDrop', 'Invoke-ConsoleOutputTrim', 'Export-ConsoleOutput',
        'Confirm-RepairDriveHealth', 'Get-VolumeCorruptionHealth', 'Invoke-ForceDelete', 'Invoke-BootTimeDelete',
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

Describe "PathForge.Core module boundary" {
    It "loads reusable operations from the core module" {
        foreach ($commandName in @(
                'Test-SafePath', 'Remove-ItemStandard', 'Get-DriveSmartHealth',
                'Get-PathForgeRepairCommand', 'Get-PathForgeDriveHealth')) {
            (Get-Command $commandName).ModuleName | Should -Be 'PathForge.Core'
        }
    }

    It "keeps extracted core definitions out of the GUI script" {
        $scriptFunctionNames = @($ast.FindAll({
                    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | ForEach-Object Name)

        foreach ($commandName in @(
                'Test-SafePath', 'Get-FileLockProcess', 'Get-VolumeFileSystem',
                'Remove-ItemStandard', 'Get-DriveSmartHealth')) {
            $scriptFunctionNames | Should -Not -Contain $commandName
        }
    }

    It "maps repair operations to reusable native commands" {
        $scan = Get-PathForgeRepairCommand -Operation ChkdskScan -Drive 'D:'
        $full = Get-PathForgeRepairCommand -Operation ChkdskFull -Drive 'D:'
        $sfc = Get-PathForgeRepairCommand -Operation SfcScan

        $scan.FilePath | Should -Be 'chkdsk.exe'
        $scan.Arguments | Should -Be 'D: /scan'
        $full.Arguments | Should -Be 'D: /R /X'
        $sfc.FilePath | Should -Be 'sfc.exe'
        $sfc.Arguments | Should -Be '/scannow'
    }

    It "parses TRIM status output without GUI dependencies" {
        $items = @(ConvertFrom-PathForgeTrimOutput -InputLine @(
                'NTFS DisableDeleteNotify = 0  (Disabled)',
                'ReFS DisableDeleteNotify = 1  (Enabled)'))

        $items.Count | Should -Be 2
        $items[0].FileSystem | Should -Be 'NTFS'
        $items[0].Enabled | Should -BeTrue
        $items[1].Enabled | Should -BeFalse
    }

    It "streams native repair output through callbacks" {
        Mock Get-PathForgeRepairCommand -ModuleName PathForge.Core {
            [PSCustomObject]@{
                Operation        = 'ChkdskScan'
                FilePath         = 'cmd.exe'
                Arguments        = '/d /c "echo 42 percent"'
                ProgressPattern  = '(\d+)\s*percent'
                SuccessExitCodes = @(0)
                StallSeconds     = 0
            }
        }
        $outputLines = New-Object 'System.Collections.Generic.List[string]'
        $progressValues = New-Object 'System.Collections.Generic.List[int]'

        $result = Invoke-PathForgeRepair -Operation ChkdskScan -Drive 'D:' `
            -OutputAction { param($line) $outputLines.Add($line) } `
            -ProgressCallback { param($percent, $display) $null = $display; $progressValues.Add($percent) }

        $result.Success | Should -BeTrue
        $result.Output | Should -Contain '42 percent'
        $outputLines | Should -Contain '42 percent'
        $progressValues | Should -Contain 42
        @(Get-EventSubscriber | Where-Object SourceIdentifier -Like 'PathForge.*').Count | Should -Be 0
        @(Get-Job | Where-Object Name -Like 'PathForge.*').Count | Should -Be 0
    }

    It "supports non-mutating previews for extracted deletion methods" {
        $target = Join-Path $TestDrive 'whatif-delete.txt'
        Set-Content -LiteralPath $target -Value 'keep me'

        $result = Remove-ItemStandard -Path $target -WhatIf

        $result.Success | Should -BeTrue
        $result.Simulated | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It "exposes WhatIf on every exported deletion method" {
        foreach ($commandName in @(
                'Move-ToRecycleBin', 'Remove-ItemStandard', 'Remove-ItemDotNet',
                'Remove-ItemLongPath', 'Remove-ItemShortName', 'Remove-ItemRobocopy',
                'Remove-ItemWMI', 'Remove-ReparsePointSafe', 'Register-BootTimeDelete')) {
            (Get-Command $commandName).Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }
    }

    It "previews recycle-bin and boot-time methods without changing the target" {
        $target = Join-Path $TestDrive 'whatif-fallbacks.txt'
        Set-Content -LiteralPath $target -Value 'keep me too'

        (Move-ToRecycleBin -Path $target -WhatIf).Simulated | Should -BeTrue
        (Register-BootTimeDelete -Path $target -WhatIf).Simulated | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It "aggregates storage diagnostics without WinForms" {
        Mock Get-PathForgePhysicalDisk -ModuleName PathForge.Core { [PSCustomObject]@{FriendlyName = 'Disk A'} }
        Mock Get-PathForgeVolume -ModuleName PathForge.Core { [PSCustomObject]@{DriveLetter = 'C'} }
        Mock Get-PathForgeSmartStatus -ModuleName PathForge.Core {
            [PSCustomObject]@{Success = $true; Items = @([PSCustomObject]@{PredictFailure = $false}); Error = $null }
        }
        Mock Get-PathForgeReliabilityCounter -ModuleName PathForge.Core {
            [PSCustomObject]@{Success = $true; Items = @([PSCustomObject]@{DeviceId = 0}); Error = $null }
        }

        $report = Get-PathForgeDriveHealth

        $report.PhysicalDisks.Count | Should -Be 1
        $report.Volumes.Count | Should -Be 1
        $report.SmartStatuses.Count | Should -Be 1
        $report.ReliabilityCounters.Count | Should -Be 1
        $report.Errors.Count | Should -Be 0
    }

    It "packages the GUI and core module together in the Scoop manifest" {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $expectedFiles = @('PathForge.ps1', 'PathForge.Core.psm1')

        @($manifest.url).Count | Should -Be 2
        @($manifest.hash).Count | Should -Be 2
        for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
            [System.IO.Path]::GetFileName([string]$manifest.url[$index]) | Should -Be $expectedFiles[$index]
            $stream = [System.IO.File]::OpenRead((Join-Path $PSScriptRoot $expectedFiles[$index]))
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try {
                $actualHash = [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
            }
            finally {
                $sha256.Dispose()
                $stream.Dispose()
            }
            $manifest.hash[$index] | Should -Be $actualHash
        }
    }

    It "builds a non-mutating deletion plan with applicable APIs" {
        $targetDirectory = Join-Path $TestDrive 'dry-run-target'
        $childFile = Join-Path $targetDirectory 'child.txt'
        New-Item -Path $targetDirectory -ItemType Directory | Out-Null
        Set-Content -LiteralPath $childFile -Value 'preview me'

        $plan = Get-PathForgeDeletionPlan -Path $targetDirectory -IncludeRecycleBin -TakeOwnership

        $plan.Success | Should -BeTrue
        $plan.IsContainer | Should -BeTrue
        $plan.ItemCount | Should -Be 2
        $plan.TotalBytes | Should -BeGreaterThan 0
        $plan.Methods.Name | Should -Contain 'Take Ownership'
        ($plan.Methods | Where-Object Name -eq 'Recycle Bin').Applicable | Should -BeTrue
        ($plan.Methods | Where-Object Name -eq 'Robocopy Mirror').Applicable | Should -BeTrue
        Test-Path -LiteralPath $childFile | Should -BeTrue
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

Describe "Explorer path drag and drop" {
    It "enables file-drop handlers on the path field" {
        $fileOpsAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-FileOpsPage'
        }, $true) | Select-Object -First 1

        $fileOpsAst.Extent.Text | Should -Match '\$Script:PathTextBox\.AllowDrop\s*=\s*\$true'
        $fileOpsAst.Extent.Text | Should -Match 'Add_DragEnter'
        $fileOpsAst.Extent.Text | Should -Match 'Add_DragDrop'
        $fileOpsAst.Extent.Text | Should -Match 'DragDropEffects\]::Copy'
    }

    It "uses the first safe path from a multi-path drop" {
        $originalPathBox = $Script:PathTextBox
        try {
            $Script:PathTextBox = [PSCustomObject]@{Text = ''}
            $dataObject = [PSCustomObject]@{Paths = @('C:\Temp\first.txt', 'C:\Temp\second.txt')}
            $dataObject | Add-Member -MemberType ScriptMethod -Name GetDataPresent -Value { param($format) return $format -eq 'FileDrop' }
            $dataObject | Add-Member -MemberType ScriptMethod -Name GetData -Value { param($format) $null = $format; return $this.Paths }

            $result = Receive-PathDrop -DataObject $dataObject -TargetTextBox $Script:PathTextBox

            $result | Should -BeTrue
            $Script:PathTextBox.Text | Should -Be 'C:\Temp\first.txt'
        }
        finally {
            $Script:PathTextBox = $originalPathBox
        }
    }

    It "ignores non-file drag payloads without changing the field" {
        $originalPathBox = $Script:PathTextBox
        try {
            $Script:PathTextBox = [PSCustomObject]@{Text = 'C:\Existing.txt'}
            $dataObject = [PSCustomObject]@{}
            $dataObject | Add-Member -MemberType ScriptMethod -Name GetDataPresent -Value { param($format) $null = $format; return $false }

            Receive-PathDrop -DataObject $dataObject -TargetTextBox $Script:PathTextBox | Should -BeFalse
            $Script:PathTextBox.Text | Should -Be 'C:\Existing.txt'
        }
        finally {
            $Script:PathTextBox = $originalPathBox
        }
    }
}

Describe "Deletion dry-run GUI wiring" {
    It "passes the dry-run selection into force deletion" {
        $fileOpsAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-FileOpsPage'
        }, $true) | Select-Object -First 1

        $fileOpsAst.Extent.Text | Should -Match '\$Script:DryRunCheck\.Text\s*=\s*"Dry-run only'
        $fileOpsAst.Extent.Text | Should -Match 'Invoke-ForceDelete[^\r\n]+-DryRun:\$Script:DryRunCheck\.Checked'
        $fileOpsAst.Extent.Text | Should -Match 'Invoke-BootTimeDelete[^\r\n]+-DryRun:\$Script:DryRunCheck\.Checked'
    }

    It "returns before lock discovery or mutation in dry-run mode" {
        $forceDeleteAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Invoke-ForceDelete'
        }, $true) | Select-Object -First 1
        $functionText = $forceDeleteAst.Extent.Text

        $functionText.IndexOf('if ($DryRun)') | Should -BeGreaterThan -1
        $functionText.IndexOf('if ($DryRun)') | Should -BeLessThan $functionText.IndexOf('Get-FileLockProcess')
        $functionText | Should -Match 'Get-PathForgeDeletionPlan'
        $functionText | Should -Match 'No files will be changed or deleted'
    }

    It "generates a plan without querying locks or changing the target" {
        $target = Join-Path $TestDrive 'gui-dry-run.txt'
        Set-Content -LiteralPath $target -Value 'preserve this file'
        $originalRecycleCheck = $Script:RecycleBinCheck
        try {
            $Script:RecycleBinCheck = [PSCustomObject]@{Checked = $true}
            Mock Write-Console
            Mock Write-Log
            Mock Set-Status
            Mock Get-FileLockProcess { throw 'lock discovery must not run during dry-run' }
            Mock Move-ToRecycleBin { throw 'recycle bin must not run during dry-run' }
            Mock Remove-ItemStandard { throw 'deletion must not run during dry-run' }

            Invoke-ForceDelete -Path $target -TakeOwnership -DryRun | Should -BeTrue

            Test-Path -LiteralPath $target | Should -BeTrue
            Should -Invoke Get-FileLockProcess -Times 0
            Should -Invoke Move-ToRecycleBin -Times 0
            Should -Invoke Remove-ItemStandard -Times 0
        }
        finally {
            $Script:RecycleBinCheck = $originalRecycleCheck
        }
    }

    It "previews boot-time scheduling without calling MoveFileEx or the registry" {
        $target = Join-Path $TestDrive 'boot-dry-run.txt'
        Set-Content -LiteralPath $target -Value 'preserve boot target'
        Mock Write-Console
        Mock Write-Log
        Mock Set-Status
        Mock Register-BootTimeDelete { throw 'MoveFileEx must not run during dry-run' }
        Mock Set-ItemProperty { throw 'registry must not change during dry-run' }

        Invoke-BootTimeDelete -Path $target -DryRun | Should -BeTrue

        Test-Path -LiteralPath $target | Should -BeTrue
        Should -Invoke Register-BootTimeDelete -Times 0
        Should -Invoke Set-ItemProperty -Times 0
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

Describe "Output action layout" {
    It "positions Save, Cancel, and Clear from the laid-out output panel width" {
        $mainFormAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-MainForm'
        }, $true) | Select-Object -First 1

        $mainFormAst.Extent.Text | Should -Match '\$rightEdge\s*=\s*\$outputPanel\.ClientSize\.Width'
        $mainFormAst.Extent.Text | Should -Match '\$saveBtn\.Left\s*=\s*\$cancelBtn\.Left'
        $mainFormAst.Extent.Text | Should -Match 'Add_SizeChanged\(\$positionOutputActions\)'
    }
}

Describe "Export-ConsoleOutput" {
    It "writes the formatted console text to the log directory" {
        $originalBox = $Script:OutputBox
        $originalPath = $Script:Config.LogPath
        try {
            $Script:OutputBox = [PSCustomObject]@{ Text = "first line`r`nsecond line`r`n" }
            $Script:Config.LogPath = Join-Path $TestDrive "console"

            $outputPath = Export-ConsoleOutput

            $outputPath | Should -Match 'Console_\d{8}_\d{6}\.txt$'
            Test-Path -LiteralPath $outputPath | Should -BeTrue
            [System.IO.File]::ReadAllText($outputPath) | Should -Be $Script:OutputBox.Text
        }
        finally {
            $Script:OutputBox = $originalBox
            $Script:Config.LogPath = $originalPath
        }
    }
}

Describe "Remove-ItemRobocopy cleanup" {
    It "removes its empty temp directory when Robocopy throws" {
        $originalTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive "robocopy-temp"
        $target = Join-Path $TestDrive "robocopy-target"
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        Mock robocopy -ModuleName PathForge.Core { throw "simulated Robocopy failure" }

        try {
            $env:TEMP = $tempRoot
            $result = Remove-ItemRobocopy -Path $target

            $result.Success | Should -BeFalse
            @(Get-ChildItem -LiteralPath $tempRoot -Filter 'PathForge_Empty_*').Count | Should -Be 0
        }
        finally {
            $env:TEMP = $originalTemp
        }
    }
}

Describe "Get-DriveSmartHealth" {
    It "maps the selected volume to its physical SMART record" {
        Mock Get-Partition -ModuleName PathForge.Core { [PSCustomObject]@{ DiskNumber = 4 } }
        Mock Get-CimInstance -ModuleName PathForge.Core {
            if ($ClassName -eq 'Win32_DiskDrive') {
                return [PSCustomObject]@{ PNPDeviceID = 'SCSI\DISK&VEN_TEST'; Model = 'Test Disk' }
            }
            return [PSCustomObject]@{
                InstanceName  = 'SCSI\DISK&VEN_TEST_0'
                PredictFailure = $true
                Reason         = 9
            }
        }

        $result = Get-DriveSmartHealth -Drive "D:"

        $result.Available | Should -BeTrue
        $result.PredictFailure | Should -BeTrue
        $result.Reason | Should -Be 9
        $result.DiskName | Should -Be 'Test Disk'
    }
}

Describe "Confirm-RepairDriveHealth" {
    BeforeEach {
        Mock Get-DriveSmartHealth {
            [PSCustomObject]@{ Available = $true; PredictFailure = $true; Reason = 1; DiskName = "Test Disk" }
        }
    }

    It "cancels repair when the user declines the SMART warning" {
        Confirm-RepairDriveHealth -Drive "D:" -Operation "CHKDSK /R" -PromptAction { 7 } | Should -BeFalse
    }

    It "allows an explicit override of the SMART warning" {
        Confirm-RepairDriveHealth -Drive "D:" -Operation "CHKDSK /R" -PromptAction { 6 } | Should -BeTrue
    }
}

Describe "Get-VolumeCorruptionHealth" {
    It "returns and reports the volume corruption count" {
        Mock Get-VolumeCorruptionCount -ModuleName PathForge.Core { [uint32]3 }

        $result = Get-VolumeCorruptionHealth -Drive "C:"

        $result.Available | Should -BeTrue
        $result.CorruptionCount | Should -Be 3
        Should -Invoke Get-VolumeCorruptionCount -ModuleName PathForge.Core -Times 1 -ParameterFilter { $DriveLetter -eq 'C' }
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
