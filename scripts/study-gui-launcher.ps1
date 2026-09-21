# Does a GUI-subsystem launcher fix the flash WITHOUT breaking the hook?
#
# Established by scripts/validate-console-flash.ps1 on pandorum (session 1,
# Win10 Pro) and GitHub windows-latest (Server 2025):
#
#   * the flash is real, and appears in the shapes where a NEW console gets
#     allocated — not in a redirected spawn from a parent that already owns
#     one, and not in `bash -c node ...`, which is how Claude Code invokes a
#     hook command;
#   * SW_HIDE genuinely suppresses the window: the same VBS launcher showed
#     1 window at SW_SHOWNORMAL and 0 at SW_HIDE;
#   * but WScript.Shell.Run replaces the child's pipes with a fresh console,
#     so the wrapped hook hung on a stdin that never reached EOF — no output,
#     no exit code, killed at the cap, on both hosts.
#
# So the requirement is not "hide a window". It is: allocate no visible
# console, INHERIT the parent's std handles rather than replace them, and
# propagate the exit code. That is CREATE_NO_WINDOW plus handle inheritance,
# in a binary linked as the Windows subsystem — in .NET, UseShellExecute
# false + CreateNoWindow true + no redirection at all.
#
# Two throwaway binaries are compiled here with the .NET Framework csc that
# ships with Windows, so the experiment needs no SDK and no checked-in exe:
#
#   NoConsoleParent.exe  a GUI-subsystem parent, i.e. one with NO console of
#                        its own. This is the shape that makes a console-
#                        subsystem child allocate one, and the closest thing
#                        to whatever spawns hooks when the flash is seen.
#   HookLauncher.exe     the candidate fix.
#
# Exit: 0 the launcher is a drop-in and kills the flash, 1 it is not,
#       3 nothing measurable (blind session, or nothing flashed).

[CmdletBinding()]
param([switch]$AllowBlindSession)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -Namespace Win32 -Name Windows -MemberDefinition @'
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
'@

$script:consoleClasses = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')
function Get-VisibleConsoles {
  $found = New-Object System.Collections.Generic.List[string]
  $cb = [Win32.Windows+EnumProc] {
    param([IntPtr]$h, [IntPtr]$p)
    if ([Win32.Windows]::IsWindowVisible($h)) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Win32.Windows]::GetClassName($h, $sb, $sb.Capacity)
      if ($script:consoleClasses -contains $sb.ToString()) { $found.Add($sb.ToString() + '#' + $h) }
    }
    return $true
  }
  [void][Win32.Windows]::EnumWindows($cb, [IntPtr]::Zero)
  return $found
}

$tmpBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $tmpBase ("guistudy-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$node = (Get-Command node).Source
$payload = '{"marker":"PAYLOAD_OK"}'

# ------------------------------------------------------------- the fixture

$hookJs = Join-Path $work 'hook.js'
@'
const fs = require("fs");
const marker = process.argv[2];
const mode = process.argv[3] || "stdin";
function finish(raw) {
  let echoed = "NO_STDIN";
  if (mode === "stdin") {
    try { echoed = JSON.parse(raw).marker || "NO_MARKER"; } catch (e) { echoed = "BAD_JSON"; }
  }
  fs.writeFileSync(marker, "ran:" + echoed + "\n");
  process.stdout.write("ECHO:" + echoed + "\n");
  setTimeout(() => process.exit(7), 700);
}
if (mode === "stdin") {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (d) => { raw += d; });
  process.stdin.on("end", () => finish(raw));
} else { finish(""); }
'@ | Set-Content -Path $hookJs -Encoding ASCII

# ------------------------------------------------------------ the binaries

$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64\v*\csc.exe' -ErrorAction SilentlyContinue |
       Sort-Object FullName -Descending | Select-Object -First 1
if (-not $csc) {
  $csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework\v*\csc.exe' -ErrorAction SilentlyContinue |
         Sort-Object FullName -Descending | Select-Object -First 1
}
if (-not $csc) { Write-Host "INCONCLUSIVE: no .NET Framework csc.exe to build the probes with."; exit 3 }
Write-Host "csc       : $($csc.FullName)"

