# PathForge reusable deletion, repair, and diagnostic operations.

Add-Type -AssemblyName Microsoft.VisualBasic

$Script:PathForgeSessionManagerRegistryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager'
$Script:PathForgePendingFileValueName = 'PendingFileRenameOperations'

if (-not ('PathForgeBootDeleteNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class PathForgeBootDeleteNative {
    private const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool MoveFileEx(string existingPath, string newPath, int flags);

    public static bool ScheduleDelete(string path) {
        return MoveFileEx(path, null, MOVEFILE_DELAY_UNTIL_REBOOT);
    }
}
"@
}

if (-not ('PathForgeRestartManagerNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PathForgeRestartManagerNative {
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public uint ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint sessionHandle, int sessionFlags, string sessionKey);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(
        uint sessionHandle,
        uint fileCount,
        string[] fileNames,
        uint applicationCount,
        RM_UNIQUE_PROCESS[] applications,
        uint serviceCount,
        string[] serviceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(
        uint sessionHandle,
        out uint processInfoNeeded,
        ref uint processInfoCount,
        [In, Out] RM_PROCESS_INFO[] affectedApplications,
        ref uint rebootReasons);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint sessionHandle);

    public static RM_PROCESS_INFO[] GetLockingProcesses(string path) {
        if (String.IsNullOrEmpty(path)) {
            return new RM_PROCESS_INFO[0];
        }

        uint sessionHandle;
        int result = RmStartSession(out sessionHandle, 0, Guid.NewGuid().ToString("N"));
        if (result != ERROR_SUCCESS) {
            throw new InvalidOperationException("RmStartSession failed with code " + result);
        }

        try {
            result = RmRegisterResources(sessionHandle, 1, new string[] { path }, 0, null, 0, null);
            if (result != ERROR_SUCCESS) {
                throw new InvalidOperationException("RmRegisterResources failed with code " + result);
            }

            uint needed;
            uint count = 0;
            uint rebootReasons = 0;
            result = RmGetList(sessionHandle, out needed, ref count, null, ref rebootReasons);
            if (result != ERROR_SUCCESS && result != ERROR_MORE_DATA) {
                throw new InvalidOperationException("RmGetList failed with code " + result);
            }
            if (needed == 0) {
                return new RM_PROCESS_INFO[0];
            }

            RM_PROCESS_INFO[] affected = new RM_PROCESS_INFO[needed];
            count = needed;
            result = RmGetList(sessionHandle, out needed, ref count, affected, ref rebootReasons);
            if (result != ERROR_SUCCESS) {
                throw new InvalidOperationException("RmGetList failed with code " + result);
            }

            var processes = new List<RM_PROCESS_INFO>();
            for (int index = 0; index < count; index++) {
                processes.Add(affected[index]);
            }
            return processes.ToArray();
        }
        finally {
            RmEndSession(sessionHandle);
        }
    }
}
"@
}

function Test-SafePath {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{Valid = $false; Reason = "Path is empty" }
    }
    if ($Path -match '[;|&`$\(\)]') {
        return @{Valid = $false; Reason = "Path contains dangerous characters: ; | & ` $ ( )" }
    }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        return @{Valid = $true; Resolved = $resolved }
    }
    catch {
        return @{Valid = $false; Reason = "Invalid path format: $($_.Exception.Message)" }
    }
}

function Get-FileLockProcess {
    [CmdletBinding()]
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return @()
    }

    try {
        $processes = @([PathForgeRestartManagerNative]::GetLockingProcesses($Path))
    }
    catch {
        Write-Verbose "Restart Manager query failed for ${Path}: $_"
        return @()
    }

    foreach ($process in $processes) {
        $processId = [int]$process.Process.dwProcessId
        if ($processId -le 0 -or $processId -eq $PID) {
            continue
        }

        $processName = $process.strAppName
        if ([string]::IsNullOrWhiteSpace($processName)) {
            try {
                $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName
            }
            catch {
                $processName = "Unknown process"
            }
        }

        [PSCustomObject]@{
            ProcessName = $processName
            ProcessId   = $processId
            ServiceName = $process.strServiceShortName
        }
    }
}

function Get-VolumeFileSystem {
    [CmdletBinding()]
    param([string]$Path)

    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root -or $root.StartsWith('\\')) { return "Unknown" }
        $letter = $root.TrimEnd('\', ':')
        if ($letter.Length -ne 1 -or $letter -notmatch '[A-Za-z]') { return "Unknown" }
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($volume) { return $volume.FileSystem }
    }
    catch {
        Write-Verbose "Volume filesystem query failed for ${Path}: $_"
    }
    return "Unknown"
}

function Move-ToRecycleBin {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Move to the Recycle Bin')) {
        return @{Success = $true; Method = 'WhatIf: Recycle Bin'; Simulated = $true }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        return @{Success = $true; Method = "Recycle Bin" }
    }
    catch {
        return @{Success = $false; Error = $_.Exception.Message }
    }
}

