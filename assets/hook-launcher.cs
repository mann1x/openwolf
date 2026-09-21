// openwolf hook launcher — runs a .wolf hook without a console window while
// leaving its stdio alone.
//
// Why a binary at all, and why these exact flags (all measured, 2026-09-21,
// Windows 10 Pro interactive session and GitHub windows-latest):
//
//   * The console flash comes from console ALLOCATION, not from running node.
//     A parent with no console of its own forces a console-subsystem child to
//     allocate one, and that console is visible. Where the parent already owns
//     a console the child attaches to it and nothing appears.
//
//   * The previous approach, wscript + WScript.Shell.Run with SW_HIDE, hid the
//     window correctly (1 window at SW_SHOWNORMAL vs 0 at SW_HIDE) but handed
//     the child a FRESH CONSOLE instead of the parent's pipes. Claude Code
//     delivers the hook payload on stdin and reads the reply from stdout, so
//     every wrapped hook hung on a stdin that never reached EOF: no output, no
//     exit code, killed at the timeout, on both hosts.
//
//   * CREATE_NO_WINDOW alone repeats that defect. It allocates a console, and
//     a child only takes its std handles from STARTUPINFO when
//     STARTF_USESTDHANDLES is set — which .NET's ProcessStartInfo sets only
//     when it is redirecting. So "don't redirect, and it will inherit" is
//     wrong, and fails identically.
//
// Both flags together are the fix: CREATE_NO_WINDOW so no console window is
// shown, STARTF_USESTDHANDLES with this process's own handles so the child
// gets the real pipes, and bInheritHandles so they survive the call.
//
// Built as /target:winexe (Windows subsystem) so the launcher itself never
// owns a console. Compiled on demand by src/utils/hook-command.ts using the
// csc.exe that ships with the .NET Framework on every Windows, so no binary
// is committed or published.
//
// Usage: hook-launcher.exe <exe> [args...]      exit code is the child's.

using System;
using System.Runtime.InteropServices;

class HookLauncher {
  const uint CREATE_NO_WINDOW = 0x08000000;
  const uint STARTF_USESTDHANDLES = 0x00000100;
  const int STD_INPUT_HANDLE = -10, STD_OUTPUT_HANDLE = -11, STD_ERROR_HANDLE = -12;
  const uint INFINITE = 0xFFFFFFFF;
  const uint HANDLE_FLAG_INHERIT = 0x00000001;
  static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);

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
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
  [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

  static int Main(string[] argv) {
    string cmd = ChildCommandLine(Environment.CommandLine);
    if (cmd.Length == 0) return 2;

    var si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    si.hStdInput  = Usable(GetStdHandle(STD_INPUT_HANDLE));
    si.hStdOutput = Usable(GetStdHandle(STD_OUTPUT_HANDLE));
    si.hStdError  = Usable(GetStdHandle(STD_ERROR_HANDLE));
    // Only claim to supply handles when there are some. Started with none —
    // double-clicked, say — asserting the flag would hand the child three
    // nulls and it would have no stdio at all.
    bool haveHandles = si.hStdInput != IntPtr.Zero || si.hStdOutput != IntPtr.Zero ||
                       si.hStdError != IntPtr.Zero;
    if (haveHandles) si.dwFlags = STARTF_USESTDHANDLES;

    // bInheritHandles carries only handles actually marked inheritable, and
    // nothing obliges a parent to mark the ones it hands us. Neither shell
    // observed here gets this wrong, so this is insurance rather than a fix
    // for a measured failure — but an unmarked handle makes CreateProcess fail
    // outright, and the cost of ruling it out is one call. Best-effort: a
    // handle we cannot mark still gets the retry below.
    MarkInheritable(si.hStdInput);
    MarkInheritable(si.hStdOutput);
    MarkInheritable(si.hStdError);

    PROCESS_INFORMATION pi;
    if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero,
                       true, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi)) {
      int err = Marshal.GetLastWin32Error();
      // Degrade to a child that works rather than none. Dropping
      // STARTF_USESTDHANDLES gives up the pipes — and with them the hook
      // payload — so retry with the window suppression dropped instead, which
      // costs only the flash this launcher exists to avoid. Better a visible
      // hook than a silent one; that inversion is the whole bug being fixed.
      if (haveHandles) {
        if (CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero,
                          true, 0, IntPtr.Zero, null, ref si, out pi))
          return Wait(ref pi);
      }
      // Say why. A launcher that swallows its own failure would reproduce, in
      // a new place, exactly the silence it was written to remove.
      try {
        Console.Error.WriteLine("hook-launcher: CreateProcess failed, error " + err +
                                " (and " + Marshal.GetLastWin32Error() +
                                " without CREATE_NO_WINDOW): " + cmd);
      } catch { }
      return 3;
    }

    return Wait(ref pi);
  }

  static int Wait(ref PROCESS_INFORMATION pi) {
    WaitForSingleObject(pi.hProcess, INFINITE);
    uint code;
    if (!GetExitCodeProcess(pi.hProcess, out code)) code = 4;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
  }

  /// Everything after our own executable name, exactly as the caller wrote it.
  ///
  /// Deliberately not rebuilt from the parsed argv. The caller's quoting is the
  /// only authority on where one argument ends and the next begins, and a
  /// parse-then-requote round trip can only ever agree with it or corrupt it —
  /// it cannot improve on it. An argument containing a quote is the obvious
  /// case, and the failure mode is the worst kind: the child path silently
  /// becomes a different string and CreateProcess reports file-not-found on a
  /// program nobody asked for.
  ///
  /// Measured 2026-09-21 on pandorum: Git bash (the shell Claude Code runs
  /// every hook through) and PowerShell both hand this process an identical,
  /// correctly-quoted command line, so the re-quoting version was not in fact
  /// broken — passing the line through is simply the version that cannot
  /// disagree with the caller.
  static string ChildCommandLine(string raw) {
    int i = 0;
    bool quoted = false;
    while (i < raw.Length) {
      char c = raw[i];
      if (c == '"') quoted = !quoted;
      else if (!quoted && (c == ' ' || c == '\t')) break;
      i++;
    }
    while (i < raw.Length && (raw[i] == ' ' || raw[i] == '\t')) i++;
    return raw.Substring(i);
  }

  /// INVALID_HANDLE_VALUE means "this process has no such stream", which is
  /// not a handle to hand a child; STARTUPINFO wants zero there.
  static IntPtr Usable(IntPtr h) {
    return h == INVALID_HANDLE ? IntPtr.Zero : h;
  }

  static void MarkInheritable(IntPtr h) {
    if (h == IntPtr.Zero) return;
    try { SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT); } catch { }
  }
}
