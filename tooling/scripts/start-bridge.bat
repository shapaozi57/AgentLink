@echo off
setlocal
cd /d "%~dp0\..\.."
set PORT=4317
if not "%~1"=="" set PORT=%~1
set AGENTLINK_AUTO_PORT=1
if not defined npm_config_registry set npm_config_registry=https://registry.npmmirror.com/
pnpm --filter agent-link-bridge start
endlocal