# The candidate fix, second attempt.
#
# The first attempt was ProcessStartInfo with UseShellExecute=false,
# CreateNoWindow=true and no redirection, on the reasoning that "no
# redirection" means "inherit the parent's handles". It hung exactly like the
# VBS wrapper — measured over SSH, node left waiting on stdin until killed —
# and the reason is worth keeping: CREATE_NO_WINDOW *allocates a new console*,
# and a child gets its std handles from STARTUPINFO only when
# STARTF_USESTDHANDLES is set. .NET sets that flag only when it is
# redirecting. So with no redirection the child was handed the fresh
# console's handles, and the parent's pipes went nowhere — the same defect in
# a different costume.
#
# So the handles have to be passed explicitly, which means CreateProcess
# directly: STARTF_USESTDHANDLES with this process's own std handles, plus
# CREATE_NO_WINDOW, plus bInheritHandles.
$launcherCs = Join-Path $work 'HookLauncher.cs'
@'
using System;
using System.Runtime.InteropServices;
using System.Text;

class HookLauncher {
  const uint CREATE_NO_WINDOW = 0x08000000;
  const uint STARTF_USESTDHANDLES = 0x00000100;
  const int STD_INPUT_HANDLE = -10, STD_OUTPUT_HANDLE = -11, STD_ERROR_HANDLE = -12;
  const uint INFINITE = 0xFFFFFFFF;

