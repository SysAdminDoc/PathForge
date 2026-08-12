<#
.SYNOPSIS
    PathForge - Windows Filesystem Repair & Deletion Suite
.DESCRIPTION
    Professional toolkit for filesystem repair, stubborn file deletion,
    permission management, and drive diagnostics with comprehensive
    educational information panels.
.VERSION
    3.1.0
.PARAMETER Path
    Optional file or folder path to pre-fill in the target path field.
.PARAMETER InstallContextMenu
    Register PathForge in the Windows Explorer right-click context menu.
.PARAMETER RemoveContextMenu
    Remove PathForge from the Windows Explorer right-click context menu.
#>
param(
    [string]$Path,
    [switch]$InstallContextMenu,
    [switch]$RemoveContextMenu
)

#Requires -RunAsAdministrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# DPI awareness - call before any form creation
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int awareness);
}
"@ -ErrorAction SilentlyContinue
try { [DpiHelper]::SetProcessDpiAwareness(2) }
catch { try { [void][DpiHelper]::SetProcessDPIAware() } catch { } }

# Dark mode title bar API
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DarkMode {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    public static void EnableDarkTitleBar(IntPtr handle) {
        int value = 1;
        DwmSetWindowAttribute(handle, 20, ref value, sizeof(int));
    }
}
"@ -ErrorAction SilentlyContinue

$coreModulePath = Join-Path $PSScriptRoot 'PathForge.Core.psm1'
Import-Module $coreModulePath -Force

# ============================================================================
# CONFIGURATION
# ============================================================================
$Script:Config = @{
    Version   = "3.1.0"
    AppName   = "PathForge"
    LogPath   = "$env:USERPROFILE\Documents\PathForge_Logs"
    MaxLogAge = 30
}

$Script:LogFile = $null
$Script:OutputBox = $null
$Script:StatusLabel = $null
$Script:ProgressBar = $null
$Script:PathTextBox = $null
$Script:TakeOwnCheck = $null
$Script:DriveCombo = $null
$Script:ContentPanel = $null
$Script:TabButtons = @{}
$Script:Pages = @{}
$Script:CurrentTab = ""
$Script:OperationRunning = $false
$Script:ActiveProcess = $null
$Script:RecycleBinCheck = $null
$Script:DryRunCheck = $null
$Script:MaxOutputChars = 50000

# ============================================================================
# COLOR THEME
# ============================================================================
$Script:Theme = @{
    BgPrimary    = [System.Drawing.Color]::FromArgb(18, 18, 22)
    BgSecondary  = [System.Drawing.Color]::FromArgb(26, 26, 32)
    BgTertiary   = [System.Drawing.Color]::FromArgb(34, 34, 42)
    BgCard       = [System.Drawing.Color]::FromArgb(30, 30, 38)
    BgInput      = [System.Drawing.Color]::FromArgb(22, 22, 28)
    BgHover      = [System.Drawing.Color]::FromArgb(45, 45, 55)
    BgInfo       = [System.Drawing.Color]::FromArgb(25, 35, 50)
    
    TextPrimary  = [System.Drawing.Color]::FromArgb(248, 248, 252)
    TextSecondary = [System.Drawing.Color]::FromArgb(180, 180, 195)
    TextMuted    = [System.Drawing.Color]::FromArgb(120, 120, 140)
    
    Accent       = [System.Drawing.Color]::FromArgb(105, 105, 255)
    AccentHover  = [System.Drawing.Color]::FromArgb(135, 135, 255)
    AccentDim    = [System.Drawing.Color]::FromArgb(70, 70, 180)
    
    TabActive    = [System.Drawing.Color]::FromArgb(105, 105, 255)
    TabInactive  = [System.Drawing.Color]::FromArgb(26, 26, 32)
    TabHover     = [System.Drawing.Color]::FromArgb(40, 40, 50)
    
    Success      = [System.Drawing.Color]::FromArgb(50, 210, 100)
    Warning      = [System.Drawing.Color]::FromArgb(255, 195, 55)
    Error        = [System.Drawing.Color]::FromArgb(255, 95, 95)
    Info         = [System.Drawing.Color]::FromArgb(85, 185, 255)
    
    Border       = [System.Drawing.Color]::FromArgb(55, 55, 70)
    InfoBorder   = [System.Drawing.Color]::FromArgb(55, 85, 130)
}

# ============================================================================
# EDUCATIONAL CONTENT
# ============================================================================
$Script:Education = @{
    ACL = @{
        Title = "What are ACLs?"
        Content = @"
ACCESS CONTROL LISTS (ACLs) are the Windows permission system that controls who can access files/folders and what they can do.

KEY CONCEPTS:
• ACE (Access Control Entry) - A single permission rule (e.g., "John: Read")
• DACL (Discretionary ACL) - List of who can access the object
• SACL (System ACL) - Audit settings (who to log when accessing)

COMMON PERMISSIONS:
• F = Full Control (read, write, execute, delete, change permissions)
• M = Modify (read, write, execute, delete - but can't change permissions)
• RX = Read & Execute
• R = Read only
• W = Write only

INHERITANCE FLAGS:
• (OI) = Object Inherit - applies to files in folder
• (CI) = Container Inherit - applies to subfolders
• (IO) = Inherit Only - doesn't apply to the folder itself

EXAMPLE: "Administrators:(OI)(CI)F" means Administrators get Full Control on this folder, all subfolders, and all files.

WHY THIS MATTERS:
When you get "Access Denied" errors, the ACL is blocking you. Taking ownership and granting permissions modifies the ACL to allow access.
"@
    }
    ADS = @{
        Title = "What are Alternate Data Streams?"
        Content = @"
ALTERNATE DATA STREAMS (ADS) are hidden data attached to files on NTFS filesystems - a feature most users don't know exists.

HOW IT WORKS:
Every file has a main stream (the actual content you see) called :`$DATA. But NTFS allows additional named streams attached to the same file that are invisible to normal tools.

COMMON ADS EXAMPLES:
• Zone.Identifier - Added by browsers to mark downloaded files. This is why Windows asks "This file came from another computer" - it's reading this stream!
• Malware hiding - Attackers can hide executables in streams
• Summary information - Some apps store metadata in streams

SYNTAX: filename.txt:streamname

SECURITY IMPLICATIONS:
• ADS can hide malicious code (file size appears normal!)
• Zone.Identifier blocks execution of untrusted downloads
• Copying to FAT32/exFAT strips all ADS (NTFS-only feature)

DETECTION:
• dir /r shows streams
• Get-Item -Stream * in PowerShell
• Streams.exe from Sysinternals

WHY "UNBLOCK" FILES:
When you right-click a file and choose "Unblock", you're deleting the Zone.Identifier stream.
"@
    }
    Ownership = @{
        Title = "What is File Ownership?"
        Content = @"
OWNERSHIP in Windows determines who has ultimate control over a file or folder and who can modify its permissions.

KEY CONCEPTS:
• Every file/folder has exactly ONE owner
• The owner can ALWAYS modify permissions, even if denied access
• Default owner is whoever created the file
• Administrators can take ownership of anything

SPECIAL OWNERS:
• BUILTIN\Administrators - The Administrators group
• NT AUTHORITY\SYSTEM - Windows itself
• NT SERVICE\TrustedInstaller - Protects Windows system files

WHY TAKE OWNERSHIP:
When you encounter "Access Denied" even as Administrator, it's often because:
1. TrustedInstaller owns the file (system protection)
2. The file was created by another user/system
3. Permissions explicitly deny Administrators

THE PROCESS:
1. takeown /F "path" /A - Claims ownership for Administrators
2. icacls "path" /grant Administrators:F - Grants Full Control
3. Now you can delete/modify the file

WARNING:
Taking ownership of system files can break Windows! Only do this for files you're sure aren't critical system components.
"@
    }
    OrphanedSID = @{
        Title = "What are Orphaned SIDs?"
        Content = @"
ORPHANED SIDs are permission entries for deleted user accounts that clutter your ACLs.

WHAT'S A SID?
Security Identifier - Windows' internal ID for users/groups. Example: S-1-5-21-3623811015-3361044348-30300820-1013

WHAT HAPPENS:
1. User "John" is created → Gets SID S-1-5-21-xxx-1001
2. John is given access to files → ACL stores his SID
3. John's account is deleted → SID no longer resolves to a name
4. ACL shows: "S-1-5-21-xxx-1001: Full Control" instead of "John: Full Control"

WHY CLEAN THEM UP:
• Clutters permission displays
• Can cause confusion about who has access
• May indicate security issues (unknown accounts)
• Slows down permission inheritance calculations

IDENTIFICATION:
Orphaned SIDs appear as "S-1-5-21-..." instead of readable names in:
• File Properties → Security tab
• icacls output

SAFE TO REMOVE:
Yes - if the account no longer exists, these entries serve no purpose and can't grant access to anyone.
"@
    }
    BootDelete = @{
        Title = "What is Boot-Time Deletion?"
        Content = @"
BOOT-TIME DELETION schedules file removal for the next system restart, before Windows fully loads.

WHY IT EXISTS:
Some files are locked by running processes and can't be deleted while Windows is running:
• System services holding files open
• DLLs loaded by running programs
• Files locked by antivirus real-time scanning
• Malware protecting itself

HOW IT WORKS:
1. MoveFileEx API with MOVEFILE_DELAY_UNTIL_REBOOT flag
2. Windows stores the request in registry
3. During early boot, Session Manager (smss.exe) processes deletions
4. Files are removed BEFORE services start

REGISTRY LOCATION:
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations

WHAT CAN BE DELETED:
• Locked application files
• Stubborn malware (before it can start)
• Windows Update leftovers
• Crashed application temp files

LIMITATIONS:
• Requires reboot to take effect
• Some rootkits load before smss.exe
• Files on network drives may fail
• If boot fails, deletions don't occur

USE CASES:
• Antivirus cleaning quarantine failures
• Removing software that won't uninstall
• Clearing locked temp files
"@
    }
    Robocopy = @{
        Title = "How Does Robocopy Mirror Deletion Work?"
        Content = @"
ROBOCOPY MIRROR TRICK is a clever technique to delete stubborn folders by "mirroring" an empty folder over them.

THE TECHNIQUE:
1. Create an empty folder
2. robocopy EmptyFolder TargetFolder /MIR
3. /MIR makes target IDENTICAL to source
4. Since source is empty, everything in target gets deleted
5. Then remove the now-empty target folder

WHY IT WORKS:
Robocopy uses different file APIs than Explorer/PowerShell:
• Opens files with backup semantics
• Has robust retry logic
• Handles long paths natively
• Can override some locks

ADVANTAGES:
• Works on paths > 260 characters
• Handles some locked files
• Very fast for deep folder trees
• Provides detailed logging

PARAMETERS EXPLAINED:
• /MIR - Mirror mode (copy + delete extras)
• /R:0 - Don't retry on failure
• /W:0 - Don't wait between retries
• /NFL - No file list (quieter output)
• /NDL - No directory list
• /NJH - No job header
• /NJS - No job summary

WHEN TO USE:
• Folder trees with thousands of files
• Paths containing special characters
• When standard deletion is too slow
• Folders with deep nesting
"@
    }
    CHKDSK = @{
        Title = "Understanding CHKDSK Parameters"
        Content = @"
CHKDSK (Check Disk) repairs filesystem corruption on NTFS/FAT32/exFAT volumes.

PARAMETER BREAKDOWN:

/SCAN (Windows 8+)
• Online scan - no volume lock needed
• Finds problems without fixing
• Safe to run anytime
• Use: Quick health check

/F (Fix)
• Fixes filesystem errors
• REQUIRES exclusive volume lock
• System drive: schedules for boot
• Use: After /scan finds issues

/R (Recover)
• Everything /F does PLUS
• Scans for bad sectors
• Attempts data recovery from bad sectors
• Takes HOURS on large drives
• Use: Suspected physical drive problems

/X (Force Dismount)
• Forces volume offline
• Closes all open handles
• Use: When /F can't get a lock

/SPOTFIX (Windows 8+)
• Ultra-fast targeted repair
• Fixes only issues logged in $corrupt file
• Requires brief offline window
• Use: After /scan on servers

/B (Re-evaluate Bad Clusters)
• Clears bad cluster list
• Rescans all "bad" sectors
• Use: After cloning to new drive

BEST PRACTICES:
1. Run /scan first (safe, online)
2. If issues found, schedule /F
3. Only run /R if physical issues suspected
4. Back up before any repair operation
"@
    }
    SFC_DISM = @{
        Title = "SFC vs DISM - What's the Difference?"
        Content = @"
SFC and DISM are complementary but DIFFERENT system repair tools. Order matters!

SFC (System File Checker)
• Repairs protected SYSTEM FILES
• Compares files against cached copies
• Source: WinSxS component store
• Command: sfc /scannow

DISM (Deployment Image Servicing)
• Repairs the COMPONENT STORE itself
• Downloads fresh copies from Windows Update
• Must run BEFORE SFC if component store is corrupt
• Command: DISM /Online /Cleanup-Image /RestoreHealth

WHY ORDER MATTERS:
1. SFC needs the component store to get clean file copies
2. If component store is corrupt, SFC repair FAILS
3. DISM fixes the component store
4. Then SFC can successfully repair system files

CORRECT ORDER:
1. DISM /Online /Cleanup-Image /RestoreHealth (15-30 min)
2. sfc /scannow (10-15 min)
3. Reboot
4. Run sfc /scannow again to verify

DISM OPTIONS:
• /CheckHealth - Quick component store check
• /ScanHealth - Deeper scan for corruption
• /RestoreHealth - Repair using Windows Update
• /Source:path - Use local .wim file instead

LOG FILES:
• SFC: %WinDir%\Logs\CBS\CBS.log
• DISM: %WinDir%\Logs\DISM\dism.log

WHEN TO USE:
• Windows Update failures
• Random application crashes
• Missing DLL errors
• Boot problems
"@
    }
    SMART = @{
        Title = "Understanding SMART Diagnostics"
        Content = @"
SMART (Self-Monitoring, Analysis, and Reporting Technology) provides early warning of drive failure.

CRITICAL ATTRIBUTES TO MONITOR:

ID 05 - Reallocated Sector Count
• Bad sectors moved to spare area
• ANY non-zero value = drive degradation
• Rising count = imminent failure likely

ID C5 - Current Pending Sectors
• Sectors waiting to be tested/remapped
• Non-zero = potential data loss
• Often precedes ID 05 increase

ID C6 - Uncorrectable Sector Count
• Sectors that couldn't be read OR remapped
• Drives with C6 > 0 are 39x MORE LIKELY to fail within 60 days!
• This is the most critical indicator

ID C4 - Reallocation Event Count
• Number of remap operations
• High churn = controller struggling

ID 01 - Raw Read Error Rate
• Don't panic! Interpretation varies by manufacturer
• Some drives report high values normally

PREDICTFAILURE STATUS:
Windows WMI reports boolean PredictFailure:
• FALSE = No imminent failure detected
• TRUE = BACKUP IMMEDIATELY!

SSD-SPECIFIC:
• SSDs don't have mechanical SMART attributes
• Monitor: Wear Leveling Count, Percentage Used
• Different failure modes than HDDs

BACKUP TRIGGERS:
• PredictFailure = TRUE
• ID 05 > 100
• ID C5 > 0 (investigate)
• ID C6 > 0 (critical!)
• Clicking/grinding sounds (HDDs)
"@
    }
    DirtyBit = @{
        Title = "What is the Dirty Bit?"
        Content = @"
The DIRTY BIT is a filesystem flag indicating the volume wasn't cleanly unmounted and may have corruption.

HOW IT WORKS:
1. When you mount a volume, Windows sets dirty bit = 1
2. On clean unmount, Windows sets dirty bit = 0
3. If system crashes/loses power, bit stays = 1
4. On next boot, Windows sees dirty bit and runs CHKDSK

WHY IT EXISTS:
NTFS uses write caching for performance. If power is lost:
• Cached writes may not have reached disk
• MFT (Master File Table) might be inconsistent
• Directory indexes could be corrupted
• Journal entries might be incomplete

CHECKING STATUS:
fsutil dirty query C:
• "Volume - C: is Dirty" = CHKDSK will run at boot
• "Volume - C: is NOT Dirty" = Volume is clean

SETTING DIRTY BIT MANUALLY:
fsutil dirty set C:
• Forces CHKDSK on next boot
• Useful when you suspect corruption
• Can't be un-set except by running CHKDSK

BOOT BEHAVIOR:
1. Windows starts loading
2. Autochk.exe runs (before GUI)
3. Checks dirty bit on each volume
4. Runs CHKDSK if dirty
5. Clears dirty bit when done
6. Windows continues booting

FALSE POSITIVES:
Sometimes the dirty bit gets stuck on:
• Driver bugs
• Disk controller issues
• BIOS bugs with AHCI/IDE mode
"@
    }
    NTFSSelfHealing = @{
        Title = "NTFS Self-Healing Explained"
        Content = @"
NTFS SELF-HEALING automatically repairs certain filesystem corruptions in the background without requiring CHKDSK.

INTRODUCED: Windows Vista/Server 2008

HOW IT WORKS:
1. NTFS detects corruption during normal I/O
2. Logs the issue to $Corrupt system file
3. Worker thread attempts automatic repair
4. Repairs happen online - no reboot needed
5. Reduces CHKDSK requirements

WHAT IT CAN FIX:
• Minor MFT inconsistencies
• Index entry corruption
• Security descriptor issues
• Small structural problems

WHAT IT CAN'T FIX:
• Major MFT damage
• Cross-linked clusters
• Bad sector data loss
• Hardware failures

CONFIGURATION:
fsutil repair query C:    - Check current state
fsutil repair set C: 1    - Enable self-healing
fsutil repair set C: 0    - Disable self-healing

REPAIR FLAGS:
• 0x01 - Enable general repair
• 0x08 - Warn about potential data loss
• 0x10 - Disabled

MONITORING:
Event Log: System
Source: Ntfs
Event ID 55: Self-healing triggered
Event ID 98: Volume needs offline CHKDSK (self-healing couldn't fix it)

BEST PRACTICE:
Keep self-healing enabled (default). It reduces unexpected CHKDSK boot delays and handles minor issues automatically.
"@
    }
    LongPath = @{
        Title = "Understanding Long Paths (MAX_PATH)"
        Content = @"
MAX_PATH is Windows' traditional 260-character path limit that causes "path too long" errors.

WHY 260 CHARACTERS?
Historical DOS/Windows limitation:
Drive (2) + Backslash (1) + Path (256) + NULL (1) = 260

THE PROBLEM:
• Modern apps create deep folder structures
• Package managers (npm, gradle) nest dependencies
• Cloud sync can create long paths
• Filename + path can easily exceed 260

THE \\?\ PREFIX SOLUTION:
Adding "\\?\" before a path tells Windows to:
• Skip path normalization
• Bypass the 260 character limit
• Allow up to ~32,767 characters
• Works with most low-level APIs

EXAMPLES:
Standard:  C:\Very\Long\Path\file.txt
Long path: \\?\C:\Very\Long\Path\file.txt

WINDOWS 10+ LONG PATH SUPPORT:
Registry: HKLM\SYSTEM\CurrentControlSet\Control\FileSystem
Value: LongPathsEnabled = 1
• Enables long paths system-wide
• Apps must also declare support in manifest

POWERSHELL:
• -LiteralPath handles \\?\ paths
• .NET 4.6.2+ handles long paths natively

TOOLS THAT HANDLE LONG PATHS:
• robocopy (always worked)
• 7-Zip
• cmd.exe with \\?\
• Modern PowerShell (v5.1+)

TOOLS THAT DON'T:
• Windows Explorer (partially fixed in Win10)
• Many older applications
• Some backup software
"@
    }
    ShortName = @{
        Title = "8.3 Short Names Explained"
        Content = @"
8.3 SHORT NAMES are DOS-compatible alternate filenames that Windows maintains for compatibility.

FORMAT: 8 characters + dot + 3 character extension
Example: "My Long Document.docx" → "MYLONG~1.DOC"

HOW THEY'RE GENERATED:
1. Take first 6 characters (strip spaces/invalid chars)
2. Add ~1 (increment if collision: ~2, ~3...)
3. Truncate extension to 3 characters
4. Uppercase everything

WHY THEY EXIST:
• DOS/16-bit app compatibility
• Some old installers require them
• Alternative access for problematic filenames

WHY THEY'RE USEFUL FOR DELETION:
Short names bypass filename problems:
• No special characters in short name
• Maximum 12 characters total
• Always valid in all Windows APIs

EXAMPLE DELETION:
Long name: "file?.txt" (invalid character)
Short name: "FILE_~1.TXT"
Delete via: del FILE_~1.TXT (success!)

CHECKING SHORT NAMES:
• dir /x - Shows both names
• fsutil 8dot3name query C: - Check if enabled

PERFORMANCE NOTE:
8.3 names have overhead:
• Extra disk space in MFT
• Slower file creation
• Index maintenance

SERVER RECOMMENDATION:
Microsoft recommends disabling on volumes with many files:
fsutil 8dot3name set C: 1  (disable)

HOME USE:
Keep enabled - useful for troubleshooting and compatibility.
"@
    }
    ReparsePoints = @{
        Title = "Symbolic Links and Junction Points"
        Content = @"
REPARSE POINTS are NTFS pointers that redirect filesystem operations to another location.

TYPES:

SYMBOLIC LINKS (symlinks)
• Can point to files OR folders
• Can cross volume boundaries
• Can point to network paths (UNC)
• Requires elevation to create
• Command: mklink [/D] LinkName Target

JUNCTION POINTS
• Folders only
• Same volume only (local paths)
• No elevation required
• Command: mklink /J LinkName Target

HARD LINKS
• Files only
• Same volume only
• Not a reparse point (different mechanism)
• Multiple directory entries → same data
• Command: mklink /H LinkName Target

DELETION SAFETY:
- DeleteFile removes a file symlink itself, not its target.
- RemoveDirectory removes a directory symlink or junction itself, not its target.
- Recursive tools remain dangerous if they enumerate through a link before removing it.

PATHFORGE SAFE DELETION:
- Reads the reparse tag and target through FSCTL_GET_REPARSE_POINT.
- Uses DeleteFile or RemoveDirectory only on a path re-inspected as a link.
- Never applies recursive deletion to a link target.

IDENTIFICATION:
• dir shows <SYMLINK>, <JUNCTION>, <SYMLINKD>
• Get-Item shows ReparsePoint attribute
• Target shown in brackets

COMMON USES:
• C:\Users\Username\AppData\Local\Application Data → junction to local folder
• C:\Documents and Settings → junction to C:\Users
• Developer: node_modules symlink to shared cache

PATHFORGE BEHAVIOR:
The Link Inspector identifies junctions, symbolic links, and hard-link sibling names. The Reparse Explorer scans without descending into discovered links. Link-only deletion requires confirmation and leaves target data reachable through its canonical path or remaining hard-link names.
"@
    }
}

# ============================================================================
# LOGGING
# ============================================================================
function Initialize-Logging {
    if (-not (Test-Path $Script:Config.LogPath)) {
        New-Item -Path $Script:Config.LogPath -ItemType Directory -Force | Out-Null
    }
    $Script:LogFile = Join-Path $Script:Config.LogPath "Session_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Get-ChildItem -Path $Script:Config.LogPath -Filter "*.log" -ErrorAction SilentlyContinue | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Script:Config.MaxLogAge) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if ($Script:LogFile) {
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
        Add-Content -Path $Script:LogFile -Value $entry -ErrorAction SilentlyContinue
    }
}

function Write-Console {
    param([string]$Message, [string]$Type = "Normal")
    if ($Script:OutputBox -and $Script:OutputBox.IsHandleCreated) {
        $color = switch ($Type) {
            "Success" { $Script:Theme.Success }
            "Warning" { $Script:Theme.Warning }
            "Error"   { $Script:Theme.Error }
            "Info"    { $Script:Theme.Info }
            "Progress" { $Script:Theme.AccentDim }
            default   { $Script:Theme.TextSecondary }
        }
        $prefix = switch ($Type) {
            "Success"  { "[+] " }
            "Warning"  { "[!] " }
            "Error"    { "[x] " }
            "Info"     { "[>] " }
            "Progress" { "[~] " }
            default    { "    " }
        }
        $Script:OutputBox.SelectionStart = $Script:OutputBox.TextLength
        $Script:OutputBox.SelectionLength = 0
        $Script:OutputBox.SelectionColor = $color
        $Script:OutputBox.AppendText("$prefix$Message`r`n")
        Invoke-ConsoleOutputTrim
        $Script:OutputBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Invoke-ConsoleOutputTrim {
    if (-not $Script:OutputBox -or $Script:OutputBox.TextLength -le $Script:MaxOutputChars) {
        return
    }

    $marker = "[Output trimmed -- oldest entries removed]`r`n"
    $targetLength = [Math]::Max(0, $Script:MaxOutputChars - $marker.Length)
    $removeLength = $Script:OutputBox.TextLength - $targetLength
    if ($removeLength -gt 0 -and $removeLength -lt $Script:OutputBox.TextLength) {
        $lineBreak = $Script:OutputBox.Text.IndexOf("`n", $removeLength)
        if ($lineBreak -ge 0) {
            $removeLength = $lineBreak + 1
        }
        $Script:OutputBox.Select(0, $removeLength)
        $Script:OutputBox.SelectedText = $marker
    }
}

function Export-ConsoleOutput {
    if (-not $Script:OutputBox -or [string]::IsNullOrWhiteSpace($Script:OutputBox.Text)) {
        Set-Status "Console is empty"
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:Config.LogPath)) {
            New-Item -Path $Script:Config.LogPath -ItemType Directory -Force | Out-Null
        }

        $outputPath = Join-Path $Script:Config.LogPath "Console_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        [System.IO.File]::WriteAllText(
            $outputPath,
            $Script:OutputBox.Text,
            [System.Text.UTF8Encoding]::new($false))

        Set-Status "Console saved: $outputPath"
        Write-Log "Console output saved: $outputPath" -Level "SUCCESS"
        return $outputPath
    }
    catch {
        Set-Status "Console save failed"
        Write-Console "Failed to save console output: $_" -Type "Error"
        Write-Log "Console output save failed: $_" -Level "ERROR"
        return $null
    }
}

