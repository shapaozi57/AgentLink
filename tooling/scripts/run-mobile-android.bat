@echo off
setlocal
set BRIDGE_URL=%~1
if "%BRIDGE_URL%"=="" set BRIDGE_URL=http://10.0.2.2:4317
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
set PATH=C:\src\flutter\bin;%PATH%
cd /d "%~dp0\..\..\apps\mobile"
flutter run --dart-define=BRIDGE_URL=%BRIDGE_URL%
endlocal
