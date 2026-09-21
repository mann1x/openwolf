# Logs every visible console window that appears, and WHICH process owns it.
#
# The hook config on this machine has five different families in it — openwolf
# and caliber through their VBS wrappers, claude-hooks' bash shim, a gitnexus
# node hook, and caliber's own .sh hooks — and only some are wrapped. Guessing
# which one flashes would mean fixing the wrong one, so this records the owner
# of each window instead: pid, image, command line, and its parent.
#
# Run it from an interactive desktop session, use Claude Code normally for a
# minute in a project that has .wolf hooks, then press a key. Window ownership
# cannot be read from session 0, which is why this cannot be done over SSH.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -Namespace Win32 -Name W -MemberDefinition @'
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
'@

$classes = @('ConsoleWindowClass','CASCADIA_HOSTING_WINDOW_CLASS')
$log = Join-Path $PSScriptRoot '..\console-windows.log'
if (Test-Path $log) { Remove-Item $log -Force }

function Snapshot {
  $seen = @{}
  $cb = [Win32.W+EnumProc] {
    param([IntPtr]$h, [IntPtr]$p)
    if ([Win32.W]::IsWindowVisible($h)) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Win32.W]::GetClassName($h, $sb, $sb.Capacity)
      if ($script:classes -contains $sb.ToString()) {
        $pid = 0; [void][Win32.W]::GetWindowThreadProcessId($h, [ref]$pid)
        $seen[[string]$h] = $pid
      }
    }
    return $true
  }
  [void][Win32.W]::EnumWindows($cb, [IntPtr]::Zero)
  return $seen
}

function Describe([uint32]$procId) {
  try {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction Stop
    $parent = $null
    try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.ParentProcessId)" -ErrorAction Stop } catch {}
    $pl = if ($parent) { "$($parent.Name) [$($parent.ProcessId)] :: $($parent.CommandLine)" } else { "<gone>" }
    return "pid=$procId $($p.Name)`n      cmd   : $($p.CommandLine)`n      parent: $pl"
  } catch { return "pid=$procId <exited before it could be identified>" }
}

Write-Host "Watching for visible console windows. Use Claude Code now."
Write-Host "Press any key here when done.`n"
$known = Snapshot
$count = 0
while (-not [Console]::KeyAvailable) {
  $now = Snapshot
  foreach ($h in $now.Keys) {
    if (-not $known.ContainsKey($h)) {
      $count++
      $line = "[{0}] window {1}`n      {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $h, (Describe $now[$h])
      Write-Host $line
      Add-Content -Path $log -Value $line
    }
  }
  $known = $now
  Start-Sleep -Milliseconds 15
}
[void][Console]::ReadKey($true)
Write-Host "`n$count window(s) recorded -> $log"
