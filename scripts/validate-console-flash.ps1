# Validates the Windows hook-command wrapper against the two things it has
# to be simultaneously: invisible, and still a working hook.
#
# The console flash is real, but "no window appeared" is also what a
# headless session produces, and what a wrapper that never ran the child
# produces. So nothing here is asserted without a control that proves the
# assertion could have failed:
#
#   * window visibility is asserted only after the BARE form has been seen
#     to raise a visible console in this very session. If it does not, the
#     session cannot show one and the run exits INCONCLUSIVE rather than
#     green — a check that cannot fail is not evidence.
#   * the wrapped form must ALSO complete the stdin -> stdout round-trip
#     and propagate its exit code, because Claude Code delivers the hook
#     payload on stdin and reads the response from stdout. A wrapper that
#     hides the window by cutting those pipes passes a window test and
#     breaks every hook.
#
# Exit codes: 0 pass, 1 fail, 3 inconclusive (harness blind).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -Namespace Win32 -Name Windows -MemberDefinition @'
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
'@

# Console hosts, by window class: the classic conhost window, and the
# Windows Terminal host a modern runner may use instead.
$consoleClasses = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')

function Get-VisibleConsoleWindows {
  $found = New-Object System.Collections.Generic.List[string]
  $cb = [Win32.Windows+EnumProc] {
    param([IntPtr]$h, [IntPtr]$p)
    if ([Win32.Windows]::IsWindowVisible($h)) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Win32.Windows]::GetClassName($h, $sb, $sb.Capacity)
      $cls = $sb.ToString()
      if ($script:consoleClasses -contains $cls) { $found.Add("$cls#$h") }
    }
    return $true
  }
  [void][Win32.Windows]::EnumWindows($cb, [IntPtr]::Zero)
  return $found
}

function Invoke-Probe {
  param(
    [string]$Label,
    [string]$Exe,
    [string]$Arguments,
    [string]$StdinPayload,
    [string]$MarkerPath
  )

  if (Test-Path $MarkerPath) { Remove-Item $MarkerPath -Force }
  $baseline = Get-VisibleConsoleWindows

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false          # exactly how Claude Code spawns it
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $false           # do NOT mask the defect under test

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $stdout = New-Object System.Text.StringBuilder
  $stderr = New-Object System.Text.StringBuilder
  $onOut = Register-ObjectEvent $proc OutputDataReceived -Action {
    if ($EventArgs.Data) { [void]$Event.MessageData.Append($EventArgs.Data) }
  } -MessageData $stdout
  $onErr = Register-ObjectEvent $proc ErrorDataReceived -Action {
    if ($EventArgs.Data) { [void]$Event.MessageData.Append($EventArgs.Data) }
  } -MessageData $stderr

  [void]$proc.Start()
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()
  $proc.StandardInput.Write($StdinPayload)
  $proc.StandardInput.Close()

  # Sample while it runs. The flash is brief by definition, so the sampler
  # has to be tighter than the thing it is looking for.
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $deadline = (Get-Date).AddSeconds(30)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    foreach ($w in Get-VisibleConsoleWindows) {
      if (-not $baseline.Contains($w)) { [void]$seen.Add($w) }
    }
    Start-Sleep -Milliseconds 20
  }
  $timedOut = -not $proc.HasExited
  if ($timedOut) { $proc.Kill() }
  [void]$proc.WaitForExit(5000)
  Start-Sleep -Milliseconds 200            # let the async readers drain
  Unregister-Event -SourceIdentifier $onOut.Name
  Unregister-Event -SourceIdentifier $onErr.Name

  return [pscustomobject]@{
    Label      = $Label
    Exit       = $proc.ExitCode
    Stdout     = $stdout.ToString()
    Stderr     = $stderr.ToString()
    NewConsoles= @($seen)
    Ran        = (Test-Path $MarkerPath)
    TimedOut   = $timedOut
  }
}

# ---------------------------------------------------------------- fixture