function Set-Status {
    param([string]$Message)
    if ($Script:StatusLabel) {
        $Script:StatusLabel.Text = "  $Message"
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-Progress {
    param([int]$Value, [int]$Maximum = 100)
    if ($Script:ProgressBar) {
        $Script:ProgressBar.Maximum = $Maximum
        $Script:ProgressBar.Value = [Math]::Min($Value, $Maximum)
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ============================================================================
# OPERATION GUARD
# ============================================================================
function Enter-Operation {
    param([string]$Name)
    if ($Script:OperationRunning) {
        Write-Console "An operation is already running. Wait for it to finish or cancel." -Type "Warning"
        return $false
    }
    $Script:OperationRunning = $true
    Write-Log "Operation started: $Name"
    return $true
}

function Exit-Operation {
    $Script:OperationRunning = $false
    $Script:ActiveProcess = $null
    Set-Status "Ready"
    Set-Progress -Value 0
}

function Stop-ActiveOperation {
    if ($Script:ActiveProcess -and -not $Script:ActiveProcess.HasExited) {
        try {
            $Script:ActiveProcess.Kill()
            Write-Console "Operation cancelled by user" -Type "Warning"
            Write-Log "Operation cancelled by user" -Level "WARN"
        }
        catch { Write-Log "Failed to cancel: $_" -Level "ERROR" }
    }
    Exit-Operation
}

# ============================================================================
# PATH VALIDATION
# ============================================================================
function Get-ValidatedPath {
    $raw = $Script:PathTextBox.Text
    $check = Test-SafePath -Path $raw
    if (-not $check.Valid) {
        Write-Console "Invalid path: $($check.Reason)" -Type "Error"
        Write-Log "Path validation failed: $raw - $($check.Reason)" -Level "ERROR"
        Set-Status "Ready"
        return $null
    }
    return $raw
}

function Receive-PathDrop {
    param(
        [object]$DataObject,
        [object]$TargetTextBox = $Script:PathTextBox
    )

    if (-not $TargetTextBox -or -not $DataObject -or -not $DataObject.GetDataPresent('FileDrop')) {
        return $false
    }

    $droppedPaths = @($DataObject.GetData('FileDrop'))
    if ($droppedPaths.Count -eq 0) {
        return $false
    }

    $candidate = [string]$droppedPaths[0]
    $check = Test-SafePath -Path $candidate
    if (-not $check.Valid) {
        Write-Console "Dropped path rejected: $($check.Reason)" -Type "Error"
        return $false
    }

    $TargetTextBox.Text = $candidate
    Set-Status "Path loaded from Explorer"
    Write-Console "Path dropped: $candidate" -Type "Info"
    if ($droppedPaths.Count -gt 1) {
        Write-Console "Multiple paths were dropped; using the first of $($droppedPaths.Count)" -Type "Warning"
    }
    return $true
}

# ============================================================================
# MAIN FORCE DELETE FUNCTION
# ============================================================================
function Invoke-ForceDelete {
    param(
        [string]$Path,
        [switch]$TakeOwnership,
        [switch]$DryRun
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        Write-Log "Path rejected: $Path - $($check.Reason)" -Level "ERROR"
        return $false
    }

    Write-Console "Processing: $Path" -Type "Info"
    Write-Log "Force delete initiated: $Path"

    if (-not (Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath "\\?\$Path")) {
        Write-Console "Path not found" -Type "Error"
        return $false
    }

    if ($DryRun) {
        $includeRecycleBin = $Script:RecycleBinCheck -and $Script:RecycleBinCheck.Checked
        $plan = Get-PathForgeDeletionPlan -Path $Path -IncludeRecycleBin:$includeRecycleBin -TakeOwnership:$TakeOwnership
        if (-not $plan.Success) {
            Write-Console "Dry-run failed: $($plan.Error)" -Type "Error"
            Set-Status "Ready"
            return $false
        }

        Write-Console "=== DRY-RUN DELETION PLAN ===" -Type "Info"
        Write-Console "No files will be changed or deleted" -Type "Warning"
        Write-Console "Target: $($plan.Path)" -Type "Normal"
        Write-Console "Type: $(if ($plan.IsContainer) { 'Directory' } else { 'File' }); Filesystem: $($plan.FileSystem); Reparse point: $($plan.IsReparsePoint)" -Type "Normal"
        Write-Console "Previewed items: $($plan.ItemCount); Data size: $([math]::Round($plan.TotalBytes / 1MB, 2)) MB" -Type "Normal"
        if ($plan.Truncated) {
            Write-Console "Preview truncated at the safety limit; the real operation would include additional descendants" -Type "Warning"
        }

        Write-Console "" -Type "Normal"
        Write-Console "Method plan:" -Type "Info"
        foreach ($method in $plan.Methods) {
            $state = if ($method.Applicable) { 'WOULD TRY' } else { 'SKIP' }
            Write-Console "  [$state] $($method.Name) - $($method.Api)" -Type $(if ($method.Applicable) { 'Progress' } else { 'Normal' })
            Write-Console "           $($method.Reason)" -Type "Normal"
        }

        Write-Console "" -Type "Normal"
        Write-Console "Sample targets:" -Type "Info"
        foreach ($samplePath in $plan.SamplePaths) {
            Write-Console "  $samplePath" -Type "Normal"
        }
        if ($plan.ItemCount -gt $plan.SamplePaths.Count) {
            Write-Console "  ... and $($plan.ItemCount - $plan.SamplePaths.Count) more previewed item(s)" -Type "Normal"
        }

        Write-Log "Dry-run deletion plan generated for $Path" -Level "INFO"
        Set-Status "Dry-run complete - no changes made"
        return $true
    }

    $lockers = @(Get-FileLockProcess -Path $Path)
    foreach ($locker in $lockers) {
        Write-Console "Locked by: $($locker.ProcessName) (PID $($locker.ProcessId))" -Type "Warning"
        Write-Log "Locking process detected: $($locker.ProcessName) (PID $($locker.ProcessId)) for $Path" -Level "WARN"
    }

    if (Test-ReparsePoint -Path $Path) {
        $linkInfo = Get-PathForgeLinkInfo -Path $Path
        if (-not $linkInfo.Success -or -not $linkInfo.CanSafeDeleteLink) {
            $reason = if ($linkInfo.Error) { $linkInfo.Error } else { "Tag $($linkInfo.ReparseTagHex) is not a recognized junction or symbolic link" }
            Write-Console "Refusing generic deletion of reparse point: $reason" -Type "Error"
            Write-Console "Use Link Inspector to review this object; recursive methods will not run." -Type "Warning"
            return $false
        }

        Write-Console "Detected $($linkInfo.Kind): $($linkInfo.Path)" -Type "Warning"
        Write-Console "Target: $($linkInfo.Target)" -Type "Info"
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Remove only this $($linkInfo.Kind)?`n`nLink: $($linkInfo.Path)`nTarget (will remain untouched): $($linkInfo.Target)",
            "Link Detected", 4, 48)
        if ($result -ne 6) {
            Write-Console "Link deletion cancelled; no fallback method was run" -Type "Warning"
            return $false
        }

        $linkResult = Remove-PathForgeLinkSafe -Path $Path -Confirm:$false
        if ($linkResult.Success) {
            Write-Console "Link removed without traversing its target" -Type "Success"
            Write-Log "Link-only deletion succeeded: $Path" -Level "SUCCESS"
            return $true
        }
        Write-Console "Link-only deletion failed: $($linkResult.Error)" -Type "Error"
        return $false
    }

    if ($Script:RecycleBinCheck -and $Script:RecycleBinCheck.Checked) {
        Write-Console "  Attempting Recycle Bin (recoverable)..." -Type "Progress"
        $rbResult = Move-ToRecycleBin -Path $Path
        if ($rbResult.Success) {
            Write-Console "SUCCESS via Recycle Bin (recoverable from trash)" -Type "Success"
            Write-Log "Recycle Bin success: $Path" -Level "SUCCESS"
            Set-Status "Ready"
            return $true
        }
        Write-Console "  Recycle Bin failed: $($rbResult.Error) -- escalating to permanent delete" -Type "Warning"
    }
    
    if ($TakeOwnership) {
        Write-Console "Taking ownership..." -Type "Progress"
        Set-Status "Taking ownership..."
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        if ($isDir) {
            $null = takeown /F $Path /A /R /D Y 2>&1
            $null = icacls $Path /grant "Administrators:(OI)(CI)F" /T /C /Q 2>&1
        }
        else {
            $null = takeown /F $Path /A 2>&1
            $null = icacls $Path /grant "Administrators:F" /C /Q 2>&1
        }
        Write-Console "Ownership claimed, permissions granted" -Type "Success"
    }
    
    $fs = Get-VolumeFileSystem -Path $Path
    $methods = @(
        @{Name = "Standard PowerShell"; Func = "Remove-ItemStandard" },
        @{Name = ".NET Framework"; Func = "Remove-ItemDotNet" },
        @{Name = "Long Path (\\?\)"; Func = "Remove-ItemLongPath" })
    if ($fs -eq "NTFS") {
        $methods += @{Name = "8.3 Short Name"; Func = "Remove-ItemShortName" }
    }
    elseif ($fs -ne "Unknown") {
        Write-Console "  Skipping 8.3 Short Name method ($fs does not support short names)" -Type "Normal"
    }
    $methods += @(
        @{Name = "Robocopy Mirror"; Func = "Remove-ItemRobocopy" },
        @{Name = "WMI/CIM"; Func = "Remove-ItemWMI" }
    )
    
    $i = 0
    foreach ($method in $methods) {
        $i++
        Set-Progress -Value $i -Maximum $methods.Count
        Set-Status "Method $i/$($methods.Count): $($method.Name)"
        Write-Console "  Method $i/$($methods.Count): $($method.Name)..." -Type "Progress"
        
        $result = & $method.Func -Path $Path
        
        if ($result.Success) {
            Write-Console "SUCCESS via $($result.Method)" -Type "Success"
            Write-Log "Success via $($result.Method): $Path" -Level "SUCCESS"
            Set-Status "Ready"
            Set-Progress -Value 0
            return $true
        }
        else {
            Write-Console "  Failed: $($result.Error)" -Type "Normal"
        }
    }
    
    Write-Console "All $($methods.Count) deletion methods failed" -Type "Error"
    Write-Log "All $($methods.Count) methods failed: $Path" -Level "ERROR"
    Set-Status "Ready"
    Set-Progress -Value 0
    
    $result = [System.Windows.Forms.MessageBox]::Show(
        "All deletion methods failed. Schedule for boot-time deletion?`n`nThe file will be deleted on next restart before Windows fully loads.",
        "Deletion Failed", 4, 32)
    
    if ($result -eq 6) {
        return Invoke-BootTimeDelete -Path $Path
    }
    
    return $false
}

function Invoke-DeletionBatch {
    param(
        [string]$BatchPath,
        [switch]$ForceDryRun,
        [scriptblock]$ConfirmAction
    )

    try {
        $records = @(Import-PathForgeDeletionBatch -Path $BatchPath)
    }
    catch {
        Write-Console "Batch import failed: $_" -Type "Error"
        return $null
    }

    if ($records.Count -eq 0) {
        Write-Console "Batch file contains no actionable rows" -Type "Warning"
        return $null
    }

    Write-Console "=== DELETION BATCH ===" -Type "Info"
    Write-Console "Source: $BatchPath" -Type "Normal"
    Write-Console "Rows: $($records.Count)" -Type "Normal"

    foreach ($record in $records) {
        if ($record.Valid) {
            $rowMode = if ($ForceDryRun -or $record.DryRun) { 'DRY-RUN' } else { 'DELETE' }
            Write-Console "  Line $($record.LineNumber): [$rowMode/$($record.Method)] $($record.Path)" -Type "Normal"
        }
        else {
            Write-Console "  Line $($record.LineNumber): INVALID - $($record.Error)" -Type "Error"
        }
    }

    $validRecords = @($records | Where-Object Valid)
    $mutatingRecords = @($validRecords | Where-Object { -not $ForceDryRun -and -not $_.DryRun })
    if ($validRecords.Count -eq 0) {
        Write-Console "No valid rows to process" -Type "Error"
        return [PSCustomObject]@{Total = $records.Count; Succeeded = 0; Failed = $records.Count; Simulated = 0; Cancelled = $false }
    }

    if ($mutatingRecords.Count -gt 0) {
        $message = "Process $($validRecords.Count) valid batch row(s)?`n`n$($mutatingRecords.Count) row(s) can delete files or modify the reboot queue. Review the console preview before continuing."
        $confirmation = if ($ConfirmAction) {
            & $ConfirmAction $message
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "Confirm Deletion Batch",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        if ($confirmation -ne 6) {
            Write-Console "Batch cancelled before any row was processed" -Type "Warning"
            return [PSCustomObject]@{Total = $records.Count; Succeeded = 0; Failed = 0; Simulated = 0; Cancelled = $true }
        }
    }

    if (-not (Enter-Operation "Deletion batch")) { return $null }
    $succeeded = 0
    $failed = @($records | Where-Object { -not $_.Valid }).Count
    $simulated = 0

    try {
        $rowIndex = 0
        foreach ($record in $validRecords) {
            $rowIndex++
            Set-Progress -Value $rowIndex -Maximum $validRecords.Count
            Set-Status "Batch row $rowIndex/$($validRecords.Count): $($record.Method)"
            $dryRun = [bool]($ForceDryRun -or $record.DryRun)

            if ($dryRun) {
                $result = Invoke-PathForgeDeletionMethod -Path $record.Path -Method $record.Method `
                    -IncludeRecycleBin:($Script:RecycleBinCheck -and $Script:RecycleBinCheck.Checked) -WhatIf
            }
            else {
                $result = Invoke-PathForgeDeletionMethod -Path $record.Path -Method $record.Method `
                    -IncludeRecycleBin:($Script:RecycleBinCheck -and $Script:RecycleBinCheck.Checked) -Confirm:$false
            }

            if ($result.Simulated) {
                $simulated++
                Write-Console "  [DRY-RUN] Line $($record.LineNumber): would use $($record.Method) on $($record.Path)" -Type "Info"
            }
            elseif ($result.Success) {
                $succeeded++
                Write-Console "  [SUCCESS] Line $($record.LineNumber): $($result.EffectiveMethod)" -Type "Success"
            }
            else {
                $failed++
                Write-Console "  [FAILED] Line $($record.LineNumber): $($result.Error)" -Type "Error"
            }
        }
    }
    finally {
        Exit-Operation
    }

    Write-Console "Batch complete: $succeeded succeeded, $simulated simulated, $failed failed/invalid" -Type $(if ($failed -gt 0) { 'Warning' } else { 'Success' })
    Write-Log "Deletion batch complete: source=$BatchPath success=$succeeded simulated=$simulated failed=$failed" -Level "INFO"
    return [PSCustomObject]@{Total = $records.Count; Succeeded = $succeeded; Failed = $failed; Simulated = $simulated; Cancelled = $false }
}

function Show-DeletionBatchDialog {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select PathForge deletion batch"
    $dialog.Filter = "Deletion batches (*.csv;*.txt)|*.csv;*.txt|CSV files (*.csv)|*.csv|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    Invoke-DeletionBatch -BatchPath $dialog.FileName -ForceDryRun:($Script:DryRunCheck -and $Script:DryRunCheck.Checked) | Out-Null
}

# ============================================================================
# OWNERSHIP & PERMISSIONS
# ============================================================================
function Invoke-TakeOwnership {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        return $false
    }

    Write-Console "Taking ownership: $Path" -Type "Info"
    Write-Console "Running: takeown /F `"$Path`" /A /R /D Y" -Type "Progress"
    Set-Status "Taking ownership..."
    
    try {
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        if ($isDir) {
            $takeownOutput = takeown /F $Path /A /R /D Y 2>&1
            foreach ($line in $takeownOutput) {
                if ($line -match "SUCCESS" -or $line -match "ERROR") {
                    Write-Console "  $line" -Type $(if ($line -match "ERROR") { "Warning" } else { "Normal" })
                }
            }
            Write-Console "Running: icacls `"$Path`" /grant Administrators:(OI)(CI)F /T /C /Q" -Type "Progress"
            $null = icacls $Path /grant "Administrators:(OI)(CI)F" /T /C /Q 2>&1
        }
        else {
            $null = takeown /F $Path /A 2>&1
            Write-Console "Running: icacls `"$Path`" /grant Administrators:F /C /Q" -Type "Progress"
            $null = icacls $Path /grant "Administrators:F" /C /Q 2>&1
        }
        Write-Console "Ownership transferred to Administrators group" -Type "Success"
        Write-Console "Full Control permissions granted" -Type "Success"
        Write-Log "Ownership taken: $Path" -Level "SUCCESS"
        Set-Status "Ready"
        return $true
    }
    catch {
        Write-Console "Failed: $_" -Type "Error"
        Set-Status "Ready"
        return $false
    }
}

function Reset-ItemPermissions {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        return $false
    }

    Write-Console "Resetting permissions to inherited defaults: $Path" -Type "Info"
    Write-Console "Running: icacls `"$Path`" /reset /T /C /Q" -Type "Progress"
    Set-Status "Resetting permissions..."
    
    try {
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        if ($isDir) {
            $output = icacls $Path /reset /T /C /Q 2>&1
        }
        else {
            $output = icacls $Path /reset /C /Q 2>&1
        }
        
        foreach ($line in $output) {
            if ($line -and $line.ToString().Trim()) {
                Write-Console "  $line" -Type "Normal"
            }
        }
        
        Write-Console "Permissions reset to inherited defaults" -Type "Success"
        Set-Status "Ready"
        return $true
    }
    catch {
        Write-Console "Failed: $_" -Type "Error"
        Set-Status "Ready"
        return $false
    }
}

function Backup-ACL {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) { Write-Console "Rejected: $($check.Reason)" -Type "Error"; return $false }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $Script:Config.LogPath "ACL_Backup_$timestamp.txt"
    
    Write-Console "Backing up ACLs: $Path" -Type "Info"
    Write-Console "Running: icacls `"$Path`" /save `"$backupFile`" /T" -Type "Progress"
    Set-Status "Backing up ACLs..."
    
    try {
        $output = icacls $Path /save $backupFile /T 2>&1
        
        if (Test-Path $backupFile) {
            $lineCount = (Get-Content $backupFile).Count
            Write-Console "ACL backup saved: $backupFile" -Type "Success"
            Write-Console "Entries saved: $lineCount" -Type "Info"
        }
        else {
            Write-Console "Backup file was not created" -Type "Warning"
        }
        
        Set-Status "Ready"
        return $true
    }
    catch {
        Write-Console "Backup failed: $_" -Type "Error"
        Set-Status "Ready"
        return $false
    }
}

function Restore-ACL {
    param([string]$Path, [string]$BackupFile)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) { Write-Console "Rejected: $($check.Reason)" -Type "Error"; return $false }

    Write-Console "Restoring ACLs from: $BackupFile" -Type "Info"
    Write-Console "Running: icacls `"$Path`" /restore `"$BackupFile`"" -Type "Progress"
    Set-Status "Restoring ACLs..."
    
    try {
        $output = icacls $Path /restore $BackupFile 2>&1
        
        foreach ($line in $output) {
            if ($line -and $line.ToString().Trim()) {
                Write-Console "  $line" -Type "Normal"
            }
        }
        
        Write-Console "ACL restore complete" -Type "Success"
        Set-Status "Ready"
        return $true
    }
    catch {
        Write-Console "Restore failed: $_" -Type "Error"
        Set-Status "Ready"
        return $false
    }
}

function Remove-OrphanedSIDs {
    param([string]$Path, [switch]$Recurse)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) { Write-Console "Rejected: $($check.Reason)" -Type "Error"; return }

    Write-Console "Scanning for orphaned SIDs (deleted accounts)..." -Type "Info"
    Write-Console "Pattern: S-1-5-21-* entries that don't resolve to usernames" -Type "Normal"
    Set-Status "Scanning..."
    
    $orphaned = 0
    $processed = 0
    $items = @(Get-Item -LiteralPath $Path -Force)
    
    if ($Recurse) {
        Write-Console "Recursive mode enabled - scanning all subfolders..." -Type "Progress"
        $items += Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    $total = $items.Count
    Write-Console "Items to scan: $total" -Type "Info"
    
    foreach ($item in $items) {
        $processed++
        if ($processed % 50 -eq 0 -or $processed -eq $total) {
            Set-Progress -Value $processed -Maximum $total
            Set-Status "Scanning $processed/$total..."
        }
        
        try {
            $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
            $modified = $false
            
            foreach ($ace in $acl.Access) {
                if ($ace.IdentityReference.Value -match "^S-1-5-21-" -and -not $ace.IsInherited) {
                    Write-Console "  Found orphaned SID: $($ace.IdentityReference.Value)" -Type "Warning"
                    Write-Console "    Location: $($item.FullName)" -Type "Normal"
                    $acl.RemoveAccessRule($ace) | Out-Null
                    $modified = $true
                    $orphaned++
                }
            }
            
            if ($modified) {
                Set-Acl -LiteralPath $item.FullName -AclObject $acl -ErrorAction Stop
                Write-Console "    Removed from ACL" -Type "Success"
            }
        }
        catch { Write-Log "ACL scan error on $($item.FullName): $_" -Level "WARN" }
    }
    
    Write-Console "Scan complete: $processed items processed, $orphaned orphaned SIDs removed" -Type "Success"
    Set-Status "Ready"
    Set-Progress -Value 0
}

function Get-ACLReport {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) { Write-Console "Rejected: $($check.Reason)" -Type "Error"; return }

    Write-Console "Generating ACL report for: $Path" -Type "Info"
    Set-Status "Analyzing permissions..."
    
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        
        Write-Console "" -Type "Normal"
        Write-Console "=== OWNER ===" -Type "Info"
        Write-Console "  $($acl.Owner)" -Type "Normal"
        
        Write-Console "" -Type "Normal"
        Write-Console "=== ACCESS CONTROL ENTRIES ===" -Type "Info"
        
        foreach ($ace in $acl.Access) {
            $inherited = if ($ace.IsInherited) { "(inherited)" } else { "(explicit)" }
            $aceType = if ($ace.AccessControlType -eq "Allow") { "[ALLOW]" } else { "[DENY]" }
            
            $color = if ($ace.AccessControlType -eq "Deny") { "Warning" } 
                     elseif ($ace.IdentityReference.Value -match "^S-1-5-21-") { "Error" }
                     else { "Normal" }
            
            Write-Console "  $aceType $($ace.IdentityReference)" -Type $color
            Write-Console "    Rights: $($ace.FileSystemRights)" -Type "Normal"
            Write-Console "    Inheritance: $($ace.InheritanceFlags) | Propagation: $($ace.PropagationFlags) $inherited" -Type "Normal"
        }
        
        if ($acl.AreAccessRulesProtected) {
            Write-Console "" -Type "Normal"
            Write-Console "NOTE: Inheritance is DISABLED for this item" -Type "Warning"
        }
        
        Set-Status "Ready"
    }
    catch {
        Write-Console "Failed to read ACL: $_" -Type "Error"
        Set-Status "Ready"
    }
}

function Export-ACLReport {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        return
    }

    Write-Console "Exporting ACL report for: $Path" -Type "Info"
    Set-Status "Exporting permissions..."

    try {
        $items = @(Get-Item -LiteralPath $Path -Force)
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $items += Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }

        $rows = [System.Collections.Generic.List[PSObject]]::new()
        $total = $items.Count
        $processed = 0

        foreach ($item in $items) {
            $processed++
            if ($processed % 50 -eq 0) {
                Set-Progress -Value $processed -Maximum $total
                Set-Status "Exporting $processed/$total..."
            }
            try {
                $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
                foreach ($ace in $acl.Access) {
                    $rows.Add([PSCustomObject]@{
                        Path = $item.FullName
                        Owner = $acl.Owner
                        Identity = $ace.IdentityReference.Value
                        AccessType = $ace.AccessControlType.ToString()
                        Rights = $ace.FileSystemRights.ToString()
                        Inherited = $ace.IsInherited
                        InheritanceFlags = $ace.InheritanceFlags.ToString()
                        PropagationFlags = $ace.PropagationFlags.ToString()
                    })
                }
            }
            catch { Write-Log "ACL export error on $($item.FullName): $_" -Level "WARN" }
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $csvPath = Join-Path $Script:Config.LogPath "ACL_Report_$timestamp.csv"
        if (-not (Test-Path $Script:Config.LogPath)) {
            New-Item -Path $Script:Config.LogPath -ItemType Directory -Force | Out-Null
        }
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

        Write-Console "ACL report exported: $csvPath" -Type "Success"
        Write-Console "Entries: $($rows.Count) ACEs from $total items" -Type "Info"
        Set-Status "Ready"
        Set-Progress -Value 0
    }
    catch {
        Write-Console "Export failed: $_" -Type "Error"
        Set-Status "Ready"
        Set-Progress -Value 0
    }
}

# ============================================================================
# BOOT-TIME DELETION
# ============================================================================
function Invoke-BootTimeDelete {
    param(
        [string]$Path,
        [switch]$DryRun
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        return $false
    }

    Write-Console "Scheduling boot-time deletion using MoveFileEx API..." -Type "Info"
    Write-Console "Target: $Path" -Type "Normal"

    if ($DryRun) {
        Write-Console "=== DRY-RUN BOOT-TIME DELETION ===" -Type "Info"
        Write-Console "No reboot queue or registry values will be changed" -Type "Warning"
        Write-Console "[WOULD SCHEDULE] MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)" -Type "Progress"
        Write-Console "[FALLBACK] PendingFileRenameOperations MultiString if MoveFileEx fails" -Type "Normal"
        Write-Log "Dry-run boot-time deletion generated for $Path" -Level "INFO"
        Set-Status "Dry-run complete - no changes made"
        return $true
    }
    
    try {
        $bootDeleteResult = Register-BootTimeDelete -Path $Path
        
        if ($bootDeleteResult.Success) {
            Write-Console "Scheduled for deletion on next reboot" -Type "Success"
            Write-Console "The file will be deleted by Session Manager before services start" -Type "Info"
            Write-Log "Boot-time deletion scheduled: $Path" -Level "SUCCESS"
            return $true
        }
        else {
            Write-Console "MoveFileEx API call failed ($($bootDeleteResult.Error)), trying registry fallback..." -Type "Warning"

            $fallbackResult = Add-PathForgePendingFileDelete -Path $Path -Confirm:$false
            if ($fallbackResult.Success) {
                Write-Console "Scheduled via registry fallback" -Type "Success"
                Write-Log "Boot-time deletion scheduled via registry: $Path" -Level "SUCCESS"
                return $true
            }

            Write-Console "Registry fallback failed: $($fallbackResult.Error)" -Type "Error"
            return $false
        }
    }
    catch {
        Write-Console "Failed to schedule boot-time deletion: $_" -Type "Error"
        return $false
    }
}