function Remove-ItemStandard {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete with Remove-Item')) {
        return @{Success = $true; Method = 'WhatIf: Standard PowerShell'; Simulated = $true }
    }

    try {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
        return @{Success = $true; Method = "Standard PowerShell" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemDotNet {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete with System.IO')) {
        return @{Success = $true; Method = 'WhatIf: .NET Framework'; Simulated = $true }
    }

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [System.IO.Directory]::Delete($Path, $true)
        }
        else {
            [System.IO.File]::Delete($Path)
        }
        return @{Success = $true; Method = ".NET Framework" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemLongPath {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete through the long-path API')) {
        return @{Success = $true; Method = 'WhatIf: Long Path'; Simulated = $true }
    }

    try {
        $longPath = "\\?\$Path"
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $null = Start-Process -FilePath "cmd.exe" -ArgumentList '/c', "rd /s /q `"$longPath`"" -NoNewWindow -Wait -PassThru 2>$null
        }
        else {
            $null = Start-Process -FilePath "cmd.exe" -ArgumentList '/c', "del /f /q `"$longPath`"" -NoNewWindow -Wait -PassThru 2>$null
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return @{Success = $true; Method = "Long Path (\\?\)" }
        }
        return @{Success = $false; Error = "Path still exists" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemShortName {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete through the 8.3 short name')) {
        return @{Success = $true; Method = 'WhatIf: 8.3 Short Name'; Simulated = $true }
    }

    $fileSystemObject = $null
    try {
        $fileSystemObject = New-Object -ComObject Scripting.FileSystemObject
        $shortPath = if (Test-Path -LiteralPath $Path -PathType Container) {
            $fileSystemObject.GetFolder($Path).ShortPath
        }
        else {
            $fileSystemObject.GetFile($Path).ShortPath
        }

        if ($shortPath -and $shortPath -ne $Path) {
            Remove-Item -LiteralPath $shortPath -Force -Recurse -ErrorAction Stop
            return @{Success = $true; Method = "8.3 Short Name" }
        }
        return @{Success = $false; Error = "No short name available" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
    finally {
        if ($fileSystemObject) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fileSystemObject) | Out-Null
        }
    }
}

function Remove-ItemRobocopy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path,
        [scriptblock]$ProgressCallback
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Mirror an empty directory and remove the target')) {
        return @{Success = $true; Method = 'WhatIf: Robocopy Mirror'; Simulated = $true }
    }

    $emptyDirectory = $null
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            return @{Success = $false; Error = "Robocopy only works on directories" }
        }
        $emptyDirectory = Join-Path $env:TEMP "PathForge_Empty_$(Get-Random)"
        New-Item -Path $emptyDirectory -ItemType Directory -Force | Out-Null

        if ($ProgressCallback) {
            $null = & $ProgressCallback "Robocopy: Mirroring empty folder over target..."
        }
        $null = robocopy $emptyDirectory $Path /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS 2>&1
        $null = Start-Process -FilePath "cmd.exe" -ArgumentList '/c', "rd /s /q `"$Path`"" -NoNewWindow -Wait -PassThru 2>$null

        if (-not (Test-Path -LiteralPath $Path)) {
            return @{Success = $true; Method = "Robocopy Mirror" }
        }
        return @{Success = $false; Error = "Directory still exists" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
    finally {
        if ($emptyDirectory -and (Test-Path -LiteralPath $emptyDirectory)) {
            Remove-Item -LiteralPath $emptyDirectory -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

function Remove-ItemWMI {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete through WMI/CIM')) {
        return @{Success = $true; Method = 'WhatIf: WMI/CIM'; Simulated = $true }
    }

    try {
        $escapedPath = $Path -replace '\\', '\\'
        $item = if (Test-Path -LiteralPath $Path -PathType Container) {
            Get-CimInstance -ClassName Win32_Directory -Filter "Name='$escapedPath'" -ErrorAction Stop
        }
        else {
            Get-CimInstance -ClassName CIM_DataFile -Filter "Name='$escapedPath'" -ErrorAction Stop
        }

        if ($item) {
            $result = $item | Invoke-CimMethod -MethodName Delete
            if ($result.ReturnValue -eq 0) {
                return @{Success = $true; Method = "WMI/CIM" }
            }
        }
        return @{Success = $false; Error = "WMI deletion failed" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Test-ReparsePoint {
    [CmdletBinding()]
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item) {
        return ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    }
    return $false
}

function Remove-ReparsePointSafe {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (Test-ReparsePoint -Path $Path) {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Remove the reparse point without traversing its target')) {
            return $true
        }
        $null = Start-Process -FilePath "cmd.exe" -ArgumentList '/c', "rmdir `"$Path`"" -NoNewWindow -Wait -PassThru 2>$null
        return -not (Test-Path -LiteralPath $Path)
    }
    return $false
}

function Register-BootTimeDelete {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Schedule deletion for the next boot with MoveFileEx')) {
        return @{Success = $true; Method = 'WhatIf: Boot-time MoveFileEx'; Simulated = $true }
    }

    try {
        if ([PathForgeBootDeleteNative]::ScheduleDelete($Path)) {
            return @{Success = $true; Method = "Boot-time MoveFileEx" }
        }
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $message = (New-Object ComponentModel.Win32Exception($errorCode)).Message
        return @{Success = $false; Error = "Win32 error ${errorCode}: $message" }
    }
    catch {
        return @{Success = $false; Error = $_.Exception.Message }
    }
}

function Read-PathForgePendingFileRegistryValue {
    try {
        $registryKey = Get-Item -LiteralPath $Script:PathForgeSessionManagerRegistryPath -ErrorAction Stop
        if (@($registryKey.GetValueNames()) -notcontains $Script:PathForgePendingFileValueName) {
            return [PSCustomObject]@{Success = $true; Exists = $false; Value = @(); Error = $null }
        }

        $value = $registryKey.GetValue(
            $Script:PathForgePendingFileValueName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [PSCustomObject]@{Success = $true; Exists = $true; Value = @($value); Error = $null }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Exists = $false; Value = @(); Error = $_.Exception.Message }
    }
}

