# Characterise the Windows console flash, then test the wrapper against it.
#
# Two things were learned on GitHub-hosted windows-latest (run 35571036631,
# Server 2025, session 2, UserInteractive True) and they shape this script:
#
#   1. A single spawn shape cannot answer the question. A child spawned with
#      REDIRECTED handles from a parent that already owns a console attaches
#      to that console and shows nothing — so "no window appeared" was true
#      for the unwrapped form too, and proved nothing about the wrapper.
#   2. The wrapper is not stdio-transparent. WScript.Shell.Run gives the
#      child a fresh console instead of the parent's pipes, so node blocked
#      forever on a stdin that never reached EOF: hook never ran, killed at
#      the cap. Claude Code delivers the payload on stdin and reads the
#      reply from stdout, so that is every hook hanging to its timeout.
#
# So: phase 0 proves this session can show a console window at all, phase 1
# measures which spawn shapes flash, phase 2 judges the wrapper. Every
# "invisible" claim is made only after something visible was observed in the
# same session, because a blind harness reports silence as success.
#
# Exit: 0 all assertions held, 1 an assertion failed, 3 inconclusive.

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

# --------------------------------------------------------------- fixture

$tmpBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$work = Join-Path $tmpBase ("cflash-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$hookJs = Join-Path $work 'hook.js'
$node   = (Get-Command node).Source

# Stands in for a .wolf hook. argv[2] = marker path, argv[3] = 'stdin' to
# wait for the payload (what Claude Code sends) or 'nostdin' for the shapes
# that have no pipe to write on. Lives ~700ms so a flash can be sampled,
# and exits 7 so propagation is observable.
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
} else {
  finish("");
}
'@ | Set-Content -Path $hookJs -Encoding ASCII

$vbsWrapper = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\hook-runner.vbs'
if (-not (Test-Path $vbsWrapper)) {
  Write-Host "FAIL: assets/hook-runner.vbs not found at $vbsWrapper"; exit 1
}

# Same launcher as the wrapper but SW_SHOWNORMAL instead of SW_HIDE. This is
# the control for the wrapper's own code path: if style 1 shows a console and
# style 0 does not, hiding demonstrably works — with no other difference.
$vbsShown = Join-Path $work 'shown-runner.vbs'
@'
Dim cmd, i
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
  If i > 0 Then cmd = cmd & " "
  cmd = cmd & """" & WScript.Arguments(i) & """"
Next
Dim sh
Set sh = CreateObject("WScript.Shell")
WScript.Quit(sh.Run(cmd, 1, True))
'@ | Set-Content -Path $vbsShown -Encoding ASCII

$payload = '{"marker":"PAYLOAD_OK"}'
$results = New-Object System.Collections.Generic.List[object]

function Invoke-Shape {
  param(
    [string]$Name,
    [string]$Description,
    [ValidateSet('redirected','startprocess')] [string]$Mode,
    [string]$Exe,
    [string[]]$Args,
    [bool]$SendStdin
  )
  $marker = Join-Path $work ("marker-" + $Name + ".txt")
  $baseline = Get-VisibleConsoles
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $stdout = ''
  $exit = $null
  $timedOut = $false

  if ($Mode -eq 'redirected') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($Args | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $false        # never mask the defect under test
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($SendStdin) { $proc.StandardInput.Write($payload) }
    $proc.StandardInput.Close()
  } else {
    # A new console by default: this is the shape that MUST show a window.
    $proc = Start-Process -FilePath $Exe -ArgumentList $Args -PassThru
  }

  $deadline = (Get-Date).AddSeconds(20)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    foreach ($w in Get-VisibleConsoles) { if (-not $baseline.Contains($w)) { [void]$seen.Add($w) } }
    Start-Sleep -Milliseconds 15
  }
  $timedOut = -not $proc.HasExited
  if ($timedOut) { try { $proc.Kill() } catch {} }
  [void]$proc.WaitForExit(5000)
  if ($Mode -eq 'redirected') { $stdout = $proc.StandardOutput.ReadToEnd() }
  try { $exit = $proc.ExitCode } catch { $exit = $null }

  $r = [pscustomobject]@{
    Shape    = $Name
    What     = $Description
    Windows  = $seen.Count
    Ran      = (Test-Path $marker)
    Stdout   = ($stdout -replace '\s+$','')
    Exit     = $exit
    TimedOut = $timedOut
  }
  $script:results.Add($r)
  return $r
}