function Show-PendingDeletionQueue {
    [CmdletBinding()]
    param(
        [scriptblock]$QueueProvider,
        [scriptblock]$RemoveAction
    )

    if (-not $QueueProvider) {
        $QueueProvider = { Get-PathForgePendingFileQueue }
    }
    if (-not $RemoveAction) {
        $RemoveAction = {
            param($Indexes, $SnapshotHash)
            Remove-PathForgePendingFileOperation -Index $Indexes -ExpectedSnapshotHash $SnapshotHash -Confirm:$false
        }
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Scheduled Deletion Queue"
    $dialog.Size = New-Object System.Drawing.Size(920, 560)
    $dialog.MinimumSize = New-Object System.Drawing.Size(760, 460)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $Script:Theme.BgPrimary
    $dialog.ForeColor = $Script:Theme.TextPrimary
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowIcon = $false

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Pending reboot file operations"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
    $titleLabel.ForeColor = $Script:Theme.TextPrimary
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(20, 18)
    $null = $dialog.Controls.Add($titleLabel)

    $helpLabel = New-Object System.Windows.Forms.Label
    $helpLabel.Text = "Select rows with Ctrl/Shift-click. Cancelling rewrites only the selected source/destination pairs."
    $helpLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $helpLabel.ForeColor = $Script:Theme.TextMuted
    $helpLabel.AutoSize = $true
    $helpLabel.Location = New-Object System.Drawing.Point(22, 50)
    $null = $dialog.Controls.Add($helpLabel)

    $summaryLabel = New-Object System.Windows.Forms.Label
    $summaryLabel.Text = "Loading queue..."
    $summaryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $summaryLabel.ForeColor = $Script:Theme.Info
    $summaryLabel.AutoSize = $true
    $summaryLabel.Location = New-Object System.Drawing.Point(22, 76)
    $null = $dialog.Controls.Add($summaryLabel)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = "PendingQueueGrid"
    $grid.AccessibleName = "Pending reboot file operations"
    $grid.Location = New-Object System.Drawing.Point(20, 104)
    $grid.Size = New-Object System.Drawing.Size(862, 348)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.BackgroundColor = $Script:Theme.BgInput
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.GridColor = $Script:Theme.Border
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Script:Theme.BgTertiary
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Script:Theme.TextPrimary
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Script:Theme.BgTertiary
    $grid.DefaultCellStyle.BackColor = $Script:Theme.BgInput
    $grid.DefaultCellStyle.ForeColor = $Script:Theme.TextSecondary
    $grid.DefaultCellStyle.SelectionBackColor = $Script:Theme.AccentDim
    $grid.DefaultCellStyle.SelectionForeColor = $Script:Theme.TextPrimary
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $true
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoGenerateColumns = $false

    $indexColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $indexColumn.Name = "QueueIndex"
    $indexColumn.HeaderText = "#"
    $indexColumn.Width = 42
    $indexColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $null = $grid.Columns.Add($indexColumn)

    $kindColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $kindColumn.Name = "OperationKind"
    $kindColumn.HeaderText = "Operation"
    $kindColumn.Width = 105
    $kindColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $null = $grid.Columns.Add($kindColumn)

    $sourceColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $sourceColumn.Name = "SourcePath"
    $sourceColumn.HeaderText = "Source"
    $sourceColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $sourceColumn.FillWeight = 55
    $sourceColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $null = $grid.Columns.Add($sourceColumn)

    $destinationColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $destinationColumn.Name = "DestinationPath"
    $destinationColumn.HeaderText = "Destination"
    $destinationColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $destinationColumn.FillWeight = 45
    $destinationColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $null = $grid.Columns.Add($destinationColumn)
    $null = $dialog.Controls.Add($grid)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.AccessibleName = "Refresh pending reboot queue"
    $refreshButton.Location = New-Object System.Drawing.Point(20, 468)
    $refreshButton.Size = New-Object System.Drawing.Size(90, 34)
    $refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $refreshButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $refreshButton.BackColor = $Script:Theme.BgTertiary
    $refreshButton.ForeColor = $Script:Theme.TextSecondary
    $null = $dialog.Controls.Add($refreshButton)

    $cancelSelectedButton = New-Object System.Windows.Forms.Button
    $cancelSelectedButton.Text = "Cancel Selected"
    $cancelSelectedButton.AccessibleName = "Cancel selected pending operations"
    $cancelSelectedButton.Location = New-Object System.Drawing.Point(522, 468)
    $cancelSelectedButton.Size = New-Object System.Drawing.Size(125, 34)
    $cancelSelectedButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $cancelSelectedButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancelSelectedButton.FlatAppearance.BorderColor = $Script:Theme.Warning
    $cancelSelectedButton.BackColor = $Script:Theme.BgTertiary
    $cancelSelectedButton.ForeColor = $Script:Theme.Warning
    $cancelSelectedButton.Enabled = $false
    $null = $dialog.Controls.Add($cancelSelectedButton)

    $clearAllButton = New-Object System.Windows.Forms.Button
    $clearAllButton.Text = "Clear All"
    $clearAllButton.AccessibleName = "Cancel all pending operations"
    $clearAllButton.Location = New-Object System.Drawing.Point(655, 468)
    $clearAllButton.Size = New-Object System.Drawing.Size(100, 34)
    $clearAllButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $clearAllButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $clearAllButton.FlatAppearance.BorderColor = $Script:Theme.Error
    $clearAllButton.BackColor = $Script:Theme.BgTertiary
    $clearAllButton.ForeColor = $Script:Theme.Error
    $clearAllButton.Enabled = $false
    $null = $dialog.Controls.Add($clearAllButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.AccessibleName = "Close scheduled deletion queue"
    $closeButton.Location = New-Object System.Drawing.Point(763, 468)
    $closeButton.Size = New-Object System.Drawing.Size(119, 34)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $closeButton.BackColor = $Script:Theme.AccentDim
    $closeButton.ForeColor = $Script:Theme.TextPrimary
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton = $closeButton
    $null = $dialog.Controls.Add($closeButton)

    $queueInfoColor = $Script:Theme.Info
    $queueWarningColor = $Script:Theme.Warning
    $queueErrorColor = $Script:Theme.Error

    $loadQueue = {
        $grid.Rows.Clear()
        try {
            $queue = & $QueueProvider
        }
        catch {
            $queue = [PSCustomObject]@{Success = $false; Operations = @(); Error = $_.Exception.Message }
        }
        $dialog.Tag = $queue

        if (-not $queue.Success) {
            $summaryLabel.Text = "Unable to read the queue: $($queue.Error)"
            $summaryLabel.ForeColor = $queueErrorColor
            $cancelSelectedButton.Enabled = $false
            $clearAllButton.Enabled = $false
            return
        }

        try {
            foreach ($operation in @($queue.Operations)) {
                $kindText = if ($operation.ReplaceExisting) { "Move/Replace" } else { [string]$operation.Kind }
                $queuePrefixes = @($operation.SourcePrefix, $operation.DestinationPrefix) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
                if ($queuePrefixes.Count -gt 0) {
                    $kindText = "$kindText [$($queuePrefixes -join '/')]"
                }
                $destinationText = switch ($operation.Kind) {
                    'Delete' { "(delete on reboot)" }
                    'Malformed' { "(missing or invalid pair)" }
                    default { [string]$operation.Destination }
                }
                $rowIndex = $grid.Rows.Add($operation.Index, $kindText, $operation.Source, $destinationText)
                if ($operation.IsMalformed) {
                    $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = $queueErrorColor
                }
                elseif ($operation.Kind -eq 'Delete') {
                    $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = $queueWarningColor
                }
            }

            $summaryLabel.Text = "$($queue.Operations.Count) operation(s): $($queue.DeleteCount) delete, $($queue.MoveCount) move, $($queue.MalformedCount) malformed"
            $summaryLabel.ForeColor = if ($queue.MalformedCount -gt 0) { $queueWarningColor } else { $queueInfoColor }
            $clearAllButton.Enabled = $queue.Operations.Count -gt 0
            if ($grid.Rows.Count -gt 0) {
                $grid.ClearSelection()
            }
            $cancelSelectedButton.Enabled = $grid.SelectedRows.Count -gt 0
        }
        catch {
            $summaryLabel.Text = "Unable to render the queue: $($_.Exception.Message)"
            $summaryLabel.ForeColor = $queueErrorColor
            $cancelSelectedButton.Enabled = $false
            $clearAllButton.Enabled = $false
        }
    }.GetNewClosure()

    $cancelOperations = {
        param([int[]]$Indexes, [bool]$AllOperations)

        if (@($Indexes).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($dialog, "Select at least one queue row first.", "Nothing Selected", 0, 48) | Out-Null
            return
        }

        $scopeText = if ($AllOperations) { "ALL $($Indexes.Count) pending operations" } else { "$($Indexes.Count) selected operation(s)" }
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "Cancel $scopeText?`n`nThis changes Windows' next-boot file operation queue immediately.",
            "Confirm Queue Edit",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        $currentQueue = $dialog.Tag
        try {
            $result = & $RemoveAction $Indexes $currentQueue.SnapshotHash
        }
        catch {
            $result = [PSCustomObject]@{Success = $false; Conflict = $false; Error = $_.Exception.Message }
        }

        if ($result.Success) {
            Write-Console "Cancelled $($result.RemovedCount) pending reboot operation(s)" -Type "Success"
            Write-Log "Pending reboot queue edited: removed=$($result.RemovedCount) remaining=$($result.RemainingCount)" -Level "SUCCESS"
            & $loadQueue
            return
        }

        $errorTitle = if ($result.Conflict) { "Queue Changed" } else { "Queue Edit Failed" }
        [System.Windows.Forms.MessageBox]::Show($dialog, $result.Error, $errorTitle, 0, 16) | Out-Null
        & $loadQueue
    }.GetNewClosure()

    $refreshButton.Add_Click({ & $loadQueue }.GetNewClosure())
    $grid.Add_SelectionChanged({
        $cancelSelectedButton.Enabled = $grid.SelectedRows.Count -gt 0
    }.GetNewClosure())
    $cancelSelectedButton.Add_Click({
        $selectedIndexes = @($grid.SelectedRows | ForEach-Object { [int]$_.Cells['QueueIndex'].Value })
        & $cancelOperations $selectedIndexes $false
    }.GetNewClosure())
    $clearAllButton.Add_Click({
        $allIndexes = @($dialog.Tag.Operations | ForEach-Object Index)
        & $cancelOperations $allIndexes $true
    }.GetNewClosure())
    $dialog.Add_Shown({ & $loadQueue }.GetNewClosure())

    Write-Console "Opening scheduled deletion queue editor" -Type "Info"
    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner -and $owner -ne $dialog) {
        [void]$dialog.ShowDialog($owner)
    }
    else {
        [void]$dialog.ShowDialog()
    }
    $dialog.Dispose()
}

# ============================================================================
# LINK INSPECTION & REPARSE EXPLORER
# ============================================================================
function Show-LinkInspector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $info = Get-PathForgeLinkInfo -Path $Path
    if (-not $info.Success) {
        [System.Windows.Forms.MessageBox]::Show("Unable to inspect the selected path:`n`n$($info.Error)", "Link Inspection Failed", 0, 16) | Out-Null
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Link Inspector"
    $dialog.Size = New-Object System.Drawing.Size(820, 590)
    $dialog.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $Script:Theme.BgPrimary
    $dialog.ForeColor = $Script:Theme.TextPrimary
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowIcon = $false

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $info.Kind
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
    $titleLabel.ForeColor = if ($info.CanSafeDeleteLink) { $Script:Theme.Info } else { $Script:Theme.TextPrimary }
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(20, 18)
    $null = $dialog.Controls.Add($titleLabel)

    $pathBox = New-Object System.Windows.Forms.Label
    $pathBox.Name = "InspectedPathLabel"
    $pathBox.Text = $info.Path
    $pathBox.AccessibleName = "Inspected path"
    $pathBox.BackColor = $Script:Theme.BgInput
    $pathBox.ForeColor = $Script:Theme.TextSecondary
    $pathBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $pathBox.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $pathBox.AutoEllipsis = $true
    $pathBox.Location = New-Object System.Drawing.Point(22, 58)
    $pathBox.Size = New-Object System.Drawing.Size(760, 26)
    $pathBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $null = $dialog.Controls.Add($pathBox)

    $detailsGrid = New-Object System.Windows.Forms.DataGridView
    $detailsGrid.Name = "LinkDetailsGrid"
    $detailsGrid.AccessibleName = "Link metadata"
    $detailsGrid.Location = New-Object System.Drawing.Point(22, 98)
    $detailsGrid.Size = New-Object System.Drawing.Size(760, 190)
    $detailsGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $detailsGrid.BackgroundColor = $Script:Theme.BgInput
    $detailsGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $detailsGrid.GridColor = $Script:Theme.Border
    $detailsGrid.EnableHeadersVisualStyles = $false
    $detailsGrid.ColumnHeadersDefaultCellStyle.BackColor = $Script:Theme.BgTertiary
    $detailsGrid.ColumnHeadersDefaultCellStyle.ForeColor = $Script:Theme.TextPrimary
    $detailsGrid.DefaultCellStyle.BackColor = $Script:Theme.BgInput
    $detailsGrid.DefaultCellStyle.ForeColor = $Script:Theme.TextSecondary
    $detailsGrid.DefaultCellStyle.SelectionBackColor = $Script:Theme.AccentDim
    $detailsGrid.DefaultCellStyle.SelectionForeColor = $Script:Theme.TextPrimary
    $detailsGrid.RowHeadersVisible = $false
    $detailsGrid.AllowUserToAddRows = $false
    $detailsGrid.AllowUserToDeleteRows = $false
    $detailsGrid.AllowUserToResizeRows = $false
    $detailsGrid.ReadOnly = $true
    $detailsGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $propertyColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $propertyColumn.HeaderText = "Property"
    $propertyColumn.Width = 145
    $propertyColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $null = $detailsGrid.Columns.Add($propertyColumn)
    $valueColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $valueColumn.HeaderText = "Value"
    $valueColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $valueColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $null = $detailsGrid.Columns.Add($valueColumn)

    $tagDisplay = if ($info.IsReparsePoint) { "$($info.ReparseTagHex) - $($info.ReparseTagName)" } else { "Not a reparse point" }
    $targetDisplay = if ([string]::IsNullOrWhiteSpace($info.Target)) { "(none or opaque reparse data)" } else { [string]$info.Target }
    $hardLinkDisplay = if ($info.IsDirectory) { "Not applicable to directories" } else { "$($info.HardLinkCount) name(s)" }
    $null = $detailsGrid.Rows.Add("Path", $info.Path)
    $null = $detailsGrid.Rows.Add("Type", $info.Kind)
    $null = $detailsGrid.Rows.Add("Reparse tag", $tagDisplay)
    $null = $detailsGrid.Rows.Add("Target", $targetDisplay)
    $null = $detailsGrid.Rows.Add("Relative target", $(if ($info.IsRelativeTarget) { "Yes" } else { "No" }))
    $null = $detailsGrid.Rows.Add("Hard-link count", $hardLinkDisplay)
    $detailsGrid.ClearSelection()
    $null = $dialog.Controls.Add($detailsGrid)

    $namesLabel = New-Object System.Windows.Forms.Label
    $namesLabel.Text = "HARD-LINK NAMES"
    $namesLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $namesLabel.ForeColor = $Script:Theme.TextMuted
    $namesLabel.AutoSize = $true
    $namesLabel.Location = New-Object System.Drawing.Point(22, 304)
    $null = $dialog.Controls.Add($namesLabel)

    $namesList = New-Object System.Windows.Forms.ListBox
    $namesList.Name = "HardLinkNamesList"
    $namesList.AccessibleName = "Hard-link names"
    $namesList.Location = New-Object System.Drawing.Point(22, 328)
    $namesList.Size = New-Object System.Drawing.Size(760, 96)
    $namesList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $namesList.BackColor = $Script:Theme.BgInput
    $namesList.ForeColor = $Script:Theme.TextSecondary
    $namesList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    if ($info.HardLinkCount -gt 0) {
        foreach ($linkName in $info.HardLinkPaths) { $null = $namesList.Items.Add($linkName) }
    }
    else {
        $null = $namesList.Items.Add("No hard-link names to enumerate for this object")
    }
    $null = $dialog.Controls.Add($namesList)

    $safetyLabel = New-Object System.Windows.Forms.Label
    $safetyLabel.Text = if ($info.CanSafeDeleteLink) {
        "Safe delete removes only the selected link/name. It never recursively enters the displayed target."
    }
    else {
        "This is an ordinary file or directory, so link-only deletion is disabled."
    }
    $safetyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $safetyLabel.ForeColor = if ($info.CanSafeDeleteLink) { $Script:Theme.Success } else { $Script:Theme.TextMuted }
    $safetyLabel.AutoSize = $true
    $safetyLabel.Location = New-Object System.Drawing.Point(22, 442)
    $null = $dialog.Controls.Add($safetyLabel)

    if (-not [string]::IsNullOrWhiteSpace($info.Warning)) {
        $safetyLabel.Text = "$($safetyLabel.Text) Inspection warning: $($info.Warning)"
        $safetyLabel.ForeColor = $Script:Theme.Warning
    }

    $dryRun = [bool]($Script:DryRunCheck -and $Script:DryRunCheck.Checked)
    $removeButton = New-Object System.Windows.Forms.Button
    $removeButton.Text = if ($dryRun) { "Preview Safe Delete" } else { "Safe Delete Link" }
    $removeButton.AccessibleName = $removeButton.Text
    $removeButton.Location = New-Object System.Drawing.Point(510, 494)
    $removeButton.Size = New-Object System.Drawing.Size(140, 36)
    $removeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $removeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $removeButton.FlatAppearance.BorderColor = $Script:Theme.Warning
    $removeButton.BackColor = $Script:Theme.BgTertiary
    $removeButton.ForeColor = $Script:Theme.Warning
    $removeButton.Enabled = [bool]$info.CanSafeDeleteLink
    $null = $dialog.Controls.Add($removeButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.AccessibleName = "Close link inspector"
    $closeButton.Location = New-Object System.Drawing.Point(662, 494)
    $closeButton.Size = New-Object System.Drawing.Size(120, 36)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $closeButton.BackColor = $Script:Theme.AccentDim
    $closeButton.ForeColor = $Script:Theme.TextPrimary
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton = $closeButton
    $null = $dialog.Controls.Add($closeButton)

    $inspectedInfo = $info
    $removeButton.Add_Click({
        if (-not $dryRun) {
            $impactText = if ($inspectedInfo.IsReparsePoint) {
                "The link will be removed. Its target will not be traversed or deleted:`n$($inspectedInfo.Target)"
            }
            else {
                "Only this hard-link name will be removed. $($inspectedInfo.HardLinkCount - 1) other name(s) will continue to reference the data."
            }
            $confirmation = [System.Windows.Forms.MessageBox]::Show($dialog, "$impactText`n`nContinue?", "Confirm Link-Only Delete", 4, 48)
            if ($confirmation -ne 6) { return }
        }

        $result = Remove-PathForgeLinkSafe -Path $inspectedInfo.Path -WhatIf:$dryRun -Confirm:$false
        if ($result.Success -and $result.Simulated) {
            Write-Console "[DRY-RUN] Would safely remove $($inspectedInfo.Kind): $($inspectedInfo.Path)" -Type "Info"
            [System.Windows.Forms.MessageBox]::Show($dialog, "Dry-run complete. The link and target were not changed.", "Safe Delete Preview", 0, 64) | Out-Null
        }
        elseif ($result.Success) {
            Write-Console "Safely removed $($inspectedInfo.Kind): $($inspectedInfo.Path)" -Type "Success"
            Write-Log "Link-only deletion succeeded: kind=$($inspectedInfo.Kind) path=$($inspectedInfo.Path)" -Level "SUCCESS"
            [System.Windows.Forms.MessageBox]::Show($dialog, "The selected link/name was removed. Target data was not traversed.", "Link Removed", 0, 64) | Out-Null
            $dialog.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, $result.Error, "Safe Delete Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner -and $owner -ne $dialog) { [void]$dialog.ShowDialog($owner) } else { [void]$dialog.ShowDialog() }
    $dialog.Dispose()
}

function Show-ReparsePointExplorer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Reparse Point Explorer"
    $dialog.Size = New-Object System.Drawing.Size(1000, 640)
    $dialog.MinimumSize = New-Object System.Drawing.Size(820, 520)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $Script:Theme.BgPrimary
    $dialog.ForeColor = $Script:Theme.TextPrimary
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowIcon = $false

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Reparse points (non-traversing scan)"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
    $titleLabel.ForeColor = $Script:Theme.TextPrimary
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(20, 16)
    $null = $dialog.Controls.Add($titleLabel)

    $rootBox = New-Object System.Windows.Forms.Label
    $rootBox.Name = "ReparseScanRootLabel"
    $rootBox.Text = $Path
    $rootBox.AccessibleName = "Reparse scan root"
    $rootBox.BackColor = $Script:Theme.BgInput
    $rootBox.ForeColor = $Script:Theme.TextSecondary
    $rootBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $rootBox.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $rootBox.AutoEllipsis = $true
    $rootBox.Location = New-Object System.Drawing.Point(22, 52)
    $rootBox.Size = New-Object System.Drawing.Size(940, 26)
    $rootBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $null = $dialog.Controls.Add($rootBox)

    $summaryLabel = New-Object System.Windows.Forms.Label
    $summaryLabel.Text = "Waiting to scan..."
    $summaryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $summaryLabel.ForeColor = $Script:Theme.Info
    $summaryLabel.AutoSize = $true
    $summaryLabel.Location = New-Object System.Drawing.Point(22, 84)
    $null = $dialog.Controls.Add($summaryLabel)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = "ReparseExplorerGrid"
    $grid.AccessibleName = "Discovered reparse points"
    $grid.Location = New-Object System.Drawing.Point(20, 110)
    $grid.Size = New-Object System.Drawing.Size(942, 426)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.BackgroundColor = $Script:Theme.BgInput
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.GridColor = $Script:Theme.Border
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Script:Theme.BgTertiary
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Script:Theme.TextPrimary
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Script:Theme.BgTertiary
    $grid.DefaultCellStyle.BackColor = $Script:Theme.BgInput
    $grid.DefaultCellStyle.ForeColor = $Script:Theme.TextSecondary
    $grid.DefaultCellStyle.SelectionBackColor = $Script:Theme.AccentDim
    $grid.DefaultCellStyle.SelectionForeColor = $Script:Theme.TextPrimary
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoGenerateColumns = $false

    $kindColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $kindColumn.Name = "LinkKind"
    $kindColumn.HeaderText = "Type"
    $kindColumn.Width = 155
    $kindColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $null = $grid.Columns.Add($kindColumn)
    $tagColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $tagColumn.Name = "ReparseTag"
    $tagColumn.HeaderText = "Tag"
    $tagColumn.Width = 105
    $tagColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $null = $grid.Columns.Add($tagColumn)
    $pathColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $pathColumn.Name = "LinkPath"
    $pathColumn.HeaderText = "Path"
    $pathColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $pathColumn.FillWeight = 55
    $pathColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $null = $grid.Columns.Add($pathColumn)
    $targetColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $targetColumn.Name = "LinkTarget"
    $targetColumn.HeaderText = "Target"
    $targetColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $targetColumn.FillWeight = 45
    $targetColumn.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    $null = $grid.Columns.Add($targetColumn)
    $null = $dialog.Controls.Add($grid)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Rescan"
    $refreshButton.AccessibleName = "Rescan reparse points"
    $refreshButton.Location = New-Object System.Drawing.Point(20, 550)
    $refreshButton.Size = New-Object System.Drawing.Size(90, 34)
    $refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $refreshButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $refreshButton.BackColor = $Script:Theme.BgTertiary
    $refreshButton.ForeColor = $Script:Theme.TextSecondary
    $null = $dialog.Controls.Add($refreshButton)

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = "Export CSV"
    $exportButton.AccessibleName = "Export reparse point report"
    $exportButton.Location = New-Object System.Drawing.Point(650, 550)
    $exportButton.Size = New-Object System.Drawing.Size(100, 34)
    $exportButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $exportButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $exportButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $exportButton.BackColor = $Script:Theme.BgTertiary
    $exportButton.ForeColor = $Script:Theme.TextSecondary
    $exportButton.Enabled = $false
    $null = $dialog.Controls.Add($exportButton)

    $inspectButton = New-Object System.Windows.Forms.Button
    $inspectButton.Text = "Inspect Selected"
    $inspectButton.AccessibleName = "Inspect selected reparse point"
    $inspectButton.Location = New-Object System.Drawing.Point(758, 550)
    $inspectButton.Size = New-Object System.Drawing.Size(120, 34)
    $inspectButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $inspectButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $inspectButton.FlatAppearance.BorderColor = $Script:Theme.Info
    $inspectButton.BackColor = $Script:Theme.BgTertiary
    $inspectButton.ForeColor = $Script:Theme.Info
    $inspectButton.Enabled = $false
    $null = $dialog.Controls.Add($inspectButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.AccessibleName = "Close reparse point explorer"
    $closeButton.Location = New-Object System.Drawing.Point(886, 550)
    $closeButton.Size = New-Object System.Drawing.Size(76, 34)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $closeButton.BackColor = $Script:Theme.AccentDim
    $closeButton.ForeColor = $Script:Theme.TextPrimary
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton = $closeButton
    $null = $dialog.Controls.Add($closeButton)

    $explorerInfoColor = $Script:Theme.Info
    $explorerWarningColor = $Script:Theme.Warning
    $explorerErrorColor = $Script:Theme.Error
    $reportDirectory = $Script:Config.LogPath
    $scanRoot = $Path

    $loadResults = {
        $grid.Rows.Clear()
        $inspectButton.Enabled = $false
        $exportButton.Enabled = $false
        $summaryLabel.Text = "Scanning without traversing any discovered reparse point..."
        $summaryLabel.ForeColor = $explorerInfoColor
        $dialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $report = Find-PathForgeReparsePoint -Path $scanRoot
        }
        catch {
            $report = [PSCustomObject]@{Success = $false; Items = @(); Error = $_.Exception.Message; Errors = @($_.Exception.Message) }
        }
        finally {
            $dialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
        $dialog.Tag = $report

        if (-not $report.Success) {
            $summaryLabel.Text = "Scan failed: $($report.Error)"
            $summaryLabel.ForeColor = $explorerErrorColor
            return
        }

        foreach ($linkInfo in @($report.Items)) {
            $targetText = if ([string]::IsNullOrWhiteSpace($linkInfo.Target)) { "(opaque or no target)" } else { [string]$linkInfo.Target }
            $rowIndex = $grid.Rows.Add($linkInfo.Kind, $linkInfo.ReparseTagHex, $linkInfo.Path, $targetText)
            $grid.Rows[$rowIndex].Tag = $linkInfo
            if (-not [string]::IsNullOrWhiteSpace($linkInfo.Warning)) {
                $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = $explorerWarningColor
            }
        }

        $suffix = if ($report.Truncated) { "; result limit reached" } else { "" }
        $summaryLabel.Text = "$($report.Items.Count) reparse point(s) found; $($report.ScannedCount) item(s) examined; $($report.Errors.Count) access/read error(s)$suffix"
        $summaryLabel.ForeColor = if ($report.Truncated -or $report.Errors.Count -gt 0) { $explorerWarningColor } else { $explorerInfoColor }
        $exportButton.Enabled = $report.Items.Count -gt 0
        if ($grid.Rows.Count -gt 0) { $grid.ClearSelection() }
    }.GetNewClosure()

    $inspectSelected = {
        if ($grid.SelectedRows.Count -eq 0) { return }
        $selectedInfo = $grid.SelectedRows[0].Tag
        if ($selectedInfo) {
            Show-LinkInspector -Path $selectedInfo.Path
            & $loadResults
        }
    }.GetNewClosure()

    $grid.Add_SelectionChanged({
        $inspectButton.Enabled = $grid.SelectedRows.Count -gt 0
    }.GetNewClosure())
    $grid.Add_CellDoubleClick({ & $inspectSelected }.GetNewClosure())
    $inspectButton.Add_Click({ & $inspectSelected }.GetNewClosure())
    $refreshButton.Add_Click({ & $loadResults }.GetNewClosure())
    $exportButton.Add_Click({
        $report = $paintSender.Tag
        if (-not $report -or $report.Items.Count -eq 0) { return }
        try {
            if (-not (Test-Path -LiteralPath $reportDirectory)) {
                New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
            }
            $exportPath = Join-Path $reportDirectory "ReparsePoints_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            $report.Items | Select-Object Path, Kind, ReparseTagHex, ReparseTagName, Target, IsRelativeTarget, Warning |
                Export-Csv -LiteralPath $exportPath -NoTypeInformation -Encoding UTF8
            Write-Console "Reparse point report exported: $exportPath" -Type "Success"
            Write-Log "Reparse point report exported: $exportPath" -Level "SUCCESS"
            [System.Windows.Forms.MessageBox]::Show($dialog, "Report saved to:`n$exportPath", "Export Complete", 0, 64) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, "Export Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $dialog.Add_Shown({ & $loadResults }.GetNewClosure())

    Write-Console "Opening non-traversing reparse point explorer for $Path" -Type "Info"
    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner -and $owner -ne $dialog) { [void]$dialog.ShowDialog($owner) } else { [void]$dialog.ShowDialog() }
    $dialog.Dispose()
}

function Invoke-QuarantinePath {
    param(
        [string]$Path,
        [switch]$DryRun
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Quarantine rejected: $($check.Reason)" -Type "Error"
        return [PSCustomObject]@{Success = $false; Simulated = $false; Error = $check.Reason }
    }

    if ($DryRun) {
        $preview = Move-PathForgeToQuarantine -Path $Path -WhatIf
        if ($preview.Success) {
            Write-Console "[DRY-RUN] Would move to quarantine: $Path" -Type "Info"
            Write-Console "  Storage: $($preview.RootPath)" -Type "Normal"
            Write-Console "  Purge after: $($preview.PurgeAfterUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" -Type "Normal"
        }
        else {
            Write-Console "Quarantine preview failed: $($preview.Error)" -Type "Error"
        }
        return $preview
    }

    $confirmation = [System.Windows.Forms.MessageBox]::Show(
        "Move this path into the PathForge quarantine zone?`n`n$Path`n`nThe item can be restored until its retention period expires.",
        "Quarantine Path",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Console "Quarantine cancelled" -Type "Warning"
        return [PSCustomObject]@{Success = $false; Simulated = $false; Cancelled = $true; Error = $null }
    }

    Set-Status "Moving path to quarantine..."
    $result = Move-PathForgeToQuarantine -Path $Path -Confirm:$false
    if ($result.Success) {
        Write-Console "Moved to quarantine: $Path" -Type "Success"
        Write-Console "  Item ID: $($result.Id)" -Type "Normal"
        Write-Console "  Auto-purge: $($result.PurgeAfterUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" -Type "Normal"
        if ($result.Warning) {
            Write-Console $result.Warning -Type "Warning"
        }
        Write-Log "Quarantined path: $Path id=$($result.Id)" -Level "SUCCESS"
    }
    else {
        Write-Console "Quarantine failed: $($result.Error)" -Type "Error"
        Write-Log "Quarantine failed: $Path - $($result.Error)" -Level "ERROR"
    }
    Set-Status "Ready"
    return $result
}

function Invoke-QuarantineStartupMaintenance {
    $result = Invoke-PathForgeQuarantineMaintenance -Confirm:$false
    if (-not $result.Success) {
        foreach ($maintenanceError in @($result.Errors)) {
            Write-Log "Quarantine maintenance failed: $maintenanceError" -Level "ERROR"
        }
        Write-Console "Quarantine maintenance needs attention; open Quarantine Zone for details" -Type "Warning"
        return $result
    }

    if ($result.Purged -gt 0) {
        Write-Console "Quarantine maintenance permanently purged $($result.Purged) expired item(s)" -Type "Info"
        Write-Log "Quarantine auto-purge removed $($result.Purged) expired item(s)" -Level "INFO"
    }
    if ($result.Invalid -gt 0) {
        Write-Console "Quarantine contains $($result.Invalid) invalid record(s); automatic purge skipped them" -Type "Warning"
    }
    return $result
}

function Show-QuarantineManager {
    param([string]$InitialPath)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "PathForge Quarantine Zone"
    $dialog.Size = New-Object System.Drawing.Size(1120, 650)
    $dialog.MinimumSize = New-Object System.Drawing.Size(980, 560)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $Script:Theme.BgPrimary
    $dialog.ForeColor = $Script:Theme.TextPrimary
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.Add_HandleCreated({ try { [DarkMode]::EnableDarkTitleBar($this.Handle) } catch { Write-Verbose "Quarantine title-bar theming failed: $_" } })

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Quarantine Zone"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(20, 15)
    $title.AutoSize = $true
    $null = $dialog.Controls.Add($title)

    $description = New-Object System.Windows.Forms.Label
    $description.Text = "Items move to same-volume recovery storage and are permanently purged after the retention period."
    $description.ForeColor = $Script:Theme.TextMuted
    $description.Location = New-Object System.Drawing.Point(22, 48)
    $description.Size = New-Object System.Drawing.Size(750, 22)
    $null = $dialog.Controls.Add($description)

    $retentionLabel = New-Object System.Windows.Forms.Label
    $retentionLabel.Text = "Retention (days)"
    $retentionLabel.ForeColor = $Script:Theme.TextSecondary
    $retentionLabel.Location = New-Object System.Drawing.Point(790, 20)
    $retentionLabel.Size = New-Object System.Drawing.Size(100, 22)
    $null = $dialog.Controls.Add($retentionLabel)

    $retentionInput = New-Object System.Windows.Forms.NumericUpDown
    $retentionInput.Name = "QuarantineRetentionDays"
    $retentionInput.AccessibleName = "Quarantine retention in days"
    $retentionInput.Minimum = 1
    $retentionInput.Maximum = 3650
    $retentionInput.Value = 30
    $retentionInput.Location = New-Object System.Drawing.Point(895, 17)
    $retentionInput.Size = New-Object System.Drawing.Size(70, 24)
    $retentionInput.BackColor = $Script:Theme.BgInput
    $retentionInput.ForeColor = $Script:Theme.TextPrimary
    $null = $dialog.Controls.Add($retentionInput)

    $savePolicyButton = New-Object System.Windows.Forms.Button
    $savePolicyButton.Text = "Save Policy"
    $savePolicyButton.AccessibleName = "Save quarantine retention policy"
    $savePolicyButton.Location = New-Object System.Drawing.Point(975, 16)
    $savePolicyButton.Size = New-Object System.Drawing.Size(105, 27)
    $savePolicyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $savePolicyButton.BackColor = $Script:Theme.AccentDim
    $savePolicyButton.ForeColor = $Script:Theme.TextPrimary
    $savePolicyButton.FlatAppearance.BorderSize = 0
    $null = $dialog.Controls.Add($savePolicyButton)

    $currentPathLabel = New-Object System.Windows.Forms.Label
    $currentPathLabel.Name = "QuarantineCurrentPath"
    $currentPathLabel.Text = if ([string]::IsNullOrWhiteSpace($InitialPath)) { "Current target: (none)" } else { "Current target: $InitialPath" }
    $currentPathLabel.ForeColor = $Script:Theme.TextSecondary
    $currentPathLabel.Location = New-Object System.Drawing.Point(22, 78)
    $currentPathLabel.Size = New-Object System.Drawing.Size(820, 24)
    $currentPathLabel.AutoEllipsis = $true
    $null = $dialog.Controls.Add($currentPathLabel)

    $quarantineButton = New-Object System.Windows.Forms.Button
    $quarantineButton.Name = "QuarantineCurrentButton"
    $quarantineButton.Text = "Quarantine Current"
    $quarantineButton.AccessibleName = "Move the current target path into quarantine"
    $quarantineButton.Location = New-Object System.Drawing.Point(875, 72)
    $quarantineButton.Size = New-Object System.Drawing.Size(205, 32)
    $quarantineButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $quarantineButton.BackColor = $Script:Theme.Warning
    $quarantineButton.ForeColor = [System.Drawing.Color]::Black
    $quarantineButton.FlatAppearance.BorderSize = 0
    $quarantineButton.Enabled = -not [string]::IsNullOrWhiteSpace($InitialPath)
    $null = $dialog.Controls.Add($quarantineButton)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = "QuarantineGrid"
    $grid.AccessibleName = "Quarantined files and folders"
    $grid.Location = New-Object System.Drawing.Point(20, 115)
    $grid.Size = New-Object System.Drawing.Size(1060, 390)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.BackgroundColor = $Script:Theme.BgInput
    $grid.ForeColor = $Script:Theme.TextPrimary
    $grid.GridColor = $Script:Theme.Border
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Script:Theme.BgTertiary
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Script:Theme.TextPrimary
    $grid.DefaultCellStyle.BackColor = $Script:Theme.BgInput
    $grid.DefaultCellStyle.ForeColor = $Script:Theme.TextSecondary
    $grid.DefaultCellStyle.SelectionBackColor = $Script:Theme.AccentDim
    $grid.DefaultCellStyle.SelectionForeColor = $Script:Theme.TextPrimary
    $grid.EnableHeadersVisualStyles = $false
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AutoGenerateColumns = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.RowHeadersVisible = $false
    foreach ($columnDefinition in @(
            @{Name = 'Name'; Header = 'Name'; Width = 145 },
            @{Name = 'Type'; Header = 'Type'; Width = 70 },
            @{Name = 'OriginalPath'; Header = 'Original path'; Width = 330 },
            @{Name = 'Quarantined'; Header = 'Quarantined'; Width = 130 },
            @{Name = 'PurgeAfter'; Header = 'Purge after'; Width = 130 },
            @{Name = 'Status'; Header = 'Status'; Width = 105 },
            @{Name = 'Volume'; Header = 'Storage root'; Width = 170 })) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $columnDefinition.Name
        $column.HeaderText = $columnDefinition.Header
        $column.Width = $columnDefinition.Width
        $null = $grid.Columns.Add($column)
    }
    $null = $dialog.Controls.Add($grid)

    $summaryLabel = New-Object System.Windows.Forms.Label
    $summaryLabel.Name = "QuarantineSummary"
    $summaryLabel.ForeColor = $Script:Theme.TextMuted
    $summaryLabel.Location = New-Object System.Drawing.Point(22, 515)
    $summaryLabel.Size = New-Object System.Drawing.Size(760, 22)
    $summaryLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $null = $dialog.Controls.Add($summaryLabel)

    $buttonY = 548
    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.Location = New-Object System.Drawing.Point(20, $buttonY)
    $refreshButton.Size = New-Object System.Drawing.Size(90, 32)

    $restoreButton = New-Object System.Windows.Forms.Button
    $restoreButton.Text = "Restore Selected"
    $restoreButton.AccessibleName = "Restore selected quarantine item"
    $restoreButton.Location = New-Object System.Drawing.Point(120, $buttonY)
    $restoreButton.Size = New-Object System.Drawing.Size(145, 32)

    $purgeButton = New-Object System.Windows.Forms.Button
    $purgeButton.Text = "Purge Selected"
    $purgeButton.AccessibleName = "Permanently purge selected quarantine item"
    $purgeButton.Location = New-Object System.Drawing.Point(275, $buttonY)
    $purgeButton.Size = New-Object System.Drawing.Size(135, 32)

    $purgeExpiredButton = New-Object System.Windows.Forms.Button
    $purgeExpiredButton.Text = "Purge Expired"
    $purgeExpiredButton.AccessibleName = "Permanently purge all expired quarantine items"
    $purgeExpiredButton.Location = New-Object System.Drawing.Point(420, $buttonY)
    $purgeExpiredButton.Size = New-Object System.Drawing.Size(125, 32)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $closeButton.Location = New-Object System.Drawing.Point(990, $buttonY)
    $closeButton.Size = New-Object System.Drawing.Size(90, 32)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    foreach ($button in @($refreshButton, $restoreButton, $purgeButton, $purgeExpiredButton, $closeButton)) {
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.BackColor = $Script:Theme.BgTertiary
        $button.ForeColor = $Script:Theme.TextSecondary
        $button.FlatAppearance.BorderColor = $Script:Theme.Border
        $null = $dialog.Controls.Add($button)
    }
    $restoreButton.ForeColor = $Script:Theme.Success
    $purgeButton.ForeColor = $Script:Theme.Error
    $purgeExpiredButton.ForeColor = $Script:Theme.Warning
    $dialog.CancelButton = $closeButton

    $refreshItems = {
        $grid.Rows.Clear()
        $policy = Get-PathForgeQuarantinePolicy
        $retentionInput.Value = [decimal]$policy.RetentionDays
        $items = @(Get-PathForgeQuarantineItem -RetentionDays $policy.RetentionDays)
        foreach ($item in $items) {
            $quarantinedText = if ($item.QuarantinedAtUtc) { $item.QuarantinedAtUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '-' }
            $purgeText = if ($item.PurgeAfterUtc) { $item.PurgeAfterUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '-' }
            $typeText = if ($item.IsContainer) { 'Folder' } else { 'File' }
            $rowIndex = $grid.Rows.Add($item.OriginalName, $typeText, $item.OriginalPath, $quarantinedText, $purgeText, $item.Status, $item.RootPath)
            $grid.Rows[$rowIndex].Tag = $item
            if (-not $item.Valid) {
                $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = $Script:Theme.Error
            }
        }
        $validCount = @($items | Where-Object Valid).Count
        $summaryLabel.Text = "$($items.Count) item(s); $validCount recoverable; retention $($policy.RetentionDays) day(s)"
        if (-not $policy.Success) {
            $summaryLabel.Text += "; policy error: $($policy.Error)"
            $summaryLabel.ForeColor = $Script:Theme.Error
        }
        else {
            $summaryLabel.ForeColor = $Script:Theme.TextMuted
        }
    }.GetNewClosure()

    $getSelectedItem = {
        if ($grid.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($dialog, "Select a quarantine item first.", "No Selection", 0, 48) | Out-Null
            return $null
        }
        return $grid.SelectedRows[0].Tag
    }.GetNewClosure()

    $quarantineButton.Add_Click({
        $result = Invoke-QuarantinePath -Path $InitialPath -DryRun:($Script:DryRunCheck -and $Script:DryRunCheck.Checked)
        if ($result.Success -and -not $result.Simulated) {
            $quarantineButton.Enabled = $false
            $currentPathLabel.Text = "Current target moved to quarantine"
            & $refreshItems
        }
    }.GetNewClosure())
    $savePolicyButton.Add_Click({
        $result = Set-PathForgeQuarantinePolicy -RetentionDays ([int]$retentionInput.Value) -Confirm:$false
        if ($result.Success) {
            Write-Console "Quarantine retention set to $($result.RetentionDays) day(s)" -Type "Success"
            Write-Log "Quarantine retention policy updated: $($result.RetentionDays) days" -Level "INFO"
            & $refreshItems
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, $result.Error, "Policy Update Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $refreshButton.Add_Click({ & $refreshItems }.GetNewClosure())
    $restoreButton.Add_Click({
        $item = & $getSelectedItem
        if (-not $item) { return }
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "Restore this item to its original path?`n`n$($item.OriginalPath)",
            "Restore Quarantine Item", 4, 48)
        if ($confirmation -ne 6) { return }
        $result = Restore-PathForgeQuarantineItem -Id $item.Id -RootPath $item.RootPath -Confirm:$false
        if ($result.Success) {
            Write-Console "Restored from quarantine: $($result.DestinationPath)" -Type "Success"
            Write-Log "Restored quarantine item $($item.Id) to $($result.DestinationPath)" -Level "SUCCESS"
            if ($result.Warning) { Write-Console $result.Warning -Type "Warning" }
            & $refreshItems
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, $result.Error, "Restore Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $purgeButton.Add_Click({
        $item = & $getSelectedItem
        if (-not $item) { return }
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "Permanently purge this quarantine item?`n`n$($item.OriginalPath)`n`nThis cannot be undone.",
            "Permanent Purge", 4, 48)
        if ($confirmation -ne 6) { return }
        $result = Remove-PathForgeQuarantineItem -Id $item.Id -RootPath $item.RootPath -Confirm:$false
        if ($result.Success) {
            Write-Console "Permanently purged quarantine item: $($item.OriginalPath)" -Type "Success"
            Write-Log "Purged quarantine item $($item.Id)" -Level "INFO"
            & $refreshItems
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, $result.Error, "Purge Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $purgeExpiredButton.Add_Click({
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $dialog,
            "Permanently purge every item past the current retention period?",
            "Purge Expired Items", 4, 48)
        if ($confirmation -ne 6) { return }
        $result = Invoke-PathForgeQuarantineMaintenance -RetentionDays ([int]$retentionInput.Value) -Confirm:$false
        if ($result.Success) {
            Write-Console "Quarantine purge complete: $($result.Purged) expired item(s) removed" -Type "Success"
            & $refreshItems
        }
        else {
            [System.Windows.Forms.MessageBox]::Show($dialog, ($result.Errors -join [Environment]::NewLine), "Purge Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $dialog.Add_Shown({ & $refreshItems }.GetNewClosure())

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner -and $owner -ne $dialog) { [void]$dialog.ShowDialog($owner) } else { [void]$dialog.ShowDialog() }
    $dialog.Dispose()
}

# ============================================================================
# ALTERNATE DATA STREAMS
# ============================================================================
function Invoke-ADSScanner {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        Write-Log "ADS scan path rejected: $Path - $($check.Reason)" -Level "ERROR"
        return @()
    }

    $fs = Get-VolumeFileSystem -Path $Path
    if ($fs -ne "NTFS" -and $fs -ne "Unknown") {
        Write-Console "Alternate Data Streams are an NTFS-only feature" -Type "Warning"
        Write-Console "This path is on a $fs volume -- ADS scanning is not applicable" -Type "Info"
        return @()
    }

    Write-Console "Scanning for Alternate Data Streams..." -Type "Info"
    Write-Console "Looking for hidden data attached to files (NTFS feature)" -Type "Normal"
    Set-Status "Scanning for ADS..."

    $items = @(Get-Item -LiteralPath $Path -Force)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $items += Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    $adsFound = [System.Collections.Generic.List[PSObject]]::new()
    $count = 0
    $total = $items.Count

    foreach ($item in $items) {
        $count++
        if ($count % 50 -eq 0) {
            Set-Progress -Value $count -Maximum $total
            Set-Status "Scanning $count/$total..."
        }

        try {
            $streams = Get-Item -LiteralPath $item.FullName -Stream * -ErrorAction SilentlyContinue
            $altStreams = $streams | Where-Object { $_.Stream -ne ':$DATA' }

            if ($altStreams) {
                foreach ($stream in $altStreams) {
                    $adsFound.Add([PSCustomObject]@{
                        Path   = $item.FullName
                        Stream = $stream.Stream
                        Size   = $stream.Length
                    })
                }
            }
        }
        catch { Write-Log "ADS scan error on $($item.FullName): $_" -Level "WARN" }
    }

    Set-Progress -Value 0
    Set-Status "Ready"
    
    Write-Console "" -Type "Normal"
    if ($adsFound.Count -eq 0) {
        Write-Console "No alternate data streams found in $count items" -Type "Success"
    }
    else {
        Write-Console "Found $($adsFound.Count) alternate data stream(s) in $count items:" -Type "Warning"
        Write-Console "" -Type "Normal"
        
        foreach ($ads in $adsFound | Select-Object -First 20) {
            $streamType = switch -Regex ($ads.Stream) {
                "Zone\.Identifier" { "(Download marker - safe to remove)" }
                "SummaryInformation" { "(File metadata)" }
                "DocumentSummaryInformation" { "(Document metadata)" }
                default { "(Unknown purpose)" }
            }
            Write-Console "  File: $($ads.Path)" -Type "Normal"
            Write-Console "    Stream: :$($ads.Stream) [$($ads.Size) bytes] $streamType" -Type "Info"
        }
        
        if ($adsFound.Count -gt 20) {
            Write-Console "" -Type "Normal"
            Write-Console "  ...and $($adsFound.Count - 20) more streams found" -Type "Normal"
        }
    }
    
    return $adsFound
}

function Remove-AllADS {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        Write-Log "ADS removal path rejected: $Path - $($check.Reason)" -Level "ERROR"
        return
    }
    
    Write-Console "Removing all alternate data streams from: $Path" -Type "Info"
    Set-Status "Removing ADS..."
    
    $removed = 0
    $failed = 0
    
    try {
        $streams = Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop
        
        foreach ($stream in $streams) {
            if ($stream.Stream -ne ':$DATA') {
                try {
                    Remove-Item -LiteralPath $Path -Stream $stream.Stream -ErrorAction Stop
                    Write-Console "  Removed: :$($stream.Stream)" -Type "Success"
                    $removed++
                }
                catch {
                    Write-Console "  Failed to remove: :$($stream.Stream) - $_" -Type "Error"
                    $failed++
                }
            }
        }
        
        Write-Console "" -Type "Normal"
        if ($removed -gt 0) {
            Write-Console "Successfully removed $removed stream(s)" -Type "Success"
        }
        if ($failed -gt 0) {
            Write-Console "Failed to remove $failed stream(s)" -Type "Warning"
        }
        if ($removed -eq 0 -and $failed -eq 0) {
            Write-Console "No alternate data streams to remove" -Type "Info"
        }
    }
    catch {
        Write-Console "Error accessing streams: $_" -Type "Error"
    }
    
    Set-Status "Ready"
}

function Invoke-UnblockFile {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        Write-Log "Unblock path rejected: $Path - $($check.Reason)" -Level "ERROR"
        return $false
    }
    
    Write-Console "Removing Zone.Identifier (unblocking downloaded file)..." -Type "Info"
    Write-Console "This removes the 'This file came from another computer' warning" -Type "Normal"
    
    try {
        $streams = Get-Item -LiteralPath $Path -Stream * -ErrorAction SilentlyContinue
        $zoneStream = $streams | Where-Object { $_.Stream -eq "Zone.Identifier" }
        
        if ($zoneStream) {
            Unblock-File -LiteralPath $Path -ErrorAction Stop
            Write-Console "File unblocked successfully" -Type "Success"
            return $true
        }
        else {
            Write-Console "File is not blocked (no Zone.Identifier stream)" -Type "Info"
            return $true
        }
    }
    catch {
        Write-Console "Failed to unblock: $_" -Type "Error"
        return $false
    }
}

function Invoke-UnblockRecursive {
    param([string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        Write-Console "Rejected: $($check.Reason)" -Type "Error"
        Write-Log "Recursive unblock path rejected: $Path - $($check.Reason)" -Level "ERROR"
        return
    }
    
    Write-Console "Unblocking all files recursively in: $Path" -Type "Info"
    Set-Status "Unblocking files..."
    
    $items = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    $unblocked = 0
    $total = @($items).Count
    $processed = 0
    
    foreach ($item in $items) {
        $processed++
        if ($processed % 20 -eq 0) {
            Set-Progress -Value $processed -Maximum $total
            Set-Status "Unblocking $processed/$total..."
        }
        
        try {
            $streams = Get-Item -LiteralPath $item.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
            if ($streams) {
                Unblock-File -LiteralPath $item.FullName -ErrorAction SilentlyContinue
                $unblocked++
            }
        }
        catch { Write-Log "Unblock error on $($item.FullName): $_" -Level "WARN" }
    }
    
    Write-Console "Unblocked $unblocked file(s) out of $total total" -Type "Success"
    Set-Status "Ready"
    Set-Progress -Value 0
}

# ============================================================================
# FILESYSTEM REPAIR
# ============================================================================
function Confirm-RepairDriveHealth {
    param(
        [string]$Drive,
        [string]$Operation,
        [scriptblock]$PromptAction
    )

    $health = Get-DriveSmartHealth -Drive $Drive
    if (-not $health.Available -or -not $health.PredictFailure) {
        return $true
    }

    Write-Console "SMART predicts failure for $Drive ($($health.DiskName))" -Type "Error"
    Write-Console "BACKUP FIRST before attempting $Operation" -Type "Error"

    $message = "SMART reports that $Drive may be failing.`n`nBACKUP FIRST. Running $Operation on a failing drive can cause additional data loss.`n`nContinue anyway?"
    $result = if ($PromptAction) {
        & $PromptAction $message
    }
    else {
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            "Drive Failure Warning",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
    }

    if ($result -eq 6) {
        Write-Log "User overrode SMART failure warning for $Operation on $Drive" -Level "WARN"
        return $true
    }

    Write-Console "$Operation cancelled - back up the drive before repair" -Type "Warning"
    Write-Log "$Operation cancelled due to SMART failure warning on $Drive" -Level "WARN"
    return $false
}

function Get-VolumeCorruptionHealth {
    param([string]$Drive)

    Write-Console "=== Quick Volume Health Check: $Drive ===" -Type "Info"
    Set-Status "Checking volume corruption count..."

    $health = Get-VolumeCorruptionRecord -Drive $Drive
    if ($health.Available) {
        if ($health.CorruptionCount -gt 0) {
            Write-Console "$Drive has $($health.CorruptionCount) recorded filesystem corruption(s)" -Type "Warning"
            Write-Console "Run CHKDSK /scan to inspect the volume before repair" -Type "Info"
        }
        else {
            Write-Console "$Drive has no recorded filesystem corruption" -Type "Success"
        }

        Set-Status "Quick health check complete"
        return $health
    }

    Write-Console "Quick health check unavailable: $($health.Error)" -Type "Warning"
    Set-Status "Quick health check unavailable"
    Write-Log "Volume corruption count failed for $Drive : $($health.Error)" -Level "WARN"
    return $health
}

function Invoke-ChkdskWithProgress {
    param(
        [string]$Drive,
        [ValidateSet('ChkdskScan', 'ChkdskFix', 'ChkdskFull', 'ChkdskSpotfix')]
        [string]$Operation
    )

    $repairResult = Invoke-PathForgeRepair -Operation $Operation -Drive $Drive `
        -OutputAction { param($line) Write-Console "  $line" -Type "Normal" } `
        -ErrorCallback { param($line) Write-Console "  $line" -Type "Error" } `
        -ProgressCallback { param($percent, $display) $null = $display; Set-Progress -Value $percent -Maximum 100 } `
        -ProcessAction { param($process) $Script:ActiveProcess = $process } `
        -PumpAction { [System.Windows.Forms.Application]::DoEvents() }

    Set-Progress -Value 0
    return $repairResult
}

function Invoke-ChkdskScan {
    param([string]$Drive)
    if (-not (Enter-Operation "CHKDSK /scan $Drive")) { return }

    Write-Console "=== CHKDSK /scan on $Drive ===" -Type "Info"
    Write-Console "Online scan - no volume lock required (Windows 8+)" -Type "Normal"
    Write-Console "" -Type "Normal"
    Set-Status "CHKDSK running..."
    
    $repairResult = Invoke-ChkdskWithProgress -Drive $Drive -Operation ChkdskScan
    
    Write-Console "" -Type "Normal"
    if ($repairResult.Success) {
        Write-Console "CHKDSK /scan complete" -Type "Success"
    }
    else {
        Write-Console "CHKDSK /scan failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
    }
    Exit-Operation
}

function Invoke-ChkdskFix {
    param([string]$Drive)
    if (-not (Confirm-RepairDriveHealth -Drive $Drive -Operation "CHKDSK /F")) { return }
    if (-not (Enter-Operation "CHKDSK /F $Drive")) { return }

    if ($Drive -eq "C:") {
        Write-Console "System drive requires reboot for /F repair" -Type "Warning"
        Write-Console "CHKDSK needs exclusive access to C: drive" -Type "Normal"
        
        $result = [System.Windows.Forms.MessageBox]::Show(
            "The system drive (C:) requires a reboot to repair.`n`nCHKDSK /F needs exclusive access to the volume which can't happen while Windows is running.`n`nSchedule CHKDSK /F for next reboot?",
            "Schedule CHKDSK", 4, 32)
        if ($result -eq 6) {
            Write-Console "Scheduling CHKDSK /F for next boot..." -Type "Progress"
            $null = Start-Process -FilePath "chkdsk.exe" -ArgumentList "$Drive /F" -NoNewWindow -Wait
            Write-Console "CHKDSK /F scheduled - will run on next reboot" -Type "Success"
            Write-Console "Reboot when ready to run the check" -Type "Info"
        }
    }
    else {
        Write-Console "=== CHKDSK /F /X on $Drive ===" -Type "Info"
        Write-Console "/F = Fix errors, /X = Force dismount first" -Type "Normal"
        Write-Console "" -Type "Normal"
        Set-Status "CHKDSK running..."
        
        $repairResult = Invoke-ChkdskWithProgress -Drive $Drive -Operation ChkdskFix
        
        Write-Console "" -Type "Normal"
        if ($repairResult.Success) {
            Write-Console "CHKDSK /F complete" -Type "Success"
        }
        else {
            Write-Console "CHKDSK /F failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
        }
    }
    Exit-Operation
}

function Invoke-ChkdskFull {
    param([string]$Drive)
    if (-not (Confirm-RepairDriveHealth -Drive $Drive -Operation "CHKDSK /R")) { return }
    if (-not (Enter-Operation "CHKDSK /R $Drive")) { return }

    Write-Console "=== CHKDSK /R on $Drive ===" -Type "Warning"
    Write-Console "/R = Full repair including bad sector recovery" -Type "Normal"
    Write-Console "WARNING: This can take SEVERAL HOURS on large drives!" -Type "Warning"
    Write-Console "" -Type "Normal"
    Set-Status "CHKDSK /R running (this takes hours)..."
    
    $repairResult = Invoke-ChkdskWithProgress -Drive $Drive -Operation ChkdskFull
    
    Write-Console "" -Type "Normal"
    if ($repairResult.Success) {
        Write-Console "CHKDSK /R complete" -Type "Success"
    }
    else {
        Write-Console "CHKDSK /R failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
    }
    Exit-Operation
}

function Invoke-ChkdskSpotfix {
    param([string]$Drive)
    if (-not (Enter-Operation "CHKDSK /spotfix $Drive")) { return }

    Write-Console "=== CHKDSK /spotfix on $Drive ===" -Type "Info"
    Write-Console "Targeted repair of issues found by /scan (very fast)" -Type "Normal"
    Write-Console "" -Type "Normal"
    Set-Status "CHKDSK running..."
    
    $repairResult = Invoke-ChkdskWithProgress -Drive $Drive -Operation ChkdskSpotfix
    
    Write-Console "" -Type "Normal"
    if ($repairResult.Success) {
        Write-Console "CHKDSK /spotfix complete" -Type "Success"
    }
    else {
        Write-Console "CHKDSK /spotfix failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
    }
    Exit-Operation
}

function Invoke-SFCScan {
    if (-not (Enter-Operation "SFC /scannow")) { return }
    Write-Console "=== SFC /scannow ===" -Type "Info"
    Write-Console "System File Checker - repairs protected Windows files" -Type "Normal"
    Write-Console "Source: WinSxS component store" -Type "Normal"
    Write-Console "Duration: ~10-15 minutes" -Type "Warning"
    Write-Console "" -Type "Normal"
    Set-Status "SFC running..."
    
    $repairResult = Invoke-PathForgeRepair -Operation SfcScan `
        -OutputAction { param($line) if ($line.Length -gt 5) { Write-Console "  $line" -Type "Normal" } } `
        -ErrorCallback { param($line) Write-Console "  $line" -Type "Error" } `
        -ProgressCallback { param($percent, $display) Set-Progress -Value $percent -Maximum 100; Set-Status "SFC running... $display" } `
        -ProcessAction { param($process) $Script:ActiveProcess = $process } `
        -PumpAction { [System.Windows.Forms.Application]::DoEvents() }

    $sfcFailed = @($repairResult.Output | Where-Object {
            $_ -match 'unable to fix|could not.*repair|found corrupt files but was unable'
        }).Count -gt 0

    Write-Console "" -Type "Normal"
    if (-not $repairResult.Success) {
        Write-Console "SFC failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
    }
    elseif ($sfcFailed) {
        Write-Console "SFC found issues it could not repair" -Type "Warning"
        Write-Console "" -Type "Normal"
        Write-Console "NEXT STEPS:" -Type "Info"
        Write-Console "  1. Run DISM /RestoreHealth first to repair the component store" -Type "Info"
        Write-Console "  2. Then re-run SFC /scannow" -Type "Info"
        Write-Console "  3. Check details in: %WinDir%\Logs\CBS\CBS.log" -Type "Info"
    }
    else {
        Write-Console "SFC scan complete" -Type "Success"
    }
    Write-Console "Log file: %WinDir%\Logs\CBS\CBS.log" -Type "Info"
    Exit-Operation
}

function Invoke-DISMRestore {
    if (-not (Enter-Operation "DISM /RestoreHealth")) { return }
    Write-Console "=== DISM /Online /Cleanup-Image /RestoreHealth ===" -Type "Info"
    Write-Console "Repairs Windows component store (WinSxS)" -Type "Normal"
    Write-Console "Source: Windows Update (requires internet)" -Type "Normal"
    Write-Console "Duration: ~15-30 minutes" -Type "Warning"
    Write-Console "" -Type "Normal"
    Write-Console "IMPORTANT: Run this BEFORE SFC if component store is corrupt!" -Type "Warning"
    Write-Console "" -Type "Normal"
    Set-Status "DISM running..."
    
    $repairResult = Invoke-PathForgeRepair -Operation DismRestore `
        -OutputAction { param($line) if ($line.Length -gt 3 -and $line -notmatch '^\[=+\s*\]') { Write-Console "  $line" -Type "Normal" } } `
        -ErrorCallback { param($line) Write-Console "  $line" -Type "Error" } `
        -ProgressCallback { param($percent, $display) Set-Progress -Value $percent -Maximum 100; Set-Status "DISM running... $display" } `
        -ProcessAction { param($process) $Script:ActiveProcess = $process } `
        -PumpAction { [System.Windows.Forms.Application]::DoEvents() } `
        -StallAction {
            param($lastPercent)
            if ($lastPercent -ge 60 -and $lastPercent -le 65) {
                Write-Console "  [NORMAL] DISM often stalls near 62% on Win11 24H2 -- this is a known behavior, not a hang" -Type "Info"
            }
            else {
                Write-Console "  [NORMAL] DISM is still working -- progress may pause for several minutes at certain stages" -Type "Info"
            }
            Write-Console "  Do NOT cancel unless you are certain the process has stopped" -Type "Warning"
        }

    Write-Console "" -Type "Normal"
    if ($repairResult.Success) {
        Write-Console "DISM RestoreHealth complete" -Type "Success"
    }
    else {
        Write-Console "DISM failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
    }
    Write-Console "Log file: %WinDir%\Logs\DISM\dism.log" -Type "Info"
    Exit-Operation
}

function Invoke-FullSystemRepair {
    if (-not (Enter-Operation "Full System Repair")) { return }

    try {
        if ([System.Windows.Forms.MessageBox]::Show(
                "Run complete repair sequence?`n`n1. DISM /RestoreHealth (15-30 min)`n2. SFC /scannow (10-15 min)`n3. CHKDSK /scan (5-10 min)`n`nTotal time: 30-60 minutes",
                "Full System Repair", 4, 32) -ne 6) {
            return
        }

        Write-Console "=== FULL SYSTEM REPAIR SEQUENCE ===" -Type "Info"
        Write-Console "" -Type "Normal"

        $steps = @(
            @{Operation = 'DismRestore'; Drive = $null; Label = 'DISM /RestoreHealth' },
            @{Operation = 'SfcScan'; Drive = $null; Label = 'SFC /scannow' },
            @{Operation = 'ChkdskScan'; Drive = 'C:'; Label = 'CHKDSK /scan on C:' }
        )

        for ($index = 0; $index -lt $steps.Count; $index++) {
            $step = $steps[$index]
            $stepNumber = $index + 1
            Write-Console "Step $stepNumber/$($steps.Count): $($step.Label)" -Type "Info"
            Set-Status "Full Repair: $($step.Label) running..."

            $repairResult = Invoke-PathForgeRepair -Operation $step.Operation -Drive $step.Drive `
                -OutputAction { param($line) if ($line.Length -gt 3 -and $line -notmatch '^\[=+\s*\]') { Write-Console "  $line" -Type "Normal" } } `
                -ErrorCallback { param($line) Write-Console "  $line" -Type "Error" } `
                -ProgressCallback { param($percent, $display) Set-Progress -Value $percent -Maximum 100; Set-Status "Full Repair: $($step.Label) $display" } `
                -ProcessAction { param($process) $Script:ActiveProcess = $process } `
                -PumpAction { [System.Windows.Forms.Application]::DoEvents() } `
                -StallAction { param($lastPercent) $null = $lastPercent; Write-Console "  The repair is still working -- progress can pause for several minutes" -Type "Info" }

            if (-not $repairResult.Success) {
                Write-Console "$($step.Label) failed (exit code $($repairResult.ExitCode)): $($repairResult.Error)" -Type "Error"
                Write-Console "Full repair sequence stopped before the next step" -Type "Warning"
                return
            }

            Write-Console "  $($step.Label) complete" -Type "Success"
            Write-Console "" -Type "Normal"
        }

        Write-Console "=== FULL REPAIR SEQUENCE COMPLETE ===" -Type "Success"
        Write-Console "Recommend: Reboot and run SFC again to verify" -Type "Info"
    }
    finally {
        Exit-Operation
    }
}

function Get-DirtyBitStatus {
    Write-Console "=== Volume Dirty Bit Status ===" -Type "Info"
    Write-Console "Dirty volumes will run CHKDSK on next boot" -Type "Normal"
    Write-Console "" -Type "Normal"
    
    $drives = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
    
    foreach ($drv in $drives) {
        $letter = "$($drv.DriveLetter):"
        $result = fsutil dirty query $letter 2>&1
        
        if ($result -match "NOT Dirty") {
            Write-Console "  $letter ($($drv.FileSystemLabel)) - Clean" -Type "Success"
        }
        elseif ($result -match "Dirty") {
            Write-Console "  $letter ($($drv.FileSystemLabel)) - DIRTY (CHKDSK pending at boot)" -Type "Error"
        }
        else {
            Write-Console "  $letter - Could not query status" -Type "Warning"
        }
    }
}

function Set-DirtyBit {
    param([string]$Drive)
    
    Write-Console "Setting dirty bit on $Drive to force CHKDSK at boot..." -Type "Warning"
    
    try {
        $result = fsutil dirty set $Drive 2>&1
        Write-Console "Dirty bit set successfully" -Type "Success"
        Write-Console "CHKDSK will automatically run on next boot" -Type "Info"
    }
    catch {
        Write-Console "Failed: $_" -Type "Error"
    }
}

function Reset-WindowsUpdate {
    if (-not (Enter-Operation "Windows Update Reset")) { return }
    Write-Console "=== Windows Update Component Reset ===" -Type "Info"
    Write-Console "Stopping services, clearing caches, re-registering DLLs..." -Type "Normal"
    Write-Console "" -Type "Normal"

    $services = @('bits', 'wuauserv', 'appidsvc', 'cryptsvc')
    foreach ($svc in $services) {
        Write-Console "  Stopping $svc..." -Type "Progress"
        $null = sc.exe stop $svc 2>&1
    }

    $sdPath = "$env:SystemRoot\SoftwareDistribution"
    $crPath = "$env:SystemRoot\System32\catroot2"
    $backupSuffix = ".bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    try {
        if (Test-Path $sdPath) {
            Rename-Item -LiteralPath $sdPath -NewName "SoftwareDistribution$backupSuffix" -Force -ErrorAction Stop
            Write-Console "  Renamed SoftwareDistribution -> SoftwareDistribution$backupSuffix" -Type "Success"
        }
        if (Test-Path $crPath) {
            Rename-Item -LiteralPath $crPath -NewName "catroot2$backupSuffix" -Force -ErrorAction Stop
            Write-Console "  Renamed catroot2 -> catroot2$backupSuffix" -Type "Success"
        }
    }
    catch {
        Write-Console "  Failed to rename cache folders: $_" -Type "Error"
        Write-Console "  Rolling back -- restarting services..." -Type "Warning"
        foreach ($svc in $services) { $null = sc.exe start $svc 2>&1 }
        Exit-Operation
        return
    }

    $dlls = @(
        'atl.dll', 'urlmon.dll', 'mshtml.dll', 'shdocvw.dll',
        'browseui.dll', 'jscript.dll', 'vbscript.dll', 'scrrun.dll',
        'msxml.dll', 'msxml3.dll', 'msxml6.dll', 'actxprxy.dll',
        'softpub.dll', 'wintrust.dll', 'dssenh.dll', 'rsaenh.dll',
        'gpkcsp.dll', 'sccbase.dll', 'slbcsp.dll', 'cryptdlg.dll',
        'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'initpki.dll',
        'wuapi.dll', 'wuaueng.dll', 'wuaueng1.dll', 'wucltui.dll',
        'wups.dll', 'wups2.dll', 'wuweb.dll', 'qmgr.dll', 'qmgrprxy.dll',
        'wucltux.dll', 'muweb.dll', 'wuwebv.dll'
    )

    Write-Console "  Re-registering $($dlls.Count) DLLs..." -Type "Progress"
    foreach ($dll in $dlls) {
        $null = regsvr32.exe /s $dll 2>&1
    }
    Write-Console "  DLL registration complete" -Type "Success"

    Write-Console "  Resetting Winsock..." -Type "Progress"
    $null = netsh winsock reset 2>&1
    $null = netsh winhttp reset proxy 2>&1

    foreach ($svc in $services) {
        Write-Console "  Starting $svc..." -Type "Progress"
        $null = sc.exe start $svc 2>&1
    }

    Write-Console "" -Type "Normal"
    Write-Console "Windows Update components reset successfully" -Type "Success"
    Write-Console "Backups saved with suffix: $backupSuffix" -Type "Info"
    Write-Console "Reboot recommended, then try Windows Update again" -Type "Info"
    Exit-Operation
}

function Get-NTFSSelfHealingStatus {
    Write-Console "=== NTFS Self-Healing Status ===" -Type "Info"
    Write-Console "Auto-repair that runs in background without CHKDSK" -Type "Normal"
    Write-Console "" -Type "Normal"
    
    $drives = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' }
    
    foreach ($drv in $drives) {
        $letter = "$($drv.DriveLetter):"
        $result = fsutil repair query $letter 2>&1
        Write-Console "  $letter ($($drv.FileSystemLabel)):" -Type "Info"
        foreach ($line in ($result -split "`n")) {
            if ($line.Trim()) {
                Write-Console "    $($line.Trim())" -Type "Normal"
            }
        }
    }
}

function Set-NTFSSelfHealing {
    param([string]$Drive, [bool]$Enable)
    
    $action = if ($Enable) { "Enabling" } else { "Disabling" }
    $value = if ($Enable) { "1" } else { "0" }
    
    Write-Console "$action NTFS self-healing on $Drive..." -Type "Info"
    
    try {
        $result = fsutil repair set $Drive $value 2>&1
        Write-Console "Self-healing $(if ($Enable) {'enabled'} else {'disabled'})" -Type "Success"
    }
    catch {
        Write-Console "Failed: $_" -Type "Error"
    }
}

# ============================================================================
# DIAGNOSTICS
# ============================================================================
function Get-DriveHealth {
    Write-Console "=== Comprehensive Drive Health Report ===" -Type "Info"
    Write-Console "" -Type "Normal"

    $report = Get-PathForgeDriveHealth
    
    # Physical disks
    Write-Console "--- Physical Disks ---" -Type "Info"
    foreach ($disk in $report.PhysicalDisks) {
        $health = $disk.HealthStatus
        $type = switch ($health) {
            "Healthy" { "Success" }
            "Warning" { "Warning" }
            default { "Error" }
        }
        Write-Console "  $($disk.FriendlyName)" -Type "Info"
        Write-Console "    Model: $($disk.Model)" -Type "Normal"
        Write-Console "    Media: $($disk.MediaType)" -Type "Normal"
        Write-Console "    Size: $([math]::Round($disk.Size/1GB)) GB" -Type "Normal"
        Write-Console "    Health: $health" -Type $type
        Write-Console "    Status: $($disk.OperationalStatus)" -Type "Normal"
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "--- Volumes ---" -Type "Info"
    foreach ($volume in $report.Volumes) {
        $pctFree = if ($volume.Size -gt 0) { [math]::Round(($volume.SizeRemaining / $volume.Size) * 100, 1) } else { 0 }
        $freeType = if ($pctFree -lt 10) { "Error" } elseif ($pctFree -lt 20) { "Warning" } else { "Normal" }
        
        Write-Console "  $($volume.DriveLetter): $($volume.FileSystemLabel)" -Type "Info"
        Write-Console "    FileSystem: $($volume.FileSystem)" -Type "Normal"
        Write-Console "    Size: $([math]::Round($volume.Size/1GB, 1)) GB" -Type "Normal"
        Write-Console "    Free: $([math]::Round($volume.SizeRemaining/1GB, 1)) GB ($pctFree%)" -Type $freeType
        Write-Console "    Health: $($volume.HealthStatus)" -Type "Normal"
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "--- SMART Failure Prediction ---" -Type "Info"
    if ($report.SmartStatuses.Count -eq 0) {
        Write-Console "  SMART data not available via WMI" -Type "Warning"
    }
    else {
        foreach ($smartStatus in $report.SmartStatuses) {
            $name = ($smartStatus.InstanceName -replace '_0$', '' -split '\\')[-1]
            if ($smartStatus.PredictFailure) {
                Write-Console "  $name : FAILURE PREDICTED!" -Type "Error"
                Write-Console "    >>> BACKUP YOUR DATA IMMEDIATELY! <<<" -Type "Error"
            }
            else {
                Write-Console "  $name : No failure predicted" -Type "Success"
            }
        }
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "--- Storage Reliability Counters ---" -Type "Info"
    if ($report.ReliabilityCounters.Count -eq 0) {
        Write-Console "  Reliability counters not available" -Type "Warning"
    }
    else {
        foreach ($counter in $report.ReliabilityCounters) {
            Write-Console "  Device: $($counter.DeviceId)" -Type "Info"
            Write-Console "    Read Errors: $($counter.ReadErrorsTotal) (Uncorrected: $($counter.ReadErrorsUncorrected))" -Type $(if ($counter.ReadErrorsUncorrected -gt 0) { "Error" } elseif ($counter.ReadErrorsTotal -gt 0) { "Warning" } else { "Normal" })
            Write-Console "    Write Errors: $($counter.WriteErrorsTotal) (Uncorrected: $($counter.WriteErrorsUncorrected))" -Type $(if ($counter.WriteErrorsUncorrected -gt 0) { "Error" } elseif ($counter.WriteErrorsTotal -gt 0) { "Warning" } else { "Normal" })
            $tempC = $counter.Temperature
            Write-Console "    Temperature: ${tempC}C" -Type $(if ($tempC -gt 55) { "Error" } elseif ($tempC -gt 45) { "Warning" } else { "Normal" })
            $wearPct = $counter.Wear
            Write-Console "    Wear: ${wearPct}%" -Type $(if ($wearPct -gt 80) { "Error" } elseif ($wearPct -gt 50) { "Warning" } else { "Normal" })
            Write-Console "    Power-On Hours: $($counter.PowerOnHours)" -Type "Normal"
            if ($counter.ReadLatencyMax -gt 0) {
                Write-Console "    Max Read Latency: $($counter.ReadLatencyMax) ms" -Type $(if ($counter.ReadLatencyMax -gt 10000) { "Error" } elseif ($counter.ReadLatencyMax -gt 1000) { "Warning" } else { "Normal" })
            }
            if ($counter.WriteLatencyMax -gt 0) {
                Write-Console "    Max Write Latency: $($counter.WriteLatencyMax) ms" -Type $(if ($counter.WriteLatencyMax -gt 10000) { "Error" } elseif ($counter.WriteLatencyMax -gt 1000) { "Warning" } else { "Normal" })
            }
        }
    }
}

function Get-SmartStatus {
    Write-Console "=== SMART Failure Prediction ===" -Type "Info"
    Write-Console "" -Type "Normal"

    $result = Get-PathForgeSmartStatus
    if (-not $result.Success) {
        Write-Console "  Failed to query SMART: $($result.Error)" -Type "Error"
        return
    }
    if ($result.Items.Count -eq 0) {
        Write-Console "  SMART data not available via WMI" -Type "Warning"
        return
    }

    foreach ($status in $result.Items) {
        $name = ($status.InstanceName -replace '_0$', '' -split '\\')[-1]
        if ($status.PredictFailure) {
            Write-Console "  $name : FAILURE PREDICTED!" -Type "Error"
            Write-Console "    Reason Code: $($status.Reason)" -Type "Error"
            Write-Console "    >>> BACKUP YOUR DATA IMMEDIATELY! <<<" -Type "Error"
        }
        else {
            Write-Console "  $name : No failure predicted" -Type "Success"
        }
    }
}

function Get-ReliabilityCounter {
    Write-Console "=== Storage Reliability Counters ===" -Type "Info"
    Write-Console "" -Type "Normal"

    $result = Get-PathForgeReliabilityCounter
    if (-not $result.Success) {
        Write-Console "  Reliability counters not available: $($result.Error)" -Type "Warning"
        return
    }

    foreach ($counter in $result.Items) {
        Write-Console "  Device ID: $($counter.DeviceId)" -Type "Info"
        Write-Console "    Read Errors (Total): $($counter.ReadErrorsTotal)" -Type $(if ($counter.ReadErrorsTotal -gt 0) { "Warning" } else { "Normal" })
        Write-Console "    Read Errors (Corrected): $($counter.ReadErrorsCorrected)" -Type "Normal"
        Write-Console "    Read Errors (Uncorrected): $($counter.ReadErrorsUncorrected)" -Type $(if ($counter.ReadErrorsUncorrected -gt 0) { "Error" } else { "Normal" })
        Write-Console "    Write Errors (Total): $($counter.WriteErrorsTotal)" -Type $(if ($counter.WriteErrorsTotal -gt 0) { "Warning" } else { "Normal" })
        Write-Console "    Temperature: $($counter.Temperature) C" -Type $(if ($counter.Temperature -gt 50) { "Warning" } else { "Normal" })
        Write-Console "    Wear: $($counter.Wear)" -Type $(if ($counter.Wear -gt 80) { "Warning" } else { "Normal" })
        Write-Console "    Power On Hours: $($counter.PowerOnHours)" -Type "Normal"
        Write-Console "" -Type "Normal"
    }
}

function Get-TRIMStatus {
    Write-Console "=== TRIM / DisableDeleteNotify Status ===" -Type "Info"
    Write-Console "TRIM should be ENABLED for SSDs" -Type "Normal"
    Write-Console "" -Type "Normal"
    
    $status = Get-PathForgeTrimStatus
    if (-not $status.Success) {
        Write-Console "Could not query TRIM status: $($status.Error)" -Type "Error"
        return
    }

    foreach ($item in $status.Items) {
        if ($null -ne $item.Enabled) {
            if ($item.Enabled) {
                Write-Console "  $($item.FileSystem) TRIM: ENABLED (recommended)" -Type "Success"
            }
            else {
                Write-Console "  $($item.FileSystem) TRIM: DISABLED" -Type "Warning"
            }
        }
        else {
            Write-Console "  $($item.Raw)" -Type "Normal"
        }
    }
}

function Get-FilesystemEvents {
    Write-Console "=== Filesystem Event Log Analysis (Last 7 Days) ===" -Type "Info"
    Write-Console "" -Type "Normal"
    
    Write-Console "Searching for critical events..." -Type "Progress"

    $foundEvents = @(Get-PathForgeFilesystemEvent -Days 7 -MaxEventsPerId 10)
    foreach ($eventGroup in ($foundEvents | Group-Object Id)) {
        $description = $eventGroup.Group[0].Description
        Write-Console "  Event ID $($eventGroup.Name): $($eventGroup.Count) occurrence(s) - $description" -Type "Warning"
    }
    
    if ($foundEvents.Count -eq 0) {
        Write-Console "" -Type "Normal"
        Write-Console "No critical filesystem events found - drives appear healthy" -Type "Success"
    }
    else {
        Write-Console "" -Type "Normal"
        Write-Console "--- Recent Critical Events ---" -Type "Error"
        $foundEvents | Sort-Object TimeCreated -Descending | Select-Object -First 15 | ForEach-Object {
            $msgPreview = $_.Message.Split("`n")[0]
            if ($msgPreview.Length -gt 70) { $msgPreview = $msgPreview.Substring(0, 70) + "..." }
            Write-Console "  $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm')) [ID:$($_.Id)]" -Type "Warning"
            Write-Console "    $msgPreview" -Type "Normal"
        }
        Write-Console "" -Type "Normal"
        Write-Console "Consider running CHKDSK and checking drive SMART status" -Type "Info"
    }
}

function Show-MftReport {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "NTFS Master File Table Report"
    $dialog.Size = New-Object System.Drawing.Size(1120, 760)
    $dialog.MinimumSize = New-Object System.Drawing.Size(1000, 680)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $Script:Theme.BgPrimary
    $dialog.ForeColor = $Script:Theme.TextPrimary
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.Add_HandleCreated({ try { [DarkMode]::EnableDarkTitleBar($this.Handle) } catch { Write-Verbose "MFT report title-bar theming failed: $_" } })

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "NTFS Master File Table"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(20, 14)
    $title.AutoSize = $true
    $null = $dialog.Controls.Add($title)

    $description = New-Object System.Windows.Forms.Label
    $description.Text = "Read-only native extent map: logical MFT order plotted against physical cluster placement."
    $description.ForeColor = $Script:Theme.TextMuted
    $description.Location = New-Object System.Drawing.Point(22, 46)
    $description.Size = New-Object System.Drawing.Size(650, 22)
    $null = $dialog.Controls.Add($description)

    $driveLabel = New-Object System.Windows.Forms.Label
    $driveLabel.Text = "NTFS DRIVE"
    $driveLabel.ForeColor = $Script:Theme.TextMuted
    $driveLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $driveLabel.Location = New-Object System.Drawing.Point(700, 16)
    $driveLabel.AutoSize = $true
    $null = $dialog.Controls.Add($driveLabel)

    $driveCombo = New-Object System.Windows.Forms.ComboBox
    $driveCombo.Name = "MftDriveCombo"
    $driveCombo.AccessibleName = "Select NTFS drive for MFT report"
    $driveCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $driveCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $driveCombo.BackColor = $Script:Theme.BgInput
    $driveCombo.ForeColor = $Script:Theme.TextPrimary
    $driveCombo.Location = New-Object System.Drawing.Point(700, 37)
    $driveCombo.Size = New-Object System.Drawing.Size(190, 25)
    try {
        foreach ($volume in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })) {
            $label = if ([string]::IsNullOrWhiteSpace([string]$volume.FileSystemLabel)) { 'Local Disk' } else { [string]$volume.FileSystemLabel }
            $null = $driveCombo.Items.Add("$($volume.DriveLetter): $label")
        }
    }
    catch {
        Write-Verbose "Could not enumerate NTFS volumes for the MFT report: $_"
    }
    if ($driveCombo.Items.Count -eq 0 -and $env:SystemDrive -match '^[A-Za-z]:$') {
        $null = $driveCombo.Items.Add("$($env:SystemDrive) System Drive")
    }
    if ($driveCombo.Items.Count -gt 0) { $driveCombo.SelectedIndex = 0 }
    $null = $dialog.Controls.Add($driveCombo)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.AccessibleName = "Refresh MFT report"
    $refreshButton.Location = New-Object System.Drawing.Point(900, 35)
    $refreshButton.Size = New-Object System.Drawing.Size(85, 29)
    $refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $refreshButton.BackColor = $Script:Theme.AccentDim
    $refreshButton.ForeColor = $Script:Theme.TextPrimary
    $refreshButton.FlatAppearance.BorderSize = 0
    $refreshButton.Enabled = $driveCombo.Items.Count -gt 0
    $null = $dialog.Controls.Add($refreshButton)

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = "Export CSV"
    $exportButton.AccessibleName = "Export MFT extent report to CSV"
    $exportButton.Location = New-Object System.Drawing.Point(993, 35)
    $exportButton.Size = New-Object System.Drawing.Size(95, 29)
    $exportButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $exportButton.BackColor = $Script:Theme.BgTertiary
    $exportButton.ForeColor = $Script:Theme.TextSecondary
    $exportButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $exportButton.Enabled = $false
    $null = $dialog.Controls.Add($exportButton)

    $summaryPanel = New-Object System.Windows.Forms.Panel
    $summaryPanel.Name = "MftSummaryPanel"
    $summaryPanel.Location = New-Object System.Drawing.Point(20, 78)
    $summaryPanel.Size = New-Object System.Drawing.Size(1068, 72)
    $summaryPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $summaryPanel.BackColor = $Script:Theme.BgCard
    $null = $dialog.Controls.Add($summaryPanel)

    $summaryValues = @{}
    $summaryDefinitions = @(
        @{Key = 'Size'; Title = 'MFT VALID DATA'; X = 18 },
        @{Key = 'Allocated'; Title = 'ALLOCATED'; X = 225 },
        @{Key = 'Extents'; Title = 'FRAGMENTATION'; X = 432 },
        @{Key = 'Records'; Title = 'EST. RECORDS'; X = 639 },
        @{Key = 'Cluster'; Title = 'CLUSTER / RECORD'; X = 846 }
    )
    foreach ($definition in $summaryDefinitions) {
        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = $definition.Title
        $heading.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 7.5)
        $heading.ForeColor = $Script:Theme.TextMuted
        $heading.Location = New-Object System.Drawing.Point($definition.X, 10)
        $heading.Size = New-Object System.Drawing.Size(195, 18)
        $null = $summaryPanel.Controls.Add($heading)

        $value = New-Object System.Windows.Forms.Label
        $value.Name = "MftSummary$($definition.Key)"
        $value.Text = "-"
        $value.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
        $value.ForeColor = $Script:Theme.Info
        $value.Location = New-Object System.Drawing.Point($definition.X, 31)
        $value.Size = New-Object System.Drawing.Size(195, 30)
        $value.AutoEllipsis = $true
        $null = $summaryPanel.Controls.Add($value)
        $summaryValues[$definition.Key] = $value
    }

    $graph = New-Object System.Windows.Forms.Panel
    $graph.Name = "MftExtentGraph"
    $graph.AccessibleName = "MFT physical extent placement graph"
    $graph.Location = New-Object System.Drawing.Point(20, 162)
    $graph.Size = New-Object System.Drawing.Size(1068, 238)
    $graph.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $graph.BackColor = $Script:Theme.BgInput
    $null = $dialog.Controls.Add($graph)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = "MftExtentGrid"
    $grid.AccessibleName = "MFT extent table"
    $grid.Location = New-Object System.Drawing.Point(20, 412)
    $grid.Size = New-Object System.Drawing.Size(1068, 245)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.BackgroundColor = $Script:Theme.BgInput
    $grid.ForeColor = $Script:Theme.TextPrimary
    $grid.GridColor = $Script:Theme.Border
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Script:Theme.BgTertiary
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Script:Theme.TextPrimary
    $grid.DefaultCellStyle.BackColor = $Script:Theme.BgInput
    $grid.DefaultCellStyle.ForeColor = $Script:Theme.TextSecondary
    $grid.DefaultCellStyle.SelectionBackColor = $Script:Theme.AccentDim
    $grid.DefaultCellStyle.SelectionForeColor = $Script:Theme.TextPrimary
    $grid.EnableHeadersVisualStyles = $false
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AutoGenerateColumns = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.RowHeadersVisible = $false
    foreach ($columnDefinition in @(
            @{Name = 'Index'; Header = '#'; Width = 45 },
            @{Name = 'LogicalStart'; Header = 'Start VCN'; Width = 150 },
            @{Name = 'LogicalEnd'; Header = 'End VCN'; Width = 150 },
            @{Name = 'PhysicalStart'; Header = 'Start LCN'; Width = 170 },
            @{Name = 'PhysicalEnd'; Header = 'End LCN'; Width = 170 },
            @{Name = 'Clusters'; Header = 'Clusters'; Width = 140 },
            @{Name = 'Bytes'; Header = 'Bytes'; Width = 170 })) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $columnDefinition.Name
        $column.HeaderText = $columnDefinition.Header
        $column.Width = $columnDefinition.Width
        $null = $grid.Columns.Add($column)
    }
    $null = $dialog.Controls.Add($grid)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Name = "MftReportStatus"
    $statusLabel.ForeColor = $Script:Theme.TextMuted
    $statusLabel.Location = New-Object System.Drawing.Point(22, 672)
    $statusLabel.Size = New-Object System.Drawing.Size(780, 30)
    $statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusLabel.Text = if ($driveCombo.Items.Count -gt 0) { 'Ready to query native NTFS metadata.' } else { 'No local NTFS volumes were found.' }
    $null = $dialog.Controls.Add($statusLabel)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $closeButton.Location = New-Object System.Drawing.Point(998, 669)
    $closeButton.Size = New-Object System.Drawing.Size(90, 32)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.BackColor = $Script:Theme.BgTertiary
    $closeButton.ForeColor = $Script:Theme.TextSecondary
    $closeButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $null = $dialog.Controls.Add($closeButton)
    $dialog.CancelButton = $closeButton

    $formatBytes = {
        param([int64]$Value)
        if ($Value -ge 1TB) { return ('{0:N2} TB' -f ($Value / 1TB)) }
        if ($Value -ge 1GB) { return ('{0:N2} GB' -f ($Value / 1GB)) }
        if ($Value -ge 1MB) { return ('{0:N2} MB' -f ($Value / 1MB)) }
        if ($Value -ge 1KB) { return ('{0:N2} KB' -f ($Value / 1KB)) }
        return "$Value bytes"
    }

    $graphState = [PSCustomObject]@{
        Report     = $null
        Background = $Script:Theme.BgInput
        Border     = $Script:Theme.Border
        Line       = $Script:Theme.Info
        Point      = $Script:Theme.Warning
        Text       = $Script:Theme.TextMuted
        Zone       = $Script:Theme.AccentDim
    }
    $graph.Tag = $graphState
    $graph.Add_Paint({
        param($paintSender, $paintEvent)
        $graphics = $null
        $titleFont = $null
        $labelFont = $null
        $axisPen = $null
        $linePen = $null
        $pointBrush = $null
        $textBrush = $null
        $zoneBrush = $null
        try {
            $state = $paintSender.Tag
            $report = $state.Report
            $bounds = $paintSender.ClientRectangle
            $graphics = $paintEvent.Graphics
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $titleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5)
            $labelFont = New-Object System.Drawing.Font("Segoe UI", 7.5)
            $axisPen = New-Object System.Drawing.Pen($state.Border, 1)
            $linePen = New-Object System.Drawing.Pen($state.Line, 2)
            $pointBrush = New-Object System.Drawing.SolidBrush($state.Point)
            $textBrush = New-Object System.Drawing.SolidBrush($state.Text)
            $zoneBrush = New-Object System.Drawing.SolidBrush($state.Zone)
            $graphics.DrawString('Physical LCN by logical MFT order', $titleFont, $textBrush, 14, 8)
            $plotLeft = 48
            $plotTop = 32
            $plotWidth = [Math]::Max(100, $bounds.Width - 68)
            $plotHeight = 112
            $graphics.DrawRectangle($axisPen, $plotLeft, $plotTop, $plotWidth, $plotHeight)

            if ($report -and $report.Success -and $report.ExtentQuerySuccess -and $report.Extents.Count -gt 0) {
                [double]$logicalTotal = [Math]::Max(1, ($report.Extents | Measure-Object LogicalEndVcn -Maximum).Maximum + 1)
                [double]$physicalTotal = [Math]::Max(1, $report.TotalClusters)
                $previousPoint = $null
                foreach ($extent in @($report.Extents | Where-Object { -not $_.IsSparse })) {
                    $pointX = $plotLeft + [int][Math]::Round(($extent.LogicalStartVcn / $logicalTotal) * $plotWidth)
                    $pointY = $plotTop + $plotHeight - [int][Math]::Round(($extent.PhysicalStartLcn / $physicalTotal) * $plotHeight)
                    $pointY = [Math]::Max($plotTop, [Math]::Min($plotTop + $plotHeight, $pointY))
                    $point = New-Object System.Drawing.Point($pointX, $pointY)
                    if ($previousPoint) { $graphics.DrawLine($linePen, $previousPoint, $point) }
                    $graphics.FillEllipse($pointBrush, $pointX - 3, $pointY - 3, 7, 7)
                    $previousPoint = $point
                }

                $barTop = 184
                $barHeight = 17
                $graphics.DrawString('Physical volume map', $labelFont, $textBrush, 14, 160)
                $graphics.DrawRectangle($axisPen, $plotLeft, $barTop, $plotWidth, $barHeight)
                $zoneX = $plotLeft + [int][Math]::Round(($report.MftZoneStartLcn / $physicalTotal) * $plotWidth)
                $zoneWidth = [Math]::Max(1, [int][Math]::Round((($report.MftZoneEndLcn - $report.MftZoneStartLcn) / $physicalTotal) * $plotWidth))
                $graphics.FillRectangle($zoneBrush, $zoneX, $barTop + 1, $zoneWidth, $barHeight - 1)
                foreach ($extent in @($report.Extents | Where-Object { -not $_.IsSparse })) {
                    $extentX = $plotLeft + [int][Math]::Round(($extent.PhysicalStartLcn / $physicalTotal) * $plotWidth)
                    $extentWidth = [Math]::Max(2, [int][Math]::Round(($extent.ClusterCount / $physicalTotal) * $plotWidth))
                    $graphics.FillRectangle($pointBrush, $extentX, $barTop + 2, $extentWidth, $barHeight - 3)
                }
                $graphics.DrawString('Blue: reserved MFT zone   Gold: allocated MFT extents', $labelFont, $textBrush, $plotLeft, 207)
            }
            else {
                $graphics.DrawString('Extent placement is unavailable for the selected volume.', $labelFont, $textBrush, $plotLeft + 12, $plotTop + 45)
            }
        }
        catch {
            $paintSender.AccessibleDescription = $_.Exception.Message
            try {
                $fallbackGraphics = $paintEvent.Graphics
                $fallbackGraphics.Clear([System.Drawing.Color]::FromArgb(22, 22, 28))
                $fallbackFont = New-Object System.Drawing.Font("Segoe UI", 8)
                $fallbackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 95, 95))
                try { $fallbackGraphics.DrawString("Graph rendering unavailable: $($_.Exception.Message)", $fallbackFont, $fallbackBrush, 16, 20) }
                finally { $fallbackFont.Dispose(); $fallbackBrush.Dispose() }
            }
            catch { Write-Verbose "MFT graph fallback rendering failed: $_" }
        }
        finally {
            foreach ($drawingResource in @($titleFont, $labelFont, $axisPen, $linePen, $pointBrush, $textBrush, $zoneBrush)) {
                if ($drawingResource) { $drawingResource.Dispose() }
            }
        }
    }.GetNewClosure())

    $loadState = [PSCustomObject]@{Running = $false}
    $loadReport = {
        if ($loadState.Running) { return }
        if ($driveCombo.SelectedIndex -lt 0) { return }
        $loadState.Running = $true
        $drive = $driveCombo.Text.Substring(0, 2)
        $statusLabel.Text = "Reading native NTFS metadata for $drive..."
        $statusLabel.ForeColor = $Script:Theme.Info
        try {
            if ($grid.Rows.Count -gt 0) { $grid.Rows.Clear() }
            $report = Get-PathForgeMftReport -Drive $drive
            $dialog.Tag = $report
            $graph.Tag.Report = $report
            if (-not $report.Success) {
                foreach ($valueLabel in $summaryValues.Values) { $valueLabel.Text = '-' }
                $statusLabel.Text = $report.Error
                $statusLabel.ForeColor = $Script:Theme.Error
                $exportButton.Enabled = $false
                $graph.Invalidate()
                Write-Console "MFT report failed for ${drive}: $($report.Error)" -Type "Error"
                return
            }

            $summaryValues.Size.Text = & $formatBytes $report.MftSizeBytes
            $summaryValues.Allocated.Text = & $formatBytes $report.MftAllocatedBytes
            $summaryValues.Extents.Text = $report.FragmentationLabel
            $summaryValues.Extents.ForeColor = if ($report.IsFragmented) { $Script:Theme.Warning } else { $Script:Theme.Success }
            $summaryValues.Records.Text = ('{0:N0}' -f $report.EstimatedRecordCount)
            $summaryValues.Cluster.Text = "$( & $formatBytes $report.BytesPerCluster) / $( & $formatBytes $report.BytesPerFileRecordSegment)"

            foreach ($extent in $report.Extents) {
                $physicalStart = if ($extent.IsSparse) { 'Sparse' } else { ('{0:N0}' -f $extent.PhysicalStartLcn) }
                $physicalEnd = if ($extent.IsSparse) { 'Sparse' } else { ('{0:N0}' -f $extent.PhysicalEndLcn) }
                $null = $grid.Rows.Add(
                    $extent.Index,
                    ('{0:N0}' -f $extent.LogicalStartVcn),
                    ('{0:N0}' -f $extent.LogicalEndVcn),
                    $physicalStart,
                    $physicalEnd,
                    ('{0:N0}' -f $extent.ClusterCount),
                    (& $formatBytes $extent.LengthBytes))
            }

            if ($report.ExtentQuerySuccess) {
                $statusLabel.Text = "Read-only report complete: $($report.ExtentCount) allocated extent(s), $($report.FragmentCount) fragmentation boundary/boundaries."
                $statusLabel.ForeColor = if ($report.IsFragmented) { $Script:Theme.Warning } else { $Script:Theme.Success }
                $exportButton.Enabled = $report.Extents.Count -gt 0
            }
            else {
                $statusLabel.Text = "MFT size loaded, but extent map failed: $($report.ExtentError)"
                $statusLabel.ForeColor = $Script:Theme.Warning
                $exportButton.Enabled = $false
            }
            Write-Console "MFT $drive : $( & $formatBytes $report.MftSizeBytes), $($report.FragmentationLabel)" -Type "Info"
            Write-Log "MFT report generated: drive=$drive size=$($report.MftSizeBytes) extents=$($report.ExtentCount)" -Level "INFO"
            $graph.Invalidate()
        }
        catch {
            $statusLabel.Text = $_.Exception.Message
            $statusLabel.ForeColor = $Script:Theme.Error
            $exportButton.Enabled = $false
            Write-Console "MFT report failed for ${drive}: $($_.Exception.Message)" -Type "Error"
        }
        finally {
            $loadState.Running = $false
        }
    }.GetNewClosure()

    $refreshButton.Add_Click({ & $loadReport }.GetNewClosure())
    $driveCombo.Add_SelectedIndexChanged({ if ($dialog.Visible) { & $loadReport } }.GetNewClosure())
    $exportButton.Add_Click({
        $report = $dialog.Tag
        if (-not $report -or -not $report.Success -or $report.Extents.Count -eq 0) { return }
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Title = "Export MFT extent report"
        $saveDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
        $saveDialog.FileName = "MFT_$($report.Drive.TrimEnd(':'))_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $saveDialog.InitialDirectory = $Script:Config.LogPath
        if ($saveDialog.ShowDialog($dialog) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        try {
            $report.Extents | Select-Object Index, LogicalStartVcn, LogicalEndVcn, PhysicalStartLcn, PhysicalEndLcn, ClusterCount, LengthBytes, IsSparse |
                Export-Csv -LiteralPath $saveDialog.FileName -NoTypeInformation -Encoding UTF8
            Write-Console "MFT extent report exported: $($saveDialog.FileName)" -Type "Success"
            Write-Log "MFT extent report exported: $($saveDialog.FileName)" -Level "SUCCESS"
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, "Export Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $dialog.Add_Shown({ & $loadReport }.GetNewClosure())

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner -and $owner -ne $dialog) { [void]$dialog.ShowDialog($owner) } else { [void]$dialog.ShowDialog() }
    $dialog.Dispose()
}

function Show-UsnJournalBrowser {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "NTFS USN Journal Browser"
    $dialog.Size = New-Object System.Drawing.Size(1260, 800)
    $dialog.MinimumSize = New-Object System.Drawing.Size(1120, 700)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $Script:Theme.BgPrimary
    $dialog.ForeColor = $Script:Theme.TextPrimary
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.Add_HandleCreated({ try { [DarkMode]::EnableDarkTitleBar($this.Handle) } catch { Write-Verbose "USN browser title-bar theming failed: $_" } })

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "NTFS USN Change Journal"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(20, 14)
    $title.AutoSize = $true
    $null = $dialog.Controls.Add($title)

    $description = New-Object System.Windows.Forms.Label
    $description.Text = "Read-only recent-change browser with native reason filtering and optional process evidence correlation."
    $description.ForeColor = $Script:Theme.TextMuted
    $description.Location = New-Object System.Drawing.Point(22, 46)
    $description.Size = New-Object System.Drawing.Size(900, 22)
    $null = $dialog.Controls.Add($description)

    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Name = "UsnFilterPanel"
    $filterPanel.Location = New-Object System.Drawing.Point(20, 76)
    $filterPanel.Size = New-Object System.Drawing.Size(1200, 108)
    $filterPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $filterPanel.BackColor = $Script:Theme.BgCard
    $null = $dialog.Controls.Add($filterPanel)

    $addFilterLabel = {
        param([string]$Text, [int]$X, [int]$Width)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 7.5)
        $label.ForeColor = $Script:Theme.TextMuted
        $label.Location = New-Object System.Drawing.Point($X, 9)
        $label.Size = New-Object System.Drawing.Size($Width, 18)
        $null = $filterPanel.Controls.Add($label)
    }

    & $addFilterLabel 'NTFS DRIVE' 16 120
    & $addFilterLabel 'REASON FLAGS' 146 230
    & $addFilterLabel 'PROCESS CONTAINS' 386 180
    & $addFilterLabel 'MAX RECORDS' 576 100
    & $addFilterLabel 'SCAN WINDOW (MB)' 686 120

    $driveCombo = New-Object System.Windows.Forms.ComboBox
    $driveCombo.Name = "UsnDriveCombo"
    $driveCombo.AccessibleName = "Select NTFS drive for USN journal browser"
    $driveCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $driveCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $driveCombo.BackColor = $Script:Theme.BgInput
    $driveCombo.ForeColor = $Script:Theme.TextPrimary
    $driveCombo.Location = New-Object System.Drawing.Point(16, 29)
    $driveCombo.Size = New-Object System.Drawing.Size(120, 25)
    try {
        foreach ($volume in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })) {
            $null = $driveCombo.Items.Add("$($volume.DriveLetter):")
        }
    }
    catch {
        Write-Verbose "Could not enumerate NTFS volumes for the USN browser: $_"
    }
    if ($driveCombo.Items.Count -eq 0 -and $env:SystemDrive -match '^[A-Za-z]:$') {
        $null = $driveCombo.Items.Add($env:SystemDrive)
    }
    if ($driveCombo.Items.Count -gt 0) { $driveCombo.SelectedIndex = 0 }
    $null = $filterPanel.Controls.Add($driveCombo)

    $reasonCombo = New-Object System.Windows.Forms.ComboBox
    $reasonCombo.Name = "UsnReasonCombo"
    $reasonCombo.AccessibleName = "Filter USN records by reason flags"
    $reasonCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $reasonCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $reasonCombo.BackColor = $Script:Theme.BgInput
    $reasonCombo.ForeColor = $Script:Theme.TextPrimary
    $reasonCombo.Location = New-Object System.Drawing.Point(146, 29)
    $reasonCombo.Size = New-Object System.Drawing.Size(230, 25)
    $reasonCombo.DisplayMember = 'Label'
    $reasonChoices = @(
        [PSCustomObject]@{Label = 'All changes'; Mask = [uint32]::MaxValue },
        [PSCustomObject]@{Label = 'File created'; Mask = [uint32]0x00000100 },
        [PSCustomObject]@{Label = 'File deleted'; Mask = [uint32]0x00000200 },
        [PSCustomObject]@{Label = 'Renamed (old or new name)'; Mask = [uint32]0x00003000 },
        [PSCustomObject]@{Label = 'Data changed'; Mask = [uint32]0x00000077 },
        [PSCustomObject]@{Label = 'Security changed'; Mask = [uint32]0x00000800 },
        [PSCustomObject]@{Label = 'Reparse point changed'; Mask = [uint32]0x00100000 },
        [PSCustomObject]@{Label = 'Stream changed'; Mask = [uint32]0x00200000 },
        [PSCustomObject]@{Label = 'Basic info changed'; Mask = [uint32]0x00008000 }
    )
    foreach ($choice in $reasonChoices) { $null = $reasonCombo.Items.Add($choice) }
    $reasonCombo.SelectedIndex = 0
    $null = $filterPanel.Controls.Add($reasonCombo)

    $processText = New-Object System.Windows.Forms.TextBox
    $processText.Name = "UsnProcessFilter"
    $processText.AccessibleName = "Filter correlated process name"
    $processText.BackColor = $Script:Theme.BgInput
    $processText.ForeColor = $Script:Theme.TextPrimary
    $processText.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $processText.Location = New-Object System.Drawing.Point(386, 30)
    $processText.Size = New-Object System.Drawing.Size(180, 24)
    $null = $filterPanel.Controls.Add($processText)

    $maxRecordsInput = New-Object System.Windows.Forms.NumericUpDown
    $maxRecordsInput.Name = "UsnMaxRecords"
    $maxRecordsInput.AccessibleName = "Maximum USN records"
    $maxRecordsInput.Minimum = 25
    $maxRecordsInput.Maximum = 50000
    $maxRecordsInput.Increment = 25
    $maxRecordsInput.Value = 500
    $maxRecordsInput.BackColor = $Script:Theme.BgInput
    $maxRecordsInput.ForeColor = $Script:Theme.TextPrimary
    $maxRecordsInput.Location = New-Object System.Drawing.Point(576, 30)
    $maxRecordsInput.Size = New-Object System.Drawing.Size(100, 24)
    $maxRecordsInput.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
    $null = $filterPanel.Controls.Add($maxRecordsInput)

    $scanWindowInput = New-Object System.Windows.Forms.NumericUpDown
    $scanWindowInput.Name = "UsnScanMegabytes"
    $scanWindowInput.AccessibleName = "USN journal scan window in megabytes"
    $scanWindowInput.Minimum = 1
    $scanWindowInput.Maximum = 1024
    $scanWindowInput.Increment = 16
    $scanWindowInput.Value = 64
    $scanWindowInput.BackColor = $Script:Theme.BgInput
    $scanWindowInput.ForeColor = $Script:Theme.TextPrimary
    $scanWindowInput.Location = New-Object System.Drawing.Point(686, 30)
    $scanWindowInput.Size = New-Object System.Drawing.Size(120, 24)
    $scanWindowInput.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
    $null = $filterPanel.Controls.Add($scanWindowInput)

    $auditCheck = New-Object System.Windows.Forms.CheckBox
    $auditCheck.Name = "UsnProcessCorrelation"
    $auditCheck.AccessibleName = "Correlate existing Security audit process evidence"
    $auditCheck.Text = "Correlate process evidence"
    $auditCheck.ForeColor = $Script:Theme.TextSecondary
    $auditCheck.Location = New-Object System.Drawing.Point(822, 17)
    $auditCheck.Size = New-Object System.Drawing.Size(190, 24)
    $null = $filterPanel.Controls.Add($auditCheck)

    $closeOnlyCheck = New-Object System.Windows.Forms.CheckBox
    $closeOnlyCheck.Name = "UsnCloseOnly"
    $closeOnlyCheck.AccessibleName = "Return only final close summary records"
    $closeOnlyCheck.Text = "Close summaries only"
    $closeOnlyCheck.ForeColor = $Script:Theme.TextSecondary
    $closeOnlyCheck.Location = New-Object System.Drawing.Point(822, 43)
    $closeOnlyCheck.Size = New-Object System.Drawing.Size(175, 24)
    $null = $filterPanel.Controls.Add($closeOnlyCheck)

    $queryButton = New-Object System.Windows.Forms.Button
    $queryButton.Text = "Query Journal"
    $queryButton.AccessibleName = "Query the selected NTFS change journal"
    $queryButton.Location = New-Object System.Drawing.Point(1040, 25)
    $queryButton.Size = New-Object System.Drawing.Size(140, 36)
    $queryButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $queryButton.BackColor = $Script:Theme.Accent
    $queryButton.ForeColor = [System.Drawing.Color]::White
    $queryButton.FlatAppearance.BorderSize = 0
    $queryButton.Enabled = $driveCombo.Items.Count -gt 0
    $null = $filterPanel.Controls.Add($queryButton)

    $processNote = New-Object System.Windows.Forms.Label
    $processNote.Text = "Process is not stored in USN records. Optional filtering correlates existing Security event 4663 evidence; audit policy and SACLs are never changed."
    $processNote.ForeColor = $Script:Theme.TextMuted
    $processNote.Location = New-Object System.Drawing.Point(16, 75)
    $processNote.Size = New-Object System.Drawing.Size(1165, 22)
    $null = $filterPanel.Controls.Add($processNote)

    $summaryPanel = New-Object System.Windows.Forms.Panel
    $summaryPanel.Name = "UsnSummaryPanel"
    $summaryPanel.Location = New-Object System.Drawing.Point(20, 194)
    $summaryPanel.Size = New-Object System.Drawing.Size(1200, 62)
    $summaryPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $summaryPanel.BackColor = $Script:Theme.BgCard
    $null = $dialog.Controls.Add($summaryPanel)

    $summaryValues = @{}
    foreach ($definition in @(
            @{Key = 'Size'; Title = 'JOURNAL TARGET SIZE'; X = 18; Width = 250 },
            @{Key = 'Range'; Title = 'USN RANGE'; X = 300; Width = 340 },
            @{Key = 'Records'; Title = 'RECORDS RETURNED'; X = 670; Width = 230 },
            @{Key = 'Process'; Title = 'PROCESS EVIDENCE'; X = 930; Width = 245 })) {
        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = $definition.Title
        $heading.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 7.5)
        $heading.ForeColor = $Script:Theme.TextMuted
        $heading.Location = New-Object System.Drawing.Point($definition.X, 7)
        $heading.Size = New-Object System.Drawing.Size($definition.Width, 17)
        $null = $summaryPanel.Controls.Add($heading)

        $value = New-Object System.Windows.Forms.Label
        $value.Name = "UsnSummary$($definition.Key)"
        $value.Text = '-'
        $value.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10.5)
        $value.ForeColor = $Script:Theme.Info
        $value.Location = New-Object System.Drawing.Point($definition.X, 27)
        $value.Size = New-Object System.Drawing.Size($definition.Width, 27)
        $value.AutoEllipsis = $true
        $null = $summaryPanel.Controls.Add($value)
        $summaryValues[$definition.Key] = $value
    }

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = "UsnJournalGrid"
    $grid.AccessibleName = "USN change journal records"
    $grid.Location = New-Object System.Drawing.Point(20, 266)
    $grid.Size = New-Object System.Drawing.Size(1200, 390)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.BackgroundColor = $Script:Theme.BgInput
    $grid.ForeColor = $Script:Theme.TextPrimary
    $grid.GridColor = $Script:Theme.Border
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $Script:Theme.BgTertiary
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $Script:Theme.TextPrimary
    $grid.DefaultCellStyle.BackColor = $Script:Theme.BgInput
    $grid.DefaultCellStyle.ForeColor = $Script:Theme.TextSecondary
    $grid.DefaultCellStyle.SelectionBackColor = $Script:Theme.AccentDim
    $grid.DefaultCellStyle.SelectionForeColor = $Script:Theme.TextPrimary
    $grid.EnableHeadersVisualStyles = $false
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AutoGenerateColumns = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.RowHeadersVisible = $false
    foreach ($columnDefinition in @(
            @{Name = 'Time'; Header = 'Local time'; Width = 165 },
            @{Name = 'Name'; Header = 'File name'; Width = 210 },
            @{Name = 'Reason'; Header = 'Reason flags'; Width = 270 },
            @{Name = 'Process'; Header = 'Correlated process'; Width = 150 },
            @{Name = 'Pid'; Header = 'PID'; Width = 65 },
            @{Name = 'Usn'; Header = 'USN'; Width = 130 },
            @{Name = 'Source'; Header = 'Source'; Width = 130 },
            @{Name = 'Attributes'; Header = 'Attributes'; Width = 145 })) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $columnDefinition.Name
        $column.HeaderText = $columnDefinition.Header
        $column.Width = $columnDefinition.Width
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
        if ($columnDefinition.Name -eq 'Name') { $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill }
        $null = $grid.Columns.Add($column)
    }
    $null = $dialog.Controls.Add($grid)

    $evidenceLabel = New-Object System.Windows.Forms.Label
    $evidenceLabel.Name = "UsnAuditStatus"
    $evidenceLabel.ForeColor = $Script:Theme.TextMuted
    $evidenceLabel.Location = New-Object System.Drawing.Point(22, 665)
    $evidenceLabel.Size = New-Object System.Drawing.Size(1195, 34)
    $evidenceLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $evidenceLabel.Text = 'Process evidence has not been requested.'
    $null = $dialog.Controls.Add($evidenceLabel)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Name = "UsnBrowserStatus"
    $statusLabel.ForeColor = $Script:Theme.TextMuted
    $statusLabel.Location = New-Object System.Drawing.Point(22, 714)
    $statusLabel.Size = New-Object System.Drawing.Size(880, 28)
    $statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusLabel.Text = if ($driveCombo.Items.Count -gt 0) { 'Ready to read the selected journal.' } else { 'No local NTFS volumes were found.' }
    $null = $dialog.Controls.Add($statusLabel)

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = "Export CSV"
    $exportButton.AccessibleName = "Export USN journal records to CSV"
    $exportButton.Location = New-Object System.Drawing.Point(1018, 708)
    $exportButton.Size = New-Object System.Drawing.Size(95, 32)
    $exportButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $exportButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $exportButton.BackColor = $Script:Theme.BgTertiary
    $exportButton.ForeColor = $Script:Theme.TextSecondary
    $exportButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $exportButton.Enabled = $false
    $null = $dialog.Controls.Add($exportButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $closeButton.Location = New-Object System.Drawing.Point(1122, 708)
    $closeButton.Size = New-Object System.Drawing.Size(98, 32)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.BackColor = $Script:Theme.BgTertiary
    $closeButton.ForeColor = $Script:Theme.TextSecondary
    $closeButton.FlatAppearance.BorderColor = $Script:Theme.Border
    $null = $dialog.Controls.Add($closeButton)
    $dialog.CancelButton = $closeButton

    $formatBytes = {
        param([uint64]$Value)
        if ($Value -ge 1GB) { return ('{0:N2} GB' -f ($Value / 1GB)) }
        if ($Value -ge 1MB) { return ('{0:N2} MB' -f ($Value / 1MB)) }
        if ($Value -ge 1KB) { return ('{0:N2} KB' -f ($Value / 1KB)) }
        return "$Value bytes"
    }

    $loadState = [PSCustomObject]@{Running = $false}
    $loadJournal = {
        if ($loadState.Running -or $driveCombo.SelectedIndex -lt 0) { return }
        $loadState.Running = $true
        $queryButton.Enabled = $false
        $statusLabel.Text = "Reading recent USN records from $($driveCombo.Text)..."
        $statusLabel.ForeColor = $Script:Theme.Info
        try {
            if ($grid.Rows.Count -gt 0) { $grid.Rows.Clear() }
            $reasonMask = [uint32]$reasonCombo.SelectedItem.Mask
            $processFilter = $processText.Text.Trim()
            $report = Get-PathForgeUsnJournal `
                -Drive $driveCombo.Text `
                -MaxRecords ([int]$maxRecordsInput.Value) `
                -ScanMegabytes ([int]$scanWindowInput.Value) `
                -ReasonMask $reasonMask `
                -ReturnOnlyOnClose:$closeOnlyCheck.Checked `
                -IncludeProcessAudit:$auditCheck.Checked `
                -ProcessName $processFilter
            $dialog.Tag = $report
            if (-not $report.Success) {
                foreach ($valueLabel in $summaryValues.Values) { $valueLabel.Text = '-' }
                $evidenceLabel.Text = $report.AuditStatus
                $statusLabel.Text = $report.Error
                $statusLabel.ForeColor = $Script:Theme.Error
                $exportButton.Enabled = $false
                Write-Console "USN journal query failed for $($driveCombo.Text): $($report.Error)" -Type "Error"
                return
            }

            $summaryValues.Size.Text = & $formatBytes $report.MaximumSize
            $summaryValues.Range.Text = ('{0:N0} -> {1:N0}' -f $report.FirstUsn, $report.NextUsn)
            $summaryValues.Records.Text = ('{0:N0} shown / {1:N0} read' -f $report.RecordCount, $report.TotalRecordsRead)
            $summaryValues.Process.Text = if ($report.ProcessAuditUsed) { "$($report.ProcessCoverage) correlated" } else { 'Not requested' }
            foreach ($record in $report.Records) {
                $timeText = if ($record.TimeCreated) { $record.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '-' }
                $processTextValue = if ([string]::IsNullOrWhiteSpace($record.ProcessName)) { '-' } else { $record.ProcessName }
                $processIdValue = if ($null -eq $record.ProcessId) { '-' } else { $record.ProcessId }
                $rowIndex = $grid.Rows.Add(
                    $timeText,
                    $record.FileName,
                    $record.ReasonText,
                    $processTextValue,
                    $processIdValue,
                    ('{0:N0}' -f $record.Usn),
                    $record.SourceText,
                    $record.FileAttributesText)
                $grid.Rows[$rowIndex].Tag = $record
                $grid.Rows[$rowIndex].Cells['Name'].ToolTipText = "File ID: $($record.FileReferenceNumber); parent: $($record.ParentFileReferenceNumber)"
                if ($record.ProcessEvidence) {
                    $grid.Rows[$rowIndex].Cells['Process'].ToolTipText = "$($record.ProcessPath) - $($record.ProcessEvidence), delta $($record.CorrelationDeltaMilliseconds) ms"
                }
            }
            $evidenceLabel.Text = $report.AuditStatus
            $evidenceLabel.ForeColor = if ($report.AuditError) { $Script:Theme.Warning } else { $Script:Theme.TextMuted }
            $limitText = if ($report.WasLimited) { ' The record cap retained the newest matches.' } else { '' }
            $statusLabel.Text = "Read-only query complete: $($report.RecordCount) matching record(s) in a $($report.ScanMegabytes) MB recent window.$limitText"
            $statusLabel.ForeColor = $Script:Theme.Success
            $exportButton.Enabled = $report.RecordCount -gt 0
            Write-Console "USN $($report.Drive): $($report.RecordCount) record(s), reason mask $('0x{0:X8}' -f $report.ReasonMask)" -Type "Info"
            Write-Log "USN journal queried: drive=$($report.Drive) records=$($report.RecordCount) processCoverage=$($report.ProcessCoverage)" -Level "INFO"
        }
        catch {
            $statusLabel.Text = $_.Exception.Message
            $statusLabel.ForeColor = $Script:Theme.Error
            $exportButton.Enabled = $false
            Write-Console "USN journal query failed: $($_.Exception.Message)" -Type "Error"
        }
        finally {
            $queryButton.Enabled = $driveCombo.Items.Count -gt 0
            $loadState.Running = $false
        }
    }.GetNewClosure()

    $processText.Add_TextChanged({ if (-not [string]::IsNullOrWhiteSpace($processText.Text)) { $auditCheck.Checked = $true } }.GetNewClosure())
    $queryButton.Add_Click({ & $loadJournal }.GetNewClosure())
    $exportButton.Add_Click({
        $report = $dialog.Tag
        if (-not $report -or -not $report.Success -or $report.RecordCount -eq 0) { return }
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Title = "Export USN journal records"
        $saveDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
        $saveDialog.FileName = "USN_$($report.Drive.TrimEnd(':'))_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $saveDialog.InitialDirectory = $Script:Config.LogPath
        if ($saveDialog.ShowDialog($dialog) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        try {
            $report.Records | Select-Object TimeCreated, FileName, ReasonHex, ReasonText, SourceText, FileAttributesText, Usn, FileReferenceNumber, ParentFileReferenceNumber, ProcessName, ProcessId, ProcessPath, ProcessEvidence, AuditEventRecordId, CorrelationDeltaMilliseconds |
                Export-Csv -LiteralPath $saveDialog.FileName -NoTypeInformation -Encoding UTF8
            Write-Console "USN journal report exported: $($saveDialog.FileName)" -Type "Success"
            Write-Log "USN journal report exported: $($saveDialog.FileName)" -Level "SUCCESS"
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, "Export Failed", 0, 16) | Out-Null
        }
    }.GetNewClosure())
    $dialog.Add_Shown({ & $loadJournal }.GetNewClosure())

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner -and $owner -ne $dialog) { [void]$dialog.ShowDialog($owner) } else { [void]$dialog.ShowDialog() }
    $dialog.Dispose()
}

# ============================================================================
# UI COMPONENTS
# ============================================================================
function New-InfoPanel {
    param([string]$Key, [int]$X, [int]$Y, [int]$Width = 900)
    
    $info = $Script:Education[$Key]
    if (-not $info) { return $null }
    
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, 0)  # Height will be calculated
    $panel.BackColor = $Script:Theme.BgInfo
    
    # Left accent bar
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point(0, 0)
    $bar.Size = New-Object System.Drawing.Size(4, 500)
    $bar.BackColor = $Script:Theme.Info
    $bar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $null = $panel.Controls.Add($bar)
    
    # Title
    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = "[i] " + $info.Title
    $titleLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $titleLbl.ForeColor = $Script:Theme.Info
    $titleLbl.Location = New-Object System.Drawing.Point(16, 10)
    $titleLbl.AutoSize = $true
    $null = $panel.Controls.Add($titleLbl)
    
    # Content (collapsible)
    $contentLbl = New-Object System.Windows.Forms.Label
    $contentLbl.Text = $info.Content
    $contentLbl.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $contentLbl.ForeColor = $Script:Theme.TextMuted
    $contentLbl.Location = New-Object System.Drawing.Point(16, 35)
    $contentLbl.Size = New-Object System.Drawing.Size(($Width - 32), 0)
    $contentLbl.AutoSize = $true
    $contentLbl.MaximumSize = New-Object System.Drawing.Size(($Width - 32), 0)
    $contentLbl.Visible = $false
    $contentLbl.Tag = "content"
    $null = $panel.Controls.Add($contentLbl)
    
    # Toggle button
    $toggleBtn = New-Object System.Windows.Forms.Label
    $toggleBtn.Text = "▶ Show Details"
    $toggleBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $toggleBtn.ForeColor = $Script:Theme.AccentDim
    $toggleBtn.Location = New-Object System.Drawing.Point(($Width - 110), 12)
    $toggleBtn.Size = New-Object System.Drawing.Size(100, 18)
    $toggleBtn.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $toggleBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $toggleBtn.Tag = "toggle"
    
    $toggleBtn.Add_Click({
        $parent = $this.Parent
        $content = $parent.Controls | Where-Object { $_.Tag -eq "content" }
        $toggle = $parent.Controls | Where-Object { $_.Tag -eq "toggle" }
        
        if ($content.Visible) {
            $content.Visible = $false
            $toggle.Text = "▶ Show Details"
            $parent.Height = 40
        }
        else {
            $content.Visible = $true
            $toggle.Text = "▼ Hide Details"
            $parent.Height = $content.Bottom + 15
        }
        
        # Trigger parent scroll panel recalculation
        $scrollParent = $parent.Parent
        if ($scrollParent -and $scrollParent.AutoScroll) {
            $scrollParent.PerformLayout()
        }
    }.GetNewClosure())
    
    $toggleBtn.Add_MouseEnter({ $this.ForeColor = $Script:Theme.Accent })
    $toggleBtn.Add_MouseLeave({ $this.ForeColor = $Script:Theme.AccentDim })
    
    $null = $panel.Controls.Add($toggleBtn)
    
    $panel.Height = 40  # Collapsed height
    
    return $panel
}

function New-ToolCard {
    param([string]$Title, [string]$Desc, [string]$BtnText, [scriptblock]$OnClick, [int]$X, [int]$Y, [int]$W = 280, [int]$H = 120)
    
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($W, $H)
    $card.BackColor = $Script:Theme.BgCard
    
    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text = $Title
    $titleLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10.5)
    $titleLbl.ForeColor = $Script:Theme.TextPrimary
    $titleLbl.Location = New-Object System.Drawing.Point(14, 12)
    $titleLbl.Size = New-Object System.Drawing.Size(($W - 28), 22)
    $null = $card.Controls.Add($titleLbl)
    
    $descLbl = New-Object System.Windows.Forms.Label
    $descLbl.Text = $Desc
    $descLbl.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $descLbl.ForeColor = $Script:Theme.TextMuted
    $descLbl.Location = New-Object System.Drawing.Point(14, 36)
    $descLbl.Size = New-Object System.Drawing.Size(($W - 28), 38)
    $null = $card.Controls.Add($descLbl)
    
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $BtnText
    $btn.AccessibleName = "$Title - $BtnText"
    $btn.AccessibleRole = [System.Windows.Forms.AccessibleRole]::PushButton
    $btn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $btn.ForeColor = $Script:Theme.TextPrimary
    $btn.BackColor = $Script:Theme.Accent
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Location = New-Object System.Drawing.Point(14, ($H - 42))
    $btn.Size = New-Object System.Drawing.Size(($W - 28), 30)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_MouseEnter({ $this.BackColor = $Script:Theme.AccentHover })
    $btn.Add_MouseLeave({ $this.BackColor = $Script:Theme.Accent })
    if ($OnClick) { $btn.Add_Click($OnClick) }
    $null = $card.Controls.Add($btn)

    return $card
}

function Switch-Tab {
    param([string]$TabName)
    $Script:CurrentTab = $TabName
    $Script:ContentPanel.Controls.Clear()
    if ($Script:Pages.ContainsKey($TabName)) {
        $null = $Script:ContentPanel.Controls.Add($Script:Pages[$TabName])
    }
    foreach ($key in $Script:TabButtons.Keys) {
        $tabBtn = $Script:TabButtons[$key]
        $isActive = ($key -eq $TabName)
        $tabBtn.BackColor = if ($isActive) { $Script:Theme.BgPrimary } else { $Script:Theme.TabInactive }
        foreach ($ctrl in $tabBtn.Controls) {
            if ($ctrl -is [System.Windows.Forms.Label]) {
                $ctrl.ForeColor = if ($isActive) { $Script:Theme.TextPrimary } else { $Script:Theme.TextMuted }
            }
            if ($ctrl -is [System.Windows.Forms.Panel] -and $ctrl.Height -eq 3) {
                $ctrl.BackColor = if ($isActive) { $Script:Theme.Accent } else { [System.Drawing.Color]::Transparent }
            }
        }
    }
}

function New-TabButton {
    param([string]$Text, [string]$Key)
    $tab = New-Object System.Windows.Forms.Panel
    $tab.Size = New-Object System.Drawing.Size(130, 35)
    $tab.BackColor = $Script:Theme.TabInactive
    $tab.Cursor = [System.Windows.Forms.Cursors]::Hand
    $tab.Margin = New-Object System.Windows.Forms.Padding(0)
    
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $lbl.ForeColor = $Script:Theme.TextMuted
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lbl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $null = $tab.Controls.Add($lbl)
    
    $indicator = New-Object System.Windows.Forms.Panel
    $indicator.Size = New-Object System.Drawing.Size(130, 3)
    $indicator.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $indicator.BackColor = [System.Drawing.Color]::Transparent
    $null = $tab.Controls.Add($indicator)
    
    $clickHandler = { Switch-Tab -TabName $Key }.GetNewClosure()
    $tab.Add_Click($clickHandler)
    $lbl.Add_Click($clickHandler)
    
    $tab.Add_MouseEnter({ if ($Script:CurrentTab -ne $Key) { $this.BackColor = $Script:Theme.TabHover } }.GetNewClosure())
    $tab.Add_MouseLeave({ if ($Script:CurrentTab -ne $Key) { $this.BackColor = $Script:Theme.TabInactive } }.GetNewClosure())
    
    $Script:TabButtons[$Key] = $tab
    return $tab
}

# ============================================================================
# PAGE BUILDERS
# ============================================================================
function Build-FileOpsPage {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $Script:Theme.BgPrimary
    $page.AutoScroll = $true
    $page.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    
    $y = 20
    
    # Title
    $title = New-Object System.Windows.Forms.Label
    $title.Text = "File Operations"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(30, $y)
    $title.AutoSize = $true
    $null = $page.Controls.Add($title)
    $y += 35
    
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Delete stubborn files, manage permissions, and handle locked items"
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $subtitle.ForeColor = $Script:Theme.TextMuted
    $subtitle.Location = New-Object System.Drawing.Point(30, $y)
    $subtitle.AutoSize = $true
    $null = $page.Controls.Add($subtitle)
    $y += 40
    
    # Path input section
    $pathLbl = New-Object System.Windows.Forms.Label
    $pathLbl.Text = "TARGET PATH"
    $pathLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $pathLbl.ForeColor = $Script:Theme.TextMuted
    $pathLbl.Location = New-Object System.Drawing.Point(30, $y)
    $pathLbl.AutoSize = $true
    $null = $page.Controls.Add($pathLbl)
    $y += 20
    
    $Script:PathTextBox = New-Object System.Windows.Forms.TextBox
    $Script:PathTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $Script:PathTextBox.ForeColor = $Script:Theme.TextPrimary
    $Script:PathTextBox.BackColor = $Script:Theme.BgInput
    $Script:PathTextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Script:PathTextBox.Location = New-Object System.Drawing.Point(30, $y)
    $Script:PathTextBox.Size = New-Object System.Drawing.Size(540, 26)
    $Script:PathTextBox.AccessibleName = "Target file or folder path"
    $Script:PathTextBox.TabIndex = 0
    $Script:PathTextBox.AllowDrop = $true
    $Script:PathTextBox.Add_DragEnter({
        param($control, $dragEvent)
        $null = $control
        if ($dragEvent.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $dragEvent.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
        else {
            $dragEvent.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })
    $Script:PathTextBox.Add_DragDrop({
        param($control, $dragEvent)
        $null = $control
        Receive-PathDrop -DataObject $dragEvent.Data -TargetTextBox $Script:PathTextBox | Out-Null
    })
    $null = $page.Controls.Add($Script:PathTextBox)
    
    $browseFileBtn = New-Object System.Windows.Forms.Button
    $browseFileBtn.Text = "File..."
    $browseFileBtn.AccessibleName = "Browse for file"
    $browseFileBtn.TabIndex = 1
    $browseFileBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $browseFileBtn.ForeColor = $Script:Theme.TextSecondary
    $browseFileBtn.BackColor = $Script:Theme.BgTertiary
    $browseFileBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $browseFileBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $browseFileBtn.Location = New-Object System.Drawing.Point(580, ($y - 1))
    $browseFileBtn.Size = New-Object System.Drawing.Size(65, 28)
    $browseFileBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Script:PathTextBox.Text = $dlg.FileName }
    })
    $null = $page.Controls.Add($browseFileBtn)
    
    $browseFolderBtn = New-Object System.Windows.Forms.Button
    $browseFolderBtn.Text = "Folder..."
    $browseFolderBtn.AccessibleName = "Browse for folder"
    $browseFolderBtn.TabIndex = 2
    $browseFolderBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $browseFolderBtn.ForeColor = $Script:Theme.TextSecondary
    $browseFolderBtn.BackColor = $Script:Theme.BgTertiary
    $browseFolderBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $browseFolderBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $browseFolderBtn.Location = New-Object System.Drawing.Point(652, ($y - 1))
    $browseFolderBtn.Size = New-Object System.Drawing.Size(65, 28)
    $browseFolderBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Script:PathTextBox.Text = $dlg.SelectedPath }
    })
    $null = $page.Controls.Add($browseFolderBtn)
    $y += 38
    
    # Quick action buttons row
    $quickLbl = New-Object System.Windows.Forms.Label
    $quickLbl.Text = "QUICK ACTIONS"
    $quickLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $quickLbl.ForeColor = $Script:Theme.TextMuted
    $quickLbl.Location = New-Object System.Drawing.Point(30, $y)
    $quickLbl.AutoSize = $true
    $null = $page.Controls.Add($quickLbl)
    $y += 22
    
    # Take Ownership Button (DEDICATED - User Request)
    $takeOwnBtn = New-Object System.Windows.Forms.Button
    $takeOwnBtn.Text = "Take Ownership"
    $takeOwnBtn.AccessibleName = "Take ownership of target path"
    $takeOwnBtn.TabIndex = 3
    $takeOwnBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $takeOwnBtn.ForeColor = $Script:Theme.TextPrimary
    $takeOwnBtn.BackColor = $Script:Theme.AccentDim
    $takeOwnBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $takeOwnBtn.FlatAppearance.BorderSize = 0
    $takeOwnBtn.Location = New-Object System.Drawing.Point(30, $y)
    $takeOwnBtn.Size = New-Object System.Drawing.Size(150, 32)
    $takeOwnBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $takeOwnBtn.Add_MouseEnter({ $this.BackColor = $Script:Theme.Accent })
    $takeOwnBtn.Add_MouseLeave({ $this.BackColor = $Script:Theme.AccentDim })
    $takeOwnBtn.Add_Click({
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Invoke-TakeOwnership -Path $Script:PathTextBox.Text
    })
    $null = $page.Controls.Add($takeOwnBtn)
    
    # View ACL Button
    $viewAclBtn = New-Object System.Windows.Forms.Button
    $viewAclBtn.Text = "View Permissions"
    $viewAclBtn.AccessibleName = "View permissions on target path"
    $viewAclBtn.TabIndex = 4
    $viewAclBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $viewAclBtn.ForeColor = $Script:Theme.TextSecondary
    $viewAclBtn.BackColor = $Script:Theme.BgTertiary
    $viewAclBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $viewAclBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $viewAclBtn.Location = New-Object System.Drawing.Point(190, $y)
    $viewAclBtn.Size = New-Object System.Drawing.Size(150, 32)
    $viewAclBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $viewAclBtn.Add_Click({
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Get-ACLReport -Path $Script:PathTextBox.Text
    })
    $null = $page.Controls.Add($viewAclBtn)
    
    # Unblock Button
    $unblockBtn = New-Object System.Windows.Forms.Button
    $unblockBtn.Text = "Unblock File"
    $unblockBtn.AccessibleName = "Unblock downloaded file"
    $unblockBtn.TabIndex = 5
    $unblockBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $unblockBtn.ForeColor = $Script:Theme.TextSecondary
    $unblockBtn.BackColor = $Script:Theme.BgTertiary
    $unblockBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $unblockBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $unblockBtn.Location = New-Object System.Drawing.Point(350, $y)
    $unblockBtn.Size = New-Object System.Drawing.Size(120, 32)
    $unblockBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $unblockBtn.Add_Click({
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Invoke-UnblockFile -Path $Script:PathTextBox.Text
    })
    $null = $page.Controls.Add($unblockBtn)
    $y += 45
    
    $Script:TakeOwnCheck = New-Object System.Windows.Forms.CheckBox
    $Script:TakeOwnCheck.Text = "Include 'Take Ownership' step when using Force Delete"
    $Script:TakeOwnCheck.AccessibleName = "Include take ownership step with force delete"
    $Script:TakeOwnCheck.TabIndex = 6
    $Script:TakeOwnCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Script:TakeOwnCheck.ForeColor = $Script:Theme.TextSecondary
    $Script:TakeOwnCheck.Location = New-Object System.Drawing.Point(30, $y)
    $Script:TakeOwnCheck.Size = New-Object System.Drawing.Size(500, 22)
    $Script:TakeOwnCheck.Checked = $false
    $null = $page.Controls.Add($Script:TakeOwnCheck)
    $y += 28

    $Script:RecycleBinCheck = New-Object System.Windows.Forms.CheckBox
    $Script:RecycleBinCheck.Text = "Try Recycle Bin first (recoverable delete before permanent)"
    $Script:RecycleBinCheck.AccessibleName = "Try Recycle Bin before permanent delete"
    $Script:RecycleBinCheck.TabIndex = 7
    $Script:RecycleBinCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Script:RecycleBinCheck.ForeColor = $Script:Theme.TextSecondary
    $Script:RecycleBinCheck.Location = New-Object System.Drawing.Point(30, $y)
    $Script:RecycleBinCheck.Size = New-Object System.Drawing.Size(500, 22)
    $Script:RecycleBinCheck.Checked = $true
    $null = $page.Controls.Add($Script:RecycleBinCheck)
    $y += 28

    $Script:DryRunCheck = New-Object System.Windows.Forms.CheckBox
    $Script:DryRunCheck.Text = "Dry-run only (preview delete/schedule APIs; make no changes)"
    $Script:DryRunCheck.AccessibleName = "Preview deletion without making changes"
    $Script:DryRunCheck.TabIndex = 8
    $Script:DryRunCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Script:DryRunCheck.ForeColor = $Script:Theme.Warning
    $Script:DryRunCheck.Location = New-Object System.Drawing.Point(30, $y)
    $Script:DryRunCheck.Size = New-Object System.Drawing.Size(500, 22)
    $Script:DryRunCheck.Checked = $false
    $null = $page.Controls.Add($Script:DryRunCheck)
    $y += 35

    # ========== ACL INFO PANEL ==========
    $aclInfo = New-InfoPanel -Key "ACL" -X 30 -Y $y -Width 900
    if ($aclInfo) {
        $null = $page.Controls.Add($aclInfo)
        $y += $aclInfo.Height + 15
    }
    
    # Section: Deletion Tools
    $secLbl1 = New-Object System.Windows.Forms.Label
    $secLbl1.Text = "DELETION TOOLS"
    $secLbl1.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl1.ForeColor = $Script:Theme.TextMuted
    $secLbl1.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl1.AutoSize = $true
    $null = $page.Controls.Add($secLbl1)
    $y += 23
    
    $card1 = New-ToolCard -Title "Force Delete" -Desc "Escalates through 6 methods: PowerShell, .NET, LongPath, ShortName, Robocopy, WMI" -BtnText "Delete Now" -X 30 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Invoke-ForceDelete -Path $Script:PathTextBox.Text -TakeOwnership:$Script:TakeOwnCheck.Checked -DryRun:$Script:DryRunCheck.Checked
    }
    $null = $page.Controls.Add($card1)
    
    $card2 = New-ToolCard -Title "Boot-Time Delete" -Desc "MoveFileEx API - deletes on next reboot before Windows services start" -BtnText "Schedule" -X 320 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Invoke-BootTimeDelete -Path $Script:PathTextBox.Text -DryRun:$Script:DryRunCheck.Checked
    }
    $null = $page.Controls.Add($card2)
    
    $card3 = New-ToolCard -Title "Pending Queue" -Desc "Review, select, and cancel PendingFileRenameOperations entries safely" -BtnText "Open Queue" -X 610 -Y $y -OnClick { Show-PendingDeletionQueue }
    $null = $page.Controls.Add($card3)
    $y += 130

    $card4 = New-ToolCard -Title "Batch Delete" -Desc "Load CSV or text rows and select Auto or a specific API per path" -BtnText "Load Batch..." -X 30 -Y $y -OnClick { Show-DeletionBatchDialog }
    $null = $page.Controls.Add($card4)

    $card4b = New-ToolCard -Title "Link Inspector" -Desc "Identify junctions, symlinks, hard links, tags, targets, and sibling names" -BtnText "Inspect Link" -X 320 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return
        }
        Show-LinkInspector -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card4b)

    $card4c = New-ToolCard -Title "Reparse Explorer" -Desc "Scan a tree for reparse types, tags, and targets without following links" -BtnText "Scan Links" -X 610 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return
        }
        Show-ReparsePointExplorer -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card4c)
    $y += 130

    $quarantineCard = New-ToolCard -Title "Quarantine Zone" -Desc "Move a path into recoverable same-volume storage; restore it or auto-purge after retention" -BtnText "Open Zone" -X 30 -Y $y -OnClick {
        Show-QuarantineManager -InitialPath $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($quarantineCard)
    $y += 130
    
    # ========== BOOT DELETE INFO PANEL ==========
    $bootInfo = New-InfoPanel -Key "BootDelete" -X 30 -Y $y -Width 900
    if ($bootInfo) {
        $null = $page.Controls.Add($bootInfo)
        $y += $bootInfo.Height + 15
    }
    
    # Long Path Info Panel
    $longPathInfo = New-InfoPanel -Key "LongPath" -X 30 -Y $y -Width 900
    if ($longPathInfo) {
        $null = $page.Controls.Add($longPathInfo)
        $y += $longPathInfo.Height + 15
    }
    
    # Section: Permission Tools
    $secLbl2 = New-Object System.Windows.Forms.Label
    $secLbl2.Text = "PERMISSION TOOLS"
    $secLbl2.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl2.ForeColor = $Script:Theme.TextMuted
    $secLbl2.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl2.AutoSize = $true
    $null = $page.Controls.Add($secLbl2)
    $y += 23
    
    $card4 = New-ToolCard -Title "Reset Permissions" -Desc "icacls /reset - restores inherited permissions from parent folder" -BtnText "Reset to Inherited" -X 30 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Reset-ItemPermissions -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card4)
    
    $card5 = New-ToolCard -Title "Remove Orphan SIDs" -Desc "Cleans up S-1-5-21-* entries from deleted user accounts" -BtnText "Scan & Remove" -X 320 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        $recurse = [System.Windows.Forms.MessageBox]::Show("Include subfolders? (can be slow for large trees)", "Recursive Scan?", 4, 32) -eq 6
        Remove-OrphanedSIDs -Path $Script:PathTextBox.Text -Recurse:$recurse
    }
    $null = $page.Controls.Add($card5)
    
    $card6 = New-ToolCard -Title "Backup ACLs" -Desc "icacls /save - exports all permissions to file for recovery" -BtnText "Backup" -X 610 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Backup-ACL -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card6)
    $y += 130
    
    # ========== OWNERSHIP INFO PANEL ==========
    $ownInfo = New-InfoPanel -Key "Ownership" -X 30 -Y $y -Width 900
    if ($ownInfo) {
        $null = $page.Controls.Add($ownInfo)
        $y += $ownInfo.Height + 15
    }
    
    # Orphaned SID Info Panel
    $sidInfo = New-InfoPanel -Key "OrphanedSID" -X 30 -Y $y -Width 900
    if ($sidInfo) {
        $null = $page.Controls.Add($sidInfo)
        $y += $sidInfo.Height + 15
    }
    
    # Section: ACL Backup/Restore
    $secLbl3 = New-Object System.Windows.Forms.Label
    $secLbl3.Text = "ACL BACKUP / RESTORE"
    $secLbl3.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl3.ForeColor = $Script:Theme.TextMuted
    $secLbl3.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl3.AutoSize = $true
    $null = $page.Controls.Add($secLbl3)
    $y += 23
    
    $card7 = New-ToolCard -Title "Restore ACLs" -Desc "icacls /restore - restores permissions from backup file" -BtnText "Restore..." -X 30 -Y $y -OnClick {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "ACL Backup Files (*.txt)|*.txt|All Files (*.*)|*.*"
        $dlg.InitialDirectory = $Script:Config.LogPath
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Enter target path first.", "No Path", 0, 48) | Out-Null
                return
            }
            Restore-ACL -Path $Script:PathTextBox.Text -BackupFile $dlg.FileName
        }
    }
    $null = $page.Controls.Add($card7)

    $card7b = New-ToolCard -Title "Export ACL Report" -Desc "Export permissions to CSV for auditing (recursive)" -BtnText "Export CSV" -X 320 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return
        }
        Export-ACLReport -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card7b)
    $y += 130

    # Section: Alternate Data Streams
    $secLbl4 = New-Object System.Windows.Forms.Label
    $secLbl4.Text = "ALTERNATE DATA STREAMS (ADS)"
    $secLbl4.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl4.ForeColor = $Script:Theme.TextMuted
    $secLbl4.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl4.AutoSize = $true
    $null = $page.Controls.Add($secLbl4)
    $y += 23
    
    $card8 = New-ToolCard -Title "Scan for ADS" -Desc "Find hidden streams attached to files (malware hiding spot)" -BtnText "Scan" -X 30 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Invoke-ADSScanner -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card8)
    
    $card9 = New-ToolCard -Title "Remove All ADS" -Desc "Delete ALL alternate data streams from a file" -BtnText "Remove All" -X 320 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        if ([System.Windows.Forms.MessageBox]::Show("Remove ALL alternate data streams from this file?`n`nThis may remove metadata streams.", "Confirm", 4, 48) -eq 6) {
            Remove-AllADS -Path $Script:PathTextBox.Text
        }
    }
    $null = $page.Controls.Add($card9)
    
    $card10 = New-ToolCard -Title "Unblock All Files" -Desc "Remove Zone.Identifier from all files in folder (recursive)" -BtnText "Unblock Folder" -X 610 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        if ([System.Windows.Forms.MessageBox]::Show("Unblock all files in this folder and subfolders?", "Confirm", 4, 32) -eq 6) {
            Invoke-UnblockRecursive -Path $Script:PathTextBox.Text
        }
    }
    $null = $page.Controls.Add($card10)
    $y += 130
    
    # ========== ADS INFO PANEL ==========
    $adsInfo = New-InfoPanel -Key "ADS" -X 30 -Y $y -Width 900
    if ($adsInfo) {
        $null = $page.Controls.Add($adsInfo)
        $y += $adsInfo.Height + 15
    }
    
    # Reparse Points Info
    $repInfo = New-InfoPanel -Key "ReparsePoints" -X 30 -Y $y -Width 900
    if ($repInfo) {
        $null = $page.Controls.Add($repInfo)
        $y += $repInfo.Height + 30
    }
    
    return $page
}

function Build-RepairPage {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $Script:Theme.BgPrimary
    $page.AutoScroll = $true
    $page.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    
    $y = 20
    
    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Filesystem Repair"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(30, $y)
    $title.AutoSize = $true
    $null = $page.Controls.Add($title)
    $y += 35
    
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Repair Windows filesystem, system files, and component store"
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $subtitle.ForeColor = $Script:Theme.TextMuted
    $subtitle.Location = New-Object System.Drawing.Point(30, $y)
    $subtitle.AutoSize = $true
    $null = $page.Controls.Add($subtitle)
    $y += 40
    
    # Warning panel about repair order
    $warnPanel = New-Object System.Windows.Forms.Panel
    $warnPanel.Location = New-Object System.Drawing.Point(30, $y)
    $warnPanel.Size = New-Object System.Drawing.Size(900, 55)
    $warnPanel.BackColor = [System.Drawing.Color]::FromArgb(50, 40, 25)
    $null = $page.Controls.Add($warnPanel)
    
    $warnBar = New-Object System.Windows.Forms.Panel
    $warnBar.Location = New-Object System.Drawing.Point(0, 0)
    $warnBar.Size = New-Object System.Drawing.Size(4, 55)
    $warnBar.BackColor = $Script:Theme.Warning
    $null = $warnPanel.Controls.Add($warnBar)
    
    $warnTitle = New-Object System.Windows.Forms.Label
    $warnTitle.Text = "[!] Critical Repair Order: DISM -> SFC -> CHKDSK"
    $warnTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
    $warnTitle.ForeColor = $Script:Theme.Warning
    $warnTitle.Location = New-Object System.Drawing.Point(18, 8)
    $warnTitle.AutoSize = $true
    $null = $warnPanel.Controls.Add($warnTitle)
    
    $warnText = New-Object System.Windows.Forms.Label
    $warnText.Text = "SFC needs the component store to work. If it's corrupt, SFC fails. Always run DISM RestoreHealth FIRST!"
    $warnText.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $warnText.ForeColor = $Script:Theme.TextMuted
    $warnText.Location = New-Object System.Drawing.Point(18, 28)
    $warnText.AutoSize = $true
    $null = $warnPanel.Controls.Add($warnText)
    $y += 70
    
    # Drive selector
    $drvLbl = New-Object System.Windows.Forms.Label
    $drvLbl.Text = "SELECT DRIVE"
    $drvLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $drvLbl.ForeColor = $Script:Theme.TextMuted
    $drvLbl.Location = New-Object System.Drawing.Point(30, $y)
    $drvLbl.AutoSize = $true
    $null = $page.Controls.Add($drvLbl)
    $y += 20
    
    $Script:DriveCombo = New-Object System.Windows.Forms.ComboBox
    $Script:DriveCombo.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $Script:DriveCombo.ForeColor = $Script:Theme.TextPrimary
    $Script:DriveCombo.BackColor = $Script:Theme.BgInput
    $Script:DriveCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Script:DriveCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $Script:DriveCombo.Location = New-Object System.Drawing.Point(30, $y)
    $Script:DriveCombo.Size = New-Object System.Drawing.Size(350, 26)
    $Script:DriveCombo.AccessibleName = "Select drive for repair operations"
    $Script:DriveCombo.TabIndex = 0
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
        $null = $Script:DriveCombo.Items.Add("$($_.DriveLetter): $($_.FileSystemLabel) ($($_.FileSystem), $([math]::Round($_.Size/1GB))GB)")
    }
    if ($Script:DriveCombo.Items.Count -gt 0) { $Script:DriveCombo.SelectedIndex = 0 }
    $null = $page.Controls.Add($Script:DriveCombo)
    $y += 45
    
    # CHKDSK section
    $secLbl1 = New-Object System.Windows.Forms.Label
    $secLbl1.Text = "CHKDSK OPERATIONS"
    $secLbl1.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl1.ForeColor = $Script:Theme.TextMuted
    $secLbl1.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl1.AutoSize = $true
    $null = $page.Controls.Add($secLbl1)
    $y += 23
    
    $card1 = New-ToolCard -Title "Quick Scan" -Desc "/scan - Online scan, no volume lock (Win8+)" -BtnText "CHKDSK /scan" -X 30 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        Invoke-ChkdskScan -Drive $drive
    }
    $null = $page.Controls.Add($card1)
    
    $card2 = New-ToolCard -Title "Fix Errors" -Desc "/F - Locks volume and fixes filesystem errors" -BtnText "CHKDSK /F" -X 320 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        Invoke-ChkdskFix -Drive $drive
    }
    $null = $page.Controls.Add($card2)
    
    $card3 = New-ToolCard -Title "Spot Fix" -Desc "/spotfix - Fast targeted repair (issues from /scan)" -BtnText "CHKDSK /spotfix" -X 610 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        Invoke-ChkdskSpotfix -Drive $drive
    }
    $null = $page.Controls.Add($card3)
    $y += 130
    
    $card4 = New-ToolCard -Title "Full Repair" -Desc "/R - Deep scan + bad sector recovery (HOURS)" -BtnText "CHKDSK /R" -X 30 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        if ([System.Windows.Forms.MessageBox]::Show("Full scan may take SEVERAL HOURS on large drives.`n`nContinue?", "Confirm Full Scan", 4, 48) -eq 6) {
            Invoke-ChkdskFull -Drive $drive
        }
    }
    $null = $page.Controls.Add($card4)
    
    $card5 = New-ToolCard -Title "Quick Health Check" -Desc "Read the volume's recorded corruption count instantly" -BtnText "Check Volume" -X 320 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        Get-VolumeCorruptionHealth -Drive $drive | Out-Null
    }
    $null = $page.Controls.Add($card5)
    
    $card6 = New-ToolCard -Title "Dirty Bit Status" -Desc "Check which volumes need CHKDSK on boot" -BtnText "Check Status" -X 610 -Y $y -OnClick { Get-DirtyBitStatus }
    $null = $page.Controls.Add($card6)
    $y += 130

    $card7 = New-ToolCard -Title "Force CHKDSK" -Desc "Set dirty bit to force CHKDSK on next reboot" -BtnText "Set Dirty Bit" -X 30 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        if ([System.Windows.Forms.MessageBox]::Show("Force CHKDSK on next boot for $drive`?`n`nThe system will run CHKDSK automatically when you restart.", "Confirm", 4, 48) -eq 6) {
            Set-DirtyBit -Drive $drive
        }
    }
    $null = $page.Controls.Add($card7)
    $y += 130
    
    # CHKDSK Info Panel
    $chkInfo = New-InfoPanel -Key "CHKDSK" -X 30 -Y $y -Width 900
    if ($chkInfo) {
        $null = $page.Controls.Add($chkInfo)
        $y += $chkInfo.Height + 15
    }
    
    # Dirty Bit Info Panel
    $dirtyInfo = New-InfoPanel -Key "DirtyBit" -X 30 -Y $y -Width 900
    if ($dirtyInfo) {
        $null = $page.Controls.Add($dirtyInfo)
        $y += $dirtyInfo.Height + 15
    }
    
    # System repair section
    $secLbl2 = New-Object System.Windows.Forms.Label
    $secLbl2.Text = "SYSTEM FILE REPAIR"
    $secLbl2.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl2.ForeColor = $Script:Theme.TextMuted
    $secLbl2.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl2.AutoSize = $true
    $null = $page.Controls.Add($secLbl2)
    $y += 23
    
    $card7 = New-ToolCard -Title "DISM Restore" -Desc "Repairs component store (WinSxS) - RUN FIRST!" -BtnText "DISM /RestoreHealth" -X 30 -Y $y -OnClick { Invoke-DISMRestore }
    $null = $page.Controls.Add($card7)
    
    $card8 = New-ToolCard -Title "SFC Scan" -Desc "Repairs protected system files (run AFTER DISM)" -BtnText "SFC /scannow" -X 320 -Y $y -OnClick { Invoke-SFCScan }
    $null = $page.Controls.Add($card8)
    
    $card9 = New-ToolCard -Title "Full System Repair" -Desc "DISM + SFC + CHKDSK in correct order (30-60 min)" -BtnText "Run All" -X 610 -Y $y -OnClick { Invoke-FullSystemRepair }
    $null = $page.Controls.Add($card9)
    $y += 130
    
    # SFC/DISM Info Panel
    $sfcInfo = New-InfoPanel -Key "SFC_DISM" -X 30 -Y $y -Width 900
    if ($sfcInfo) {
        $null = $page.Controls.Add($sfcInfo)
        $y += $sfcInfo.Height + 15
    }
    
    # NTFS Self-Healing
    $secLbl3 = New-Object System.Windows.Forms.Label
    $secLbl3.Text = "NTFS SELF-HEALING"
    $secLbl3.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl3.ForeColor = $Script:Theme.TextMuted
    $secLbl3.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl3.AutoSize = $true
    $null = $page.Controls.Add($secLbl3)
    $y += 23
    
    $card10 = New-ToolCard -Title "Self-Healing Status" -Desc "fsutil repair query - check NTFS auto-repair state" -BtnText "Check Status" -X 30 -Y $y -OnClick { Get-NTFSSelfHealingStatus }
    $null = $page.Controls.Add($card10)
    
    $card11 = New-ToolCard -Title "Enable Self-Healing" -Desc "fsutil repair set 1 - enable background NTFS repair" -BtnText "Enable" -X 320 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        Set-NTFSSelfHealing -Drive $drive -Enable $true
    }
    $null = $page.Controls.Add($card11)
    
    $card12 = New-ToolCard -Title "Disable Self-Healing" -Desc "fsutil repair set 0 - disable (not recommended)" -BtnText "Disable" -X 610 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        if ([System.Windows.Forms.MessageBox]::Show("Disabling self-healing is not recommended.`n`nContinue anyway?", "Warning", 4, 48) -eq 6) {
            Set-NTFSSelfHealing -Drive $drive -Enable $false
        }
    }
    $null = $page.Controls.Add($card12)
    $y += 130
    
    # NTFS Self-Healing Info Panel
    $healInfo = New-InfoPanel -Key "NTFSSelfHealing" -X 30 -Y $y -Width 900
    if ($healInfo) {
        $null = $page.Controls.Add($healInfo)
        $y += $healInfo.Height + 15
    }

    # Windows Update Reset
    $secLbl4 = New-Object System.Windows.Forms.Label
    $secLbl4.Text = "WINDOWS UPDATE"
    $secLbl4.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl4.ForeColor = $Script:Theme.TextMuted
    $secLbl4.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl4.AutoSize = $true
    $null = $page.Controls.Add($secLbl4)
    $y += 23

    $card13 = New-ToolCard -Title "Reset Windows Update" -Desc "Stop services, clear caches, re-register DLLs, restart" -BtnText "Reset Components" -X 30 -Y $y -OnClick {
        if ([System.Windows.Forms.MessageBox]::Show(
            "Reset Windows Update components?`n`nThis will:`n- Stop BITS, wuauserv, cryptsvc`n- Rename SoftwareDistribution and catroot2`n- Re-register 36 DLLs`n- Reset Winsock`n- Restart services`n`nA reboot is recommended afterward.",
            "Confirm Reset", 4, 48) -eq 6) {
            Reset-WindowsUpdate
        }
    }
    $null = $page.Controls.Add($card13)
    $y += 130

    return $page
}

