# PathForge reusable deletion, repair, and diagnostic operations.

Add-Type -AssemblyName Microsoft.VisualBasic

$Script:PathForgeSessionManagerRegistryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager'
$Script:PathForgePendingFileValueName = 'PendingFileRenameOperations'
$Script:PathForgeQuarantineDirectoryName = 'PathForge.Quarantine'
$Script:PathForgeQuarantineSchemaVersion = 1

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

if (-not ('PathForgeLinkNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class PathForgeNativeReparseInfo {
    public uint Tag { get; set; }
    public string SubstituteName { get; set; }
    public string PrintName { get; set; }
    public bool IsRelative { get; set; }
}

public static class PathForgeLinkNative {
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FSCTL_GET_REPARSE_POINT = 0x000900A8;
    private const uint IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003;
    private const uint IO_REPARSE_TAG_SYMLINK = 0xA000000C;
    private const uint SYMLINK_FLAG_RELATIVE = 1;
    private const int ERROR_MORE_DATA = 234;
    private const int ERROR_HANDLE_EOF = 38;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        FileShare shareMode,
        IntPtr securityAttributes,
        FileMode creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint controlCode,
        IntPtr inputBuffer,
        int inputBufferSize,
        byte[] outputBuffer,
        int outputBufferSize,
        out int bytesReturned,
        IntPtr overlapped);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFileNameW(
        string fileName,
        uint flags,
        ref uint stringLength,
        StringBuilder linkName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool FindNextFileNameW(
        IntPtr findStream,
        ref uint stringLength,
        StringBuilder linkName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FindClose(IntPtr findFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFileW(string fileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool RemoveDirectoryW(string pathName);

    private static string DecodeUnicode(byte[] buffer, int offset, int length, int bytesReturned) {
        if (length == 0) {
            return String.Empty;
        }
        if (offset < 0 || length < 0 || offset + length > bytesReturned) {
            throw new InvalidDataException("The reparse point contains an invalid path buffer.");
        }
        return Encoding.Unicode.GetString(buffer, offset, length);
    }

    private static string ToExtendedPath(string path) {
        string fullPath = Path.GetFullPath(path);
        if (fullPath.StartsWith("\\\\?\\", StringComparison.Ordinal)) {
            return fullPath;
        }
        if (fullPath.StartsWith("\\\\", StringComparison.Ordinal)) {
            return "\\\\?\\UNC\\" + fullPath.Substring(2);
        }
        return "\\\\?\\" + fullPath;
    }

    public static PathForgeNativeReparseInfo GetReparseInfo(string path) {
        using (SafeFileHandle handle = CreateFileW(
            ToExtendedPath(path),
            0,
            FileShare.Read | FileShare.Write | FileShare.Delete,
            IntPtr.Zero,
            FileMode.Open,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
            IntPtr.Zero)) {
            if (handle.IsInvalid) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            byte[] buffer = new byte[16 * 1024];
            int bytesReturned;
            if (!DeviceIoControl(
                handle,
                FSCTL_GET_REPARSE_POINT,
                IntPtr.Zero,
                0,
                buffer,
                buffer.Length,
                out bytesReturned,
                IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (bytesReturned < 8) {
                throw new InvalidDataException("The reparse point data is shorter than its header.");
            }

            uint tag = BitConverter.ToUInt32(buffer, 0);
            PathForgeNativeReparseInfo result = new PathForgeNativeReparseInfo();
            result.Tag = tag;
            result.SubstituteName = String.Empty;
            result.PrintName = String.Empty;

            if (tag == IO_REPARSE_TAG_SYMLINK) {
                if (bytesReturned < 20) {
                    throw new InvalidDataException("The symbolic-link reparse data is incomplete.");
                }
                ushort substituteOffset = BitConverter.ToUInt16(buffer, 8);
                ushort substituteLength = BitConverter.ToUInt16(buffer, 10);
                ushort printOffset = BitConverter.ToUInt16(buffer, 12);
                ushort printLength = BitConverter.ToUInt16(buffer, 14);
                uint flags = BitConverter.ToUInt32(buffer, 16);
                result.SubstituteName = DecodeUnicode(buffer, 20 + substituteOffset, substituteLength, bytesReturned);
                result.PrintName = DecodeUnicode(buffer, 20 + printOffset, printLength, bytesReturned);
                result.IsRelative = (flags & SYMLINK_FLAG_RELATIVE) != 0;
            }
            else if (tag == IO_REPARSE_TAG_MOUNT_POINT) {
                if (bytesReturned < 16) {
                    throw new InvalidDataException("The mount-point reparse data is incomplete.");
                }
                ushort substituteOffset = BitConverter.ToUInt16(buffer, 8);
                ushort substituteLength = BitConverter.ToUInt16(buffer, 10);
                ushort printOffset = BitConverter.ToUInt16(buffer, 12);
                ushort printLength = BitConverter.ToUInt16(buffer, 14);
                result.SubstituteName = DecodeUnicode(buffer, 16 + substituteOffset, substituteLength, bytesReturned);
                result.PrintName = DecodeUnicode(buffer, 16 + printOffset, printLength, bytesReturned);
            }

            return result;
        }
    }

    private static string ExpandHardLinkName(string root, string linkName) {
        if (linkName.StartsWith("\\", StringComparison.Ordinal)) {
            return root.TrimEnd('\\') + linkName;
        }
        return Path.Combine(root, linkName);
    }

    public static string[] GetHardLinkNames(string path) {
        string fullPath = Path.GetFullPath(path);
        string root = Path.GetPathRoot(fullPath);
        int capacity = 1024;
        IntPtr searchHandle = new IntPtr(-1);
        StringBuilder buffer = null;

        while (true) {
            uint length = (uint)capacity;
            buffer = new StringBuilder(capacity);
            searchHandle = FindFirstFileNameW(ToExtendedPath(fullPath), 0, ref length, buffer);
            if (searchHandle != new IntPtr(-1)) {
                break;
            }
            int error = Marshal.GetLastWin32Error();
            if (error != ERROR_MORE_DATA) {
                throw new Win32Exception(error);
            }
            capacity = checked((int)length + 1);
        }

        HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try {
            names.Add(ExpandHardLinkName(root, buffer.ToString()));
            while (true) {
                uint length = (uint)capacity;
                buffer = new StringBuilder(capacity);
                if (FindNextFileNameW(searchHandle, ref length, buffer)) {
                    names.Add(ExpandHardLinkName(root, buffer.ToString()));
                    continue;
                }

                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_HANDLE_EOF) {
                    break;
                }
                if (error == ERROR_MORE_DATA) {
                    capacity = checked((int)length + 1);
                    continue;
                }
                throw new Win32Exception(error);
            }
        }
        finally {
            FindClose(searchHandle);
        }
        string[] result = new string[names.Count];
        names.CopyTo(result);
        Array.Sort(result, StringComparer.OrdinalIgnoreCase);
        return result;
    }

    public static void DeleteFileLink(string path) {
        if (!DeleteFileW(ToExtendedPath(path))) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void DeleteDirectoryLink(string path) {
        if (!RemoveDirectoryW(ToExtendedPath(path))) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
}

if (-not ('PathForgeNtfsNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class PathForgeNtfsVolumeData {
    public long VolumeSerialNumber { get; set; }
    public long NumberSectors { get; set; }
    public long TotalClusters { get; set; }
    public long FreeClusters { get; set; }
    public long TotalReserved { get; set; }
    public uint BytesPerSector { get; set; }
    public uint BytesPerCluster { get; set; }
    public uint BytesPerFileRecordSegment { get; set; }
    public uint ClustersPerFileRecordSegment { get; set; }
    public long MftValidDataLength { get; set; }
    public long MftStartLcn { get; set; }
    public long Mft2StartLcn { get; set; }
    public long MftZoneStart { get; set; }
    public long MftZoneEnd { get; set; }
}

public sealed class PathForgeUsnJournalData {
    public ulong JournalId { get; set; }
    public long FirstUsn { get; set; }
    public long NextUsn { get; set; }
    public long LowestValidUsn { get; set; }
    public long MaxUsn { get; set; }
    public ulong MaximumSize { get; set; }
    public ulong AllocationDelta { get; set; }
    public ushort MinSupportedMajorVersion { get; set; }
    public ushort MaxSupportedMajorVersion { get; set; }
}

public sealed class PathForgeUsnRecordData {
    public ushort MajorVersion { get; set; }
    public ushort MinorVersion { get; set; }
    public string FileReferenceNumber { get; set; }
    public string ParentFileReferenceNumber { get; set; }
    public long Usn { get; set; }
    public DateTime? TimestampUtc { get; set; }
    public uint Reason { get; set; }
    public uint SourceInfo { get; set; }
    public uint SecurityId { get; set; }
    public uint FileAttributes { get; set; }
    public string FileName { get; set; }
}

public sealed class PathForgeUsnReadResult {
    public string Drive { get; set; }
    public PathForgeUsnJournalData Journal { get; set; }
    public long RequestedStartUsn { get; set; }
    public long ResumeUsn { get; set; }
    public int TotalRecordsRead { get; set; }
    public bool WasLimited { get; set; }
    public PathForgeUsnRecordData[] Records { get; set; }
}

public static class PathForgeUsnNative {
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FSCTL_READ_USN_JOURNAL = 0x000900BB;
    private const uint FSCTL_QUERY_USN_JOURNAL = 0x000900F4;
    private const int ERROR_HANDLE_EOF = 38;
    private const int ERROR_JOURNAL_DELETE_IN_PROGRESS = 1178;
    private const int ERROR_JOURNAL_NOT_ACTIVE = 1179;
    private const int ERROR_JOURNAL_ENTRY_DELETED = 1181;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    private static extern bool DeviceIoControlBuffer(
        SafeFileHandle device,
        uint controlCode,
        byte[] inputBuffer,
        int inputBufferSize,
        byte[] outputBuffer,
        int outputBufferSize,
        out int bytesReturned,
        IntPtr overlapped);

    private static string NormalizeDrive(string drive) {
        if (String.IsNullOrWhiteSpace(drive)) {
            throw new ArgumentException("A drive in X: format is required.", "drive");
        }
        string normalized = drive.Trim().TrimEnd('\\');
        if (normalized.Length != 2 || normalized[1] != ':' || !Char.IsLetter(normalized[0])) {
            throw new ArgumentException("A drive in X: format is required.", "drive");
        }
        return Char.ToUpperInvariant(normalized[0]) + ":";
    }

    private static SafeFileHandle OpenVolume(string drive) {
        string path = @"\\.\" + NormalizeDrive(drive);
        uint shareMode = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        SafeFileHandle handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, shareMode, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            string detail = new Win32Exception(error).Message;
            throw new Win32Exception(error, "Cannot open " + path + " for USN journal access: " + detail);
        }
        return handle;
    }

    private static Exception JournalException(int error, string operation) {
        if (error == ERROR_JOURNAL_NOT_ACTIVE) {
            return new InvalidOperationException("The NTFS change journal is not active on this volume.");
        }
        if (error == ERROR_JOURNAL_DELETE_IN_PROGRESS) {
            return new InvalidOperationException("The NTFS change journal is currently being deleted.");
        }
        return new Win32Exception(error, operation + " failed: " + new Win32Exception(error).Message);
    }

    private static PathForgeUsnJournalData QueryJournal(SafeFileHandle handle) {
        byte[] output = new byte[96];
        int bytesReturned;
        if (!DeviceIoControlBuffer(handle, FSCTL_QUERY_USN_JOURNAL, null, 0, output, output.Length, out bytesReturned, IntPtr.Zero)) {
            throw JournalException(Marshal.GetLastWin32Error(), "FSCTL_QUERY_USN_JOURNAL");
        }
        if (bytesReturned < 56) {
            throw new InvalidDataException("Windows returned an incomplete USN journal data buffer.");
        }

        PathForgeUsnJournalData data = new PathForgeUsnJournalData {
            JournalId = BitConverter.ToUInt64(output, 0),
            FirstUsn = BitConverter.ToInt64(output, 8),
            NextUsn = BitConverter.ToInt64(output, 16),
            LowestValidUsn = BitConverter.ToInt64(output, 24),
            MaxUsn = BitConverter.ToInt64(output, 32),
            MaximumSize = BitConverter.ToUInt64(output, 40),
            AllocationDelta = BitConverter.ToUInt64(output, 48),
            MinSupportedMajorVersion = bytesReturned >= 60 ? BitConverter.ToUInt16(output, 56) : (ushort)2,
            MaxSupportedMajorVersion = bytesReturned >= 60 ? BitConverter.ToUInt16(output, 58) : (ushort)2
        };
        return data;
    }

    private static string ReadFileId(byte[] buffer, int offset, int byteCount) {
        if (byteCount == 8) {
            return BitConverter.ToUInt64(buffer, offset).ToString("X16");
        }
        byte[] raw = new byte[byteCount];
        Buffer.BlockCopy(buffer, offset, raw, 0, byteCount);
        Array.Reverse(raw);
        StringBuilder builder = new StringBuilder(byteCount * 2);
        foreach (byte value in raw) {
            builder.Append(value.ToString("X2"));
        }
        return builder.ToString();
    }

    public static PathForgeUsnRecordData[] ParseRecordBuffer(byte[] buffer, int bytesReturned) {
        if (buffer == null) {
            throw new ArgumentNullException("buffer");
        }
        if (bytesReturned < 8 || bytesReturned > buffer.Length) {
            throw new InvalidDataException("The USN record buffer length is invalid.");
        }

        List<PathForgeUsnRecordData> records = new List<PathForgeUsnRecordData>();
        int offset = 8;
        while (offset < bytesReturned) {
            if (bytesReturned - offset < 8) {
                throw new InvalidDataException("Windows returned a truncated USN record header.");
            }
            uint recordLength = BitConverter.ToUInt32(buffer, offset);
            if (recordLength == 0) {
                break;
            }
            if (recordLength > Int32.MaxValue || offset + (long)recordLength > bytesReturned) {
                throw new InvalidDataException("A USN record extends beyond the returned buffer.");
            }

            ushort majorVersion = BitConverter.ToUInt16(buffer, offset + 4);
            ushort minorVersion = BitConverter.ToUInt16(buffer, offset + 6);
            int minimumLength;
            int fileIdOffset;
            int parentIdOffset;
            int fileIdLength;
            int usnOffset;
            int timestampOffset;
            int reasonOffset;
            int sourceOffset;
            int securityOffset;
            int attributesOffset;
            int fileNameLengthOffset;
            int fileNameOffsetOffset;

            if (majorVersion == 2) {
                minimumLength = 60;
                fileIdOffset = 8;
                parentIdOffset = 16;
                fileIdLength = 8;
                usnOffset = 24;
                timestampOffset = 32;
                reasonOffset = 40;
                sourceOffset = 44;
                securityOffset = 48;
                attributesOffset = 52;
                fileNameLengthOffset = 56;
                fileNameOffsetOffset = 58;
            }
            else if (majorVersion == 3) {
                minimumLength = 76;
                fileIdOffset = 8;
                parentIdOffset = 24;
                fileIdLength = 16;
                usnOffset = 40;
                timestampOffset = 48;
                reasonOffset = 56;
                sourceOffset = 60;
                securityOffset = 64;
                attributesOffset = 68;
                fileNameLengthOffset = 72;
                fileNameOffsetOffset = 74;
            }
            else {
                offset += (int)recordLength;
                continue;
            }

            if (recordLength < minimumLength) {
                throw new InvalidDataException("Windows returned an undersized USN version " + majorVersion + " record.");
            }
            ushort fileNameLength = BitConverter.ToUInt16(buffer, offset + fileNameLengthOffset);
            ushort fileNameOffset = BitConverter.ToUInt16(buffer, offset + fileNameOffsetOffset);
            if ((fileNameLength & 1) != 0 || fileNameOffset < minimumLength || fileNameOffset + (long)fileNameLength > recordLength) {
                throw new InvalidDataException("A USN record contains an invalid file-name range.");
            }

            long fileTime = BitConverter.ToInt64(buffer, offset + timestampOffset);
            DateTime? timestamp = null;
            if (fileTime > 0) {
                try { timestamp = DateTime.FromFileTimeUtc(fileTime); }
                catch (ArgumentOutOfRangeException) { timestamp = null; }
            }

            records.Add(new PathForgeUsnRecordData {
                MajorVersion = majorVersion,
                MinorVersion = minorVersion,
                FileReferenceNumber = ReadFileId(buffer, offset + fileIdOffset, fileIdLength),
                ParentFileReferenceNumber = ReadFileId(buffer, offset + parentIdOffset, fileIdLength),
                Usn = BitConverter.ToInt64(buffer, offset + usnOffset),
                TimestampUtc = timestamp,
                Reason = BitConverter.ToUInt32(buffer, offset + reasonOffset),
                SourceInfo = BitConverter.ToUInt32(buffer, offset + sourceOffset),
                SecurityId = BitConverter.ToUInt32(buffer, offset + securityOffset),
                FileAttributes = BitConverter.ToUInt32(buffer, offset + attributesOffset),
                FileName = Encoding.Unicode.GetString(buffer, offset + fileNameOffset, fileNameLength)
            });
            offset += (int)recordLength;
        }
        return records.ToArray();
    }

    public static PathForgeUsnReadResult ReadJournal(string drive, long scanBytes, int maxRecords, uint reasonMask, bool returnOnlyOnClose) {
        string normalized = NormalizeDrive(drive);
        if (scanBytes < 1024 * 1024) {
            throw new ArgumentOutOfRangeException("scanBytes", "The journal scan window must be at least 1 MB.");
        }
        if (maxRecords < 1 || maxRecords > 50000) {
            throw new ArgumentOutOfRangeException("maxRecords", "The record limit must be between 1 and 50,000.");
        }

        using (SafeFileHandle handle = OpenVolume(normalized)) {
            PathForgeUsnJournalData journal = QueryJournal(handle);
            long requestedStart = Math.Max(journal.FirstUsn, journal.NextUsn - scanBytes);
            long cursor = requestedStart;
            int totalRecordsRead = 0;
            Queue<PathForgeUsnRecordData> retained = new Queue<PathForgeUsnRecordData>(maxRecords);
            byte[] output = new byte[1024 * 1024];

            for (int requestIndex = 0; requestIndex < 1024 && cursor < journal.NextUsn; requestIndex++) {
                byte[] input = new byte[48];
                Buffer.BlockCopy(BitConverter.GetBytes(cursor), 0, input, 0, 8);
                Buffer.BlockCopy(BitConverter.GetBytes(reasonMask), 0, input, 8, 4);
                Buffer.BlockCopy(BitConverter.GetBytes(returnOnlyOnClose ? 1u : 0u), 0, input, 12, 4);
                Buffer.BlockCopy(BitConverter.GetBytes(journal.JournalId), 0, input, 32, 8);
                Buffer.BlockCopy(BitConverter.GetBytes((ushort)2), 0, input, 40, 2);
                Buffer.BlockCopy(BitConverter.GetBytes((ushort)3), 0, input, 42, 2);

                int bytesReturned;
                bool success = DeviceIoControlBuffer(
                    handle,
                    FSCTL_READ_USN_JOURNAL,
                    input,
                    input.Length,
                    output,
                    output.Length,
                    out bytesReturned,
                    IntPtr.Zero);
                int error = success ? 0 : Marshal.GetLastWin32Error();
                if (!success && error == ERROR_HANDLE_EOF) {
                    break;
                }
                if (!success && error == ERROR_JOURNAL_ENTRY_DELETED && cursor != journal.FirstUsn) {
                    cursor = journal.FirstUsn;
                    requestedStart = cursor;
                    continue;
                }
                if (!success) {
                    throw JournalException(error, "FSCTL_READ_USN_JOURNAL");
                }
                if (bytesReturned < 8) {
                    throw new InvalidDataException("Windows returned an incomplete USN journal read buffer.");
                }

                long nextCursor = BitConverter.ToInt64(output, 0);
                foreach (PathForgeUsnRecordData record in ParseRecordBuffer(output, bytesReturned)) {
                    totalRecordsRead++;
                    if (retained.Count == maxRecords) {
                        retained.Dequeue();
                    }
                    retained.Enqueue(record);
                }
                if (nextCursor <= cursor) {
                    break;
                }
                cursor = nextCursor;
            }

            return new PathForgeUsnReadResult {
                Drive = normalized,
                Journal = journal,
                RequestedStartUsn = requestedStart,
                ResumeUsn = cursor,
                TotalRecordsRead = totalRecordsRead,
                WasLimited = totalRecordsRead > retained.Count,
                Records = retained.ToArray()
            };
        }
    }
}

public sealed class PathForgeFileExtent {
    public long StartingVcn { get; set; }
    public long NextVcn { get; set; }
    public long Lcn { get; set; }
}

public static class PathForgeNtfsNative {
    private const uint GENERIC_READ = 0x80000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FSCTL_GET_NTFS_VOLUME_DATA = 0x00090064;
    private const uint FSCTL_GET_RETRIEVAL_POINTERS = 0x00090073;
    private const int ERROR_HANDLE_EOF = 38;
    private const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeNtfsVolumeData {
        public long VolumeSerialNumber;
        public long NumberSectors;
        public long TotalClusters;
        public long FreeClusters;
        public long TotalReserved;
        public uint BytesPerSector;
        public uint BytesPerCluster;
        public uint BytesPerFileRecordSegment;
        public uint ClustersPerFileRecordSegment;
        public long MftValidDataLength;
        public long MftStartLcn;
        public long Mft2StartLcn;
        public long MftZoneStart;
        public long MftZoneEnd;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint controlCode,
        IntPtr inputBuffer,
        int inputBufferSize,
        out NativeNtfsVolumeData outputBuffer,
        int outputBufferSize,
        out int bytesReturned,
        IntPtr overlapped);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    private static extern bool DeviceIoControlBuffer(
        SafeFileHandle device,
        uint controlCode,
        byte[] inputBuffer,
        int inputBufferSize,
        byte[] outputBuffer,
        int outputBufferSize,
        out int bytesReturned,
        IntPtr overlapped);

    private static string NormalizeDrive(string drive) {
        if (String.IsNullOrWhiteSpace(drive)) {
            throw new ArgumentException("A drive in X: format is required.", "drive");
        }
        string normalized = drive.Trim().TrimEnd('\\');
        if (normalized.Length != 2 || normalized[1] != ':' || !Char.IsLetter(normalized[0])) {
            throw new ArgumentException("A drive in X: format is required.", "drive");
        }
        return Char.ToUpperInvariant(normalized[0]) + ":";
    }

    private static SafeFileHandle OpenHandle(string path, uint flags) {
        uint shareMode = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        SafeFileHandle handle = CreateFileW(path, GENERIC_READ, shareMode, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        if (!handle.IsInvalid) {
            return handle;
        }

        handle.Dispose();
        handle = CreateFileW(path, 0, shareMode, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Cannot open " + path);
        }
        return handle;
    }

    public static PathForgeNtfsVolumeData GetVolumeData(string drive) {
        string normalized = NormalizeDrive(drive);
        string volumePath = @"\\.\" + normalized;
        using (SafeFileHandle handle = OpenHandle(volumePath, 0)) {
            NativeNtfsVolumeData nativeData;
            int bytesReturned;
            int outputSize = Marshal.SizeOf(typeof(NativeNtfsVolumeData));
            if (!DeviceIoControl(
                    handle,
                    FSCTL_GET_NTFS_VOLUME_DATA,
                    IntPtr.Zero,
                    0,
                    out nativeData,
                    outputSize,
                    out bytesReturned,
                    IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "FSCTL_GET_NTFS_VOLUME_DATA failed");
            }
            if (bytesReturned < outputSize) {
                throw new InvalidDataException("Windows returned an incomplete NTFS volume data buffer.");
            }

            return new PathForgeNtfsVolumeData {
                VolumeSerialNumber = nativeData.VolumeSerialNumber,
                NumberSectors = nativeData.NumberSectors,
                TotalClusters = nativeData.TotalClusters,
                FreeClusters = nativeData.FreeClusters,
                TotalReserved = nativeData.TotalReserved,
                BytesPerSector = nativeData.BytesPerSector,
                BytesPerCluster = nativeData.BytesPerCluster,
                BytesPerFileRecordSegment = nativeData.BytesPerFileRecordSegment,
                ClustersPerFileRecordSegment = nativeData.ClustersPerFileRecordSegment,
                MftValidDataLength = nativeData.MftValidDataLength,
                MftStartLcn = nativeData.MftStartLcn,
                Mft2StartLcn = nativeData.Mft2StartLcn,
                MftZoneStart = nativeData.MftZoneStart,
                MftZoneEnd = nativeData.MftZoneEnd
            };
        }
    }

    public static PathForgeFileExtent[] GetFileExtents(string path) {
        if (String.IsNullOrWhiteSpace(path)) {
            throw new ArgumentException("A file path is required.", "path");
        }

        string fullPath = Path.GetFullPath(path);
        if (!fullPath.StartsWith(@"\\?\", StringComparison.Ordinal)) {
            fullPath = @"\\?\" + fullPath;
        }

        using (SafeFileHandle handle = OpenHandle(fullPath, FILE_FLAG_BACKUP_SEMANTICS)) {
            List<PathForgeFileExtent> extents = new List<PathForgeFileExtent>();
            long requestedVcn = 0;
            byte[] output = new byte[1024 * 1024];

            for (int requestIndex = 0; requestIndex < 128; requestIndex++) {
                byte[] input = BitConverter.GetBytes(requestedVcn);
                int bytesReturned;
                bool success = DeviceIoControlBuffer(
                    handle,
                    FSCTL_GET_RETRIEVAL_POINTERS,
                    input,
                    input.Length,
                    output,
                    output.Length,
                    out bytesReturned,
                    IntPtr.Zero);
                int error = success ? 0 : Marshal.GetLastWin32Error();

                if (!success && error == ERROR_HANDLE_EOF && bytesReturned == 0) {
                    break;
                }
                if (!success && error != ERROR_MORE_DATA) {
                    throw new Win32Exception(error, "FSCTL_GET_RETRIEVAL_POINTERS failed");
                }
                if (bytesReturned < 16) {
                    throw new InvalidDataException("Windows returned an incomplete retrieval-pointers buffer.");
                }

                uint extentCount = BitConverter.ToUInt32(output, 0);
                long currentVcn = BitConverter.ToInt64(output, 8);
                long requiredBytes = 16L + (long)extentCount * 16L;
                if (requiredBytes > bytesReturned) {
                    throw new InvalidDataException("The retrieval-pointers extent count exceeds the returned buffer.");
                }

                for (uint extentIndex = 0; extentIndex < extentCount; extentIndex++) {
                    int offset = 16 + (int)extentIndex * 16;
                    long nextVcn = BitConverter.ToInt64(output, offset);
                    long lcn = BitConverter.ToInt64(output, offset + 8);
                    long effectiveStart = Math.Max(currentVcn, requestedVcn);
                    if (nextVcn > effectiveStart) {
                        long effectiveLcn = lcn < 0 ? lcn : lcn + (effectiveStart - currentVcn);
                        extents.Add(new PathForgeFileExtent {
                            StartingVcn = effectiveStart,
                            NextVcn = nextVcn,
                            Lcn = effectiveLcn
                        });
                    }
                    currentVcn = nextVcn;
                }

                if (success) {
                    return extents.ToArray();
                }
                if (currentVcn <= requestedVcn) {
                    throw new InvalidDataException("Retrieval-pointer pagination did not advance.");
                }
                requestedVcn = currentVcn;
            }

            if (extents.Count == 0) {
                throw new InvalidDataException("No allocated extents were returned for the file.");
            }
            return extents.ToArray();
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

    try {
        $targetItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return @{Success = $false; Error = 'Recycle Bin is skipped for reparse points; use link-only safe deletion.' }
        }
        if (-not $PSCmdlet.ShouldProcess($Path, 'Move to the Recycle Bin')) {
            return @{Success = $true; Method = 'WhatIf: Recycle Bin'; Simulated = $true }
        }
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

function ConvertFrom-PathForgeReparseTarget {
    param(
        [AllowNull()][string]$Target,
        [bool]$IsRelative = $false
    )

    if ([string]::IsNullOrWhiteSpace($Target) -or $IsRelative) {
        return $Target
    }
    if ($Target.StartsWith('\??\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Target.Substring(8)
    }
    if ($Target.StartsWith('\??\Volume{', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\?\' + $Target.Substring(4)
    }
    if ($Target.StartsWith('\??\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Target.Substring(4)
    }
    if ($Target.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Target.Substring(8)
    }
    return $Target
}

function Get-PathForgeReparseTagName {
    param([uint32]$Tag)

    switch ('{0:X8}' -f $Tag) {
        'A0000003' { return 'Mount Point' }
        'A000000C' { return 'Symbolic Link' }
        '80000007' { return 'Single Instance Storage' }
        '80000008' { return 'WIM' }
        '8000000A' { return 'DFS' }
        '80000012' { return 'DFSR' }
        '80000013' { return 'Windows Overlay Filter' }
        '8000001B' { return 'App Execution Link' }
        default { return 'Other Reparse Point' }
    }
}

function Get-PathForgeLinkInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return [PSCustomObject]@{Success = $false; Path = $Path; Error = $check.Reason }
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{Success = $false; Path = $Path; Error = $_.Exception.Message }
    }

    $isDirectory = [bool]$item.PSIsContainer
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $kind = if ($isDirectory) { 'Directory' } else { 'File' }
    $tag = [uint32]0
    $tagHex = $null
    $tagName = $null
    $target = $null
    $rawTarget = $null
    $isRelative = $false
    $hardLinkPaths = @()
    $inspectionWarning = $null
    $isSafeLinkReparsePoint = $false

    if ($isReparsePoint) {
        try {
            $nativeInfo = [PathForgeLinkNative]::GetReparseInfo($item.FullName)
            $tag = [uint32]$nativeInfo.Tag
            $tagHex = '0x{0:X8}' -f $tag
            $tagName = Get-PathForgeReparseTagName -Tag $tag
            $isRelative = [bool]$nativeInfo.IsRelative
            $rawTarget = if (-not [string]::IsNullOrWhiteSpace($nativeInfo.PrintName)) {
                [string]$nativeInfo.PrintName
            }
            else {
                [string]$nativeInfo.SubstituteName
            }
            $target = ConvertFrom-PathForgeReparseTarget -Target $rawTarget -IsRelative $isRelative

            if ($tagHex -eq '0xA000000C') {
                $kind = if ($isDirectory) { 'Directory Symbolic Link' } else { 'File Symbolic Link' }
            }
            elseif ($tagHex -eq '0xA0000003') {
                $kind = if ($target -match '^(?:\\\\\?\\)?Volume\{') { 'Volume Mount Point' } else { 'Junction' }
            }
            else {
                $kind = $tagName
            }
            $isSafeLinkReparsePoint = $tagHex -in @('0xA0000003', '0xA000000C')
        }
        catch {
            $kind = 'Unknown Reparse Point'
            $inspectionWarning = $_.Exception.Message
        }
    }
    elseif (-not $isDirectory) {
        try {
            $hardLinkPaths = @([PathForgeLinkNative]::GetHardLinkNames($item.FullName))
            if ($hardLinkPaths.Count -gt 1) {
                $kind = 'Hard Link'
            }
        }
        catch {
            $inspectionWarning = $_.Exception.Message
        }
    }

    return [PSCustomObject]@{
        Success           = $true
        Path              = $item.FullName
        Name              = $item.Name
        Kind              = $kind
        IsDirectory       = $isDirectory
        IsReparsePoint    = $isReparsePoint
        ReparseTag        = $tag
        ReparseTagHex     = $tagHex
        ReparseTagName    = $tagName
        Target            = $target
        RawTarget         = $rawTarget
        IsRelativeTarget  = $isRelative
        HardLinkCount     = $hardLinkPaths.Count
        HardLinkPaths     = $hardLinkPaths
        CanSafeDeleteLink = $isSafeLinkReparsePoint -or $hardLinkPaths.Count -gt 1
        Warning           = $inspectionWarning
        Error             = $null
    }
}

function Find-PathForgeReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 1000000)][int]$MaxItems = 10000,
        [ValidateRange(0, 1024)][int]$MaxDepth = 64
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return [PSCustomObject]@{Success = $false; RootPath = $Path; Items = @(); ScannedCount = 0; Truncated = $false; Errors = @($check.Reason); Error = $check.Reason }
    }

    try {
        $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{Success = $false; RootPath = $Path; Items = @(); ScannedCount = 0; Truncated = $false; Errors = @($_.Exception.Message); Error = $_.Exception.Message }
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $rootIsReparse = ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($rootIsReparse) {
        $rootInfo = Get-PathForgeLinkInfo -Path $rootItem.FullName
        if ($rootInfo.Success) { $results.Add($rootInfo) } else { $errors.Add($rootInfo.Error) }
        return [PSCustomObject]@{Success = $true; RootPath = $rootItem.FullName; Items = $results.ToArray(); ScannedCount = 1; Truncated = $false; Errors = $errors.ToArray(); Error = $null }
    }
    if (-not $rootItem.PSIsContainer) {
        return [PSCustomObject]@{Success = $true; RootPath = $rootItem.FullName; Items = @(); ScannedCount = 1; Truncated = $false; Errors = @(); Error = $null }
    }

    $directories = New-Object 'System.Collections.Generic.Queue[object]'
    $directories.Enqueue([PSCustomObject]@{Path = $rootItem.FullName; Depth = 0 })
    $scannedCount = 0
    $truncated = $false

    while ($directories.Count -gt 0 -and -not $truncated) {
        $current = $directories.Dequeue()
        try {
            $children = @(Get-ChildItem -LiteralPath $current.Path -Force -ErrorAction Stop)
        }
        catch {
            $errors.Add("$($current.Path): $($_.Exception.Message)")
            continue
        }

        foreach ($child in $children) {
            $scannedCount++
            if ($scannedCount -gt $MaxItems) {
                $truncated = $true
                break
            }

            $childIsReparse = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($childIsReparse) {
                $linkInfo = Get-PathForgeLinkInfo -Path $child.FullName
                if ($linkInfo.Success) { $results.Add($linkInfo) } else { $errors.Add("$($child.FullName): $($linkInfo.Error)") }
                continue
            }
            if ($child.PSIsContainer -and $current.Depth -lt $MaxDepth) {
                $directories.Enqueue([PSCustomObject]@{Path = $child.FullName; Depth = $current.Depth + 1 })
            }
        }
    }

    return [PSCustomObject]@{
        Success      = $true
        RootPath     = $rootItem.FullName
        Items        = $results.ToArray()
        ScannedCount = [Math]::Min($scannedCount, $MaxItems)
        Truncated    = $truncated
        Errors       = $errors.ToArray()
        Error        = $null
    }
}

function Remove-PathForgeLinkSafe {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Path)

    $info = Get-PathForgeLinkInfo -Path $Path
    if (-not $info.Success) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $Path; Kind = $null; Error = $info.Error }
    }
    if (-not $info.CanSafeDeleteLink) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $info.Path; Kind = $info.Kind; Error = 'The selected path is not a reparse point or a file with multiple hard links.' }
    }

    $action = if ($info.IsReparsePoint) { 'Remove the link without traversing its target' } else { 'Remove only this hard-link directory entry' }
    if (-not $PSCmdlet.ShouldProcess($info.Path, $action)) {
        return [PSCustomObject]@{Success = $true; Simulated = $true; Path = $info.Path; Kind = $info.Kind; Error = $null }
    }

    try {
        if ($info.IsDirectory) {
            [PathForgeLinkNative]::DeleteDirectoryLink($info.Path)
        }
        else {
            [PathForgeLinkNative]::DeleteFileLink($info.Path)
        }
        $remainingItem = Get-Item -LiteralPath $info.Path -Force -ErrorAction SilentlyContinue
        if ($remainingItem) {
            return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $info.Path; Kind = $info.Kind; Error = 'Windows reported success but the selected link still exists.' }
        }
        return [PSCustomObject]@{Success = $true; Simulated = $false; Path = $info.Path; Kind = $info.Kind; Error = $null }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $info.Path; Kind = $info.Kind; Error = $_.Exception.Message }
    }
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

    $info = Get-PathForgeLinkInfo -Path $Path
    if (-not $info.Success -or -not $info.IsReparsePoint) {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($info.Path, 'Remove the reparse point without traversing its target')) {
        return $true
    }
    $result = Remove-PathForgeLinkSafe -Path $info.Path -Confirm:$false
    return [bool]$result.Success
}

function Test-PathForgePathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath
    )

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($RootPath)
    $trimCharacters = [char[]]@('\', '/')
    $candidateComparable = $candidate.TrimEnd($trimCharacters)
    $rootComparable = $root.TrimEnd($trimCharacters)

    if ($candidateComparable.Equals($rootComparable, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootPrefix = $root
    if (-not $rootPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString())) {
        $rootPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    return $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PathForgeQuarantineRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        throw $check.Reason
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw "Cannot determine the filesystem root for $Path"
    }
    return [System.IO.Path]::Combine($volumeRoot, $Script:PathForgeQuarantineDirectoryName)
}

function Get-PathForgeQuarantinePolicyPath {
    param([string]$ConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return [System.IO.Path]::GetFullPath($ConfigPath)
    }

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:TEMP
    }
    return [System.IO.Path]::Combine($localAppData, 'PathForge', 'quarantine-policy.json')
}

function Write-PathForgeJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        throw "Cannot determine the parent directory for $Path"
    }
    $null = [System.IO.Directory]::CreateDirectory($parentPath)

    $temporaryPath = [System.IO.Path]::Combine(
        $parentPath,
        ".pathforge-$([Guid]::NewGuid().ToString('N')).tmp")
    $backupPath = [System.IO.Path]::Combine(
        $parentPath,
        ".pathforge-$([Guid]::NewGuid().ToString('N')).bak")
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = $Value | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
}