Write-Host "session   : id=$((Get-Process -Id $PID).SessionId) interactive=$([Environment]::UserInteractive) user=$env:USERNAME"
Write-Host "os        : $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Host "workdir   : $work"
Write-Host ""

# ---- phase 0: can this session show a console window at all? ------------
Write-Host "-- phase 0: harness sanity (a new console MUST be visible) --"
$sanity = Invoke-Shape -Name 'new-console' -Description 'Start-Process node (its own console)' `
  -Mode 'startprocess' -Exe $node -Args @($hookJs, (Join-Path $work 'marker-new-console.txt'), 'nostdin') -SendStdin $false
$sanity | Format-List | Out-String | Write-Host

if (-not $sanity.Ran) {
  # Distinct from "no window": the fixture itself never completed, so the
  # window observation is not the thing that failed. Seen over SSH on
  # pandorum, where Start-Process in session 0 never produced a running
  # child at all — reporting that as "no window appeared" would have
  # pointed the next reader at the wrong half of the harness.
  Write-Host "INCONCLUSIVE: the phase 0 fixture never ran (marker absent" +
             $(if ($sanity.TimedOut) { ", and it had to be killed at the cap" } else { "" }) + ")."
  Write-Host "              Nothing was measured. This is a broken fixture or a session"
  Write-Host "              that cannot start a child with its own console — not evidence"
  Write-Host "              about window visibility either way."
  exit 3
}
if ($sanity.Windows -eq 0) {
  Write-Host "INCONCLUSIVE: a process given its own console ran, but showed no visible window."
  Write-Host "              This session cannot display one (service/Session 0, or no"
  Write-Host "              desktop attached), so no invisibility claim made here would"
  Write-Host "              mean anything. Re-run from an interactive desktop session."
  exit 3
}
Write-Host ("harness can see console windows ({0} observed). Proceeding." -f $sanity.Windows)
Write-Host ""

# ---- phase 1: which spawn shapes actually flash? -----------------------
Write-Host "-- phase 1: characterise the spawn shapes --"

Invoke-Shape -Name 'redirected' -Description 'node, redirected stdio, parent owns a console (CI shape)' `
  -Mode 'redirected' -Exe $node -Args @($hookJs, (Join-Path $work 'marker-redirected.txt'), 'stdin') -SendStdin $true |
  Format-List | Out-String | Write-Host

# `bash` on PATH is often C:\Windows\System32\bash.exe — the WSL launcher.
# That runs the hook inside a Linux distro where these Windows paths do not
# exist, so it would report "did not run" and read as "this shape does not
# flash" when the shape was never tested. Claude Code uses an msys/Git bash,
# so prefer that and say which one was used.
$bashCandidates = @(
  'C:\msys64\usr\bin\bash.exe',
  'C:\Program Files\Git\bin\bash.exe',
  'C:\Program Files\Git\usr\bin\bash.exe'
) + @(Get-Command bash -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
$bash = $null
foreach ($c in $bashCandidates) {
  if ($c -and (Test-Path $c) -and ($c -notlike '*\System32\bash.exe') -and
      ($c -notlike '*\WindowsApps\bash.exe')) {
    $bash = Get-Item $c; break
  }
}
if ($bash) {
  Write-Host ("using bash: {0}" -f $bash.FullName)
  # Claude Code runs hook commands through bash on every platform, so this
  # is the shape closest to production.
  $cmdLine = 'node "{0}" "{1}" stdin' -f ($hookJs -replace '\\','/'), (($work -replace '\\','/') + '/marker-bash.txt')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $bash.FullName
  $psi.Arguments = '-c "' + ($cmdLine -replace '"','\"') + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $baseline = Get-VisibleConsoles
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.StandardInput.Write($payload); $proc.StandardInput.Close()
  $deadline = (Get-Date).AddSeconds(20)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    foreach ($w in Get-VisibleConsoles) { if (-not $baseline.Contains($w)) { [void]$seen.Add($w) } }
    Start-Sleep -Milliseconds 15
  }
  [void]$proc.WaitForExit(5000)
  $r = [pscustomobject]@{
    Shape='bash-c'; What='bash -c node ... (Claude Code hook shape)'; Windows=$seen.Count;
    Ran=(Test-Path (Join-Path $work 'marker-bash.txt')); Stdout=($proc.StandardOutput.ReadToEnd() -replace '\s+$','');
    Exit=$proc.ExitCode; TimedOut=$false }
  $script:results.Add($r); $r | Format-List | Out-String | Write-Host
} else {
  Write-Host "no msys/Git bash found (WSL's System32 bash does not count) — skipping the Claude Code hook shape."
}

