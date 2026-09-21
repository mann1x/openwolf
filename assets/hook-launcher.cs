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

    // Re-quote every argument so a path with spaces survives the round-trip
    // into a single command line.
    var cmd = new StringBuilder();
    for (int i = 0; i < argv.Length; i++) {
      if (i > 0) cmd.Append(' ');
      cmd.Append('"').Append(argv[i]).Append('"');
    }

    var si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError  = GetStdHandle(STD_ERROR_HANDLE);
    // Only claim to supply handles when there are some. Started with none —
    // double-clicked, say — asserting the flag would hand the child three
    // nulls and it would have no stdio at all.
    if (si.hStdInput != IntPtr.Zero || si.hStdOutput != IntPtr.Zero || si.hStdError != IntPtr.Zero)
      si.dwFlags = STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    if (!CreateProcess(null, cmd.ToString(), IntPtr.Zero, IntPtr.Zero,
                       true, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi))
      return 3;                      // spawn failed; caller sees a hard error

    WaitForSingleObject(pi.hProcess, INFINITE);
    uint code;
    if (!GetExitCodeProcess(pi.hProcess, out code)) code = 4;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
  }
}