function Get-PathForgeQuarantinePolicy {
    [CmdletBinding()]
    param([string]$ConfigPath)

    $policyPath = Get-PathForgeQuarantinePolicyPath -ConfigPath $ConfigPath
    $defaultRetentionDays = 30
    if (-not [System.IO.File]::Exists($policyPath)) {
        return [PSCustomObject]@{
            Success       = $true
            ConfigPath    = $policyPath
            RetentionDays = $defaultRetentionDays
            IsDefault     = $true
            Error         = $null
        }
    }

    try {
        $policy = Get-Content -Raw -LiteralPath $policyPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        [int]$retentionDays = $policy.RetentionDays
        if ($retentionDays -lt 1 -or $retentionDays -gt 3650) {
            throw 'RetentionDays must be between 1 and 3650.'
        }
        return [PSCustomObject]@{
            Success       = $true
            ConfigPath    = $policyPath
            RetentionDays = $retentionDays
            IsDefault     = $false
            Error         = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Success       = $false
            ConfigPath    = $policyPath
            RetentionDays = $defaultRetentionDays
            IsDefault     = $true
            Error         = $_.Exception.Message
        }
    }
}

function Set-PathForgeQuarantinePolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 3650)][int]$RetentionDays,
        [string]$ConfigPath
    )

    $policyPath = Get-PathForgeQuarantinePolicyPath -ConfigPath $ConfigPath
    if (-not $PSCmdlet.ShouldProcess($policyPath, "Set quarantine retention to $RetentionDays day(s)")) {
        return [PSCustomObject]@{Success = $true; Simulated = $true; ConfigPath = $policyPath; RetentionDays = $RetentionDays; Error = $null }
    }

    try {
        $policy = [ordered]@{
            SchemaVersion = $Script:PathForgeQuarantineSchemaVersion
            RetentionDays = $RetentionDays
            UpdatedAtUtc  = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Write-PathForgeJsonAtomic -Path $policyPath -Value $policy
        return [PSCustomObject]@{Success = $true; Simulated = $false; ConfigPath = $policyPath; RetentionDays = $RetentionDays; Error = $null }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; ConfigPath = $policyPath; RetentionDays = $RetentionDays; Error = $_.Exception.Message }
    }
}