function Build-DiagnosticsPage {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $Script:Theme.BgPrimary
    $page.AutoScroll = $true
    $page.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    
    $y = 20
    
    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Drive Diagnostics"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(30, $y)
    $title.AutoSize = $true
    $null = $page.Controls.Add($title)
    $y += 35
    
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Monitor drive health, SMART status, and system events"
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $subtitle.ForeColor = $Script:Theme.TextMuted
    $subtitle.Location = New-Object System.Drawing.Point(30, $y)
    $subtitle.AutoSize = $true
    $null = $page.Controls.Add($subtitle)
    $y += 45
    
    # Warning panel about SMART
    $warnPanel = New-Object System.Windows.Forms.Panel
    $warnPanel.Location = New-Object System.Drawing.Point(30, $y)
    $warnPanel.Size = New-Object System.Drawing.Size(900, 70)
    $warnPanel.BackColor = [System.Drawing.Color]::FromArgb(50, 30, 30)
    $null = $page.Controls.Add($warnPanel)
    
    $warnBar = New-Object System.Windows.Forms.Panel
    $warnBar.Location = New-Object System.Drawing.Point(0, 0)
    $warnBar.Size = New-Object System.Drawing.Size(4, 70)
    $warnBar.BackColor = $Script:Theme.Error
    $null = $warnPanel.Controls.Add($warnBar)
    
    $warnTitle = New-Object System.Windows.Forms.Label
    $warnTitle.Text = "[!!] SMART Warning Signs - BACKUP IMMEDIATELY if you see:"
    $warnTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
    $warnTitle.ForeColor = $Script:Theme.Error
    $warnTitle.Location = New-Object System.Drawing.Point(18, 8)
    $warnTitle.AutoSize = $true
    $null = $warnPanel.Controls.Add($warnTitle)
    
    $warnText = New-Object System.Windows.Forms.Label
    $warnText.Text = "• PredictFailure = TRUE    • ID 05 (Reallocated Sectors) > 0    • ID C5 (Pending Sectors) > 0`n• ID C6 (Uncorrectable Sectors) > 0  →  Drives with C6 > 0 are 39x MORE LIKELY to fail within 60 days!"
    $warnText.Font = New-Object System.Drawing.Font("Consolas", 8.5)
    $warnText.ForeColor = $Script:Theme.TextMuted
    $warnText.Location = New-Object System.Drawing.Point(18, 30)
    $warnText.Size = New-Object System.Drawing.Size(870, 35)
    $null = $warnPanel.Controls.Add($warnText)
    $y += 85
    
    # Diagnostic tools section
    $secLbl = New-Object System.Windows.Forms.Label
    $secLbl.Text = "DIAGNOSTIC TOOLS"
    $secLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $secLbl.ForeColor = $Script:Theme.TextMuted
    $secLbl.Location = New-Object System.Drawing.Point(30, $y)
    $secLbl.AutoSize = $true
    $null = $page.Controls.Add($secLbl)
    $y += 23
    
    $card1 = New-ToolCard -Title "Drive Health Report" -Desc "Comprehensive: physical disks, volumes, SMART, reliability" -BtnText "Generate Report" -X 30 -Y $y -OnClick { Get-DriveHealth }
    $null = $page.Controls.Add($card1)
    
    $card2 = New-ToolCard -Title "SMART Check" -Desc "FailurePredictStatus - early warning of drive failure" -BtnText "Check SMART" -X 320 -Y $y -OnClick { Get-SmartStatus }
    $null = $page.Controls.Add($card2)
    
    $card3 = New-ToolCard -Title "Event Log Analysis" -Desc "Critical events: 55, 50, 98, 129, 153, 157 (7 days)" -BtnText "Analyze Logs" -X 610 -Y $y -OnClick { Get-FilesystemEvents }
    $null = $page.Controls.Add($card3)
    $y += 130
    
    $card4 = New-ToolCard -Title "TRIM Status" -Desc "Check if TRIM is enabled for SSDs (recommended ON)" -BtnText "Check TRIM" -X 30 -Y $y -OnClick { Get-TRIMStatus }
    $null = $page.Controls.Add($card4)
    
    $card5 = New-ToolCard -Title "Dirty Bit Status" -Desc "Check volumes that will run CHKDSK on boot" -BtnText "Check Status" -X 320 -Y $y -OnClick { Get-DirtyBitStatus }
    $null = $page.Controls.Add($card5)
    
    $card6 = New-ToolCard -Title "Reliability Counters" -Desc "Read/Write errors, temperature, wear level" -BtnText "View Counters" -X 610 -Y $y -OnClick { Get-ReliabilityCounter }
    $null = $page.Controls.Add($card6)
    $y += 130

    $mftCard = New-ToolCard -Title "MFT Layout" -Desc "Report Master File Table size, records, extents, and physical fragmentation graph" -BtnText "Open MFT Report" -X 30 -Y $y -OnClick { Show-MftReport }
    $null = $page.Controls.Add($mftCard)

    $usnCard = New-ToolCard -Title "USN Journal" -Desc "Browse recent NTFS changes by reason flags and optional process evidence" -BtnText "Open Journal" -X 320 -Y $y -OnClick { Show-UsnJournalBrowser }
    $null = $page.Controls.Add($usnCard)
    $y += 130
    
    # SMART Info Panel
    $smartInfo = New-InfoPanel -Key "SMART" -X 30 -Y $y -Width 900
    if ($smartInfo) {
        $null = $page.Controls.Add($smartInfo)
        $y += $smartInfo.Height + 30
    }
    
    return $page
}

