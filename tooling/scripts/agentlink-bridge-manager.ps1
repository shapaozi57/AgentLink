param(
  [int]$Port = 4317,
  [string]$RelayUrl = $env:AGENTLINK_RELAY_URL,
  [string]$RelaySecret = $env:AGENTLINK_RELAY_SECRET,
  [string]$RelayDeviceId = $env:AGENTLINK_RELAY_DEVICE_ID,
  [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LogDir = Join-Path $Root 'tooling\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'bridge-manager.log'
$RelayUrl = if ($RelayUrl) { $RelayUrl.TrimEnd('/') } else { 'https://agentlink-relay.onrender.com' }
$RelayDeviceId = if ($RelayDeviceId) { $RelayDeviceId } else { 'pc-main' }

function Write-ManagerLog([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-JsonFast([string]$Uri, [int]$TimeoutMs = 1200) {
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

function Get-RelaySecretFromPairing([string]$Url) {
  if (-not $Url) { return $null }
  try {
    $pairing = Invoke-JsonFast "$Url/v1/pairing" 4000
    if (-not $pairing.payload) { return $null }
    $uri = [System.Uri]$pairing.payload
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    return $query['token']
  } catch {
    Write-ManagerLog "Relay token lookup failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-PortPid([int]$TargetPort) {
  try {
    $line = netstat -ano -p tcp | Select-String -Pattern ":$TargetPort\s+.*LISTENING" | Select-Object -First 1
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
      $candidatePort = [int]$Matches[1]
      if ($candidatePort -ge $StartPort -and $candidatePort -le $EndPort -and -not $ports.Contains($candidatePort)) {
        $ports.Add($candidatePort)
      }
    }
  } catch {}
  return @($ports | Sort-Object)
}

function Find-Bridge([int]$StartPort = 4317, [int]$EndPort = 4337) {
  foreach ($candidatePort in (Get-ListeningCandidatePorts $StartPort $EndPort)) {
    try {
      $pairing = Invoke-JsonFast "http://127.0.0.1:$candidatePort/v1/pairing" 700
      if ($pairing.service -eq 'agent-link-bridge') {
        return [pscustomobject]@{
          Url = [string]$pairing.preferredUrl
          LocalManageUrl = "http://127.0.0.1:$candidatePort/manage"
          Port = [int]$candidatePort
          Pid = Get-PortPid $candidatePort
          Pairing = $pairing
        }
      }
    } catch {}
  }
  return $null
}

function Stop-BridgeIfLocalOnly([object]$Bridge) {
  if (-not $Bridge) { return }
  if ($RelayUrl -and $Bridge.Pairing.preferredUrl -ne $RelayUrl) {
    $pidToStop = $Bridge.Pid
    if ($pidToStop) {
      Write-ManagerLog "Restarting Bridge PID $pidToStop to enable Relay URL $RelayUrl"
      taskkill /PID $pidToStop /F | Out-Null
      Start-Sleep -Milliseconds 900
    }
  }
}

function Start-BridgeProcess() {
  if ($RelayUrl -and -not $RelaySecret) { $RelaySecret = Get-RelaySecretFromPairing $RelayUrl }

  Write-ManagerLog "Starting Bridge browser manager on port $Port with Relay $RelayUrl"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = "/c pnpm --filter agent-link-bridge start >> `"$LogFile`" 2>>&1"
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['PORT'] = [string]$Port
  $psi.EnvironmentVariables['AGENTLINK_AUTO_PORT'] = '1'
  if ($RelayUrl) { $psi.EnvironmentVariables['AGENTLINK_RELAY_URL'] = $RelayUrl }
  if ($RelaySecret) { $psi.EnvironmentVariables['AGENTLINK_RELAY_SECRET'] = $RelaySecret }
  if ($RelayDeviceId) { $psi.EnvironmentVariables['AGENTLINK_RELAY_DEVICE_ID'] = $RelayDeviceId }
  if (-not $psi.EnvironmentVariables['npm_config_registry']) {
    $psi.EnvironmentVariables['npm_config_registry'] = 'https://registry.npmmirror.com/'
  }
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
}

function Wait-Bridge([int]$TimeoutMs = 15000) {
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  do {
    $bridge = Find-Bridge 4317 4337
    if ($bridge) { return $bridge }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return $null
}

if ($ValidateOnly) {
  Write-Output "AgentLink Bridge Browser Manager script is valid. Root=$Root"
  exit 0
}

try {
  $bridge = Find-Bridge 4317 4337
  Stop-BridgeIfLocalOnly $bridge
  $bridge = Find-Bridge 4317 4337
  if (-not $bridge) {
    Start-BridgeProcess
    $bridge = Wait-Bridge 20000
  }
  if (-not $bridge) {
    Write-ManagerLog 'Bridge did not become ready in time.'
    Start-Process notepad.exe $LogFile
    exit 1
  }
  Write-ManagerLog "Opening browser manager: $($bridge.LocalManageUrl)"
  Start-Process $bridge.LocalManageUrl
} catch {
  Write-ManagerLog "Manager launch failed: $($_.Exception.Message)"
  Start-Process notepad.exe $LogFile
  exit 1
}
