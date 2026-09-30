#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$Refspec,
    [Parameter(Mandatory)][string]$OptionsPath,
    [Parameter(Mandatory)][int]$OwnerProcessId,
    [Parameter(Mandatory)][long]$DeadlineMs
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$process = $null
$reason = 'unavailable'
$clock = [Diagnostics.Stopwatch]::StartNew()
$limitMs = [math]::Min(15000, [math]::Max(0,
    $DeadlineMs - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
try {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class HudGitFetchJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong A, B, C, D, E, F; }
    [StructLayout(LayoutKind.Sequential)]
    struct Accounting {
        public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
        public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes {
        public int Length;
        public IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfo {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
        public ushort ShowWindow, ReservedBytes;
        public IntPtr ReservedData, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr Process, Thread; public uint Id, ThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits data, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool present);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int kind,
        out Accounting data, uint size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr attributes, uint count, uint flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr attributes, uint flags, IntPtr kind,
        IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr attributes);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share,
        ref SecurityAttributes attributes, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string application, StringBuilder command,
        IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags,
        IntPtr environment, string cwd, ref StartupInfoEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr job, process;
    static Win32Exception Failure(string step) {
        return new Win32Exception(Marshal.GetLastWin32Error(), step);
    }

    static string Quote(string value) {
        var text = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value) {
            if (character == '\\') { slashes++; continue; }
            text.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
            text.Append(character);
            slashes = 0;
        }
        return text.Append('\\', slashes * 2).Append('"').ToString();
    }
    public static HudGitFetchJob Start(string executable, string[] arguments) {
        var instance = new HudGitFetchJob();
        IntPtr nul = IntPtr.Zero, thread = IntPtr.Zero, attributes = IntPtr.Zero;
        IntPtr jobValue = IntPtr.Zero, handleValue = IntPtr.Zero;
        bool initialized = false;
        try {
            instance.job = CreateJobObjectW(IntPtr.Zero, null);
            if (instance.job == IntPtr.Zero) { throw Failure("job-create"); }
            var limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000; // Kill every job member when the last handle closes.
            if (!SetInformationJobObject(instance.job, 9, ref limits,
                (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) { throw Failure("job-limits"); }
            var security = new SecurityAttributes {
                Length = Marshal.SizeOf(typeof(SecurityAttributes)), Inherit = true
            };
            nul = CreateFileW("NUL", 0xC0000000, 3, ref security, 3, 0x80, IntPtr.Zero);
            if (nul == new IntPtr(-1)) { throw Failure("nul-open"); }
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
            if (size == IntPtr.Zero) { throw Failure("attributes-size"); }
            attributes = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attributes, 2, 0, ref size)) {
                throw Failure("attributes-create");
            }
            initialized = true;
            jobValue = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(jobValue, instance.job);
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x2000D), jobValue,
                new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) { throw Failure("job-attribute"); }
            handleValue = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(handleValue, nul);
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handleValue,
                new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) { throw Failure("handle-attribute"); }
            var startup = new StartupInfoEx {
                Startup = new StartupInfo {
                    Size = Marshal.SizeOf(typeof(StartupInfoEx)), Flags = 0x100,
                    Input = nul, Output = nul, Error = nul
                },
                Attributes = attributes
            };
            var command = new StringBuilder(Quote(executable));
            foreach (string argument in arguments) { command.Append(' ').Append(Quote(argument)); }
            ProcessInfo created;
            // Contain Git at creation; inherit only NUL, never the helper's output pipes.
            if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, true,
                0x08080004, IntPtr.Zero, null, ref startup, out created)) { throw Failure("process-create"); }
            instance.process = created.Process;
            thread = created.Thread;
            bool present;
            if (!IsProcessInJob(instance.process, instance.job, out present) || !present) {
                throw Failure("job-membership");
            }
            if (ResumeThread(thread) == uint.MaxValue) { throw Failure("thread-resume"); }
            return instance;
        } catch { instance.Dispose(); throw; }
        finally {
            if (initialized) { DeleteProcThreadAttributeList(attributes); }
            if (attributes != IntPtr.Zero) { Marshal.FreeHGlobal(attributes); }
            if (jobValue != IntPtr.Zero) { Marshal.FreeHGlobal(jobValue); }
            if (handleValue != IntPtr.Zero) { Marshal.FreeHGlobal(handleValue); }
            if (thread != IntPtr.Zero) { CloseHandle(thread); }
            if (nul != IntPtr.Zero && nul != new IntPtr(-1)) { CloseHandle(nul); }
        }
    }
    public bool Wait(int milliseconds) {
        uint result = WaitForSingleObject(process, (uint)milliseconds);
        if (result == uint.MaxValue) { throw Failure("process-wait"); }
        return result == 0;
    }
    public uint ExitCode {
        get { uint code; if (!GetExitCodeProcess(process, out code)) { throw Failure("process-exit"); } return code; }
    }
    public void Dispose() {
        try {
            if (job != IntPtr.Zero) {
                if (!TerminateJobObject(job, 1)) { throw Failure("job-terminate"); }
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (true) {
                    Accounting accounting;
                    if (!QueryInformationJobObject(job, 1, out accounting,
                        (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero)) {
                        throw Failure("job-accounting");
                    }
                    if (accounting.ActiveProcesses == 0) { break; }
                    if (clock.ElapsedMilliseconds >= 1000) { throw Failure("job-drain"); }
                    System.Threading.Thread.Sleep(10);
                }
            }
        } finally {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
        }
    }
}
'@
function Test-FetchEnabled {
    try {
        if (-not [IO.File]::Exists($OptionsPath) -or
            (Get-Item -LiteralPath $OptionsPath).Length -gt 256) { return $false }
        $options = [IO.File]::ReadAllText($OptionsPath) | ConvertFrom-Json -AsHashtable
        return $options -is [Collections.IDictionary] -and $options.Count -eq 2 -and
            $options.Contains('version') -and $options.Contains('enabled') -and
            $options.version -isnot [bool] -and $options.version -eq 1 -and
            $options.enabled -is [bool] -and $options.enabled
    } catch { return $false }
}
    if ($Remote -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_./-]{0,127}$' -or
        $Refspec -cnotmatch '^\+refs/heads/[^:\s]+:refs/remotes/[^:\s]+$') {
        throw 'Invalid fetch parameters'
    }
    if (-not (Test-FetchEnabled) -or
        $null -eq (Get-Process -Id $OwnerProcessId -ErrorAction SilentlyContinue)) {
        throw 'Fetch disabled'
    }
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $arguments = @(
        '-C', $Repository, '-c', 'credential.interactive=false',
        '-c', 'core.hooksPath=NUL', '-c', 'core.fsmonitor=false',
        '-c', 'gc.auto=0', '-c', 'maintenance.auto=false',
        '-c', 'protocol.ext.allow=never', '-c', 'http.lowSpeedLimit=1',
        '-c', 'http.lowSpeedTime=10', 'fetch', '--quiet', '--no-tags',
        '--no-recurse-submodules', '--no-auto-maintenance',
        '--no-write-fetch-head', '--', $Remote, $Refspec
    )
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    $env:GIT_ASKPASS = ''
    $env:SSH_ASKPASS = ''
    $env:GIT_SSH_COMMAND = 'ssh -oBatchMode=yes -oConnectTimeout=10'
    $env:GIT_SSH_VARIANT = 'ssh'
    if ($clock.ElapsedMilliseconds -ge $limitMs) {
        $reason = 'timeout'
    } else {
        $process = [HudGitFetchJob]::Start($git.Source, [string[]]$arguments)
        $reason = 'failed'
        while (-not $process.Wait(250)) {
            if ($clock.ElapsedMilliseconds -ge $limitMs) { $reason = 'timeout'; break }
            if (-not (Test-FetchEnabled) -or
                $null -eq (Get-Process -Id $OwnerProcessId -ErrorAction SilentlyContinue)) {
                $reason = 'stopped'
                break
            }
        }
        if ($process.Wait(0) -and $process.ExitCode -eq 0) { $reason = 'ok' }
    }
} catch {
    $reason = 'unavailable'
} finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
}
[Console]::Out.Write((@{ reason = $reason } | ConvertTo-Json -Compress))