function Build-HelpPage {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $Script:Theme.BgPrimary
    $page.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    
    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Help & Documentation"
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $Script:Theme.TextPrimary
    $title.Location = New-Object System.Drawing.Point(30, 20)
    $title.AutoSize = $true
    $null = $page.Controls.Add($title)
    
    $helpBox = New-Object System.Windows.Forms.RichTextBox
    $helpBox.Location = New-Object System.Drawing.Point(30, 60)
    $helpBox.Size = New-Object System.Drawing.Size(900, 480)
    $helpBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $helpBox.BackColor = $Script:Theme.BgCard
    $helpBox.ForeColor = $Script:Theme.TextSecondary
    $helpBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $helpBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $helpBox.ReadOnly = $true
    $helpBox.Text = @"
================================================================================
                    PATHFORGE v$($Script:Config.Version) - DOCUMENTATION
================================================================================

FORCE DELETE - 6 Escalating Methods
-----------------------------------
1. Standard PowerShell  - Remove-Item -Force -Recurse
2. .NET Framework       - System.IO.File/Directory.Delete()
3. Long Path Prefix     - \\?\ prefix bypasses 260 char limit
4. 8.3 Short Name       - Uses DOS 8.3 names for invalid chars
5. Robocopy Mirror      - Mirrors empty folder over target
6. WMI/CIM              - Windows Management Instrumentation

"COULD NOT FIND THIS ITEM" Error
--------------------------------
Caused by: trailing spaces/dots, reserved names (CON, PRN, NUL, COM1-9, 
LPT1-9), invalid characters, paths over 260 characters.
Solution: Methods 3 (Long Path) and 4 (Short Name) handle these.

REPAIR ORDER (Critical!)
------------------------
Always run in this sequence:
  1. DISM /RestoreHealth  - Repairs Windows component store FIRST
  2. SFC /scannow         - Repairs system files using component store
  3. CHKDSK               - Checks/repairs filesystem

Running SFC before DISM will fail if component store is corrupted!

SMART Warning Signs - BACKUP IMMEDIATELY if you see:
-----------------------------------------------------
  * PredictFailure = TRUE
  * Reallocated Sector Count (ID 05) > 0
  * Current Pending Sectors (ID C5) > 0
  * Uncorrectable Sectors (ID C6) > 0

Drives with ID C6 > 0 are 39x more likely to fail within 60 days!

Critical Event IDs
------------------
  55  - Filesystem corrupt
  50  - Delayed write failed (potential data loss)
  98  - Volume needs offline check
  129 - Reset to device issued (timeout)
  153 - Disk retry occurred
  157 - Disk surprise removed

Educational Info Panels
-----------------------
Each section has expandable "[i] Show Details" panels that explain:
  * What ACLs are and how permissions work
  * Alternate Data Streams and why they matter
  * File ownership and when to take it
  * Boot-time deletion mechanics
  * CHKDSK parameters explained
  * SFC vs DISM differences
  * SMART attributes to monitor
  * And much more!

Click "Show Details" on any blue info panel to learn more.

Log Files: $($Script:Config.LogPath)
"@
    $null = $page.Controls.Add($helpBox)
    
    return $page
}