function Get-PathForgeQuarantineRootList {
    param([string[]]$RootPath)

    $roots = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($PSBoundParameters.ContainsKey('RootPath')) {
        foreach ($candidateRoot in @($RootPath)) {
            if ([string]::IsNullOrWhiteSpace($candidateRoot)) { continue }
            $fullRoot = [System.IO.Path]::GetFullPath($candidateRoot)
            if ([System.IO.Directory]::Exists($fullRoot)) {
                $rootItem = Get-Item -LiteralPath $fullRoot -Force -ErrorAction SilentlyContinue
                if (-not $rootItem -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Write-Verbose "Skipping missing or reparse-point quarantine root: $fullRoot"
                    continue
                }
                $null = $roots.Add($fullRoot)
            }
        }
    }
    else {
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace([string]$drive.Root)) { continue }
            try {
                $candidateRoot = [System.IO.Path]::Combine([string]$drive.Root, $Script:PathForgeQuarantineDirectoryName)
                if ([System.IO.Directory]::Exists($candidateRoot)) {
                    $rootItem = Get-Item -LiteralPath $candidateRoot -Force -ErrorAction SilentlyContinue
                    if ($rootItem -and ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $null = $roots.Add([System.IO.Path]::GetFullPath($candidateRoot))
                    }
                }
            }
            catch {
                Write-Verbose "Cannot inspect quarantine root for drive $($drive.Name): $_"
            }
        }
    }

    return @($roots)
}

