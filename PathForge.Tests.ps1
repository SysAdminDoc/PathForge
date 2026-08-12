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
        'Invoke-DeletionBatch', 'Invoke-QuarantinePath', 'Invoke-QuarantineStartupMaintenance',
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
                'Get-PathForgeRepairCommand', 'Get-PathForgeDriveHealth',
                'Get-PathForgePendingFileQueue', 'Remove-PathForgePendingFileOperation',
                'Get-PathForgeLinkInfo', 'Find-PathForgeReparsePoint', 'Remove-PathForgeLinkSafe',
                'Get-PathForgeQuarantineItem', 'Move-PathForgeToQuarantine',
                'Restore-PathForgeQuarantineItem', 'Remove-PathForgeQuarantineItem',
                'Invoke-PathForgeQuarantineMaintenance')) {
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
                'Remove-ItemWMI', 'Remove-ReparsePointSafe', 'Register-BootTimeDelete',
                'Move-PathForgeToQuarantine', 'Restore-PathForgeQuarantineItem',
                'Remove-PathForgeQuarantineItem', 'Invoke-PathForgeQuarantineMaintenance')) {
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

    It "imports CSV batch rows with canonical methods and validation" {
        $batchPath = Join-Path $TestDrive 'delete-batch.csv'
        @(
            'Path,Method,DryRun',
            'C:\Temp\one.txt,dotnet,true',
            'C:\Temp\two.txt,boot,false',
            'C:\Temp\three.txt,unsupported,false'
        ) | Set-Content -LiteralPath $batchPath

        $records = @(Import-PathForgeDeletionBatch -Path $batchPath)

        $records.Count | Should -Be 3
        $records[0].Method | Should -Be 'DotNet'
        $records[0].DryRun | Should -BeTrue
        $records[1].Method | Should -Be 'BootTime'
        $records[2].Valid | Should -BeFalse
        $records[2].Error | Should -Match 'Unsupported deletion method'
    }

    It "imports text rows as path, method, and optional dry-run fields" {
        $batchPath = Join-Path $TestDrive 'delete-batch.txt'
        @(
            '# PathForge batch',
            'C:\Temp\one.txt|powershell|yes',
            'C:\Temp\two.txt'
        ) | Set-Content -LiteralPath $batchPath

        $records = @(Import-PathForgeDeletionBatch -Path $batchPath)

        $records.Count | Should -Be 2
        $records[0].Method | Should -Be 'Standard'
        $records[0].DryRun | Should -BeTrue
        $records[1].Method | Should -Be 'Auto'
        $records[1].DryRun | Should -BeFalse
    }

    It "honors the selected batch method in dry-run and live modes" {
        $previewTarget = Join-Path $TestDrive 'batch-preview.txt'
        $liveTarget = Join-Path $TestDrive 'batch-live.txt'
        Set-Content -LiteralPath $previewTarget -Value 'preview'
        Set-Content -LiteralPath $liveTarget -Value 'delete in test drive'

        $preview = Invoke-PathForgeDeletionMethod -Path $previewTarget -Method DotNet -WhatIf
        $live = Invoke-PathForgeDeletionMethod -Path $liveTarget -Method Standard -Confirm:$false

        $preview.Simulated | Should -BeTrue
        Test-Path -LiteralPath $previewTarget | Should -BeTrue
        $live.Success | Should -BeTrue
        Test-Path -LiteralPath $liveTarget | Should -BeFalse
    }

    It "imports and previews the quarantine batch method" {
        $batchPath = Join-Path $TestDrive 'quarantine-batch.csv'
        $target = Join-Path $TestDrive 'quarantine-batch-target.txt'
        Set-Content -LiteralPath $target -Value 'keep in preview'
        @('Path,Method,DryRun', "`"$target`",quarantine,true") | Set-Content -LiteralPath $batchPath

        $record = @(Import-PathForgeDeletionBatch -Path $batchPath)[0]
        $preview = Invoke-PathForgeDeletionMethod -Path $target -Method $record.Method -WhatIf

        $record.Valid | Should -BeTrue
        $record.Method | Should -Be 'Quarantine'
        $preview.Success | Should -BeTrue
        $preview.Simulated | Should -BeTrue
        $preview.EffectiveMethod | Should -Be 'Quarantine'
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It "quarantines and restores a file from its recovery manifest" {
        $root = Join-Path $TestDrive 'quarantine-zone'
        $target = Join-Path $TestDrive 'quarantine-me.txt'
        Set-Content -LiteralPath $target -Value 'recoverable content'

        $move = Move-PathForgeToQuarantine -Path $target -RootPath $root -RetentionDays 14 -Confirm:$false
        $items = @(Get-PathForgeQuarantineItem -RootPath $root -RetentionDays 14)
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $move.EntryPath 'manifest.json') | ConvertFrom-Json

        $move.Success | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeFalse
        $items.Count | Should -Be 1
        $items[0].OriginalPath | Should -Be $target
        $items[0].PurgeAfterUtc | Should -BeGreaterThan $items[0].QuarantinedAtUtc
        $manifest.State | Should -Be 'Quarantined'
        Get-Content -LiteralPath $items[0].PayloadPath | Should -Be 'recoverable content'

        $restore = Restore-PathForgeQuarantineItem -Id $move.Id -RootPath $root -Confirm:$false

        $restore.Success | Should -BeTrue
        Get-Content -LiteralPath $target | Should -Be 'recoverable content'
        Test-Path -LiteralPath $move.EntryPath | Should -BeFalse
    }

    It "keeps a quarantine preview free of filesystem side effects" {
        $root = Join-Path $TestDrive 'preview-zone'
        $target = Join-Path $TestDrive 'preview-quarantine.txt'
        Set-Content -LiteralPath $target -Value 'stay here'

        $result = Move-PathForgeToQuarantine -Path $target -RootPath $root -RetentionDays 30 -WhatIf

        $result.Success | Should -BeTrue
        $result.Simulated | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeTrue
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It "auto-purges items after the configured retention window" {
        $root = Join-Path $TestDrive 'expiry-zone'
        $target = Join-Path $TestDrive 'expire-me.txt'
        Set-Content -LiteralPath $target -Value 'expired content'
        $move = Move-PathForgeToQuarantine -Path $target -RootPath $root -RetentionDays 30 -Confirm:$false

        $result = Invoke-PathForgeQuarantineMaintenance -RootPath $root -RetentionDays 1 `
            -Now ([DateTimeOffset]::UtcNow.AddDays(2)) -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Purged | Should -Be 1
        Test-Path -LiteralPath $move.EntryPath | Should -BeFalse
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It "purges a quarantined tree without traversing nested junctions" {
        $root = Join-Path $TestDrive 'junction-quarantine-zone'
        $outsideTarget = Join-Path $TestDrive 'outside-quarantine-target'
        $sourceDirectory = Join-Path $TestDrive 'directory-with-junction'
        $junctionPath = Join-Path $sourceDirectory 'outside-link'
        New-Item -ItemType Directory -Path $outsideTarget, $sourceDirectory | Out-Null
        Set-Content -LiteralPath (Join-Path $outsideTarget 'keep.txt') -Value 'must survive purge'
        New-Item -ItemType Junction -Path $junctionPath -Target $outsideTarget | Out-Null

        $move = Move-PathForgeToQuarantine -Path $sourceDirectory -RootPath $root -RetentionDays 30 -Confirm:$false
        $purge = Remove-PathForgeQuarantineItem -Id $move.Id -RootPath $root -Confirm:$false

        $move.Success | Should -BeTrue
        $purge.Success | Should -BeTrue
        Test-Path -LiteralPath $move.EntryPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outsideTarget 'keep.txt') | Should -BeTrue
    }

    It "refuses to quarantine a reparse point" {
        $root = Join-Path $TestDrive 'reparse-refusal-zone'
        $outsideTarget = Join-Path $TestDrive 'reparse-refusal-target'
        $junctionPath = Join-Path $TestDrive 'reparse-refusal-link'
        New-Item -ItemType Directory -Path $outsideTarget | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $outsideTarget | Out-Null

        $result = Move-PathForgeToQuarantine -Path $junctionPath -RootPath $root -RetentionDays 30 -Confirm:$false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'Reparse points cannot be quarantined'
        Test-Path -LiteralPath $junctionPath | Should -BeTrue
        Test-Path -LiteralPath $outsideTarget | Should -BeTrue
    }

    It "treats a quarantine record replaced by a junction as invalid" {
        $root = Join-Path $TestDrive 'tampered-quarantine-zone'
        $outsideTarget = Join-Path $TestDrive 'tampered-record-target'
        $id = '0123456789abcdef0123456789abcdef'
        $entryPath = Join-Path $root $id
        New-Item -ItemType Directory -Path $root, $outsideTarget | Out-Null
        Set-Content -LiteralPath (Join-Path $outsideTarget 'keep.txt') -Value 'never traverse tampered record'
        New-Item -ItemType Junction -Path $entryPath -Target $outsideTarget | Out-Null

        $items = @(Get-PathForgeQuarantineItem -RootPath $root -RetentionDays 30)
        $purge = Remove-PathForgeQuarantineItem -Id $id -RootPath $root -Confirm:$false

        $items.Count | Should -Be 1
        $items[0].Valid | Should -BeFalse
        $items[0].Error | Should -Match 'cannot be a reparse point'
        $purge.Success | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outsideTarget 'keep.txt') | Should -BeTrue
    }

    It "persists retention policy updates and fails closed on corruption" {
        $policyPath = Join-Path $TestDrive 'quarantine-policy.json'
        $first = Set-PathForgeQuarantinePolicy -RetentionDays 45 -ConfigPath $policyPath -Confirm:$false
        $second = Set-PathForgeQuarantinePolicy -RetentionDays 60 -ConfigPath $policyPath -Confirm:$false
        $loaded = Get-PathForgeQuarantinePolicy -ConfigPath $policyPath

        $first.Success | Should -BeTrue
        $second.Success | Should -BeTrue
        $loaded.Success | Should -BeTrue
        $loaded.RetentionDays | Should -Be 60

        Set-Content -LiteralPath $policyPath -Value '{ invalid json'
        $maintenance = Invoke-PathForgeQuarantineMaintenance -ConfigPath $policyPath -Confirm:$false

        $maintenance.Success | Should -BeFalse
        $maintenance.Purged | Should -Be 0
        $maintenance.Errors[0] | Should -Match 'policy is invalid'
    }

    It "parses pending delete, move, replace, and malformed queue entries" {
        $rawValue = @(
            '*1\??\C:\Temp\delete.txt', '',
            '\??\C:\Temp\old.txt', '!\??\C:\Temp\new.txt',
            '\??\C:\Temp\orphan.txt'
        )

        $queue = Get-PathForgePendingFileQueue -RegistryValue $rawValue

        $queue.Success | Should -BeTrue
        $queue.DeleteCount | Should -Be 1
        $queue.MoveCount | Should -Be 1
        $queue.MalformedCount | Should -Be 1
        $queue.Operations[0].Source | Should -Be 'C:\Temp\delete.txt'
        $queue.Operations[0].SourcePrefix | Should -Be '*1'
        $queue.Operations[1].Destination | Should -Be 'C:\Temp\new.txt'
        $queue.Operations[1].ReplaceExisting | Should -BeTrue
        $queue.Operations[2].HasDestination | Should -BeFalse
        $queue.SnapshotHash | Should -Match '^[A-F0-9]{64}$'
    }

    It "removes only selected raw queue pairs and preserves their order" {
        Mock Read-PathForgePendingFileRegistryValue -ModuleName PathForge.Core {
            [PSCustomObject]@{
                Success = $true
                Exists  = $true
                Value   = @(
                    '\??\C:\Temp\delete.txt', '',
                    '\??\C:\Temp\old.txt', '\??\C:\Temp\new.txt',
                    '\??\C:\Temp\keep.txt', ''
                )
                Error   = $null
            }
        }
        Mock Write-PathForgePendingFileRegistryValue -ModuleName PathForge.Core {}
        $snapshot = (Get-PathForgePendingFileQueue).SnapshotHash

        $result = Remove-PathForgePendingFileOperation -Index 1 -ExpectedSnapshotHash $snapshot -Confirm:$false

        $result.Success | Should -BeTrue
        $result.RemovedCount | Should -Be 1
        $result.RemainingCount | Should -Be 2
        Should -Invoke Write-PathForgePendingFileRegistryValue -ModuleName PathForge.Core -Times 1 -ParameterFilter {
            @($Value).Count -eq 4 -and
            $Value[0] -eq '\??\C:\Temp\delete.txt' -and $Value[1] -eq '' -and
            $Value[2] -eq '\??\C:\Temp\keep.txt' -and $Value[3] -eq ''
        }
    }

    It "rejects stale queue edits before writing the registry" {
        Mock Read-PathForgePendingFileRegistryValue -ModuleName PathForge.Core {
            [PSCustomObject]@{Success = $true; Exists = $true; Value = @('\??\C:\Temp\delete.txt', ''); Error = $null }
        }
        Mock Write-PathForgePendingFileRegistryValue -ModuleName PathForge.Core {}

        $result = Remove-PathForgePendingFileOperation -Index 0 -ExpectedSnapshotHash ('0' * 64) -Confirm:$false

        $result.Success | Should -BeFalse
        $result.Conflict | Should -BeTrue
        $result.Error | Should -Match 'changed after it was loaded'
        Should -Invoke Write-PathForgePendingFileRegistryValue -ModuleName PathForge.Core -Times 0
    }

    It "supports a non-mutating queue cancellation preview" {
        Mock Read-PathForgePendingFileRegistryValue -ModuleName PathForge.Core {
            [PSCustomObject]@{Success = $true; Exists = $true; Value = @('\??\C:\Temp\delete.txt', ''); Error = $null }
        }
        Mock Write-PathForgePendingFileRegistryValue -ModuleName PathForge.Core {}

        $result = Remove-PathForgePendingFileOperation -Index 0 -WhatIf

        $result.Success | Should -BeTrue
        $result.Simulated | Should -BeTrue
        Should -Invoke Write-PathForgePendingFileRegistryValue -ModuleName PathForge.Core -Times 0
    }

    It "inspects and removes a hard-link name without deleting shared data" {
        $originalPath = Join-Path $TestDrive 'hardlink-original.txt'
        $linkPath = Join-Path $TestDrive 'hardlink-second-name.txt'
        Set-Content -LiteralPath $originalPath -Value 'shared hard-link content'
        New-Item -ItemType HardLink -Path $linkPath -Target $originalPath | Out-Null

        $info = Get-PathForgeLinkInfo -Path $linkPath

        $info.Success | Should -BeTrue
        $info.Kind | Should -Be 'Hard Link'
        $info.IsReparsePoint | Should -BeFalse
        $info.HardLinkCount | Should -Be 2
        $info.HardLinkPaths | Should -Contain $originalPath
        $info.HardLinkPaths | Should -Contain $linkPath

        $result = Remove-PathForgeLinkSafe -Path $linkPath -Confirm:$false

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $linkPath | Should -BeFalse
        Test-Path -LiteralPath $originalPath | Should -BeTrue
        Get-Content -LiteralPath $originalPath | Should -Be 'shared hard-link content'
    }

    It "inspects and safely removes a junction without traversing its target" {
        $targetPath = Join-Path $TestDrive 'junction-target'
        $scanRoot = Join-Path $TestDrive 'junction-scan'
        $junctionPath = Join-Path $scanRoot 'target-link'
        New-Item -ItemType Directory -Path $targetPath, $scanRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $targetPath 'keep.txt') -Value 'do not traverse'
        New-Item -ItemType Junction -Path $junctionPath -Target $targetPath | Out-Null

        $info = Get-PathForgeLinkInfo -Path $junctionPath
        $report = Find-PathForgeReparsePoint -Path $scanRoot
        $plan = Get-PathForgeDeletionPlan -Path $junctionPath -IncludeRecycleBin
        $recycleResult = Move-ToRecycleBin -Path $junctionPath -Confirm:$false

        $info.Success | Should -BeTrue
        $info.Kind | Should -Be 'Junction'
        $info.ReparseTagHex | Should -Be '0xA0000003'
        $info.Target | Should -Be $targetPath
        $report.Success | Should -BeTrue
        $report.Items.Count | Should -Be 1
        $report.ScannedCount | Should -Be 1
        ($plan.Methods | Where-Object Name -eq 'Recycle Bin').Applicable | Should -BeFalse
        $recycleResult.Success | Should -BeFalse
        $recycleResult.Error | Should -Match 'skipped for reparse points'
        Get-Item -LiteralPath $junctionPath -Force | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $targetPath 'keep.txt') | Should -BeTrue

        $result = Remove-PathForgeLinkSafe -Path $junctionPath -Confirm:$false

        $result.Success | Should -BeTrue
        Get-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $targetPath 'keep.txt') | Should -BeTrue
    }

    It "refuses safe-link deletion for an ordinary file" {
        $regularPath = Join-Path $TestDrive 'ordinary-file.txt'
        Set-Content -LiteralPath $regularPath -Value 'keep ordinary data'

        $result = Remove-PathForgeLinkSafe -Path $regularPath -Confirm:$false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'not a reparse point or a file with multiple hard links'
        Test-Path -LiteralPath $regularPath | Should -BeTrue
    }

    It "previews link-only removal without changing the link or target" {
        $targetPath = Join-Path $TestDrive 'preview-junction-target'
        $junctionPath = Join-Path $TestDrive 'preview-junction'
        New-Item -ItemType Directory -Path $targetPath | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $targetPath | Out-Null

        $result = Remove-PathForgeLinkSafe -Path $junctionPath -WhatIf

        $result.Success | Should -BeTrue
        $result.Simulated | Should -BeTrue
        Get-Item -LiteralPath $junctionPath -Force | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $targetPath | Should -BeTrue
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

Describe "Deletion batch GUI" {
    It "exposes the batch loader from the File Operations page" {
        $fileOpsAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-FileOpsPage'
        }, $true) | Select-Object -First 1

        $fileOpsAst.Extent.Text | Should -Match 'Title "Batch Delete"'
        $fileOpsAst.Extent.Text | Should -Match 'BtnText "Load Batch\.\.\."'
        $fileOpsAst.Extent.Text | Should -Match 'Show-DeletionBatchDialog'
    }

    It "processes a forced dry-run batch without confirmation or mutation" {
        $target = Join-Path $TestDrive 'batch-gui-preview.txt'
        $batchPath = Join-Path $TestDrive 'batch-gui-preview.csv'
        Set-Content -LiteralPath $target -Value 'keep batch target'
        @('Path,Method,DryRun', "`"$target`",Standard,false") | Set-Content -LiteralPath $batchPath
        $originalRecycleCheck = $Script:RecycleBinCheck
        try {
            $Script:RecycleBinCheck = [PSCustomObject]@{Checked = $false}
            Mock Write-Console
            Mock Write-Log
            Mock Set-Status
            Mock Set-Progress

            $summary = Invoke-DeletionBatch -BatchPath $batchPath -ForceDryRun -ConfirmAction { throw 'dry-run batch must not prompt' }

            $summary.Simulated | Should -Be 1
            $summary.Failed | Should -Be 0
            Test-Path -LiteralPath $target | Should -BeTrue
        }
        finally {
            $Script:RecycleBinCheck = $originalRecycleCheck
            $Script:OperationRunning = $false
        }
    }

    It "cancels a mutating batch before processing any row" {
        $target = Join-Path $TestDrive 'batch-gui-cancel.txt'
        $batchPath = Join-Path $TestDrive 'batch-gui-cancel.txtlist'
        Set-Content -LiteralPath $target -Value 'keep cancelled target'
        "$target|Standard|false" | Set-Content -LiteralPath $batchPath
        Mock Write-Console

        $summary = Invoke-DeletionBatch -BatchPath $batchPath -ConfirmAction { 7 }

        $summary.Cancelled | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeTrue
    }
}

Describe "Scheduled deletion queue editor" {
    It "uses the reusable queue API and exposes selective cancellation controls" {
        $queueAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Show-PendingDeletionQueue'
        }, $true) | Select-Object -First 1
        $fileOpsAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-FileOpsPage'
        }, $true) | Select-Object -First 1

        $queueAst.Extent.Text | Should -Match 'DataGridView'
        $queueAst.Extent.Text | Should -Match 'Cancel Selected'
        $queueAst.Extent.Text | Should -Match 'Clear All'
        $queueAst.Extent.Text | Should -Match 'SnapshotHash'
        $fileOpsAst.Extent.Text | Should -Match 'Title "Pending Queue"'
        $fileOpsAst.Extent.Text | Should -Match 'Show-PendingDeletionQueue'
    }

    It "routes boot-time registry fallback through the core module" {
        $bootAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Invoke-BootTimeDelete'
        }, $true) | Select-Object -First 1

        $bootAst.Extent.Text | Should -Match 'Add-PathForgePendingFileDelete'
        $bootAst.Extent.Text | Should -Not -Match 'Set-ItemProperty'
    }
}

Describe "Link inspector and reparse explorer" {
    It "exposes both link tools from the File Operations page" {
        $fileOpsAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-FileOpsPage'
        }, $true) | Select-Object -First 1

        $fileOpsAst.Extent.Text | Should -Match 'Title "Link Inspector"'
        $fileOpsAst.Extent.Text | Should -Match 'BtnText "Inspect Link"'
        $fileOpsAst.Extent.Text | Should -Match 'Show-LinkInspector'
        $fileOpsAst.Extent.Text | Should -Match 'Title "Reparse Explorer"'
        $fileOpsAst.Extent.Text | Should -Match 'BtnText "Scan Links"'
        $fileOpsAst.Extent.Text | Should -Match 'Show-ReparsePointExplorer'
    }

    It "renders native link metadata and link-only deletion safeguards" {
        $inspectorAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Show-LinkInspector'
        }, $true) | Select-Object -First 1
        $explorerAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Show-ReparsePointExplorer'
        }, $true) | Select-Object -First 1

        $inspectorAst.Extent.Text | Should -Match 'Safe Delete Link'
        $inspectorAst.Extent.Text | Should -Match 'Remove-PathForgeLinkSafe'
        $inspectorAst.Extent.Text | Should -Match 'HardLinkNamesList'
        $explorerAst.Extent.Text | Should -Match 'ReparseExplorerGrid'
        $explorerAst.Extent.Text | Should -Match 'Find-PathForgeReparsePoint'
        $explorerAst.Extent.Text | Should -Match 'Export CSV'
    }

    It "checks reparse safety before any recycle or generic deletion attempt" {
        $forceDeleteAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Invoke-ForceDelete'
        }, $true) | Select-Object -First 1
        $functionText = $forceDeleteAst.Extent.Text

        $functionText.IndexOf('if (Test-ReparsePoint') | Should -BeLessThan $functionText.IndexOf('Attempting Recycle Bin')
        $functionText | Should -Match 'Refusing generic deletion of reparse point'
        $functionText | Should -Match 'Link deletion cancelled; no fallback method was run'
    }
}

Describe "Quarantine zone GUI" {
    It "exposes recoverable quarantine management from File Operations" {
        $fileOpsAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Build-FileOpsPage'
        }, $true) | Select-Object -First 1
        $managerAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Show-QuarantineManager'
        }, $true) | Select-Object -First 1

        $fileOpsAst.Extent.Text | Should -Match 'Title "Quarantine Zone"'
        $fileOpsAst.Extent.Text | Should -Match 'BtnText "Open Zone"'
        $fileOpsAst.Extent.Text | Should -Match 'Show-QuarantineManager'
        $managerAst.Extent.Text | Should -Match 'QuarantineGrid'
        $managerAst.Extent.Text | Should -Match 'Quarantine Current'
        $managerAst.Extent.Text | Should -Match 'Restore Selected'
        $managerAst.Extent.Text | Should -Match 'Purge Selected'
        $managerAst.Extent.Text | Should -Match 'Purge Expired'
        $managerAst.Extent.Text | Should -Match 'QuarantineRetentionDays'
        $managerAst.Extent.Text | Should -Match 'Set-PathForgeQuarantinePolicy'
    }

    It "runs retention maintenance when the application is shown" {
        $startAst = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Start-Application'
        }, $true) | Select-Object -First 1

        $startAst.Extent.Text | Should -Match 'Add_Shown'
        $startAst.Extent.Text | Should -Match 'Invoke-QuarantineStartupMaintenance'
    }

    It "previews a quarantine move without prompting or mutating" {
        $target = Join-Path $TestDrive 'gui-quarantine-preview.txt'
        Set-Content -LiteralPath $target -Value 'preserve GUI preview'
        Mock Write-Console
        Mock Move-PathForgeToQuarantine {
            [PSCustomObject]@{
                Success = $true
                Simulated = $true
                RootPath = (Join-Path $TestDrive 'preview-root')
                PurgeAfterUtc = [DateTimeOffset]::UtcNow.AddDays(30)
                Error = $null
            }
        }

        $result = Invoke-QuarantinePath -Path $target -DryRun

        $result.Success | Should -BeTrue
        $result.Simulated | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeTrue
        Should -Invoke Move-PathForgeToQuarantine -Times 1 -ParameterFilter { $WhatIf }
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