# ============================================================================
# MAIN FORM
# ============================================================================
function Build-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $iconPath = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path $iconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    }
    $form.Text = "PathForge v$($Script:Config.Version)"
    $form.Size = New-Object System.Drawing.Size(1020, 900)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $Script:Theme.BgPrimary
    $form.ForeColor = $Script:Theme.TextPrimary
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 800)
    
    # Dark title bar
    $form.Add_HandleCreated({ try { [DarkMode]::EnableDarkTitleBar($this.Handle) } catch {} })

    $form.Add_FormClosing({
        param($formSender, $closingEvent)
        $null = $formSender

        if (-not $Script:OperationRunning) {
            return
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            "An operation is running. Cancel it and close?",
            "Operation in Progress",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Stop-ActiveOperation
        }
        else {
            $closingEvent.Cancel = $true
        }
    })
    
    # Header panel
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = 55
    $headerPanel.BackColor = $Script:Theme.BgSecondary
    
    $logo = New-Object System.Windows.Forms.Label
    $logo.Text = "PATHFORGE"
    $logo.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $logo.ForeColor = $Script:Theme.Accent
    $logo.Location = New-Object System.Drawing.Point(20, 12)
    $logo.AutoSize = $true
    $null = $headerPanel.Controls.Add($logo)
    
    # Tab strip
    $tabStrip = New-Object System.Windows.Forms.FlowLayoutPanel
    $tabStrip.Location = New-Object System.Drawing.Point(180, 10)
    $tabStrip.Size = New-Object System.Drawing.Size(700, 40)
    $tabStrip.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $tabStrip.BackColor = $Script:Theme.BgSecondary
    $tabStrip.WrapContents = $false
    
    $tab1 = New-TabButton -Text "File Operations" -Key "FileOps"
    $null = $tabStrip.Controls.Add($tab1)
    $tab2 = New-TabButton -Text "Filesystem Repair" -Key "Repair"
    $null = $tabStrip.Controls.Add($tab2)
    $tab3 = New-TabButton -Text "Diagnostics" -Key "Diagnostics"
    $null = $tabStrip.Controls.Add($tab3)
    $tab4 = New-TabButton -Text "Help" -Key "Help"
    $null = $tabStrip.Controls.Add($tab4)
    
    $null = $headerPanel.Controls.Add($tabStrip)
    $null = $form.Controls.Add($headerPanel)
    
    # Output panel (bottom)
    $outputPanel = New-Object System.Windows.Forms.Panel
    $outputPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $outputPanel.Height = 180
    $outputPanel.BackColor = $Script:Theme.BgSecondary
    
    $outputTitle = New-Object System.Windows.Forms.Label
    $outputTitle.Text = "OUTPUT CONSOLE"
    $outputTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $outputTitle.ForeColor = $Script:Theme.TextMuted
    $outputTitle.Location = New-Object System.Drawing.Point(15, 8)
    $outputTitle.AutoSize = $true
    $null = $outputPanel.Controls.Add($outputTitle)
    
    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $cancelBtn.ForeColor = $Script:Theme.TextPrimary
    $cancelBtn.BackColor = $Script:Theme.Error
    $cancelBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancelBtn.FlatAppearance.BorderSize = 0
    $cancelBtn.Location = New-Object System.Drawing.Point(850, 5)
    $cancelBtn.Size = New-Object System.Drawing.Size(60, 22)
    $cancelBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top
    $cancelBtn.Add_Click({ Stop-ActiveOperation })
    $null = $outputPanel.Controls.Add($cancelBtn)

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = "Save"
    $saveBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $saveBtn.ForeColor = $Script:Theme.TextPrimary
    $saveBtn.BackColor = $Script:Theme.BgTertiary
    $saveBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $saveBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $saveBtn.Location = New-Object System.Drawing.Point(785, 5)
    $saveBtn.Size = New-Object System.Drawing.Size(55, 22)
    $saveBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top
    $saveBtn.AccessibleName = "Save console output"
    $saveBtn.Add_Click({ Export-ConsoleOutput | Out-Null })
    $null = $outputPanel.Controls.Add($saveBtn)

    $clearBtn = New-Object System.Windows.Forms.Button
    $clearBtn.Text = "Clear"
    $clearBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $clearBtn.ForeColor = $Script:Theme.TextMuted
    $clearBtn.BackColor = $Script:Theme.BgTertiary
    $clearBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $clearBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $clearBtn.Location = New-Object System.Drawing.Point(920, 5)
    $clearBtn.Size = New-Object System.Drawing.Size(55, 22)
    $clearBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top
    $clearBtn.Add_Click({ $Script:OutputBox.Clear() })
    $null = $outputPanel.Controls.Add($clearBtn)

    $Script:OutputBox = New-Object System.Windows.Forms.RichTextBox
    $Script:OutputBox.Location = New-Object System.Drawing.Point(10, 32)
    $Script:OutputBox.Size = New-Object System.Drawing.Size(980, 140)
    $Script:OutputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $Script:OutputBox.BackColor = $Script:Theme.BgInput
    $Script:OutputBox.ForeColor = $Script:Theme.TextSecondary
    $Script:OutputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $Script:OutputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $Script:OutputBox.ReadOnly = $true
    $null = $outputPanel.Controls.Add($Script:OutputBox)
    
    $null = $form.Controls.Add($outputPanel)

    $positionOutputActions = {
        $rightEdge = $outputPanel.ClientSize.Width - 15
        $clearBtn.Left = $rightEdge - $clearBtn.Width
        $cancelBtn.Left = $clearBtn.Left - $cancelBtn.Width - 10
        $saveBtn.Left = $cancelBtn.Left - $saveBtn.Width - 10
    }.GetNewClosure()
    $outputPanel.Add_SizeChanged($positionOutputActions)
    & $positionOutputActions
    
    # Status bar
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.BackColor = $Script:Theme.BgSecondary
    $statusStrip.SizingGrip = $false
    
    $Script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $Script:StatusLabel.Text = "  Ready"
    $Script:StatusLabel.ForeColor = $Script:Theme.TextMuted
    $Script:StatusLabel.Spring = $true
    $Script:StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $null = $statusStrip.Items.Add($Script:StatusLabel)
    
    $Script:ProgressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $Script:ProgressBar.Size = New-Object System.Drawing.Size(200, 16)
    $null = $statusStrip.Items.Add($Script:ProgressBar)
    
    $null = $form.Controls.Add($statusStrip)
    
    # Content panel (MUST BE ADDED LAST to fill remaining space)
    $Script:ContentPanel = New-Object System.Windows.Forms.Panel
    $Script:ContentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $Script:ContentPanel.BackColor = $Script:Theme.BgPrimary
    $Script:ContentPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
    $null = $form.Controls.Add($Script:ContentPanel)
    
    # Build pages
    $Script:Pages["FileOps"] = Build-FileOpsPage
    $Script:Pages["Repair"] = Build-RepairPage
    $Script:Pages["Diagnostics"] = Build-DiagnosticsPage
    $Script:Pages["Help"] = Build-HelpPage
    
    Switch-Tab -TabName "FileOps"
    
    return $form
}

