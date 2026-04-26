<#
.SYNOPSIS
    PathForge - Windows Filesystem Repair & Deletion Suite
.DESCRIPTION
    Professional toolkit for filesystem repair, stubborn file deletion,
    permission management, and drive diagnostics with comprehensive
    educational information panels.
.VERSION
    3.0.0
#>

#Requires -RunAsAdministrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

# Boot-time deletion API (MoveFileEx)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class BootDelete {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;
    public static bool ScheduleDelete(string path) {
        return MoveFileEx(path, null, MOVEFILE_DELAY_UNTIL_REBOOT);
    }
}
"@ -ErrorAction SilentlyContinue

# ============================================================================
# CONFIGURATION
# ============================================================================
$Script:Config = @{
    Version   = "3.0.0"
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

DANGERS OF DELETION:
Regular deletion follows the link and DELETES THE TARGET!
• "del symlink" deletes target file
• "rmdir /s junction" deletes target folder contents!

SAFE DELETION:
• rmdir linkname (without /s) - removes link only
• fsutil reparsepoint delete linkname

IDENTIFICATION:
• dir shows <SYMLINK>, <JUNCTION>, <SYMLINKD>
• Get-Item shows ReparsePoint attribute
• Target shown in brackets

COMMON USES:
• C:\Users\Username\AppData\Local\Application Data → junction to local folder
• C:\Documents and Settings → junction to C:\Users
• Developer: node_modules symlink to shared cache

PATHFORGE BEHAVIOR:
When detecting a reparse point, we ask before deletion to prevent accidentally destroying target data.
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
        $Script:OutputBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
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
# DELETION METHODS (6 escalating techniques from research)
# ============================================================================
function Remove-ItemStandard {
    param([string]$Path)
    try {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
        return @{Success = $true; Method = "Standard PowerShell" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemDotNet {
    param([string]$Path)
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
    param([string]$Path)
    try {
        $longPath = "\\?\$Path"
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $null = cmd /c "rd /s /q `"$longPath`"" 2>&1
        }
        else {
            $null = cmd /c "del /f /q `"$longPath`"" 2>&1
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return @{Success = $true; Method = "Long Path (\\?\)" }
        }
        return @{Success = $false; Error = "Path still exists" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemShortName {
    param([string]$Path)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $shortPath = if (Test-Path -LiteralPath $Path -PathType Container) {
            $fso.GetFolder($Path).ShortPath
        }
        else {
            $fso.GetFile($Path).ShortPath
        }
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($fso) | Out-Null
        
        if ($shortPath -and $shortPath -ne $Path) {
            Remove-Item -LiteralPath $shortPath -Force -Recurse -ErrorAction Stop
            return @{Success = $true; Method = "8.3 Short Name" }
        }
        return @{Success = $false; Error = "No short name available" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemRobocopy {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            return @{Success = $false; Error = "Robocopy only works on directories" }
        }
        $emptyDir = Join-Path $env:TEMP "PathForge_Empty_$(Get-Random)"
        New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
        
        Write-Console "  Robocopy: Mirroring empty folder over target..." -Type "Progress"
        $null = robocopy $emptyDir $Path /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS 2>&1
        Remove-Item -Path $emptyDir -Force -ErrorAction SilentlyContinue
        
        $null = cmd /c "rd /s /q `"$Path`"" 2>&1
        
        if (-not (Test-Path -LiteralPath $Path)) {
            return @{Success = $true; Method = "Robocopy Mirror" }
        }
        return @{Success = $false; Error = "Directory still exists" }
    }
    catch { return @{Success = $false; Error = $_.Exception.Message } }
}

function Remove-ItemWMI {
    param([string]$Path)
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

# ============================================================================
# REPARSE POINT HANDLING
# ============================================================================
function Test-ReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item) {
        return ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    }
    return $false
}

function Remove-ReparsePointSafe {
    param([string]$Path)
    if (Test-ReparsePoint -Path $Path) {
        $null = cmd /c "rmdir `"$Path`"" 2>&1
        return -not (Test-Path -LiteralPath $Path)
    }
    return $false
}

# ============================================================================
# MAIN FORCE DELETE FUNCTION
# ============================================================================
function Invoke-ForceDelete {
    param([string]$Path, [switch]$TakeOwnership)
    
    Write-Console "Processing: $Path" -Type "Info"
    Write-Log "Force delete initiated: $Path"
    
    if (-not (Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath "\\?\$Path")) {
        Write-Console "Path not found" -Type "Error"
        return $false
    }
    
    if (Test-ReparsePoint -Path $Path) {
        Write-Console "Detected symbolic link or junction point" -Type "Warning"
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This is a symbolic link or junction. Remove link only (not target)?",
            "Reparse Point Detected", 4, 48)
        if ($result -eq 6) {
            if (Remove-ReparsePointSafe -Path $Path) {
                Write-Console "Reparse point removed successfully" -Type "Success"
                return $true
            }
        }
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
    
    $methods = @(
        @{Name = "Standard PowerShell"; Func = "Remove-ItemStandard" },
        @{Name = ".NET Framework"; Func = "Remove-ItemDotNet" },
        @{Name = "Long Path (\\?\)"; Func = "Remove-ItemLongPath" },
        @{Name = "8.3 Short Name"; Func = "Remove-ItemShortName" },
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
    
    Write-Console "All 6 deletion methods failed" -Type "Error"
    Write-Log "All methods failed: $Path" -Level "ERROR"
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

# ============================================================================
# OWNERSHIP & PERMISSIONS
# ============================================================================
function Invoke-TakeOwnership {
    param([string]$Path)
    
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
        catch { }
    }
    
    Write-Console "Scan complete: $processed items processed, $orphaned orphaned SIDs removed" -Type "Success"
    Set-Status "Ready"
    Set-Progress -Value 0
}

function Get-ACLReport {
    param([string]$Path)
    
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

# ============================================================================
# BOOT-TIME DELETION
# ============================================================================
function Invoke-BootTimeDelete {
    param([string]$Path)
    
    Write-Console "Scheduling boot-time deletion using MoveFileEx API..." -Type "Info"
    Write-Console "Target: $Path" -Type "Normal"
    
    try {
        $success = [BootDelete]::ScheduleDelete($Path)
        
        if ($success) {
            Write-Console "Scheduled for deletion on next reboot" -Type "Success"
            Write-Console "The file will be deleted by Session Manager before services start" -Type "Info"
            Write-Log "Boot-time deletion scheduled: $Path" -Level "SUCCESS"
            return $true
        }
        else {
            Write-Console "MoveFileEx API call failed, trying registry fallback..." -Type "Warning"
            
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
            $existing = @()
            try {
                $prop = Get-ItemProperty -Path $regPath -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                if ($prop) { $existing = @($prop.PendingFileRenameOperations) }
            }
            catch { }
            
            $newEntries = $existing + @("\??\$Path", "")
            Set-ItemProperty -Path $regPath -Name PendingFileRenameOperations -Value $newEntries -Type MultiString -Force
            
            Write-Console "Scheduled via registry fallback" -Type "Success"
            return $true
        }
    }
    catch {
        Write-Console "Failed to schedule boot-time deletion: $_" -Type "Error"
        return $false
    }
}

function Get-PendingDeletions {
    Write-Console "=== Pending Boot-Time Operations ===" -Type "Info"
    Write-Console "Registry: HKLM\...\Session Manager\PendingFileRenameOperations" -Type "Normal"
    Write-Console "" -Type "Normal"
    
    try {
        $prop = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        
        if ($prop -and $prop.PendingFileRenameOperations) {
            $ops = $prop.PendingFileRenameOperations
            $deleteCount = 0
            $moveCount = 0
            
            for ($i = 0; $i -lt $ops.Count; $i += 2) {
                $source = $ops[$i] -replace '^\\\?\?\\', ''
                $dest = if ($i + 1 -lt $ops.Count) { $ops[$i + 1] } else { "" }
                
                if (-not $dest -or $dest -eq "") {
                    Write-Console "  DELETE: $source" -Type "Warning"
                    $deleteCount++
                }
                else {
                    $dest = $dest -replace '^\\\?\?\\', ''
                    Write-Console "  MOVE: $source" -Type "Info"
                    Write-Console "     -> $dest" -Type "Normal"
                    $moveCount++
                }
            }
            
            Write-Console "" -Type "Normal"
            Write-Console "Total: $deleteCount deletion(s), $moveCount move(s) pending" -Type "Info"
        }
        else {
            Write-Console "No pending boot-time operations" -Type "Success"
        }
    }
    catch {
        Write-Console "Error reading pending operations: $_" -Type "Error"
    }
}

function Clear-PendingDeletions {
    Write-Console "Clearing all pending boot-time operations..." -Type "Warning"
    
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will cancel ALL pending file operations scheduled for next boot.`n`nAre you sure?",
        "Confirm Clear", 4, 48)
    
    if ($result -eq 6) {
        try {
            Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction Stop
            Write-Console "All pending operations cleared" -Type "Success"
        }
        catch {
            Write-Console "Failed to clear (may already be empty): $_" -Type "Warning"
        }
    }
}

# ============================================================================
# ALTERNATE DATA STREAMS
# ============================================================================
function Invoke-ADSScanner {
    param([string]$Path)
    
    Write-Console "Scanning for Alternate Data Streams..." -Type "Info"
    Write-Console "Looking for hidden data attached to files (NTFS feature)" -Type "Normal"
    Set-Status "Scanning for ADS..."
    
    $items = @(Get-Item -LiteralPath $Path -Force)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $items += Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    $adsFound = @()
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
                    $adsFound += [PSCustomObject]@{
                        Path   = $item.FullName
                        Stream = $stream.Stream
                        Size   = $stream.Length
                    }
                }
            }
        }
        catch { }
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
        catch { }
    }
    
    Write-Console "Unblocked $unblocked file(s) out of $total total" -Type "Success"
    Set-Status "Ready"
    Set-Progress -Value 0
}

# ============================================================================
# FILESYSTEM REPAIR
# ============================================================================
function Invoke-ChkdskWithProgress {
    param([string]$Drive, [string]$Arguments)
    
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "chkdsk.exe"
    $pinfo.Arguments = "$Drive $Arguments"
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    
    $outputHandler = {
        if ($EventArgs.Data) {
            $line = $EventArgs.Data.Trim()
            if ($line) {
                if ($line -match "(\d+)\s*percent") {
                    Set-Progress -Value ([int]$matches[1]) -Maximum 100
                }
                Write-Console "  $line" -Type "Normal"
            }
        }
    }
    
    $process.EnableRaisingEvents = $true
    $null = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outputHandler
    
    $null = $process.Start()
    $process.BeginOutputReadLine()
    
    while (-not $process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    
    Set-Progress -Value 0
}

function Invoke-ChkdskScan {
    param([string]$Drive)
    
    Write-Console "=== CHKDSK /scan on $Drive ===" -Type "Info"
    Write-Console "Online scan - no volume lock required (Windows 8+)" -Type "Normal"
    Write-Console "" -Type "Normal"
    Set-Status "CHKDSK running..."
    
    Invoke-ChkdskWithProgress -Drive $Drive -Arguments "/scan"
    
    Write-Console "" -Type "Normal"
    Write-Console "CHKDSK /scan complete" -Type "Success"
    Set-Status "Ready"
}

function Invoke-ChkdskFix {
    param([string]$Drive)
    
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
        
        Invoke-ChkdskWithProgress -Drive $Drive -Arguments "/F /X"
        
        Write-Console "" -Type "Normal"
        Write-Console "CHKDSK /F complete" -Type "Success"
        Set-Status "Ready"
    }
}

function Invoke-ChkdskFull {
    param([string]$Drive)
    
    Write-Console "=== CHKDSK /R on $Drive ===" -Type "Warning"
    Write-Console "/R = Full repair including bad sector recovery" -Type "Normal"
    Write-Console "WARNING: This can take SEVERAL HOURS on large drives!" -Type "Warning"
    Write-Console "" -Type "Normal"
    Set-Status "CHKDSK /R running (this takes hours)..."
    
    $args = if ($Drive -eq "C:") { "/R" } else { "/R /X" }
    
    Invoke-ChkdskWithProgress -Drive $Drive -Arguments $args
    
    Write-Console "" -Type "Normal"
    Write-Console "CHKDSK /R complete" -Type "Success"
    Set-Status "Ready"
}

function Invoke-ChkdskSpotfix {
    param([string]$Drive)
    
    Write-Console "=== CHKDSK /spotfix on $Drive ===" -Type "Info"
    Write-Console "Targeted repair of issues found by /scan (very fast)" -Type "Normal"
    Write-Console "" -Type "Normal"
    Set-Status "CHKDSK running..."
    
    Invoke-ChkdskWithProgress -Drive $Drive -Arguments "/spotfix"
    
    Write-Console "" -Type "Normal"
    Write-Console "CHKDSK /spotfix complete" -Type "Success"
    Set-Status "Ready"
}

function Invoke-SFCScan {
    Write-Console "=== SFC /scannow ===" -Type "Info"
    Write-Console "System File Checker - repairs protected Windows files" -Type "Normal"
    Write-Console "Source: WinSxS component store" -Type "Normal"
    Write-Console "Duration: ~10-15 minutes" -Type "Warning"
    Write-Console "" -Type "Normal"
    Set-Status "SFC running..."
    
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "sfc.exe"
    $pinfo.Arguments = "/scannow"
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $pinfo.RedirectStandardOutput = $true
    
    $process = [System.Diagnostics.Process]::Start($pinfo)
    
    while (-not $process.HasExited) {
        $line = $process.StandardOutput.ReadLine()
        if ($line) {
            $line = $line.Trim()
            if ($line -match "(\d+)%") {
                Set-Progress -Value ([int]$matches[1]) -Maximum 100
                Set-Status "SFC running... $($matches[0])"
            }
            if ($line -and $line.Length -gt 5) {
                Write-Console "  $line" -Type "Normal"
            }
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    
    $remaining = $process.StandardOutput.ReadToEnd()
    foreach ($line in $remaining.Split("`n")) {
        $line = $line.Trim()
        if ($line.Length -gt 5) {
            Write-Console "  $line" -Type "Normal"
        }
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "SFC scan complete" -Type "Success"
    Write-Console "Log file: %WinDir%\Logs\CBS\CBS.log" -Type "Info"
    Set-Status "Ready"
    Set-Progress -Value 0
}

function Invoke-DISMRestore {
    Write-Console "=== DISM /Online /Cleanup-Image /RestoreHealth ===" -Type "Info"
    Write-Console "Repairs Windows component store (WinSxS)" -Type "Normal"
    Write-Console "Source: Windows Update (requires internet)" -Type "Normal"
    Write-Console "Duration: ~15-30 minutes" -Type "Warning"
    Write-Console "" -Type "Normal"
    Write-Console "IMPORTANT: Run this BEFORE SFC if component store is corrupt!" -Type "Warning"
    Write-Console "" -Type "Normal"
    Set-Status "DISM running..."
    
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "DISM.exe"
    $pinfo.Arguments = "/Online /Cleanup-Image /RestoreHealth"
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $pinfo.RedirectStandardOutput = $true
    
    $process = [System.Diagnostics.Process]::Start($pinfo)
    
    while (-not $process.HasExited) {
        $line = $process.StandardOutput.ReadLine()
        if ($line) {
            $line = $line.Trim()
            if ($line -match "(\d+)\.(\d+)%") {
                Set-Progress -Value ([int]$matches[1]) -Maximum 100
                Set-Status "DISM running... $($matches[0])"
            }
            if ($line.Length -gt 3 -and $line -notmatch "^\[=+\s*\]") {
                Write-Console "  $line" -Type "Normal"
            }
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    
    $remaining = $process.StandardOutput.ReadToEnd()
    foreach ($line in $remaining.Split("`n")) {
        $line = $line.Trim()
        if ($line.Length -gt 5 -and $line -notmatch "^\[=+\s*\]") {
            Write-Console "  $line" -Type "Normal"
        }
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "DISM RestoreHealth complete" -Type "Success"
    Write-Console "Log file: %WinDir%\Logs\DISM\dism.log" -Type "Info"
    Set-Status "Ready"
    Set-Progress -Value 0
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
    
    # Physical disks
    Write-Console "--- Physical Disks ---" -Type "Info"
    Get-PhysicalDisk | ForEach-Object {
        $health = $_.HealthStatus
        $type = switch ($health) {
            "Healthy" { "Success" }
            "Warning" { "Warning" }
            default { "Error" }
        }
        Write-Console "  $($_.FriendlyName)" -Type "Info"
        Write-Console "    Model: $($_.Model)" -Type "Normal"
        Write-Console "    Media: $($_.MediaType)" -Type "Normal"
        Write-Console "    Size: $([math]::Round($_.Size/1GB)) GB" -Type "Normal"
        Write-Console "    Health: $health" -Type $type
        Write-Console "    Status: $($_.OperationalStatus)" -Type "Normal"
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "--- Volumes ---" -Type "Info"
    Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
        $pctFree = if ($_.Size -gt 0) { [math]::Round(($_.SizeRemaining / $_.Size) * 100, 1) } else { 0 }
        $freeType = if ($pctFree -lt 10) { "Error" } elseif ($pctFree -lt 20) { "Warning" } else { "Normal" }
        
        Write-Console "  $($_.DriveLetter): $($_.FileSystemLabel)" -Type "Info"
        Write-Console "    FileSystem: $($_.FileSystem)" -Type "Normal"
        Write-Console "    Size: $([math]::Round($_.Size/1GB, 1)) GB" -Type "Normal"
        Write-Console "    Free: $([math]::Round($_.SizeRemaining/1GB, 1)) GB ($pctFree%)" -Type $freeType
        Write-Console "    Health: $($_.HealthStatus)" -Type "Normal"
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "--- SMART Failure Prediction ---" -Type "Info"
    try {
        $smart = Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction Stop
        if ($smart) {
            foreach ($s in $smart) {
                $name = ($s.InstanceName -replace '_0$', '' -split '\\')[-1]
                if ($s.PredictFailure) {
                    Write-Console "  $name : FAILURE PREDICTED!" -Type "Error"
                    Write-Console "    >>> BACKUP YOUR DATA IMMEDIATELY! <<<" -Type "Error"
                }
                else {
                    Write-Console "  $name : No failure predicted" -Type "Success"
                }
            }
        }
    }
    catch {
        Write-Console "  SMART data not available via WMI" -Type "Warning"
    }
    
    Write-Console "" -Type "Normal"
    Write-Console "--- Storage Reliability Counters ---" -Type "Info"
    try {
        Get-PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Console "  Device: $($_.DeviceId)" -Type "Info"
            Write-Console "    Read Errors: $($_.ReadErrorsTotal)" -Type $(if ($_.ReadErrorsTotal -gt 0) { "Warning" } else { "Normal" })
            Write-Console "    Write Errors: $($_.WriteErrorsTotal)" -Type $(if ($_.WriteErrorsTotal -gt 0) { "Warning" } else { "Normal" })
            Write-Console "    Temperature: $($_.Temperature)°C" -Type $(if ($_.Temperature -gt 50) { "Warning" } else { "Normal" })
            Write-Console "    Wear: $($_.Wear)" -Type "Normal"
        }
    }
    catch {
        Write-Console "  Reliability counters not available" -Type "Warning"
    }
}

function Get-TRIMStatus {
    Write-Console "=== TRIM / DisableDeleteNotify Status ===" -Type "Info"
    Write-Console "TRIM should be ENABLED for SSDs" -Type "Normal"
    Write-Console "" -Type "Normal"
    
    try {
        $result = fsutil behavior query DisableDeleteNotify 2>&1
        
        foreach ($line in ($result -split "`n")) {
            if ($line -match "DisableDeleteNotify\s*=\s*(\d)") {
                $fs = $line -replace "DisableDeleteNotify.*", "" 
                $fs = $fs.Trim()
                $value = $matches[1]
                
                if ($value -eq "0") {
                    Write-Console "  $fs TRIM: ENABLED (recommended)" -Type "Success"
                }
                else {
                    Write-Console "  $fs TRIM: DISABLED" -Type "Warning"
                }
            }
            elseif ($line.Trim()) {
                Write-Console "  $($line.Trim())" -Type "Normal"
            }
        }
    }
    catch {
        Write-Console "Could not query TRIM status: $_" -Type "Error"
    }
}

function Get-FilesystemEvents {
    Write-Console "=== Filesystem Event Log Analysis (Last 7 Days) ===" -Type "Info"
    Write-Console "" -Type "Normal"
    
    $criticalEvents = @(
        @{Id = 55; Desc = "Filesystem structure corrupt" },
        @{Id = 50; Desc = "Delayed write failed (data loss)" },
        @{Id = 98; Desc = "Volume needs offline CHKDSK" },
        @{Id = 129; Desc = "Reset to device issued (timeout)" },
        @{Id = 153; Desc = "Disk retry occurred" },
        @{Id = 157; Desc = "Disk surprise removed" }
    )
    
    $foundEvents = @()
    
    Write-Console "Searching for critical events..." -Type "Progress"
    
    foreach ($eventDef in $criticalEvents) {
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = $eventDef.Id
                StartTime = (Get-Date).AddDays(-7)
            } -MaxEvents 10 -ErrorAction SilentlyContinue
            
            if ($events) {
                $foundEvents += $events
                Write-Console "  Event ID $($eventDef.Id): $($events.Count) occurrence(s) - $($eventDef.Desc)" -Type "Warning"
            }
        }
        catch { }
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
    $titleLbl.Text = "ℹ️ " + $info.Title
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
    $null = $page.Controls.Add($Script:PathTextBox)
    
    $browseFileBtn = New-Object System.Windows.Forms.Button
    $browseFileBtn.Text = "File..."
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
    $takeOwnBtn.Text = "🔐 Take Ownership"
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
    $viewAclBtn.Text = "📋 View Permissions"
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
    $unblockBtn.Text = "🔓 Unblock File"
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
    
    # Checkbox - UNCHECKED BY DEFAULT (User Request)
    $Script:TakeOwnCheck = New-Object System.Windows.Forms.CheckBox
    $Script:TakeOwnCheck.Text = "Include 'Take Ownership' step when using Force Delete"
    $Script:TakeOwnCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Script:TakeOwnCheck.ForeColor = $Script:Theme.TextSecondary
    $Script:TakeOwnCheck.Location = New-Object System.Drawing.Point(30, $y)
    $Script:TakeOwnCheck.Size = New-Object System.Drawing.Size(500, 22)
    $Script:TakeOwnCheck.Checked = $false  # UNCHECKED BY DEFAULT
    $null = $page.Controls.Add($Script:TakeOwnCheck)
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
        Invoke-ForceDelete -Path $Script:PathTextBox.Text -TakeOwnership:$Script:TakeOwnCheck.Checked
    }
    $null = $page.Controls.Add($card1)
    
    $card2 = New-ToolCard -Title "Boot-Time Delete" -Desc "MoveFileEx API - deletes on next reboot before Windows services start" -BtnText "Schedule" -X 320 -Y $y -OnClick {
        if ([string]::IsNullOrWhiteSpace($Script:PathTextBox.Text)) { 
            [System.Windows.Forms.MessageBox]::Show("Enter a path first.", "No Path", 0, 48) | Out-Null
            return 
        }
        Invoke-BootTimeDelete -Path $Script:PathTextBox.Text
    }
    $null = $page.Controls.Add($card2)
    
    $card3 = New-ToolCard -Title "View/Clear Pending" -Desc "Shows PendingFileRenameOperations scheduled for next reboot" -BtnText "View List" -X 610 -Y $y -OnClick { 
        Get-PendingDeletions 
    }
    $null = $page.Controls.Add($card3)
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
    $warnTitle.Text = "⚠️ Critical Repair Order: DISM → SFC → CHKDSK"
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
    
    $card5 = New-ToolCard -Title "Dirty Bit Status" -Desc "Check which volumes need CHKDSK on boot" -BtnText "Check Status" -X 320 -Y $y -OnClick { Get-DirtyBitStatus }
    $null = $page.Controls.Add($card5)
    
    $card6 = New-ToolCard -Title "Force CHKDSK" -Desc "Set dirty bit to force CHKDSK on next reboot" -BtnText "Set Dirty Bit" -X 610 -Y $y -OnClick {
        $drive = $Script:DriveCombo.Text.Substring(0, 2)
        if ([System.Windows.Forms.MessageBox]::Show("Force CHKDSK on next boot for $drive`?`n`nThe system will run CHKDSK automatically when you restart.", "Confirm", 4, 48) -eq 6) {
            Set-DirtyBit -Drive $drive
        }
    }
    $null = $page.Controls.Add($card6)
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
    
    $card9 = New-ToolCard -Title "Full System Repair" -Desc "DISM + SFC + CHKDSK in correct order (30-60 min)" -BtnText "Run All" -X 610 -Y $y -OnClick {
        if ([System.Windows.Forms.MessageBox]::Show(
            "Run complete repair sequence?`n`n1. DISM /RestoreHealth (15-30 min)`n2. SFC /scannow (10-15 min)`n3. CHKDSK /scan (5-10 min)`n`nTotal time: 30-60 minutes", 
            "Full System Repair", 4, 32) -eq 6) {
            Write-Console "=== FULL SYSTEM REPAIR SEQUENCE ===" -Type "Info"
            Write-Console "" -Type "Normal"
            Write-Console "Step 1/3: DISM /RestoreHealth" -Type "Info"
            Invoke-DISMRestore
            Write-Console "" -Type "Normal"
            Write-Console "Step 2/3: SFC /scannow" -Type "Info"
            Invoke-SFCScan
            Write-Console "" -Type "Normal"
            Write-Console "Step 3/3: CHKDSK /scan" -Type "Info"
            Invoke-ChkdskScan -Drive "C:"
            Write-Console "" -Type "Normal"
            Write-Console "=== FULL REPAIR SEQUENCE COMPLETE ===" -Type "Success"
            Write-Console "Recommend: Reboot and run SFC again to verify" -Type "Info"
        }
    }
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
        $y += $healInfo.Height + 30
    }
    
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
    $warnTitle.Text = "🔴 SMART Warning Signs - BACKUP IMMEDIATELY if you see:"
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
    
    $card2 = New-ToolCard -Title "SMART Check" -Desc "FailurePredictStatus - early warning of drive failure" -BtnText "Check SMART" -X 320 -Y $y -OnClick {
        Write-Console "=== SMART Failure Prediction ===" -Type "Info"
        Write-Console "" -Type "Normal"
        try {
            $smart = Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction Stop
            if ($smart) {
                foreach ($s in $smart) {
                    $name = ($s.InstanceName -replace '_0$', '' -split '\\')[-1]
                    if ($s.PredictFailure) {
                        Write-Console "  $name : FAILURE PREDICTED!" -Type "Error"
                        Write-Console "    Reason Code: $($s.Reason)" -Type "Error"
                        Write-Console "    >>> BACKUP YOUR DATA IMMEDIATELY! <<<" -Type "Error"
                    }
                    else {
                        Write-Console "  $name : No failure predicted" -Type "Success"
                    }
                }
            }
            else {
                Write-Console "  SMART data not available via WMI" -Type "Warning"
            }
        }
        catch {
            Write-Console "  Failed to query SMART: $_" -Type "Error"
        }
    }
    $null = $page.Controls.Add($card2)
    
    $card3 = New-ToolCard -Title "Event Log Analysis" -Desc "Critical events: 55, 50, 98, 129, 153, 157 (7 days)" -BtnText "Analyze Logs" -X 610 -Y $y -OnClick { Get-FilesystemEvents }
    $null = $page.Controls.Add($card3)
    $y += 130
    
    $card4 = New-ToolCard -Title "TRIM Status" -Desc "Check if TRIM is enabled for SSDs (recommended ON)" -BtnText "Check TRIM" -X 30 -Y $y -OnClick { Get-TRIMStatus }
    $null = $page.Controls.Add($card4)
    
    $card5 = New-ToolCard -Title "Dirty Bit Status" -Desc "Check volumes that will run CHKDSK on boot" -BtnText "Check Status" -X 320 -Y $y -OnClick { Get-DirtyBitStatus }
    $null = $page.Controls.Add($card5)
    
    $card6 = New-ToolCard -Title "Reliability Counters" -Desc "Read/Write errors, temperature, wear level" -BtnText "View Counters" -X 610 -Y $y -OnClick {
        Write-Console "=== Storage Reliability Counters ===" -Type "Info"
        Write-Console "" -Type "Normal"
        try {
            Get-PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop | ForEach-Object {
                Write-Console "  Device ID: $($_.DeviceId)" -Type "Info"
                Write-Console "    Read Errors (Total): $($_.ReadErrorsTotal)" -Type $(if ($_.ReadErrorsTotal -gt 0) { "Warning" } else { "Normal" })
                Write-Console "    Read Errors (Corrected): $($_.ReadErrorsCorrected)" -Type "Normal"
                Write-Console "    Read Errors (Uncorrected): $($_.ReadErrorsUncorrected)" -Type $(if ($_.ReadErrorsUncorrected -gt 0) { "Error" } else { "Normal" })
                Write-Console "    Write Errors (Total): $($_.WriteErrorsTotal)" -Type $(if ($_.WriteErrorsTotal -gt 0) { "Warning" } else { "Normal" })
                Write-Console "    Temperature: $($_.Temperature)°C" -Type $(if ($_.Temperature -gt 50) { "Warning" } else { "Normal" })
                Write-Console "    Wear: $($_.Wear)" -Type $(if ($_.Wear -gt 80) { "Warning" } else { "Normal" })
                Write-Console "    Power On Hours: $($_.PowerOnHours)" -Type "Normal"
                Write-Console "" -Type "Normal"
            }
        }
        catch {
            Write-Console "  Reliability counters not available: $_" -Type "Warning"
        }
    }
    $null = $page.Controls.Add($card6)
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
Each section has expandable "ℹ️ Show Details" panels that explain:
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
# codex-branding:start
                $brandingIconPath = Join-Path $PSScriptRoot 'icon.ico'
                if (Test-Path $brandingIconPath) {
                    try {
                        $form.Icon = New-Object System.Drawing.Icon($brandingIconPath)
                    } catch {
                    }
                }
                # codex-branding:end
    $form.Text = "PathForge v$($Script:Config.Version)"
    $form.Size = New-Object System.Drawing.Size(1020, 900)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $Script:Theme.BgPrimary
    $form.ForeColor = $Script:Theme.TextPrimary
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 800)
    
    # Dark title bar
    $form.Add_HandleCreated({ try { [DarkMode]::EnableDarkTitleBar($this.Handle) } catch {} })
    
    # Header panel
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = 55
    $headerPanel.BackColor = $Script:Theme.BgSecondary
    
    $logo = New-Object System.Windows.Forms.Label
    $logo.Text = "⚡ PATHFORGE"
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
    
    $clearBtn = New-Object System.Windows.Forms.Button
    $clearBtn.Text = "Clear"
    $clearBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $clearBtn.ForeColor = $Script:Theme.TextMuted
    $clearBtn.BackColor = $Script:Theme.BgTertiary
    $clearBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $clearBtn.FlatAppearance.BorderColor = $Script:Theme.Border
    $clearBtn.Location = New-Object System.Drawing.Point(920, 5)
    $clearBtn.Size = New-Object System.Drawing.Size(55, 22)
    $clearBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
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
# ENTRY POINT
# ============================================================================
function Start-Application {
    Initialize-Logging
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
    
    $mainForm = Build-MainForm
    
    $mainForm.Add_Shown({
        Write-Console "PathForge v$($Script:Config.Version) initialized" -Type "Info"
        Write-Console "Log location: $Script:LogFile" -Type "Normal"
        Write-Console "" -Type "Normal"
        Write-Console "TIP: Click 'ℹ️ Show Details' on any blue panel to learn more!" -Type "Info"
    })
    
    [void]$mainForm.ShowDialog()
    $mainForm.Dispose()
}

Start-Application
