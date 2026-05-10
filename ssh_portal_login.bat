@echo off
setlocal

set "LOGIN_URL=https://10.248.98.2"
set "SOCKS_HOST=127.0.0.1"
set "SOCKS_PORT=1080"
set "PROFILE_ROOT=%~dp0.campus-login-profile"

if "%~1"=="" (
    echo Usage:
    echo   %~nx0 TARGET
    echo   %~nx0 user@a.b.c.d
    exit /b 2
)

set "SSH_TARGET=%~1"

where ssh >nul 2>nul
if errorlevel 1 (
    echo Error: ssh command was not found.
    echo Please install OpenSSH Client and make sure ssh.exe is available in PATH.
    echo On Windows, install it from Settings -^> System -^> Optional features.
    exit /b 1
)

echo Starting SSH SOCKS5 proxy on %SOCKS_HOST%:%SOCKS_PORT%
echo If SSH asks for a password, type it in the new SSH window.

start "ssh-portal-login proxy" ssh -o ExitOnForwardFailure=yes -N -D %SOCKS_HOST%:%SOCKS_PORT% %SSH_TARGET%

echo Waiting for proxy port...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$deadline=(Get-Date).AddSeconds(180); while((Get-Date) -lt $deadline){ $c=New-Object Net.Sockets.TcpClient; try { $iar=$c.BeginConnect('%SOCKS_HOST%',%SOCKS_PORT%,$null,$null); if($iar.AsyncWaitHandle.WaitOne(500)){ $c.EndConnect($iar); exit 0 } } catch {} finally { $c.Close() }; Start-Sleep -Milliseconds 500 }; exit 1"

if errorlevel 1 (
    echo Error: SSH SOCKS5 proxy did not become ready.
    echo Check SSH login, network reachability, and whether port %SOCKS_PORT% is already in use.
    exit /b 1
)

echo Starting browser...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$profileRoot='%PROFILE_ROOT%'; $hostName='%SOCKS_HOST%'; $port=%SOCKS_PORT%; $url='%LOGIN_URL%';" ^
  "$pf=$env:ProgramFiles; $pfx=${env:ProgramFiles(x86)}; $la=$env:LocalAppData;" ^
  "$browsers=@();" ^
  "if($pf){ $browsers += @{Name='Google Chrome'; Kind='chromium'; Key='chrome'; Path=Join-Path $pf 'Google\Chrome\Application\chrome.exe'} }" ^
  "if($pfx){ $browsers += @{Name='Google Chrome'; Kind='chromium'; Key='chrome'; Path=Join-Path $pfx 'Google\Chrome\Application\chrome.exe'} }" ^
  "if($la){ $browsers += @{Name='Google Chrome'; Kind='chromium'; Key='chrome'; Path=Join-Path $la 'Google\Chrome\Application\chrome.exe'} }" ^
  "$browsers += @{Name='Google Chrome'; Kind='chromium'; Key='chrome'; Command='chrome.exe'};" ^
  "if($pf){ $browsers += @{Name='Microsoft Edge'; Kind='chromium'; Key='edge'; Path=Join-Path $pf 'Microsoft\Edge\Application\msedge.exe'} }" ^
  "if($pfx){ $browsers += @{Name='Microsoft Edge'; Kind='chromium'; Key='edge'; Path=Join-Path $pfx 'Microsoft\Edge\Application\msedge.exe'} }" ^
  "$browsers += @{Name='Microsoft Edge'; Kind='chromium'; Key='edge'; Command='msedge.exe'};" ^
  "if($pf){ $browsers += @{Name='Firefox'; Kind='firefox'; Key='firefox'; Path=Join-Path $pf 'Mozilla Firefox\firefox.exe'} }" ^
  "if($pfx){ $browsers += @{Name='Firefox'; Kind='firefox'; Key='firefox'; Path=Join-Path $pfx 'Mozilla Firefox\firefox.exe'} }" ^
  "$browsers += @{Name='Firefox'; Kind='firefox'; Key='firefox'; Command='firefox.exe'};" ^
  "$browser=$null; foreach($b in $browsers){ if($b.Path -and (Test-Path -LiteralPath $b.Path)){ $browser=$b; $browser.Exe=$b.Path; break }; if($b.Command){ $cmd=Get-Command $b.Command -ErrorAction SilentlyContinue; if($cmd){ $browser=$b; $browser.Exe=$cmd.Source; break } } }" ^
  "if(-not $browser){ Write-Host 'Error: Edge, Firefox, or Chrome was not found.'; exit 1 }" ^
  "$profileDir = $profileRoot + '-' + $browser.Key;" ^
  "if(Test-Path -LiteralPath $profileDir){ Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue; if(Test-Path -LiteralPath $profileDir){ Write-Host 'Error: temporary browser profile is still in use:'; Write-Host ('  ' + $profileDir); exit 1 } }" ^
  "New-Item -ItemType Directory -Path $profileDir | Out-Null;" ^
  "if($browser.Kind -eq 'firefox'){ $userJs=@('user_pref(""network.proxy.type"", 1);','user_pref(""network.proxy.socks"", ""127.0.0.1"");',('user_pref(""network.proxy.socks_port"", ' + $port + ');'),'user_pref(""network.proxy.socks_version"", 5);','user_pref(""network.proxy.socks_remote_dns"", true);','user_pref(""network.proxy.no_proxies_on"", """");','user_pref(""browser.shell.checkDefaultBrowser"", false);'); Set-Content -Path (Join-Path $profileDir 'user.js') -Value ($userJs -join [Environment]::NewLine) -Encoding ASCII; $argsList=@('--no-remote','--profile',$profileDir,$url) } else { $argsList=@(('--user-data-dir=' + $profileDir),'--no-first-run','--no-default-browser-check',('--proxy-server=socks5://' + $hostName + ':' + $port),$url) }" ^
  "$p=Start-Process -FilePath $browser.Exe -ArgumentList $argsList -PassThru;" ^
  "Write-Host ''; Write-Host ($browser.Name + ' has started.');" ^
  "Start-Sleep -Seconds 2;" ^
  "if($p.HasExited){ Write-Host 'The browser launcher process already exited, so window-close detection is not reliable.'; Write-Host 'Finish portal login, then press any key here.'; [void][Console]::ReadKey($true) } else { Write-Host 'Finish portal login, then close the browser or press any key here.'; while(-not $p.HasExited){ if([Console]::KeyAvailable){ [void][Console]::ReadKey($true); break }; Start-Sleep -Milliseconds 500 } }" ^
  "Start-Sleep -Seconds 1;" ^
  "Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue;" ^
  "if(Test-Path -LiteralPath $profileDir){ Write-Host 'Warning: could not remove temporary browser profile:'; Write-Host ('  ' + $profileDir); Write-Host 'Close the browser and delete it manually.' }"

echo.
echo Close the SSH window named "ssh-portal-login proxy" if it is still open.

endlocal