function Write-PathForgePendingFileRegistryValue {
    param([AllowEmptyCollection()][string[]]$Value)

    if (@($Value).Count -eq 0) {
        Remove-ItemProperty -LiteralPath $Script:PathForgeSessionManagerRegistryPath `
            -Name $Script:PathForgePendingFileValueName -ErrorAction Stop
        return
    }

    Set-ItemProperty -LiteralPath $Script:PathForgeSessionManagerRegistryPath `
        -Name $Script:PathForgePendingFileValueName -Value ([string[]]$Value) `
        -Type MultiString -Force -ErrorAction Stop
}

function Get-PathForgePendingFileQueueHash {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Value)

    $builder = New-Object System.Text.StringBuilder
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) {
            $null = $builder.Append('-1:|')
        }
        else {
            $text = [string]$entry
            $null = $builder.Append($text.Length).Append(':').Append($text).Append('|')
        }
    }

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
        return [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertFrom-PathForgeNativeQueuePath {
    param([AllowNull()][string]$Path)

    if ($null -eq $Path) {
        return $null
    }

    $displayPath = $Path
    if ($displayPath.StartsWith('!', [System.StringComparison]::Ordinal)) {
        $displayPath = $displayPath.Substring(1)
    }
    if ($displayPath -match '^\*[12]') {
        $displayPath = $displayPath.Substring(2)
    }
    if ($displayPath.StartsWith('!', [System.StringComparison]::Ordinal)) {
        $displayPath = $displayPath.Substring(1)
    }
    if ($displayPath.StartsWith('\??\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $displayPath = $displayPath.Substring(4)
    }
    elseif ($displayPath.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $displayPath = $displayPath.Substring(4)
    }
    if ($displayPath.StartsWith('UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $displayPath = '\\' + $displayPath.Substring(4)
    }
    return $displayPath
}

function Get-PathForgePendingFileQueue {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][string[]]$RegistryValue)

    if ($PSBoundParameters.ContainsKey('RegistryValue')) {
        $readResult = [PSCustomObject]@{Success = $true; Exists = $true; Value = @($RegistryValue); Error = $null }
    }
    else {
        $readResult = Read-PathForgePendingFileRegistryValue
    }

    if (-not $readResult.Success) {
        return [PSCustomObject]@{
            Success        = $false
            ValueExists    = $false
            RawValue       = @()
            SnapshotHash   = $null
            Operations     = @()
            DeleteCount    = 0
            MoveCount      = 0
            MalformedCount = 0
            Error          = $readResult.Error
        }
    }

    $rawValue = @($readResult.Value)
    $snapshotHash = Get-PathForgePendingFileQueueHash -Value $rawValue
    $operations = New-Object 'System.Collections.Generic.List[object]'
    for ($rawIndex = 0; $rawIndex -lt $rawValue.Count; $rawIndex += 2) {
        $operationIndex = [int]($rawIndex / 2)
        $hasDestination = $rawIndex + 1 -lt $rawValue.Count
        $rawSource = if ($null -eq $rawValue[$rawIndex]) { '' } else { [string]$rawValue[$rawIndex] }
        $rawDestination = if ($hasDestination) { $rawValue[$rawIndex + 1] } else { $null }
        $destinationText = if ($null -eq $rawDestination) { $null } else { [string]$rawDestination }
        $malformed = -not $hasDestination -or [string]::IsNullOrWhiteSpace($rawSource)
        $kind = if ($malformed) { 'Malformed' } elseif ([string]::IsNullOrEmpty($destinationText)) { 'Delete' } else { 'Move' }
        $replaceExisting = -not [string]::IsNullOrEmpty($destinationText) -and $destinationText -match '^(?:\*[12])?!'
        $sourcePrefix = if ($rawSource -match '^(?:!)?(\*[12])') { $Matches[1] } else { '' }
        $destinationPrefix = if ($destinationText -match '^(?:!)?(\*[12])') { $Matches[1] } else { '' }

        $operations.Add([PSCustomObject]@{
                Index             = $operationIndex
                RawIndex          = $rawIndex
                Kind              = $kind
                Source            = ConvertFrom-PathForgeNativeQueuePath -Path $rawSource
                Destination       = ConvertFrom-PathForgeNativeQueuePath -Path $destinationText
                ReplaceExisting   = $replaceExisting
                SourcePrefix      = $sourcePrefix
                DestinationPrefix = $destinationPrefix
                IsMalformed       = $malformed
                HasDestination    = $hasDestination
                RawSource         = $rawSource
                RawDestination    = $rawDestination
            })
    }

    $operationArray = $operations.ToArray()
    return [PSCustomObject]@{
        Success        = $true
        ValueExists    = [bool]$readResult.Exists
        RawValue       = $rawValue
        SnapshotHash   = $snapshotHash
        Operations     = $operationArray
        DeleteCount    = @($operationArray | Where-Object Kind -eq 'Delete').Count
        MoveCount      = @($operationArray | Where-Object Kind -eq 'Move').Count
        MalformedCount = @($operationArray | Where-Object IsMalformed).Count
        Error          = $null
    }
}

function Add-PathForgePendingFileDelete {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Error = $check.Reason }
    }

    $queue = Get-PathForgePendingFileQueue
    if (-not $queue.Success) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Error = $queue.Error }
    }

    $resolvedPath = [string]$check.Resolved
    $nativePath = if ($resolvedPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        '\??\UNC\' + $resolvedPath.TrimStart('\')
    }
    else {
        '\??\' + $resolvedPath
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedPath, 'Append a deletion to PendingFileRenameOperations')) {
        return [PSCustomObject]@{Success = $true; Simulated = $true; Error = $null }
    }

    try {
        $updatedValue = @($queue.RawValue) + @($nativePath, '')
        Write-PathForgePendingFileRegistryValue -Value $updatedValue
        return [PSCustomObject]@{Success = $true; Simulated = $false; Error = $null }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Error = $_.Exception.Message }
    }
}

function Remove-PathForgePendingFileOperation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][int[]]$Index,
        [string]$ExpectedSnapshotHash
    )

    $queue = Get-PathForgePendingFileQueue
    if (-not $queue.Success) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Conflict = $false; RemovedCount = 0; RemainingCount = 0; Error = $queue.Error }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSnapshotHash) -and $ExpectedSnapshotHash -ne $queue.SnapshotHash) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Conflict = $true; RemovedCount = 0; RemainingCount = $queue.Operations.Count; Error = 'The reboot queue changed after it was loaded. Refresh before cancelling entries.' }
    }

    $requestedIndexes = @($Index | Sort-Object -Unique)
    $availableIndexes = New-Object 'System.Collections.Generic.List[int]'
    foreach ($operation in @($queue.Operations)) {
        $availableIndexes.Add([int]$operation.Index)
    }
    $invalidIndexes = @($requestedIndexes | Where-Object { $_ -notin $availableIndexes })
    if ($requestedIndexes.Count -eq 0 -or $invalidIndexes.Count -gt 0) {
        $invalidText = if ($invalidIndexes.Count -gt 0) { $invalidIndexes -join ', ' } else { '(none)' }
        return [PSCustomObject]@{Success = $false; Simulated = $false; Conflict = $false; RemovedCount = 0; RemainingCount = $queue.Operations.Count; Error = "Invalid queue index: $invalidText" }
    }

    $targetDescription = "$($requestedIndexes.Count) pending file operation(s)"
    if (-not $PSCmdlet.ShouldProcess($targetDescription, 'Cancel selected reboot queue entries')) {
        return [PSCustomObject]@{Success = $true; Simulated = $true; Conflict = $false; RemovedCount = $requestedIndexes.Count; RemainingCount = $queue.Operations.Count - $requestedIndexes.Count; Error = $null }
    }

    $removedOffsets = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($operation in @($queue.Operations | Where-Object { $_.Index -in $requestedIndexes })) {
        $null = $removedOffsets.Add([int]$operation.RawIndex)
        if ($operation.HasDestination) {
            $null = $removedOffsets.Add([int]$operation.RawIndex + 1)
        }
    }

    $remainingValue = New-Object 'System.Collections.Generic.List[string]'
    for ($rawIndex = 0; $rawIndex -lt $queue.RawValue.Count; $rawIndex++) {
        if (-not $removedOffsets.Contains($rawIndex)) {
            $remainingValue.Add([string]$queue.RawValue[$rawIndex])
        }
    }

    try {
        Write-PathForgePendingFileRegistryValue -Value $remainingValue.ToArray()
        return [PSCustomObject]@{
            Success        = $true
            Simulated      = $false
            Conflict       = $false
            RemovedCount   = $requestedIndexes.Count
            RemainingCount = $queue.Operations.Count - $requestedIndexes.Count
            Error          = $null
        }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Conflict = $false; RemovedCount = 0; RemainingCount = $queue.Operations.Count; Error = $_.Exception.Message }
    }
}

function Get-PathForgeDeletionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$IncludeRecycleBin,
        [switch]$TakeOwnership,
        [ValidateRange(1, 100000)]
        [int]$MaxPreviewItems = 10000,
        [ValidateRange(1, 100)]
        [int]$SampleSize = 25
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return [PSCustomObject]@{
            Success = $false
            Path    = $Path
            Error   = $check.Reason
        }
    }

    try {
        $target = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            Path    = $Path
            Error   = $_.Exception.Message
        }
    }

    $isContainer = [bool]$target.PSIsContainer
    $isReparsePoint = ($target.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $fileSystem = Get-VolumeFileSystem -Path $Path
    $previewItems = @($target)
    $truncated = $false

    if ($isContainer -and -not $isReparsePoint) {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First ($MaxPreviewItems + 1))
        if ($children.Count -gt $MaxPreviewItems) {
            $truncated = $true
            $children = @($children | Select-Object -First $MaxPreviewItems)
        }
        $previewItems += $children
    }

    [int64]$totalBytes = 0
    foreach ($previewItem in $previewItems) {
        if (-not $previewItem.PSIsContainer -and $null -ne $previewItem.Length) {
            $totalBytes += [int64]$previewItem.Length
        }
    }

    $methods = New-Object 'System.Collections.Generic.List[object]'
    $order = 0
    $addMethod = {
        param(
            [string]$Name,
            [string]$Api,
            [bool]$Applicable,
            [string]$Reason,
            [bool]$Recoverable = $false
        )

        $order++
        $methods.Add([PSCustomObject]@{
                Order       = $order
                Name        = $Name
                Api         = $Api
                Applicable  = $Applicable
                Reason      = $Reason
                Recoverable = $Recoverable
            })
    }.GetNewClosure()

    if ($TakeOwnership) {
        $null = & $addMethod 'Take Ownership' 'takeown.exe + icacls.exe' $true 'Requested prerequisite before permanent deletion'
    }
    $null = & $addMethod 'Recycle Bin' 'Microsoft.VisualBasic.FileIO.FileSystem' ([bool]$IncludeRecycleBin) $(if ($IncludeRecycleBin) { 'Enabled as the first recoverable attempt' } else { 'Recycle Bin option is disabled' }) $true
    $null = & $addMethod 'Reparse Point Removal' 'cmd.exe rmdir (link only)' $isReparsePoint $(if ($isReparsePoint) { 'Target is a reparse point; remove the link without traversing it' } else { 'Target is not a reparse point' })

    $permanentReason = if ($isReparsePoint) { 'Skipped unless safe link-only removal is declined' } else { 'Applicable permanent deletion attempt' }
    $permanentApplicable = -not $isReparsePoint
    $null = & $addMethod 'Standard PowerShell' 'Remove-Item -LiteralPath -Force -Recurse' $permanentApplicable $permanentReason
    $null = & $addMethod '.NET Framework' 'System.IO.File.Delete / Directory.Delete' $permanentApplicable $permanentReason
    $null = & $addMethod 'Long Path' 'cmd.exe del/rd with the \\?\ prefix' $permanentApplicable $permanentReason
    $shortNameApplicable = $permanentApplicable -and $fileSystem -eq 'NTFS'
    $shortNameReason = if ($fileSystem -eq 'NTFS') { $permanentReason } else { "$fileSystem does not support the NTFS 8.3 method" }
    $null = & $addMethod '8.3 Short Name' 'Scripting.FileSystemObject + Remove-Item' $shortNameApplicable $shortNameReason
    $robocopyApplicable = $permanentApplicable -and $isContainer
    $robocopyReason = if (-not $isContainer) { 'Robocopy mirror applies only to directories' } else { $permanentReason }
    $null = & $addMethod 'Robocopy Mirror' 'robocopy.exe /MIR + cmd.exe rd' $robocopyApplicable $robocopyReason
    $null = & $addMethod 'WMI/CIM' 'Win32_Directory or CIM_DataFile Delete()' $permanentApplicable $permanentReason
    $null = & $addMethod 'Boot-Time Delete' 'MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)' $true 'Fallback if all immediate methods fail'

    return [PSCustomObject]@{
        Success        = $true
        Path           = $target.FullName
        FileSystem     = $fileSystem
        IsContainer    = $isContainer
        IsReparsePoint = $isReparsePoint
        ItemCount      = $previewItems.Count
        TotalBytes     = $totalBytes
        Truncated      = $truncated
        SamplePaths    = @($previewItems | Select-Object -First $SampleSize | ForEach-Object FullName)
        Methods        = $methods.ToArray()
        Error          = $null
    }
}

function ConvertTo-PathForgeBoolean {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    switch (([string]$Value).Trim().ToLowerInvariant()) {
        { $_ -in @('1', 'true', 'yes', 'y', 'on') } { return $true }
        { $_ -in @('0', 'false', 'no', 'n', 'off') } { return $false }
        default { throw "Unsupported Boolean value: $Value" }
    }
}

function Resolve-PathForgeDeletionMethod {
    param([string]$Method)

    if ([string]::IsNullOrWhiteSpace($Method)) {
        return 'Auto'
    }

    $key = $Method.Trim().ToLowerInvariant() -replace '[\s._-]', ''
    $aliases = @{
        auto          = 'Auto'
        standard      = 'Standard'
        powershell    = 'Standard'
        dotnet        = 'DotNet'
        framework     = 'DotNet'
        longpath      = 'LongPath'
        shortname     = 'ShortName'
        eightdotthree = 'ShortName'
        robocopy      = 'Robocopy'
        wmi           = 'WMI'
        cim           = 'WMI'
        recyclebin    = 'RecycleBin'
        recycle       = 'RecycleBin'
        boottime      = 'BootTime'
        boot          = 'BootTime'
        reparsepoint  = 'ReparsePoint'
        reparse       = 'ReparsePoint'
        linkonly      = 'ReparsePoint'
    }

    if (-not $aliases.ContainsKey($key)) {
        throw "Unsupported deletion method '$Method'. Use Auto, Standard, DotNet, LongPath, ShortName, Robocopy, WMI, RecycleBin, BootTime, or ReparsePoint."
    }
    return $aliases[$key]
}

function Import-PathForgeDeletionBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Batch file not found: $Path"
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    $records = New-Object 'System.Collections.Generic.List[object]'

    if ($extension -ieq '.csv') {
        $rows = @(Import-Csv -LiteralPath $Path)
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $row = $rows[$index]
            $lineNumber = $index + 2
            $rawPath = if ($row.PSObject.Properties.Name -contains 'Path') { [string]$row.Path } else { $null }
            $rawMethod = if ($row.PSObject.Properties.Name -contains 'Method') { [string]$row.Method } else { 'Auto' }
            $rawDryRun = if ($row.PSObject.Properties.Name -contains 'DryRun') { $row.DryRun } else { $false }

            $errorParts = New-Object 'System.Collections.Generic.List[string]'
            try { $method = Resolve-PathForgeDeletionMethod -Method $rawMethod }
            catch { $method = 'Auto'; $errorParts.Add($_.Exception.Message) }
            try { $dryRun = ConvertTo-PathForgeBoolean -Value $rawDryRun }
            catch { $dryRun = $false; $errorParts.Add($_.Exception.Message) }
            $pathCheck = Test-SafePath -Path $rawPath
            if (-not $pathCheck.Valid) {
                $errorParts.Add($pathCheck.Reason)
            }
            $errorMessage = $errorParts -join '; '

            $records.Add([PSCustomObject]@{
                    LineNumber = $lineNumber
                    Path       = $rawPath
                    Method     = $method
                    DryRun     = $dryRun
                    Valid      = [string]::IsNullOrWhiteSpace($errorMessage)
                    Error      = $errorMessage
                })
        }
    }
    else {
        $lines = @(Get-Content -LiteralPath $Path)
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
                continue
            }

            $parts = $line -split '\|', 3
            $rawPath = $parts[0].Trim()
            $rawMethod = if ($parts.Count -ge 2) { $parts[1].Trim() } else { 'Auto' }
            $rawDryRun = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $false }
            $errorParts = New-Object 'System.Collections.Generic.List[string]'
            try { $method = Resolve-PathForgeDeletionMethod -Method $rawMethod }
            catch { $method = 'Auto'; $errorParts.Add($_.Exception.Message) }
            try { $dryRun = ConvertTo-PathForgeBoolean -Value $rawDryRun }
            catch { $dryRun = $false; $errorParts.Add($_.Exception.Message) }
            $pathCheck = Test-SafePath -Path $rawPath
            if (-not $pathCheck.Valid) {
                $errorParts.Add($pathCheck.Reason)
            }
            $errorMessage = $errorParts -join '; '

            $records.Add([PSCustomObject]@{
                    LineNumber = $index + 1
                    Path       = $rawPath
                    Method     = $method
                    DryRun     = $dryRun
                    Valid      = [string]::IsNullOrWhiteSpace($errorMessage)
                    Error      = $errorMessage
                })
        }
    }

    return $records.ToArray()
}

function Invoke-PathForgeDeletionMethod {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'Standard', 'DotNet', 'LongPath', 'ShortName', 'Robocopy', 'WMI', 'RecycleBin', 'BootTime', 'ReparsePoint')]
        [string]$Method,
        [switch]$IncludeRecycleBin
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $Path; Method = $Method; EffectiveMethod = $null; Attempts = @(); Error = $check.Reason }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $Path; Method = $Method; EffectiveMethod = $null; Attempts = @(); Error = 'Path not found' }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Delete with PathForge method $Method")) {
        return [PSCustomObject]@{Success = $true; Simulated = $true; Path = $Path; Method = $Method; EffectiveMethod = $Method; Attempts = @(); Error = $null }
    }

    $methodCommands = @{
        Standard     = 'Remove-ItemStandard'
        DotNet       = 'Remove-ItemDotNet'
        LongPath     = 'Remove-ItemLongPath'
        ShortName    = 'Remove-ItemShortName'
        Robocopy     = 'Remove-ItemRobocopy'
        WMI          = 'Remove-ItemWMI'
        RecycleBin   = 'Move-ToRecycleBin'
        BootTime     = 'Register-BootTimeDelete'
        ReparsePoint = 'Remove-ReparsePointSafe'
    }

    if ($Method -ne 'Auto') {
        $commandName = $methodCommands[$Method]
        $rawResult = & $commandName -Path $Path -Confirm:$false
        if ($Method -eq 'ReparsePoint') {
            $rawResult = if ($rawResult) { @{Success = $true; Method = 'Reparse Point Removal'} } else { @{Success = $false; Error = 'Target is not a removable reparse point'} }
        }
        return [PSCustomObject]@{
            Success         = [bool]$rawResult.Success
            Simulated       = [bool]$rawResult.Simulated
            Path            = $Path
            Method          = $Method
            EffectiveMethod = $rawResult.Method
            Attempts        = @([PSCustomObject]@{Method = $Method; Success = [bool]$rawResult.Success; Error = $rawResult.Error })
            Error           = $rawResult.Error
        }
    }

    $attemptNames = New-Object 'System.Collections.Generic.List[string]'
    if ($IncludeRecycleBin) { $attemptNames.Add('RecycleBin') }
    if (Test-ReparsePoint -Path $Path) {
        $attemptNames.Add('ReparsePoint')
    }
    else {
        foreach ($attemptName in @('Standard', 'DotNet', 'LongPath')) { $attemptNames.Add($attemptName) }
        if ((Get-VolumeFileSystem -Path $Path) -eq 'NTFS') { $attemptNames.Add('ShortName') }
        if (Test-Path -LiteralPath $Path -PathType Container) { $attemptNames.Add('Robocopy') }
        $attemptNames.Add('WMI')
    }

    $attempts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($attemptName in $attemptNames) {
        $commandName = $methodCommands[$attemptName]
        $rawResult = & $commandName -Path $Path -Confirm:$false
        if ($attemptName -eq 'ReparsePoint') {
            $rawResult = if ($rawResult) { @{Success = $true; Method = 'Reparse Point Removal'} } else { @{Success = $false; Error = 'Reparse-point removal failed'} }
        }
        $attempts.Add([PSCustomObject]@{Method = $attemptName; Success = [bool]$rawResult.Success; Error = $rawResult.Error })
        if ($rawResult.Success) {
            return [PSCustomObject]@{Success = $true; Simulated = $false; Path = $Path; Method = 'Auto'; EffectiveMethod = $rawResult.Method; Attempts = $attempts.ToArray(); Error = $null }
        }
    }

    return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $Path; Method = 'Auto'; EffectiveMethod = $null; Attempts = $attempts.ToArray(); Error = 'All applicable immediate methods failed' }
}

function Get-DriveSmartHealth {
    [CmdletBinding()]
    param([string]$Drive)

    try {
        $driveLetter = $Drive.TrimEnd(':')
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop | Select-Object -First 1
        $disk = Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index = $($partition.DiskNumber)" -ErrorAction Stop
        if (-not $disk -or [string]::IsNullOrWhiteSpace($disk.PNPDeviceID)) {
            throw "The physical disk could not be resolved"
        }

        $statuses = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
        $deviceId = [string]$disk.PNPDeviceID
        $status = $statuses | Where-Object {
            $_.InstanceName -and $_.InstanceName.StartsWith(
                $deviceId,
                [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        if (-not $status) {
            return [PSCustomObject]@{
                Available      = $false
                PredictFailure = $false
                Reason         = 0
                DiskName       = $disk.Model
            }
        }

        return [PSCustomObject]@{
            Available      = $true
            PredictFailure = [bool]$status.PredictFailure
            Reason         = [uint32]$status.Reason
            DiskName       = $disk.Model
        }
    }
    catch {
        Write-Verbose "SMART pre-repair query failed for ${Drive}: $_"
        return [PSCustomObject]@{
            Available      = $false
            PredictFailure = $false
            Reason         = 0
            DiskName       = "Unknown"
        }
    }
}

function Get-VolumeCorruptionRecord {
    [CmdletBinding()]
    param([string]$Drive)

    try {
        $driveLetter = $Drive.TrimEnd(':')
        $count = [uint32](Get-VolumeCorruptionCount -DriveLetter $driveLetter -ErrorAction Stop)
        return [PSCustomObject]@{
            Drive           = $Drive
            CorruptionCount = $count
            Available       = $true
            Error           = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Drive           = $Drive
            CorruptionCount = 0
            Available       = $false
            Error           = $_.Exception.Message
        }
    }
}

function Get-PathForgeRepairCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ChkdskScan', 'ChkdskFix', 'ChkdskFull', 'ChkdskSpotfix', 'SfcScan', 'DismRestore')]
        [string]$Operation,
        [string]$Drive
    )

    if ($Operation -like 'Chkdsk*' -and $Drive -notmatch '^[A-Za-z]:$') {
        throw "A drive in X: format is required for $Operation"
    }

    switch ($Operation) {
        'ChkdskScan' {
            $filePath = 'chkdsk.exe'
            $arguments = "$Drive /scan"
            $progressPattern = '(\d+)\s*percent'
            $successExitCodes = @(0, 1, 2)
        }
        'ChkdskFix' {
            $filePath = 'chkdsk.exe'
            $arguments = if ($Drive -eq 'C:') { "$Drive /F" } else { "$Drive /F /X" }
            $progressPattern = '(\d+)\s*percent'
            $successExitCodes = @(0, 1, 2)
        }
        'ChkdskFull' {
            $filePath = 'chkdsk.exe'
            $arguments = if ($Drive -eq 'C:') { "$Drive /R" } else { "$Drive /R /X" }
            $progressPattern = '(\d+)\s*percent'
            $successExitCodes = @(0, 1, 2)
        }
        'ChkdskSpotfix' {
            $filePath = 'chkdsk.exe'
            $arguments = "$Drive /spotfix"
            $progressPattern = '(\d+)\s*percent'
            $successExitCodes = @(0, 1, 2)
        }
        'SfcScan' {
            $filePath = 'sfc.exe'
            $arguments = '/scannow'
            $progressPattern = '(\d+)%'
            $successExitCodes = @(0)
        }
        'DismRestore' {
            $filePath = 'DISM.exe'
            $arguments = '/Online /Cleanup-Image /RestoreHealth'
            $progressPattern = '(\d+)\.(\d+)%'
            $successExitCodes = @(0)
        }
    }

    return [PSCustomObject]@{
        Operation        = $Operation
        FilePath         = $filePath
        Arguments        = $arguments
        ProgressPattern  = $progressPattern
        SuccessExitCodes = $successExitCodes
        StallSeconds     = if ($Operation -eq 'DismRestore') { 60 } else { 0 }
    }
}

function Invoke-PathForgeRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ChkdskScan', 'ChkdskFix', 'ChkdskFull', 'ChkdskSpotfix', 'SfcScan', 'DismRestore')]
        [string]$Operation,
        [string]$Drive,
        [scriptblock]$OutputAction,
        [scriptblock]$ErrorCallback,
        [scriptblock]$ProgressCallback,
        [scriptblock]$ProcessAction,
        [scriptblock]$PumpAction,
        [scriptblock]$StallAction
    )

    $command = Get-PathForgeRepairCommand -Operation $Operation -Drive $Drive
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $command.FilePath
    $process.StartInfo.Arguments = $command.Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.EnableRaisingEvents = $true

    $outputQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $errorQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $errorLines = New-Object 'System.Collections.Generic.List[string]'
    $outputSource = "PathForge.Output.$([Guid]::NewGuid().ToString('N'))"
    $errorSource = "PathForge.Error.$([Guid]::NewGuid().ToString('N'))"
    $outputJob = $null
    $errorJob = $null
    $failure = $null
    $exitCode = -1
    $callbacks = [PSCustomObject]@{
        Output   = $OutputAction
        Error    = $ErrorCallback
        Progress = $ProgressCallback
    }
    $progressState = [PSCustomObject]@{
        LastPercent = -1
        LastTime    = Get-Date
        StallShown  = $false
    }

    $consumeOutput = {
        param([string]$Line, [bool]$IsError)

        $trimmed = $Line.Trim()
        if (-not $trimmed) { return }

        if ($IsError) {
            $errorLines.Add($trimmed)
            if ($callbacks.Error) { $null = & $callbacks.Error $trimmed }
            return
        }

        $outputLines.Add($trimmed)
        if ($trimmed -match $command.ProgressPattern) {
            $percent = [int]$Matches[1]
            if ($percent -ne $progressState.LastPercent) {
                $progressState.LastPercent = $percent
                $progressState.LastTime = Get-Date
                $progressState.StallShown = $false
            }
            if ($callbacks.Progress) { $null = & $callbacks.Progress $percent $Matches[0] }
        }
        if ($callbacks.Output) { $null = & $callbacks.Output $trimmed }
    }.GetNewClosure()

    $drainQueues = {
        [string]$line = $null
        while ($outputQueue.TryDequeue([ref]$line)) {
            $null = & $consumeOutput $line $false
            $line = $null
        }
        while ($errorQueue.TryDequeue([ref]$line)) {
            $null = & $consumeOutput $line $true
            $line = $null
        }
    }.GetNewClosure()

    try {
        $outputJob = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -SourceIdentifier $outputSource -MessageData $outputQueue -Action {
            if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        }
        $errorJob = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -SourceIdentifier $errorSource -MessageData $errorQueue -Action {
            if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        }

        if (-not $process.Start()) {
            throw "Failed to start $($command.FilePath)"
        }
        if ($ProcessAction) { $null = & $ProcessAction $process }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        while (-not $process.HasExited) {
            $null = & $drainQueues
            if ($PumpAction) { $null = & $PumpAction }

            if ($command.StallSeconds -gt 0 -and -not $progressState.StallShown) {
                $stalledFor = ((Get-Date) - $progressState.LastTime).TotalSeconds
                if ($stalledFor -gt $command.StallSeconds) {
                    $progressState.StallShown = $true
                    if ($StallAction) { $null = & $StallAction $progressState.LastPercent }
                }
            }
            Start-Sleep -Milliseconds 100
        }

        $process.WaitForExit()
        Start-Sleep -Milliseconds 50
        $null = & $drainQueues
        $exitCode = $process.ExitCode
    }
    catch {
        $failure = $_.Exception.Message
        if (-not $process.HasExited) {
            try { $process.Kill() }
            catch { Write-Verbose "Failed to stop repair process after an error: $_" }
        }
    }
    finally {
        if ($ProcessAction) { $null = & $ProcessAction $null }
        foreach ($source in @($outputSource, $errorSource)) {
            Unregister-Event -SourceIdentifier $source -ErrorAction SilentlyContinue
        }
        foreach ($job in @($outputJob, $errorJob)) {
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
        $process.Dispose()
    }

    return [PSCustomObject]@{
        Operation   = $Operation
        FilePath    = $command.FilePath
        Arguments   = $command.Arguments
        ExitCode    = $exitCode
        Success     = -not $failure -and $exitCode -in $command.SuccessExitCodes
        Output      = $outputLines.ToArray()
        ErrorOutput = $errorLines.ToArray()
        Error       = $failure
    }
}

function Get-PathForgePhysicalDisk {
    @(Get-PhysicalDisk -ErrorAction Stop)
}

function Get-PathForgeVolume {
    @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter })
}

function Get-PathForgeDriveHealth {
    [CmdletBinding()]
    param()

    $errors = New-Object 'System.Collections.Generic.List[string]'
    try { $physicalDisks = @(Get-PathForgePhysicalDisk) }
    catch {
        $physicalDisks = @()
        $errors.Add("Physical disks: $($_.Exception.Message)")
    }

    try { $volumes = @(Get-PathForgeVolume) }
    catch {
        $volumes = @()
        $errors.Add("Volumes: $($_.Exception.Message)")
    }

    $smartResult = Get-PathForgeSmartStatus
    if (-not $smartResult.Success) { $errors.Add("SMART: $($smartResult.Error)") }

    $reliabilityResult = Get-PathForgeReliabilityCounter -PhysicalDisk $physicalDisks
    if (-not $reliabilityResult.Success) { $errors.Add("Reliability counters: $($reliabilityResult.Error)") }

    return [PSCustomObject]@{
        PhysicalDisks       = $physicalDisks
        Volumes             = $volumes
        SmartStatuses       = $smartResult.Items
        ReliabilityCounters = $reliabilityResult.Items
        Errors              = $errors.ToArray()
    }
}

function Get-PathForgeSmartStatus {
    [CmdletBinding()]
    param()

    try {
        return [PSCustomObject]@{
            Success = $true
            Items   = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
            Error   = $null
        }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Items = @(); Error = $_.Exception.Message }
    }
}

function Get-PathForgeReliabilityCounter {
    [CmdletBinding()]
    param([object[]]$PhysicalDisk)

    try {
        $disks = if ($PSBoundParameters.ContainsKey('PhysicalDisk')) {
            @($PhysicalDisk)
        }
        else {
            @(Get-PathForgePhysicalDisk)
        }
        return [PSCustomObject]@{
            Success = $true
            Items   = @($disks | Get-StorageReliabilityCounter -ErrorAction Stop)
            Error   = $null
        }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Items = @(); Error = $_.Exception.Message }
    }
}

function ConvertFrom-PathForgeTrimOutput {
    [CmdletBinding()]
    param([string[]]$InputLine)

    foreach ($line in $InputLine) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        if ($trimmed -match 'DisableDeleteNotify\s*=\s*(\d)') {
            [PSCustomObject]@{
                FileSystem = ($trimmed -replace 'DisableDeleteNotify.*', '').Trim()
                Enabled    = $Matches[1] -eq '0'
                Raw        = $trimmed
            }
        }
        else {
            [PSCustomObject]@{
                FileSystem = $null
                Enabled    = $null
                Raw        = $trimmed
            }
        }
    }
}

function Get-PathForgeTrimStatus {
    [CmdletBinding()]
    param()

    try {
        $rawOutput = @(& fsutil.exe behavior query DisableDeleteNotify 2>&1)
        $exitCode = $LASTEXITCODE
        return [PSCustomObject]@{
            Success  = $exitCode -eq 0
            ExitCode = $exitCode
            Items    = @(ConvertFrom-PathForgeTrimOutput -InputLine $rawOutput)
            Error    = if ($exitCode -eq 0) { $null } else { $rawOutput -join [Environment]::NewLine }
        }
    }
    catch {
        return [PSCustomObject]@{Success = $false; ExitCode = -1; Items = @(); Error = $_.Exception.Message }
    }
}

function Get-PathForgeFilesystemEvent {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3650)]
        [int]$Days = 7,
        [ValidateRange(1, 1000)]
        [int]$MaxEventsPerId = 10
    )

    $definitions = @(
        @{Id = 55; Description = "Filesystem structure corrupt" },
        @{Id = 50; Description = "Delayed write failed (data loss)" },
        @{Id = 98; Description = "Volume needs offline CHKDSK" },
        @{Id = 129; Description = "Reset to device issued (timeout)" },
        @{Id = 153; Description = "Disk retry occurred" },
        @{Id = 157; Description = "Disk surprise removed" }
    )

    foreach ($definition in $definitions) {
        $events = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = $definition.Id
                StartTime = (Get-Date).AddDays(-$Days)
            } -MaxEvents $MaxEventsPerId -ErrorAction SilentlyContinue)

        foreach ($eventRecord in $events) {
            [PSCustomObject]@{
                Id          = $eventRecord.Id
                Description = $definition.Description
                TimeCreated = $eventRecord.TimeCreated
                Message     = $eventRecord.Message
                Record      = $eventRecord
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Test-SafePath',
    'Get-FileLockProcess',
    'Get-VolumeFileSystem',
    'Move-ToRecycleBin',
    'Remove-ItemStandard',
    'Remove-ItemDotNet',
    'Remove-ItemLongPath',
    'Remove-ItemShortName',
    'Remove-ItemRobocopy',
    'Remove-ItemWMI',
    'Test-ReparsePoint',
    'Remove-ReparsePointSafe',
    'Register-BootTimeDelete',
    'Get-PathForgePendingFileQueue',
    'Add-PathForgePendingFileDelete',
    'Remove-PathForgePendingFileOperation',
    'Get-PathForgeDeletionPlan',
    'Import-PathForgeDeletionBatch',
    'Invoke-PathForgeDeletionMethod',
    'Get-DriveSmartHealth',
    'Get-VolumeCorruptionRecord',
    'Get-PathForgeRepairCommand',
    'Invoke-PathForgeRepair',
    'Get-PathForgeDriveHealth',
    'Get-PathForgeSmartStatus',
    'Get-PathForgeReliabilityCounter',
    'ConvertFrom-PathForgeTrimOutput',
    'Get-PathForgeTrimStatus',
    'Get-PathForgeFilesystemEvent'
)