function Initialize-PathForgeQuarantineRoot {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [switch]$HardenAccess
    )

    $fullRoot = [System.IO.Path]::GetFullPath($RootPath)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullRoot)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $fullRoot.TrimEnd([char[]]@('\', '/')).Equals($volumeRoot.TrimEnd([char[]]@('\', '/')), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The quarantine root cannot be a filesystem root.'
    }

    $null = [System.IO.Directory]::CreateDirectory($fullRoot)
    $rootItem = Get-Item -LiteralPath $fullRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The quarantine root cannot be a reparse point.'
    }

    $warning = $null
    if ($HardenAccess) {
        try {
            [System.IO.File]::SetAttributes($fullRoot, $rootItem.Attributes -bor [System.IO.FileAttributes]::Hidden)
            $icacls = Get-Command icacls.exe -ErrorAction SilentlyContinue
            if ($icacls) {
                $null = & $icacls.Source $fullRoot '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $warning = "Could not restrict quarantine ACLs (icacls exit code $LASTEXITCODE)."
                }
            }
            else {
                $warning = 'icacls.exe is unavailable; quarantine ACLs were not restricted.'
            }
        }
        catch {
            $warning = "Could not harden quarantine storage: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{RootPath = $fullRoot; Warning = $warning }
}

function Get-PathForgeQuarantineItem {
    [CmdletBinding()]
    param(
        [string[]]$RootPath,
        [ValidateRange(1, 3650)][int]$RetentionDays,
        [string]$ConfigPath
    )

    if (-not $PSBoundParameters.ContainsKey('RetentionDays')) {
        $RetentionDays = (Get-PathForgeQuarantinePolicy -ConfigPath $ConfigPath).RetentionDays
    }
    $roots = if ($PSBoundParameters.ContainsKey('RootPath')) {
        @(Get-PathForgeQuarantineRootList -RootPath $RootPath)
    }
    else {
        @(Get-PathForgeQuarantineRootList)
    }

    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $roots) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            $id = [string]$entry.Name
            if ($id -notmatch '^[A-Fa-f0-9]{32}$') { continue }

            $manifestPath = [System.IO.Path]::Combine($entry.FullName, 'manifest.json')
            $payloadPath = [System.IO.Path]::Combine($entry.FullName, 'payload')
            try {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Quarantine entry directory cannot be a reparse point.'
                }
                $manifest = Get-Content -Raw -LiteralPath $manifestPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ([int]$manifest.SchemaVersion -ne $Script:PathForgeQuarantineSchemaVersion) {
                    throw "Unsupported manifest schema $($manifest.SchemaVersion)."
                }
                if (-not ([string]$manifest.Id).Equals($id, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Manifest ID does not match its quarantine directory.'
                }

                $quarantinedAtUtc = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse(
                        [string]$manifest.QuarantinedAtUtc,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind,
                        [ref]$quarantinedAtUtc)) {
                    throw 'Manifest quarantine timestamp is invalid.'
                }
                if (-not [System.IO.File]::Exists($payloadPath) -and -not [System.IO.Directory]::Exists($payloadPath)) {
                    throw 'Quarantined payload is missing.'
                }
                $payloadItem = Get-Item -LiteralPath $payloadPath -Force -ErrorAction Stop
                if (($payloadItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Quarantined payload cannot be a reparse point.'
                }

                $manifestState = [string]$manifest.State
                $items.Add([PSCustomObject]@{
                        Id                 = $id
                        RootPath           = $root
                        EntryPath          = $entry.FullName
                        PayloadPath        = $payloadPath
                        OriginalPath       = [string]$manifest.OriginalPath
                        OriginalName       = [string]$manifest.OriginalName
                        IsContainer        = [bool]$manifest.IsContainer
                        LengthBytes        = [int64]$manifest.LengthBytes
                        QuarantinedAtUtc   = $quarantinedAtUtc
                        PurgeAfterUtc      = $quarantinedAtUtc.AddDays($RetentionDays)
                        RecordedRetention  = [int]$manifest.RetentionDays
                        Valid              = $manifestState -in @('Quarantined', 'Prepared')
                        Status             = $manifestState
                        Error              = $null
                    })
            }
            catch {
                $items.Add([PSCustomObject]@{
                        Id                 = $id
                        RootPath           = $root
                        EntryPath          = $entry.FullName
                        PayloadPath        = $payloadPath
                        OriginalPath       = '(unavailable)'
                        OriginalName       = $id
                        IsContainer        = $true
                        LengthBytes        = 0
                        QuarantinedAtUtc   = $null
                        PurgeAfterUtc      = $null
                        RecordedRetention  = 0
                        Valid              = $false
                        Status             = 'Invalid'
                        Error              = $_.Exception.Message
                    })
            }
        }
    }

    return @($items.ToArray() | Sort-Object QuarantinedAtUtc -Descending)
}