Invoke-Shape -Name 'vbs-shown' -Description 'wscript + identical VBS but SW_SHOWNORMAL (wrapper control)' `
  -Mode 'redirected' -Exe 'wscript.exe' `
  -Args @('//nologo', $vbsShown, $node, $hookJs, (Join-Path $work 'marker-vbs-shown.txt'), 'nostdin') -SendStdin $false |
  Format-List | Out-String | Write-Host

# ---- phase 2: the wrapper itself ---------------------------------------
Write-Host "-- phase 2: the wrapper under test --"
$wrapped = Invoke-Shape -Name 'vbs-hidden' -Description 'wscript + assets/hook-runner.vbs (SW_HIDE), stdin payload' `
  -Mode 'redirected' -Exe 'wscript.exe' `
  -Args @('//nologo', $vbsWrapper, $node, $hookJs, (Join-Path $work 'marker-vbs-hidden.txt'), 'stdin') -SendStdin $true
$wrapped | Format-List | Out-String | Write-Host

# ---- verdict ------------------------------------------------------------
Write-Host "-- summary --"
$results | Format-Table Shape, Windows, Ran, Exit, TimedOut, Stdout -AutoSize | Out-String | Write-Host

$flashing = @($results | Where-Object { $_.Shape -ne 'new-console' -and $_.Windows -gt 0 })
if ($flashing.Count -eq 0) {
  Write-Host "NOT REPRODUCED: no spawn shape other than an explicitly-own-console process"
  Write-Host "                showed a visible window. The flash does not occur here, so"
  Write-Host "                there is nothing for a wrapper to fix on this host."
  exit 3
}
Write-Host ("REPRODUCED: {0} shape(s) flash — {1}" -f $flashing.Count, (($flashing | ForEach-Object { $_.Shape }) -join ', '))

$failures = New-Object System.Collections.Generic.List[string]
if ($wrapped.Windows -ne 0) { $failures.Add("wrapper still showed $($wrapped.Windows) console window(s)") }
if (-not $wrapped.Ran)      { $failures.Add("wrapper never ran the hook — it hid a window by doing nothing") }
if ($wrapped.TimedOut)      { $failures.Add("wrapper hung and had to be killed (stdin never reached the child)") }
if ($wrapped.Stdout -notmatch 'ECHO:PAYLOAD_OK') {
  $failures.Add("wrapper broke the stdin->stdout round-trip; Claude Code would read nothing back (stdout: '$($wrapped.Stdout)')")
}
if ($wrapped.Exit -ne 7)    { $failures.Add("wrapper did not propagate the exit code: expected 7, got $($wrapped.Exit)") }

if ($failures.Count -gt 0) {
  Write-Host ""
  Write-Host "FAIL — the wrapper is not a drop-in for the bare form:"
  foreach ($f in $failures) { Write-Host "  * $f" }
  exit 1
}
Write-Host ""
Write-Host "PASS — flash reproduced, wrapper invisible, hook ran, stdio round-tripped, exit propagated."
exit 0