  [StructLayout(LayoutKind.Sequential)]
  struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint pid, tid; }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO {
    public int cb;
    public string lpReserved, lpDesktop, lpTitle;
    public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars,
                dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcess(string app, string cmdLine, IntPtr pa, IntPtr ta,
    bool inherit, uint flags, IntPtr env, string cwd,
    ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

  static int Main(string[] argv) {
    if (argv.Length < 1) return 2;
    var sb = new StringBuilder();
    for (int i = 0; i < argv.Length; i++) {
      if (i > 0) sb.Append(' ');
      sb.Append('"').Append(argv[i]).Append('"');
    }

    var si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError  = GetStdHandle(STD_ERROR_HANDLE);
    // Only claim to supply handles if we actually have some. Launched with
    // none (double-clicked, say), asserting the flag would hand the child
    // three null handles and it would have no stdio at all.
    if (si.hStdInput != IntPtr.Zero || si.hStdOutput != IntPtr.Zero || si.hStdError != IntPtr.Zero)
      si.dwFlags = STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    if (!CreateProcess(null, sb.ToString(), IntPtr.Zero, IntPtr.Zero,
                       true, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi))
      return 3;
    WaitForSingleObject(pi.hProcess, INFINITE);
    uint code;
    if (!GetExitCodeProcess(pi.hProcess, out code)) code = 4;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
  }
}
'@ | Set-Content -Path $launcherCs -Encoding ASCII

# A parent with no console of its own, which is the condition that makes a
# console child allocate one. It reports through a file because it has no
# console to print to.
$parentCs = Join-Path $work 'NoConsoleParent.cs'
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
class NoConsoleParent {
  static int Main(string[] argv) {
    // argv[0] = result file, argv[1] = exe, argv[2..] = its arguments
    if (argv.Length < 2) return 2;
    var psi = new ProcessStartInfo();
    psi.FileName = argv[1];
    var sb = new StringBuilder();
    for (int i = 2; i < argv.Length; i++) {
      if (i > 2) sb.Append(' ');
      sb.Append('"').Append(argv[i]).Append('"');
    }
    psi.Arguments = sb.ToString();
    psi.UseShellExecute = false;
    psi.RedirectStandardInput = true;
    psi.RedirectStandardOutput = true;
    psi.RedirectStandardError = true;
    psi.CreateNoWindow = false;    // do not mask the defect under study
    string outText = "", errText = "";
    int code = -1;
    try {
      using (var p = Process.Start(psi)) {
        p.StandardInput.Write("{\"marker\":\"PAYLOAD_OK\"}");
        p.StandardInput.Close();
        outText = p.StandardOutput.ReadToEnd();
        errText = p.StandardError.ReadToEnd();
        if (!p.WaitForExit(20000)) { try { p.Kill(); } catch {} outText += "[TIMEOUT]"; }
        else code = p.ExitCode;
      }
    } catch (Exception ex) { errText += ex.Message; }
    File.WriteAllText(argv[0],
      "exit=" + code + "\nstdout=" + outText.Trim() + "\nstderr=" + errText.Trim() + "\n");
    return code;
  }
}
'@ | Set-Content -Path $parentCs -Encoding ASCII

$launcherExe = Join-Path $work 'HookLauncher.exe'
$parentExe   = Join-Path $work 'NoConsoleParent.exe'
foreach ($pair in @(@($launcherCs, $launcherExe), @($parentCs, $parentExe))) {
  # /target:winexe is the load-bearing flag: it marks the binary as Windows
  # subsystem, so starting it allocates no console of its own.
  $out = & $csc.FullName /nologo /target:winexe /optimize+ ("/out:" + $pair[1]) $pair[0] 2>&1
  if (-not (Test-Path $pair[1])) {
    Write-Host "INCONCLUSIVE: failed to compile $($pair[0]):"; $out | ForEach-Object { Write-Host "  $_" }
    exit 3
  }
}
Write-Host "built     : HookLauncher.exe, NoConsoleParent.exe (/target:winexe)"
Write-Host "workdir   : $work"
Write-Host "session   : id=$((Get-Process -Id $PID).SessionId) interactive=$([Environment]::UserInteractive)"
Write-Host ""

# ------------------------------------------------------------- measurement

$results = New-Object System.Collections.Generic.List[object]

function Measure-Shape {
  param(
    [string]$Name, [string]$What, [string]$Exe, [string[]]$ArgList,
    [bool]$Redirect, [string]$Marker, [string]$ResultFile
  )
  $baseline = Get-VisibleConsoles
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $stdout = ''; $exit = $null

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = ($ArgList | ForEach-Object {
    if ($_ -match '^(//|[-/])') { $_ } else { '"' + $_ + '"' } }) -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $false
  if ($Redirect) {
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
  }
  $proc = [System.Diagnostics.Process]::Start($psi)
  if ($Redirect) { $proc.StandardInput.Write($payload); $proc.StandardInput.Close() }

  $deadline = (Get-Date).AddSeconds(25)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    foreach ($w in Get-VisibleConsoles) { if (-not $baseline.Contains($w)) { [void]$seen.Add($w) } }
    Start-Sleep -Milliseconds 15
  }
  $timedOut = -not $proc.HasExited
  if ($timedOut) { try { $proc.Kill() } catch {} }
  [void]$proc.WaitForExit(5000)
  if ($Redirect) { $stdout = ($proc.StandardOutput.ReadToEnd() -replace '\s+$','') }
  try { $exit = $proc.ExitCode } catch { $exit = $null }

  # A no-console parent reports through a file; fold that in so every row
  # is comparable.
  if ($ResultFile -and (Test-Path $ResultFile)) {
    $rf = Get-Content $ResultFile -Raw
    if ($rf -match 'stdout=(.*)') { $stdout = $Matches[1].Trim() }
    if ($rf -match 'exit=(-?\d+)') { $exit = [int]$Matches[1] }
  }

  $r = [pscustomobject]@{
    Shape = $Name; What = $What; Windows = $seen.Count
    Ran = ($Marker -and (Test-Path $Marker)); Stdout = $stdout; Exit = $exit; TimedOut = $timedOut
  }
  $script:results.Add($r)
  $r | Format-List | Out-String | Write-Host
  return $r
}

Write-Host "-- phase 0: can this session show a console window at all? --"
$sanity = Measure-Shape -Name 'new-console' -What 'a process given its own console' `
  -Exe $node -ArgList @($hookJs, (Join-Path $work 'm0.txt'), 'nostdin') -Redirect $false `
  -Marker (Join-Path $work 'm0.txt') -ResultFile ''