function Resolve-PathForgeQuarantineEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$RootPath
    )

    if ($Id -notmatch '^[A-Fa-f0-9]{32}$') {
        throw 'A quarantine item ID must be a 32-character hexadecimal GUID.'
    }
    $roots = if ($PSBoundParameters.ContainsKey('RootPath')) {
        @(Get-PathForgeQuarantineRootList -RootPath $RootPath)
    }
    else {
        @(Get-PathForgeQuarantineRootList)
    }

    $matchedEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $roots) {
        $entryPath = [System.IO.Path]::Combine($root, $Id)
        if ([System.IO.Directory]::Exists($entryPath) -and (Test-PathForgePathWithinRoot -Path $entryPath -RootPath $root)) {
            $entryItem = Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
            if (($entryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Quarantine entry directory cannot be a reparse point.'
            }
            $matchedEntries.Add([PSCustomObject]@{RootPath = $root; EntryPath = $entryPath; PayloadPath = [System.IO.Path]::Combine($entryPath, 'payload') })
        }
    }
    if ($matchedEntries.Count -eq 0) {
        throw "Quarantine item not found: $Id"
    }
    if ($matchedEntries.Count -gt 1) {
        throw "Quarantine item ID is ambiguous across storage roots: $Id"
    }
    return $matchedEntries[0]
}

function Invoke-PathForgeTreeRemovalNoFollow {
    param([Parameter(Mandatory)][string]$Path)

    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $rootIsReparse = ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($rootIsReparse) {
        if ($rootItem.PSIsContainer) {
            [PathForgeLinkNative]::DeleteDirectoryLink($rootItem.FullName)
        }
        else {
            [PathForgeLinkNative]::DeleteFileLink($rootItem.FullName)
        }
        return
    }
    if (-not $rootItem.PSIsContainer) {
        [System.IO.File]::SetAttributes($rootItem.FullName, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($rootItem.FullName)
        return
    }

    $directories = New-Object 'System.Collections.Generic.List[string]'
    $leaves = New-Object 'System.Collections.Generic.List[object]'
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $directories.Add($rootItem.FullName)
    $pending.Enqueue($rootItem.FullName)

    while ($pending.Count -gt 0) {
        $directoryPath = $pending.Dequeue()
        foreach ($child in @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)) {
            $isReparse = ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($child.PSIsContainer -and -not $isReparse) {
                $directories.Add($child.FullName)
                $pending.Enqueue($child.FullName)
            }
            else {
                $leaves.Add([PSCustomObject]@{Path = $child.FullName; IsContainer = [bool]$child.PSIsContainer; IsReparse = $isReparse })
            }
        }
    }

    foreach ($leaf in $leaves) {
        if ($leaf.IsReparse) {
            if ($leaf.IsContainer) {
                [PathForgeLinkNative]::DeleteDirectoryLink($leaf.Path)
            }
            else {
                [PathForgeLinkNative]::DeleteFileLink($leaf.Path)
            }
        }
        else {
            [System.IO.File]::SetAttributes($leaf.Path, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($leaf.Path)
        }
    }
    for ($index = $directories.Count - 1; $index -ge 0; $index--) {
        [System.IO.Directory]::Delete($directories[$index], $false)
    }
}

function Move-PathForgeToQuarantine {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RootPath,
        [ValidateRange(1, 3650)][int]$RetentionDays,
        [string]$ConfigPath
    )

    $check = Test-SafePath -Path $Path
    if (-not $check.Valid) {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $Path; Error = $check.Reason }
    }
    try {
        $sourceItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $sourcePath = $sourceItem.FullName
        $sourceVolume = [System.IO.Path]::GetPathRoot($sourcePath)
        if ($sourcePath.TrimEnd([char[]]@('\', '/')).Equals($sourceVolume.TrimEnd([char[]]@('\', '/')), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'A filesystem root cannot be quarantined.'
        }
        if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Reparse points cannot be quarantined; inspect and remove the link with Link Inspector.'
        }

        $rootWasExplicit = $PSBoundParameters.ContainsKey('RootPath')
        $resolvedRoot = if ($rootWasExplicit) {
            [System.IO.Path]::GetFullPath($RootPath)
        }
        else {
            Get-PathForgeQuarantineRoot -Path $sourcePath
        }
        if ((Test-PathForgePathWithinRoot -Path $sourcePath -RootPath $resolvedRoot) -or
            (Test-PathForgePathWithinRoot -Path $resolvedRoot -RootPath $sourcePath)) {
            throw 'The source and quarantine root cannot contain one another.'
        }

        $destinationVolume = [System.IO.Path]::GetPathRoot($resolvedRoot)
        if ($sourceItem.PSIsContainer -and
            -not $sourceVolume.Equals($destinationVolume, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Directories must use a quarantine root on the same volume so the move is complete and non-recursive.'
        }
        if (-not $PSBoundParameters.ContainsKey('RetentionDays')) {
            $policy = Get-PathForgeQuarantinePolicy -ConfigPath $ConfigPath
            if (-not $policy.Success) {
                throw "Quarantine policy is invalid: $($policy.Error)"
            }
            $RetentionDays = $policy.RetentionDays
        }
        if ($RetentionDays -lt 1 -or $RetentionDays -gt 3650) {
            throw 'RetentionDays must be between 1 and 3650.'
        }

        $quarantinedAtUtc = [DateTimeOffset]::UtcNow
        $purgeAfterUtc = $quarantinedAtUtc.AddDays($RetentionDays)
        if (-not $PSCmdlet.ShouldProcess($sourcePath, "Move to quarantine until $($purgeAfterUtc.ToString('u'))")) {
            return [PSCustomObject]@{
                Success = $true; Simulated = $true; Path = $sourcePath; RootPath = $resolvedRoot
                Id = $null; PurgeAfterUtc = $purgeAfterUtc; Method = 'WhatIf: Quarantine'; Error = $null
            }
        }

        $rootState = Initialize-PathForgeQuarantineRoot -RootPath $resolvedRoot -HardenAccess:(-not $rootWasExplicit)
        $id = [Guid]::NewGuid().ToString('N')
        $entryPath = [System.IO.Path]::Combine($resolvedRoot, $id)
        $payloadPath = [System.IO.Path]::Combine($entryPath, 'payload')
        $manifestPath = [System.IO.Path]::Combine($entryPath, 'manifest.json')
        $null = [System.IO.Directory]::CreateDirectory($entryPath)

        $manifest = [ordered]@{
            SchemaVersion        = $Script:PathForgeQuarantineSchemaVersion
            Id                   = $id
            State                = 'Prepared'
            OriginalPath         = $sourcePath
            OriginalName         = $sourceItem.Name
            IsContainer          = [bool]$sourceItem.PSIsContainer
            LengthBytes          = if ($sourceItem.PSIsContainer) { 0 } else { [int64]$sourceItem.Length }
            OriginalAttributes   = [int64]$sourceItem.Attributes
            OriginalLastWriteUtc = $sourceItem.LastWriteTimeUtc.ToString('o')
            QuarantinedAtUtc     = $quarantinedAtUtc.ToString('o')
            RetentionDays        = $RetentionDays
        }
        Write-PathForgeJsonAtomic -Path $manifestPath -Value $manifest

        $moved = $false
        try {
            Move-Item -LiteralPath $sourcePath -Destination $payloadPath -ErrorAction Stop
            $moved = $true
            $manifest.State = 'Quarantined'
            Write-PathForgeJsonAtomic -Path $manifestPath -Value $manifest
        }
        catch {
            $moveError = $_.Exception.Message
            $rollbackError = $null
            if ($moved -and (Test-Path -LiteralPath $payloadPath) -and -not (Test-Path -LiteralPath $sourcePath)) {
                try { Move-Item -LiteralPath $payloadPath -Destination $sourcePath -ErrorAction Stop }
                catch { $rollbackError = $_.Exception.Message }
            }
            if (-not $rollbackError -and (Test-Path -LiteralPath $entryPath)) {
                try { Invoke-PathForgeTreeRemovalNoFollow -Path $entryPath }
                catch { $rollbackError = $_.Exception.Message }
            }
            $detail = if ($rollbackError) { "$moveError Rollback failed: $rollbackError Recovery path: $payloadPath" } else { $moveError }
            throw $detail
        }

        return [PSCustomObject]@{
            Success          = $true
            Simulated        = $false
            Path             = $sourcePath
            OriginalPath     = $sourcePath
            RootPath         = $resolvedRoot
            EntryPath        = $entryPath
            PayloadPath      = $payloadPath
            Id               = $id
            QuarantinedAtUtc = $quarantinedAtUtc
            PurgeAfterUtc    = $purgeAfterUtc
            Method           = 'Quarantine'
            Warning          = $rootState.Warning
            Error            = $null
        }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Path = $Path; Method = 'Quarantine'; Error = $_.Exception.Message }
    }
}