$work = Join-Path $env:RUNNER_TEMP ("console-flash-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$marker = Join-Path $work 'ran.txt'
$hookJs = Join-Path $work 'hook.js'

# Stands in for a .wolf hook: reads the payload from stdin, answers on
# stdout, records that it ran, and exits non-zero so propagation is visible.
@'
const fs = require("fs");
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  fs.writeFileSync(process.argv[2], "ran\n");
  let echoed = "NO_STDIN";
  try { echoed = JSON.parse(raw).marker || "NO_MARKER"; } catch (e) { echoed = "BAD_JSON"; }
  process.stdout.write("ECHO:" + echoed + "\n");
  setTimeout(() => process.exit(7), 400);   // stay alive long enough to be seen
});
'@ | Set-Content -Path $hookJs -Encoding ASCII

$vbs = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\hook-runner.vbs'
if (-not (Test-Path $vbs)) { Write-Host "FAIL: hook-runner.vbs not found at $vbs"; exit 1 }

$payload = '{"marker":"PAYLOAD_OK"}'
$node = (Get-Command node).Source

Write-Host "== control: bare node (the form that flashes) =="
$bare = Invoke-Probe -Label 'bare' -Exe $node `
  -Arguments ('"{0}" "{1}"' -f $hookJs, $marker) -StdinPayload $payload -MarkerPath $marker
$bare | Format-List | Out-String | Write-Host

Write-Host "== subject: wscript + hook-runner.vbs =="
$wrapped = Invoke-Probe -Label 'wrapped' -Exe 'wscript.exe' `
  -Arguments ('//nologo "{0}" "{1}" "{2}" "{3}"' -f $vbs, $node, $hookJs, $marker) `
  -StdinPayload $payload -MarkerPath $marker
$wrapped | Format-List | Out-String | Write-Host

# ---------------------------------------------------------------- verdict

$failures = New-Object System.Collections.Generic.List[string]

if (-not $bare.Ran) {
  Write-Host "INCONCLUSIVE: the control hook did not run at all; the fixture is broken."
  exit 3
}
if ($bare.Stdout -notmatch 'ECHO:PAYLOAD_OK') {
  Write-Host "INCONCLUSIVE: the control did not complete the stdin->stdout round-trip, so"
  Write-Host "              this harness cannot tell a broken pipe from a working one."
  exit 3
}
if ($bare.NewConsoles.Count -eq 0) {
  Write-Host "INCONCLUSIVE: no visible console window appeared even for the BARE form."
  Write-Host "              Either this session cannot show one (headless/Session 0) or"
  Write-Host "              the flash does not reproduce here. Asserting the wrapper is"
  Write-Host "              invisible would be asserting nothing."
  exit 3
}

Write-Host ("control raised {0} visible console window(s) — the harness can see the defect." -f $bare.NewConsoles.Count)

if ($wrapped.NewConsoles.Count -ne 0) {
  $failures.Add(("wrapped form still showed {0} visible console window(s): {1}" -f
    $wrapped.NewConsoles.Count, ($wrapped.NewConsoles -join ', ')))
}
if (-not $wrapped.Ran) {
  $failures.Add("wrapped form never ran the hook (no marker file) — it hid a window by doing nothing")
}
if ($wrapped.Stdout -notmatch 'ECHO:PAYLOAD_OK') {
  $failures.Add(("wrapped form broke the stdin->stdout round-trip; Claude Code would read " +
    "nothing back. stdout was: '{0}'" -f $wrapped.Stdout.Trim()))
}
if ($wrapped.Exit -ne 7) {
  $failures.Add(("wrapped form did not propagate the hook's exit code: expected 7, got {0}" -f $wrapped.Exit))
}

if ($failures.Count -gt 0) {
  Write-Host ""
  Write-Host "FAIL — the wrapper is not a drop-in for the bare form:"
  foreach ($f in $failures) { Write-Host "  * $f" }
  exit 1
}

Write-Host ""
Write-Host "PASS — no visible console, hook ran, stdin/stdout round-tripped, exit code propagated."
exit 0