# ============================================================================
# CONTEXT MENU INTEGRATION
# ============================================================================
function Install-ContextMenu {
    $scriptPath = $PSCommandPath
    $keyPaths = @(
        "Registry::HKEY_CLASSES_ROOT\*\shell\PathForge",
        "Registry::HKEY_CLASSES_ROOT\Directory\shell\PathForge"
    )
    foreach ($keyPath in $keyPaths) {
        $null = New-Item -Path $keyPath -Force
        Set-ItemProperty -Path $keyPath -Name "(Default)" -Value "Open with PathForge"
        Set-ItemProperty -Path $keyPath -Name "Icon" -Value "powershell.exe,0"
        $cmdPath = "$keyPath\command"
        $null = New-Item -Path $cmdPath -Force
        Set-ItemProperty -Path $cmdPath -Name "(Default)" -Value "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`" -Path `"%1`""
    }
    Write-Host "PathForge context menu installed. Right-click any file or folder to see 'Open with PathForge'."
}

function Remove-ContextMenu {
    $keyPaths = @(
        "Registry::HKEY_CLASSES_ROOT\*\shell\PathForge",
        "Registry::HKEY_CLASSES_ROOT\Directory\shell\PathForge"
    )
    foreach ($keyPath in $keyPaths) {
        if (Test-Path $keyPath) {
            Remove-Item -Path $keyPath -Recurse -Force
        }
    }
    Write-Host "PathForge context menu removed."
}

# ============================================================================
# ENTRY POINT
# ============================================================================
if ($InstallContextMenu) {
    Install-ContextMenu
    return
}
if ($RemoveContextMenu) {
    Remove-ContextMenu
    return
}

function Start-Application {
    param([string]$InitialPath)
    Initialize-Logging
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}

    $mainForm = Build-MainForm

    $mainForm.Add_Shown({
        Write-Console "PathForge v$($Script:Config.Version) initialized" -Type "Info"
        Write-Console "Log location: $Script:LogFile" -Type "Normal"
        Write-Console "" -Type "Normal"
        Write-Console "TIP: Click '[i] Show Details' on any blue panel to learn more!" -Type "Info"
        if ($InitialPath -and $Script:PathTextBox) {
            $Script:PathTextBox.Text = $InitialPath
            Write-Console "Path pre-filled: $InitialPath" -Type "Info"
        }
        Invoke-QuarantineStartupMaintenance | Out-Null
    }.GetNewClosure())

    [void]$mainForm.ShowDialog()
    $mainForm.Dispose()
}

Start-Application -InitialPath $Path