function Restore-PathForgeQuarantineItem {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$RootPath,
        [string]$DestinationPath,
        [string]$ConfigPath
    )

    try {
        $entry = if ($PSBoundParameters.ContainsKey('RootPath')) {
            Resolve-PathForgeQuarantineEntry -Id $Id -RootPath $RootPath
        }
        else {
            Resolve-PathForgeQuarantineEntry -Id $Id
        }
        $items = @(Get-PathForgeQuarantineItem -RootPath $entry.RootPath -ConfigPath $ConfigPath)
        $item = $null
        foreach ($candidateItem in $items) {
            if ($candidateItem.Id -eq $Id) {
                $item = $candidateItem
                break
            }
        }
        if (-not $item -or -not $item.Valid) {
            $reason = if ($item) { $item.Error } else { 'Manifest is unavailable.' }
            throw "Quarantine item cannot be restored: $reason"
        }

        $destination = if ([string]::IsNullOrWhiteSpace($DestinationPath)) { $item.OriginalPath } else { [System.IO.Path]::GetFullPath($DestinationPath) }
        $destinationCheck = Test-SafePath -Path $destination
        if (-not $destinationCheck.Valid) { throw $destinationCheck.Reason }
        if (Test-PathForgePathWithinRoot -Path $destination -RootPath $entry.RootPath) {
            throw 'A quarantined item cannot be restored inside its quarantine root.'
        }
        if (Test-Path -LiteralPath $destination) {
            throw "Restore destination already exists: $destination"
        }
        if ($item.IsContainer -and
            -not ([System.IO.Path]::GetPathRoot($entry.PayloadPath)).Equals([System.IO.Path]::GetPathRoot($destination), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'A quarantined directory must be restored to the same volume.'
        }

        $destinationParent = [System.IO.Path]::GetDirectoryName($destination)
        if ([string]::IsNullOrWhiteSpace($destinationParent)) {
            throw 'Restore destination has no parent directory.'
        }
        if (-not $PSCmdlet.ShouldProcess($destination, "Restore quarantine item $Id")) {
            return [PSCustomObject]@{Success = $true; Simulated = $true; Id = $Id; DestinationPath = $destination; Error = $null }
        }

        $null = [System.IO.Directory]::CreateDirectory($destinationParent)
        Move-Item -LiteralPath $entry.PayloadPath -Destination $destination -ErrorAction Stop
        $warning = $null
        try { Invoke-PathForgeTreeRemovalNoFollow -Path $entry.EntryPath }
        catch { $warning = "Item was restored, but its empty quarantine record could not be removed: $($_.Exception.Message)" }

        return [PSCustomObject]@{Success = $true; Simulated = $false; Id = $Id; DestinationPath = $destination; Warning = $warning; Error = $null }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Id = $Id; DestinationPath = $DestinationPath; Error = $_.Exception.Message }
    }
}

function Remove-PathForgeQuarantineItem {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$RootPath
    )

    try {
        $entry = if ($PSBoundParameters.ContainsKey('RootPath')) {
            Resolve-PathForgeQuarantineEntry -Id $Id -RootPath $RootPath
        }
        else {
            Resolve-PathForgeQuarantineEntry -Id $Id
        }
        if (-not $PSCmdlet.ShouldProcess($entry.EntryPath, "Permanently purge quarantine item $Id")) {
            return [PSCustomObject]@{Success = $true; Simulated = $true; Id = $Id; RootPath = $entry.RootPath; Error = $null }
        }

        Invoke-PathForgeTreeRemovalNoFollow -Path $entry.EntryPath
        return [PSCustomObject]@{Success = $true; Simulated = $false; Id = $Id; RootPath = $entry.RootPath; Error = $null }
    }
    catch {
        return [PSCustomObject]@{Success = $false; Simulated = $false; Id = $Id; RootPath = $RootPath; Error = $_.Exception.Message }
    }
}

