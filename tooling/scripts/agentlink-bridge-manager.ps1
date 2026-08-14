param(
  [int]$Port = 4317,
  [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LogDir = Join-Path $Root 'tooling\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'bridge-manager.log'

if ($ValidateOnly) {
  Write-Output "AgentLink Bridge Manager script is valid. Root=$Root"
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:BridgeProcess = $null
$script:BridgeUrl = $null
$script:BridgePid = $null
$script:BridgePort = $Port

function Write-ManagerLog([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-JsonFast([string]$Uri, [int]$TimeoutMs = 500) {
  $request = [System.Net.WebRequest]::Create($Uri)
  $request.Timeout = $TimeoutMs
  $request.ReadWriteTimeout = $TimeoutMs
  $response = $null
  $reader = $null
  try {
    $response = $request.GetResponse()
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
    return ($reader.ReadToEnd() | ConvertFrom-Json)
  } finally {
    if ($reader) { $reader.Dispose() }
    if ($response) { $response.Dispose() }
  }
}

function Get-PortPid([int]$Port) {
  try {
    $line = netstat -ano -p tcp | Select-String -Pattern ":$Port\s+.*LISTENING" | Select-Object -First 1
    if (-not $line) { return $null }
    $parts = ($line.ToString().Trim() -split '\s+')
    return [int]$parts[-1]
  } catch {
    return $null
  }
}

function Get-ListeningCandidatePorts([int]$StartPort, [int]$EndPort) {
  $ports = New-Object System.Collections.Generic.List[int]
  try {
    foreach ($line in (netstat -ano -p tcp | Select-String -Pattern 'LISTENING')) {
      $parts = ($line.ToString().Trim() -split '\s+')
      if ($parts.Count -lt 5) { continue }
      $local = $parts[1]
      if ($local -notmatch ':(\d+)$') { continue }
      $port = [int]$Matches[1]
      if ($port -ge $StartPort -and $port -le $EndPort -and -not $ports.Contains($port)) {
        $ports.Add($port)
      }
    }
  } catch {}
  return @($ports | Sort-Object)
}

function Find-Bridge([int]$StartPort = 4317, [int]$EndPort = 4337) {
  $candidatePorts = Get-ListeningCandidatePorts $StartPort $EndPort
  foreach ($p in $candidatePorts) {
    try {
      $pairing = Invoke-JsonFast "http://127.0.0.1:$p/v1/pairing" 450
      if ($pairing.service -eq 'agent-link-bridge') {
        return [pscustomobject]@{
          Url = [string]$pairing.preferredUrl
          Port = [int]$p
          Pid = Get-PortPid $p
          Pairing = $pairing
        }
      }
    } catch {}
  }
  return $null
}

function Set-Status([string]$Status, [string]$Url = $null, [string]$Detail = $null) {
  $statusLabel.Text = "Status: $Status"
  if ($Url) {
    $script:BridgeUrl = $Url
    $urlBox.Text = $Url
  }
  if ($Detail) { $detailBox.Text = $Detail }
}

function Refresh-BridgeStatus() {
  $bridge = Find-Bridge 4317 4337
  if ($bridge) {
    $script:BridgeUrl = $bridge.Url
    $script:BridgePid = $bridge.Pid
    $script:BridgePort = $bridge.Port
    $statusLabel.Text = "Status: running (PID $($bridge.Pid), port $($bridge.Port))"
    $urlBox.Text = $bridge.Url
    $detailBox.Text = @"
Bridge is running.

URL: $($bridge.Url)
Port: $($bridge.Port)
PID: $($bridge.Pid)

Open QR: $($bridge.Url)/pair
Open Web Manager: $($bridge.Url)/manage

The web manager page loads full diagnostics without freezing this window.
"@
    return $true
  }
  $statusLabel.Text = 'Status: stopped'
  $detailBox.Text = 'Bridge is not running.'
  return $false
}

function Start-BridgeProcess() {
  if (Refresh-BridgeStatus) {
    Write-ManagerLog "Bridge already running at $script:BridgeUrl"
    return
  }

  Write-ManagerLog 'Starting Bridge process...'
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = '/c pnpm --filter agent-link-bridge start'
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['PORT'] = [string]$Port
  $psi.EnvironmentVariables['AGENTLINK_AUTO_PORT'] = '1'
  if (-not $psi.EnvironmentVariables['npm_config_registry']) {
    $psi.EnvironmentVariables['npm_config_registry'] = 'https://registry.npmmirror.com/'
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $proc.EnableRaisingEvents = $true
  $proc.add_OutputDataReceived({
    if ($EventArgs.Data) {
      Write-ManagerLog $EventArgs.Data
      if ($EventArgs.Data -match '(http://[^\s]+)') {
        $script:BridgeUrl = $Matches[1]
      }
    }
  })
  $proc.add_ErrorDataReceived({ if ($EventArgs.Data) { Write-ManagerLog "ERR $($EventArgs.Data)" } })
  $proc.add_Exited({ Write-ManagerLog "Bridge process exited with code $($proc.ExitCode)" })
  [void]$proc.Start()
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()
  $script:BridgeProcess = $proc
  Set-Status 'starting' $null 'Waiting for Bridge diagnostics...'
  Start-Sleep -Milliseconds 900
  [void](Refresh-BridgeStatus)
}

function Stop-BridgeProcess() {
  if ($script:BridgeProcess -and -not $script:BridgeProcess.HasExited) {
    Write-ManagerLog "Stopping managed Bridge PID $($script:BridgeProcess.Id)"
    $script:BridgeProcess.Kill()
    $script:BridgeProcess.WaitForExit(3000) | Out-Null
    $script:BridgeProcess = $null
    Set-Status 'stopped' $null 'Managed Bridge process stopped.'
    return
  }
  [System.Windows.Forms.MessageBox]::Show('This manager did not start the current Bridge process. Stop it from its original terminal, or use Restart after closing it.', 'AgentLink Bridge Manager') | Out-Null
}

function Restart-BridgeProcess() {
  Stop-BridgeProcess
  Start-Sleep -Milliseconds 600
  Start-BridgeProcess
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AgentLink Bridge Manager'
$form.Size = New-Object System.Drawing.Size(780, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(700, 520)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Status: checking'
$statusLabel.AutoSize = $true
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$statusLabel.Location = New-Object System.Drawing.Point(18, 16)
$form.Controls.Add($statusLabel)

$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.Location = New-Object System.Drawing.Point(18, 52)
$urlBox.Size = New-Object System.Drawing.Size(720, 28)
$urlBox.ReadOnly = $true
$form.Controls.Add($urlBox)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = 'Start'
$startButton.Location = New-Object System.Drawing.Point(18, 92)
$startButton.Size = New-Object System.Drawing.Size(105, 34)
$startButton.Add_Click({ Start-BridgeProcess })
$form.Controls.Add($startButton)

$restartButton = New-Object System.Windows.Forms.Button
$restartButton.Text = 'Restart'
$restartButton.Location = New-Object System.Drawing.Point(132, 92)
$restartButton.Size = New-Object System.Drawing.Size(105, 34)
$restartButton.Add_Click({ Restart-BridgeProcess })
$form.Controls.Add($restartButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = 'Stop'
$stopButton.Location = New-Object System.Drawing.Point(246, 92)
$stopButton.Size = New-Object System.Drawing.Size(105, 34)
$stopButton.Add_Click({ Stop-BridgeProcess })
$form.Controls.Add($stopButton)

$pairButton = New-Object System.Windows.Forms.Button
$pairButton.Text = 'Open QR'
$pairButton.Location = New-Object System.Drawing.Point(360, 92)
$pairButton.Size = New-Object System.Drawing.Size(105, 34)
$pairButton.Add_Click({ if ($script:BridgeUrl) { Start-Process "$script:BridgeUrl/pair" } })
$form.Controls.Add($pairButton)

$manageButton = New-Object System.Windows.Forms.Button
$manageButton.Text = 'Open Manager'
$manageButton.Location = New-Object System.Drawing.Point(474, 92)
$manageButton.Size = New-Object System.Drawing.Size(120, 34)
$manageButton.Add_Click({ if ($script:BridgeUrl) { Start-Process "$script:BridgeUrl/manage" } })
$form.Controls.Add($manageButton)

$logButton = New-Object System.Windows.Forms.Button
$logButton.Text = 'Open Log'
$logButton.Location = New-Object System.Drawing.Point(603, 92)
$logButton.Size = New-Object System.Drawing.Size(105, 34)
$logButton.Add_Click({ Start-Process notepad.exe $LogFile })
$form.Controls.Add($logButton)

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = 'Copy URL'
$copyButton.Location = New-Object System.Drawing.Point(18, 136)
$copyButton.Size = New-Object System.Drawing.Size(105, 32)
$copyButton.Add_Click({ if ($urlBox.Text) { Set-Clipboard -Value $urlBox.Text } })
$form.Controls.Add($copyButton)

$detailBox = New-Object System.Windows.Forms.TextBox
$detailBox.Location = New-Object System.Drawing.Point(18, 180)
$detailBox.Size = New-Object System.Drawing.Size(720, 360)
$detailBox.Multiline = $true
$detailBox.ScrollBars = 'Both'
$detailBox.ReadOnly = $true
$detailBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($detailBox)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ [void](Refresh-BridgeStatus) })
$timer.Start()

$form.Add_Shown({
  if (-not (Refresh-BridgeStatus)) { Start-BridgeProcess }
})
$form.Add_FormClosing({ $timer.Stop() })

[void][System.Windows.Forms.Application]::Run($form)
