param([string]$Name = 'AgentLink Bridge Manager')
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $scriptDir 'agentlink-bridge-manager.bat'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$linkPath = Join-Path $desktop ($Name + '.lnk')
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($linkPath)
$link.TargetPath = $target
$link.WorkingDirectory = $scriptDir
$link.IconLocation = 'shell32.dll,137'
$link.Description = 'Start and manage AgentLink Bridge'
$link.Save()
Write-Output $linkPath