function Invoke-PathForgeQuarantineMaintenance {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$RootPath,
        [ValidateRange(1, 3650)][int]$RetentionDays,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [string]$ConfigPath
    )

    if (-not $PSBoundParameters.ContainsKey('RetentionDays')) {
        $policy = Get-PathForgeQuarantinePolicy -ConfigPath $ConfigPath
        if (-not $policy.Success) {
            return [PSCustomObject]@{
                Success = $false; RetentionDays = $policy.RetentionDays; Scanned = 0; Purged = 0
                Simulated = 0; Failed = 0; Invalid = 0; Errors = @("Quarantine policy is invalid: $($policy.Error)")
            }
        }
        $RetentionDays = $policy.RetentionDays
    }
    $items = if ($PSBoundParameters.ContainsKey('RootPath')) {
        @(Get-PathForgeQuarantineItem -RootPath $RootPath -RetentionDays $RetentionDays -ConfigPath $ConfigPath)
    }
    else {
        @(Get-PathForgeQuarantineItem -RetentionDays $RetentionDays -ConfigPath $ConfigPath)
    }

    $purged = 0
    $simulated = 0
    $failed = 0
    $invalid = 0
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $items) {
        if (-not $item.Valid) {
            $invalid++
            continue
        }
        if ($item.Status -ne 'Quarantined') { continue }
        if ($item.PurgeAfterUtc -gt $Now) { continue }

        if (-not $PSCmdlet.ShouldProcess($item.EntryPath, "Auto-purge quarantine item $($item.Id)")) {
            $simulated++
            continue
        }
        $result = Remove-PathForgeQuarantineItem -Id $item.Id -RootPath $item.RootPath -Confirm:$false
        if ($result.Success) {
            $purged++
        }
        else {
            $failed++
            $errors.Add("$($item.Id): $($result.Error)")
        }
    }

    return [PSCustomObject]@{
        Success       = $failed -eq 0
        RetentionDays = $RetentionDays
        Scanned       = $items.Count
        Purged        = $purged
        Simulated     = $simulated
        Failed        = $failed
        Invalid       = $invalid
        Errors        = $errors.ToArray()
    }
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
    $recycleApplicable = [bool]$IncludeRecycleBin -and -not $isReparsePoint
    $recycleReason = if ($isReparsePoint) { 'Skipped for reparse points; inspect and remove the link only' } elseif ($IncludeRecycleBin) { 'Enabled as the first recoverable attempt' } else { 'Recycle Bin option is disabled' }
    $null = & $addMethod 'Recycle Bin' 'Microsoft.VisualBasic.FileIO.FileSystem' $recycleApplicable $recycleReason $true
    $null = & $addMethod 'Reparse Point Removal' 'DeleteFileW / RemoveDirectoryW (link only)' $isReparsePoint $(if ($isReparsePoint) { 'Target is a reparse point; remove recognized links without traversing them' } else { 'Target is not a reparse point' })

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
        quarantine    = 'Quarantine'
        quarantinezone = 'Quarantine'
        boottime      = 'BootTime'
        boot          = 'BootTime'
        reparsepoint  = 'ReparsePoint'
        reparse       = 'ReparsePoint'
        linkonly      = 'ReparsePoint'
    }

    if (-not $aliases.ContainsKey($key)) {
        throw "Unsupported deletion method '$Method'. Use Auto, Standard, DotNet, LongPath, ShortName, Robocopy, WMI, RecycleBin, Quarantine, BootTime, or ReparsePoint."
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
        [ValidateSet('Auto', 'Standard', 'DotNet', 'LongPath', 'ShortName', 'Robocopy', 'WMI', 'RecycleBin', 'Quarantine', 'BootTime', 'ReparsePoint')]
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
        Quarantine   = 'Move-PathForgeToQuarantine'
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
    if (Test-ReparsePoint -Path $Path) {
        $attemptNames.Add('ReparsePoint')
    }
    else {
        if ($IncludeRecycleBin) { $attemptNames.Add('RecycleBin') }
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

function Get-PathForgeNtfsVolumeDataNative {
    param([Parameter(Mandatory)][string]$Drive)
    return [PathForgeNtfsNative]::GetVolumeData($Drive)
}

function Get-PathForgeUsnReasonCatalog {
    [CmdletBinding()]
    param()

    $closeMask = [uint32]::Parse('80000000', [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture)
    return @(
        [PSCustomObject]@{Name = 'Data overwrite'; Mask = [uint32]0x00000001; Group = 'Data' },
        [PSCustomObject]@{Name = 'Data extend'; Mask = [uint32]0x00000002; Group = 'Data' },
        [PSCustomObject]@{Name = 'Data truncate'; Mask = [uint32]0x00000004; Group = 'Data' },
        [PSCustomObject]@{Name = 'Named data overwrite'; Mask = [uint32]0x00000010; Group = 'Data' },
        [PSCustomObject]@{Name = 'Named data extend'; Mask = [uint32]0x00000020; Group = 'Data' },
        [PSCustomObject]@{Name = 'Named data truncate'; Mask = [uint32]0x00000040; Group = 'Data' },
        [PSCustomObject]@{Name = 'File create'; Mask = [uint32]0x00000100; Group = 'Lifecycle' },
        [PSCustomObject]@{Name = 'File delete'; Mask = [uint32]0x00000200; Group = 'Lifecycle' },
        [PSCustomObject]@{Name = 'Extended attributes'; Mask = [uint32]0x00000400; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Security change'; Mask = [uint32]0x00000800; Group = 'Security' },
        [PSCustomObject]@{Name = 'Rename old name'; Mask = [uint32]0x00001000; Group = 'Rename' },
        [PSCustomObject]@{Name = 'Rename new name'; Mask = [uint32]0x00002000; Group = 'Rename' },
        [PSCustomObject]@{Name = 'Indexable change'; Mask = [uint32]0x00004000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Basic info change'; Mask = [uint32]0x00008000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Hard link change'; Mask = [uint32]0x00010000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Compression change'; Mask = [uint32]0x00020000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Encryption change'; Mask = [uint32]0x00040000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Object ID change'; Mask = [uint32]0x00080000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Reparse point change'; Mask = [uint32]0x00100000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Stream change'; Mask = [uint32]0x00200000; Group = 'Data' },
        [PSCustomObject]@{Name = 'Transacted change'; Mask = [uint32]0x00400000; Group = 'Metadata' },
        [PSCustomObject]@{Name = 'Integrity change'; Mask = [uint32]0x00800000; Group = 'Security' },
        [PSCustomObject]@{Name = 'Close'; Mask = $closeMask; Group = 'Lifecycle' }
    )
}

function ConvertTo-PathForgeUsnReasonText {
    param([Parameter(Mandatory)][uint32]$Reason)

    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($definition in Get-PathForgeUsnReasonCatalog) {
        if (($Reason -band [uint32]$definition.Mask) -ne 0) {
            $names.Add([string]$definition.Name)
        }
    }
    if ($names.Count -eq 0) { return ('Unknown (0x{0:X8})' -f $Reason) }
    return $names -join ', '
}

function ConvertTo-PathForgeUsnSourceText {
    param([Parameter(Mandatory)][uint32]$SourceInfo)

    if ($SourceInfo -eq 0) { return 'Application data' }
    $sources = New-Object 'System.Collections.Generic.List[string]'
    if (($SourceInfo -band [uint32]0x00000001) -ne 0) { $sources.Add('Data management') }
    if (($SourceInfo -band [uint32]0x00000002) -ne 0) { $sources.Add('Auxiliary data') }
    if (($SourceInfo -band [uint32]0x00000004) -ne 0) { $sources.Add('Replication management') }
    if (($SourceInfo -band [uint32]0x00000008) -ne 0) { $sources.Add('Client replication') }
    if ($sources.Count -eq 0) { return ('Unknown (0x{0:X8})' -f $SourceInfo) }
    return $sources -join ', '
}

function Get-PathForgeUsnJournalNative {
    param(
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][int64]$ScanBytes,
        [Parameter(Mandatory)][int]$MaxRecords,
        [Parameter(Mandatory)][uint32]$ReasonMask,
        [Parameter(Mandatory)][bool]$ReturnOnlyOnClose
    )
    return [PathForgeUsnNative]::ReadJournal($Drive, $ScanBytes, $MaxRecords, $ReasonMask, $ReturnOnlyOnClose)
}

function Get-PathForgeUsnAuditEvent {
    param(
        [Parameter(Mandatory)][datetime]$StartTimeUtc,
        [Parameter(Mandatory)][datetime]$EndTimeUtc,
        [Parameter(Mandatory)][string]$Drive,
        [ValidateRange(1, 50000)][int]$MaxEvents = 10000
    )

    $filter = @{
        LogName   = 'Security'
        Id        = 4663
        StartTime = $StartTimeUtc.ToLocalTime()
        EndTime   = $EndTimeUtc.ToLocalTime()
    }
    try {
        $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match 'No events were found') {
            return @()
        }
        throw
    }

    $normalizedPrefix = $Drive.TrimEnd(':') + ':\'
    foreach ($eventRecord in $events) {
        try {
            [xml]$eventXml = $eventRecord.ToXml()
            $eventData = @{}
            foreach ($dataNode in @($eventXml.Event.EventData.Data)) {
                $eventData[[string]$dataNode.Name] = [string]$dataNode.'#text'
            }
            if ($eventData.ObjectType -ne 'File' -or
                [string]::IsNullOrWhiteSpace($eventData.ObjectName) -or
                -not $eventData.ObjectName.StartsWith($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            [int64]$processId = 0
            $processIdText = [string]$eventData.ProcessId
            if ($processIdText.StartsWith('0x', [System.StringComparison]::OrdinalIgnoreCase)) {
                [void][int64]::TryParse(
                    $processIdText.Substring(2),
                    [System.Globalization.NumberStyles]::HexNumber,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$processId)
            }
            else {
                [void][int64]::TryParse($processIdText, [ref]$processId)
            }

            [PSCustomObject]@{
                TimeCreatedUtc = $eventRecord.TimeCreated.ToUniversalTime()
                ObjectName     = [string]$eventData.ObjectName
                ProcessId      = $processId
                ProcessPath    = [string]$eventData.ProcessName
                ProcessName    = if ([string]::IsNullOrWhiteSpace($eventData.ProcessName)) { '' } else { [System.IO.Path]::GetFileName($eventData.ProcessName) }
                EventRecordId  = $eventRecord.RecordId
                AccessMask     = [string]$eventData.AccessMask
            }
        }
        catch {
            continue
        }
    }
}

function Get-PathForgeUsnJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Drive,

        [ValidateRange(1, 50000)]
        [int]$MaxRecords = 500,

        [ValidateRange(1, 1024)]
        [int]$ScanMegabytes = 64,

        [uint32]$ReasonMask = [uint32]::MaxValue,

        [switch]$ReturnOnlyOnClose,

        [switch]$IncludeProcessAudit,

        [string]$ProcessName,

        [ValidateRange(1, 30)]
        [int]$CorrelationSeconds = 3
    )

    $normalizedDrive = $Drive.Substring(0, 1).ToUpperInvariant() + ':'
    $fileSystem = Get-VolumeFileSystem -Path "$normalizedDrive\"
    if ($fileSystem -notin @('NTFS', 'Unknown')) {
        return [PSCustomObject]@{
            Success       = $false
            Supported     = $false
            Drive         = $normalizedDrive
            FileSystem    = $fileSystem
            Records       = @()
            AuditStatus   = 'Not requested.'
            Error         = "The USN Journal browser applies only to NTFS volumes; $normalizedDrive uses $fileSystem."
        }
    }

    try {
        $nativeResult = Get-PathForgeUsnJournalNative `
            -Drive $normalizedDrive `
            -ScanBytes ([int64]$ScanMegabytes * 1MB) `
            -MaxRecords $MaxRecords `
            -ReasonMask $ReasonMask `
            -ReturnOnlyOnClose ([bool]$ReturnOnlyOnClose)
        $fileSystem = 'NTFS'
    }
    catch {
        $rootException = $_.Exception
        while ($rootException.InnerException) { $rootException = $rootException.InnerException }
        $message = $rootException.Message
        if (($rootException -is [System.ComponentModel.Win32Exception] -and $rootException.NativeErrorCode -eq 5) -or
            $message -match 'Access is denied|denied access') {
            $message = "Administrator access is required to read the NTFS change journal. $message"
        }
        return [PSCustomObject]@{
            Success       = $false
            Supported     = $fileSystem -eq 'NTFS'
            Drive         = $normalizedDrive
            FileSystem    = $fileSystem
            Records       = @()
            AuditStatus   = 'Not requested.'
            Error         = $message
        }
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rawRecord in @($nativeResult.Records)) {
        $rawReason = [uint32]$rawRecord.Reason
        if ($ReasonMask -ne [uint32]::MaxValue -and ($rawReason -band $ReasonMask) -eq 0) { continue }
        $timestampUtc = if ($null -eq $rawRecord.TimestampUtc) { $null } else { ([datetime]$rawRecord.TimestampUtc).ToUniversalTime() }
        $records.Add([PSCustomObject]@{
                TimeCreatedUtc           = $timestampUtc
                TimeCreated              = if ($timestampUtc) { $timestampUtc.ToLocalTime() } else { $null }
                FileName                 = [string]$rawRecord.FileName
                FileReferenceNumber      = [string]$rawRecord.FileReferenceNumber
                ParentFileReferenceNumber = [string]$rawRecord.ParentFileReferenceNumber
                Usn                       = [int64]$rawRecord.Usn
                Reason                    = $rawReason
                ReasonHex                 = ('0x{0:X8}' -f $rawReason)
                ReasonText                = ConvertTo-PathForgeUsnReasonText -Reason $rawReason
                SourceInfo                = [uint32]$rawRecord.SourceInfo
                SourceText                = ConvertTo-PathForgeUsnSourceText -SourceInfo ([uint32]$rawRecord.SourceInfo)
                SecurityId                = [uint32]$rawRecord.SecurityId
                FileAttributes            = [uint32]$rawRecord.FileAttributes
                FileAttributesText        = ([System.IO.FileAttributes][uint32]$rawRecord.FileAttributes).ToString()
                IsDirectory               = ([uint32]$rawRecord.FileAttributes -band [uint32]0x00000010) -ne 0
                RecordVersion             = "$($rawRecord.MajorVersion).$($rawRecord.MinorVersion)"
                ProcessName               = $null
                ProcessPath               = $null
                ProcessId                 = $null
                ProcessEvidence           = $null
                AuditEventRecordId        = $null
                CorrelationDeltaMilliseconds = $null
            })
    }

    $auditRequested = $IncludeProcessAudit -or -not [string]::IsNullOrWhiteSpace($ProcessName)
    $auditStatus = 'Process correlation was not requested.'
    $auditError = $null
    if ($auditRequested -and $records.Count -gt 0) {
        $timestampedRecords = @($records | Where-Object { $null -ne $_.TimeCreatedUtc })
        if ($timestampedRecords.Count -eq 0) {
            $auditStatus = 'Process correlation is unavailable because these records have no timestamp.'
        }
        else {
            $startTimeUtc = ($timestampedRecords | Measure-Object TimeCreatedUtc -Minimum).Minimum.AddSeconds(-$CorrelationSeconds)
            $endTimeUtc = ($timestampedRecords | Measure-Object TimeCreatedUtc -Maximum).Maximum.AddSeconds($CorrelationSeconds)
            try {
                $maxAuditEvents = [Math]::Min(50000, [Math]::Max(1000, $MaxRecords * 10))
                $auditEvents = @(Get-PathForgeUsnAuditEvent -StartTimeUtc $startTimeUtc -EndTimeUtc $endTimeUtc -Drive $normalizedDrive -MaxEvents $maxAuditEvents)
                $eventsByFileName = @{}
                foreach ($auditEvent in $auditEvents) {
                    $leafName = [System.IO.Path]::GetFileName([string]$auditEvent.ObjectName)
                    if ([string]::IsNullOrWhiteSpace($leafName)) { continue }
                    $key = $leafName.ToUpperInvariant()
                    if (-not $eventsByFileName.ContainsKey($key)) {
                        $eventsByFileName[$key] = New-Object 'System.Collections.Generic.List[object]'
                    }
                    $eventsByFileName[$key].Add($auditEvent)
                }

                foreach ($record in $records) {
                    if ($null -eq $record.TimeCreatedUtc -or [string]::IsNullOrWhiteSpace($record.FileName)) { continue }
                    $key = $record.FileName.ToUpperInvariant()
                    if (-not $eventsByFileName.ContainsKey($key)) { continue }
                    $bestEvent = $null
                    [double]$bestDelta = [double]::MaxValue
                    foreach ($candidate in $eventsByFileName[$key]) {
                        $delta = [Math]::Abs(($candidate.TimeCreatedUtc - $record.TimeCreatedUtc).TotalMilliseconds)
                        if ($delta -le ($CorrelationSeconds * 1000) -and $delta -lt $bestDelta) {
                            $bestDelta = $delta
                            $bestEvent = $candidate
                        }
                    }
                    if ($bestEvent) {
                        $record.ProcessName = $bestEvent.ProcessName
                        $record.ProcessPath = $bestEvent.ProcessPath
                        $record.ProcessId = $bestEvent.ProcessId
                        $record.ProcessEvidence = 'Security 4663 name/time correlation'
                        $record.AuditEventRecordId = $bestEvent.EventRecordId
                        $record.CorrelationDeltaMilliseconds = [Math]::Round($bestDelta)
                    }
                }
                $coverage = @($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ProcessName) }).Count
                if ($auditEvents.Count -eq 0) {
                    $auditStatus = 'No matching Security 4663 events were available. Process attribution requires Audit File System and a matching SACL.'
                }
                else {
                    $auditStatus = "Correlated process evidence for $coverage of $($records.Count) record(s) from Security event 4663."
                }
            }
            catch {
                $auditError = $_.Exception.Message
                $auditStatus = "Process correlation unavailable: $auditError"
            }
        }
    }

    $processCoverage = @($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ProcessName) }).Count
    $filteredRecords = @(
        if ([string]::IsNullOrWhiteSpace($ProcessName)) {
            $records
        }
        else {
            $records | Where-Object {
                ([string]$_.ProcessName).IndexOf($ProcessName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                ([string]$_.ProcessPath).IndexOf($ProcessName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        }
    )

    return [PSCustomObject]@{
        Success            = $true
        Supported          = $true
        Drive              = $normalizedDrive
        FileSystem         = $fileSystem
        QueryTimeUtc       = [DateTimeOffset]::UtcNow
        JournalId          = [uint64]$nativeResult.Journal.JournalId
        FirstUsn           = [int64]$nativeResult.Journal.FirstUsn
        NextUsn            = [int64]$nativeResult.Journal.NextUsn
        LowestValidUsn     = [int64]$nativeResult.Journal.LowestValidUsn
        MaxUsn             = [int64]$nativeResult.Journal.MaxUsn
        MaximumSize        = [uint64]$nativeResult.Journal.MaximumSize
        AllocationDelta    = [uint64]$nativeResult.Journal.AllocationDelta
        MinRecordVersion   = [uint16]$nativeResult.Journal.MinSupportedMajorVersion
        MaxRecordVersion   = [uint16]$nativeResult.Journal.MaxSupportedMajorVersion
        RequestedStartUsn  = [int64]$nativeResult.RequestedStartUsn
        ResumeUsn          = [int64]$nativeResult.ResumeUsn
        ScanMegabytes      = $ScanMegabytes
        ReasonMask         = $ReasonMask
        ReturnOnlyOnClose  = [bool]$ReturnOnlyOnClose
        TotalRecordsRead   = [int]$nativeResult.TotalRecordsRead
        NativeRecordCount  = @($nativeResult.Records).Count
        RecordCount        = $filteredRecords.Count
        WasLimited         = [bool]$nativeResult.WasLimited
        ProcessAuditUsed   = $auditRequested
        ProcessCoverage    = $processCoverage
        ProcessFilter      = $ProcessName
        AuditStatus        = $auditStatus
        AuditError         = $auditError
        Records            = $filteredRecords
        Error              = $null
    }
}

function Get-PathForgeMftExtentNative {
    param([Parameter(Mandatory)][string]$Drive)
    $mftPath = [System.IO.Path]::Combine("$Drive\", '$MFT')
    return @([PathForgeNtfsNative]::GetFileExtents($mftPath))
}

function Get-PathForgeMftReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Drive
    )

    $normalizedDrive = $Drive.Substring(0, 1).ToUpperInvariant() + ':'
    $fileSystem = Get-VolumeFileSystem -Path "$normalizedDrive\"
    if ($fileSystem -notin @('NTFS', 'Unknown')) {
        return [PSCustomObject]@{
            Success            = $false
            Supported          = $false
            Drive              = $normalizedDrive
            FileSystem         = $fileSystem
            ExtentQuerySuccess = $false
            Extents            = @()
            Error              = "The MFT report applies only to NTFS volumes; $normalizedDrive uses $fileSystem."
        }
    }

    try {
        $volumeData = Get-PathForgeNtfsVolumeDataNative -Drive $normalizedDrive
        $fileSystem = 'NTFS'
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'Access is denied|denied access') {
            $message = "Administrator access is required to read native NTFS volume data. $message"
        }
        return [PSCustomObject]@{
            Success            = $false
            Supported          = $fileSystem -eq 'NTFS'
            Drive              = $normalizedDrive
            FileSystem         = $fileSystem
            ExtentQuerySuccess = $false
            Extents            = @()
            Error              = $message
        }
    }

    $extentError = $null
    try {
        $nativeExtents = @(Get-PathForgeMftExtentNative -Drive $normalizedDrive)
        $extentQuerySuccess = $true
    }
    catch {
        $nativeExtents = @()
        $extentQuerySuccess = $false
        $extentError = $_.Exception.Message
        if ($extentError -match 'Access is denied|denied access') {
            $extentError = "Administrator access is required to read the MFT extent map. $extentError"
        }
    }

    $extents = New-Object 'System.Collections.Generic.List[object]'
    [int64]$allocatedClusters = 0
    [int64]$largestExtentClusters = 0
    for ($index = 0; $index -lt $nativeExtents.Count; $index++) {
        $nativeExtent = $nativeExtents[$index]
        [int64]$clusterCount = [Math]::Max(0, ([int64]$nativeExtent.NextVcn - [int64]$nativeExtent.StartingVcn))
        $isSparse = [int64]$nativeExtent.Lcn -lt 0
        if (-not $isSparse) {
            $allocatedClusters += $clusterCount
            $largestExtentClusters = [Math]::Max($largestExtentClusters, $clusterCount)
        }
        $extents.Add([PSCustomObject]@{
                Index           = $index + 1
                LogicalStartVcn = [int64]$nativeExtent.StartingVcn
                LogicalEndVcn   = [int64]$nativeExtent.NextVcn - 1
                PhysicalStartLcn = [int64]$nativeExtent.Lcn
                PhysicalEndLcn  = if ($isSparse) { -1 } else { [int64]$nativeExtent.Lcn + $clusterCount - 1 }
                ClusterCount    = $clusterCount
                LengthBytes     = $clusterCount * [int64]$volumeData.BytesPerCluster
                IsSparse        = $isSparse
            })
    }

    $allocatedExtentCount = @($extents | Where-Object { -not $_.IsSparse }).Count
    $fragmentCount = [Math]::Max(0, $allocatedExtentCount - 1)
    [int64]$mftSizeBytes = [Math]::Max(0, [int64]$volumeData.MftValidDataLength)
    [int64]$allocatedBytes = $allocatedClusters * [int64]$volumeData.BytesPerCluster
    [int64]$volumeBytes = [int64]$volumeData.TotalClusters * [int64]$volumeData.BytesPerCluster
    [int64]$mftZoneClusters = [Math]::Max(0, [int64]$volumeData.MftZoneEnd - [int64]$volumeData.MftZoneStart)
    [int64]$mftZoneBytes = $mftZoneClusters * [int64]$volumeData.BytesPerCluster
    [int64]$estimatedRecordCount = if ($volumeData.BytesPerFileRecordSegment -gt 0) {
        [Math]::Floor($mftSizeBytes / [double]$volumeData.BytesPerFileRecordSegment)
    }
    else { 0 }
    $fragmentationLabel = if (-not $extentQuerySuccess) {
        'Extent map unavailable'
    }
    elseif ($allocatedExtentCount -le 1) {
        'Contiguous (1 extent)'
    }
    else {
        "Fragmented ($allocatedExtentCount extents)"
    }

    return [PSCustomObject]@{
        Success                   = $true
        Supported                 = $true
        Drive                     = $normalizedDrive
        FileSystem                = $fileSystem
        QueryTimeUtc              = [DateTimeOffset]::UtcNow
        VolumeSerialNumber        = [int64]$volumeData.VolumeSerialNumber
        VolumeBytes               = $volumeBytes
        TotalClusters             = [int64]$volumeData.TotalClusters
        FreeClusters              = [int64]$volumeData.FreeClusters
        BytesPerSector            = [uint32]$volumeData.BytesPerSector
        BytesPerCluster           = [uint32]$volumeData.BytesPerCluster
        BytesPerFileRecordSegment = [uint32]$volumeData.BytesPerFileRecordSegment
        MftSizeBytes              = $mftSizeBytes
        MftAllocatedBytes         = $allocatedBytes
        EstimatedRecordCount      = $estimatedRecordCount
        MftStartLcn               = [int64]$volumeData.MftStartLcn
        MftMirrorStartLcn         = [int64]$volumeData.Mft2StartLcn
        MftZoneStartLcn           = [int64]$volumeData.MftZoneStart
        MftZoneEndLcn             = [int64]$volumeData.MftZoneEnd
        MftZoneBytes              = $mftZoneBytes
        ExtentQuerySuccess        = $extentQuerySuccess
        ExtentCount               = $allocatedExtentCount
        FragmentCount             = $fragmentCount
        IsFragmented              = $allocatedExtentCount -gt 1
        FragmentationLabel        = $fragmentationLabel
        LargestExtentBytes        = $largestExtentClusters * [int64]$volumeData.BytesPerCluster
        Extents                   = $extents.ToArray()
        ExtentError               = $extentError
        Error                     = $null
    }
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
    'Get-PathForgeLinkInfo',
    'Find-PathForgeReparsePoint',
    'Remove-PathForgeLinkSafe',
    'Remove-ReparsePointSafe',
    'Get-PathForgeQuarantineRoot',
    'Get-PathForgeQuarantinePolicy',
    'Set-PathForgeQuarantinePolicy',
    'Get-PathForgeQuarantineItem',
    'Move-PathForgeToQuarantine',
    'Restore-PathForgeQuarantineItem',
    'Remove-PathForgeQuarantineItem',
    'Invoke-PathForgeQuarantineMaintenance',
    'Register-BootTimeDelete',
    'Get-PathForgePendingFileQueue',
    'Add-PathForgePendingFileDelete',
    'Remove-PathForgePendingFileOperation',
    'Get-PathForgeDeletionPlan',
    'Import-PathForgeDeletionBatch',
    'Invoke-PathForgeDeletionMethod',
    'Get-PathForgeUsnReasonCatalog',
    'Get-PathForgeUsnJournal',
    'Get-PathForgeMftReport',
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