$script:blind = $sanity.Windows -eq 0
if ($script:blind) {
  Write-Host "INCONCLUSIVE: no visible console even for a process given its own console."
  if (-not $AllowBlindSession) { exit 3 }
  Write-Host "-AllowBlindSession: continuing to exercise the binaries; window counts below are NOT evidence."
}

Write-Host "-- phase 1: is a console-less parent what makes the flash? --"
Measure-Shape -Name 'noconsole-parent-bare' `
  -What 'GUI-subsystem parent spawns node with redirected stdio (presumed production shape)' `
  -Exe $parentExe -ArgList @((Join-Path $work 'r1.txt'), $node, $hookJs, (Join-Path $work 'm1.txt'), 'stdin') `
  -Redirect $false -Marker (Join-Path $work 'm1.txt') -ResultFile (Join-Path $work 'r1.txt') | Out-Null

Write-Host "-- phase 2: the candidate fix --"
$direct = Measure-Shape -Name 'gui-launcher' `
  -What 'HookLauncher.exe from a console-owning parent, stdin payload' `
  -Exe $launcherExe -ArgList @($node, $hookJs, (Join-Path $work 'm2.txt'), 'stdin') `
  -Redirect $true -Marker (Join-Path $work 'm2.txt') -ResultFile ''

$viaParent = Measure-Shape -Name 'noconsole-parent-launcher' `
  -What 'the flashing shape, but through HookLauncher.exe' `
  -Exe $parentExe -ArgList @((Join-Path $work 'r3.txt'), $launcherExe, $node, $hookJs, (Join-Path $work 'm3.txt'), 'stdin') `
  -Redirect $false -Marker (Join-Path $work 'm3.txt') -ResultFile (Join-Path $work 'r3.txt')

Write-Host "-- summary --"
$results | Format-Table Shape, Windows, Ran, Exit, TimedOut, Stdout -AutoSize | Out-String | Write-Host

if ($script:blind) {
  Write-Host "INCONCLUSIVE: blind shakeout. 'Ran', 'Stdout' and 'Exit' above are real; windows are not."
  exit 3
}

$flashShape = @($results | Where-Object { $_.Shape -eq 'noconsole-parent-bare' -and $_.Windows -gt 0 })
if ($flashShape.Count -eq 0) {
  Write-Host "NOT REPRODUCED in the production shape: a console-less parent spawning node"
  Write-Host "                showed no visible window either, so the flash comes from"
  Write-Host "                something else and a launcher would be aimed at the wrong"
  Write-Host "                thing. Do not build it on this evidence."
  exit 3
}
Write-Host "REPRODUCED: a console-less parent makes node allocate a visible console."

$failures = New-Object System.Collections.Generic.List[string]
foreach ($c in @($direct, $viaParent)) {
  if ($c.Windows -ne 0)   { $failures.Add("$($c.Shape): still showed $($c.Windows) console window(s)") }
  if (-not $c.Ran)        { $failures.Add("$($c.Shape): hook never ran") }
  if ($c.TimedOut)        { $failures.Add("$($c.Shape): hung and had to be killed") }
  if ($c.Stdout -notmatch 'ECHO:PAYLOAD_OK') { $failures.Add("$($c.Shape): stdin->stdout round-trip broken (stdout: '$($c.Stdout)')") }
  if ($c.Exit -ne 7)      { $failures.Add("$($c.Shape): exit code not propagated (expected 7, got $($c.Exit))") }
}
if ($failures.Count -gt 0) {
  Write-Host ""; Write-Host "FAIL - the GUI-subsystem launcher is not a drop-in either:"
  foreach ($f in $failures) { Write-Host "  * $f" }
  exit 1
}
Write-Host ""
Write-Host "PASS - the launcher removes the window AND keeps the hook contract:"
Write-Host "       no visible console, hook ran, stdin/stdout round-tripped, exit 7 propagated,"
Write-Host "       in both the console-owning and console-less parent shapes."
exit 0
