param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $SshTarget,

    [string] $Url = "http://10.248.98.2",

    [int] $Port = 1080,

    [int] $WaitSeconds = 180
)

$SocksHost = "127.0.0.1"
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ProfileRoot = Join-Path $ScriptDir ".campus-login-profile"
$BrowserSearchOrder = @("chrome", "edge", "firefox")

function Stop-LoginProxy {
    param([System.Diagnostics.Process] $Process)

    if ($Process -and -not $Process.HasExited) {
        Write-Host "Stopping SSH proxy..."
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Test-LocalPort {
    param(
        [string] $HostName,
        [int] $PortNumber
    )

    $Client = [System.Net.Sockets.TcpClient]::new()
    try {
        $Connect = $Client.BeginConnect($HostName, $PortNumber, $null, $null)
        if (-not $Connect.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }

        $Client.EndConnect($Connect)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $Client.Close()
    }
}

function Remove-BrowserProfile {
    param([string] $ProfileDir)

    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        return $true
    }

    for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
        try {
            Remove-Item -LiteralPath $ProfileDir -Recurse -Force -ErrorAction Stop
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Host "Warning: could not remove temporary browser profile:"
    Write-Host "  $ProfileDir"
    return $false
}

function Get-BrowserCandidates {
    param([string] $BrowserKey)

    $Candidates = @()

    switch ($BrowserKey) {
        "edge" {
            if ($env:ProgramFiles) {
                $Candidates += [pscustomobject]@{
                    Name = "Microsoft Edge"
                    Kind = "chromium"
                    Key = "edge"
                    Path = Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"
                    Command = $null
                }
            }
            if (${env:ProgramFiles(x86)}) {
                $Candidates += [pscustomobject]@{
                    Name = "Microsoft Edge"
                    Kind = "chromium"
                    Key = "edge"
                    Path = Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"
                    Command = $null
                }
            }
            $Candidates += [pscustomobject]@{
                Name = "Microsoft Edge"
                Kind = "chromium"
                Key = "edge"
                Path = $null
                Command = "msedge.exe"
            }
        }
        "firefox" {
            if ($env:ProgramFiles) {
                $Candidates += [pscustomobject]@{
                    Name = "Firefox"
                    Kind = "firefox"
                    Key = "firefox"
                    Path = Join-Path $env:ProgramFiles "Mozilla Firefox\firefox.exe"
                    Command = $null
                }
            }
            if (${env:ProgramFiles(x86)}) {
                $Candidates += [pscustomobject]@{
                    Name = "Firefox"
                    Kind = "firefox"
                    Key = "firefox"
                    Path = Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox\firefox.exe"
                    Command = $null
                }
            }
            $Candidates += [pscustomobject]@{
                Name = "Firefox"
                Kind = "firefox"
                Key = "firefox"
                Path = $null
                Command = "firefox.exe"
            }
        }
        "chrome" {
            foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LocalAppData)) {
                if ($Root) {
                    $Candidates += [pscustomobject]@{
                        Name = "Google Chrome"
                        Kind = "chromium"
                        Key = "chrome"
                        Path = Join-Path $Root "Google\Chrome\Application\chrome.exe"
                        Command = $null
                    }
                }
            }
            $Candidates += [pscustomobject]@{
                Name = "Google Chrome"
                Kind = "chromium"
                Key = "chrome"
                Path = $null
                Command = "chrome.exe"
            }
        }
    }

    return $Candidates
}

function Find-Browser {
    foreach ($BrowserKey in $BrowserSearchOrder) {
        foreach ($Candidate in (Get-BrowserCandidates -BrowserKey $BrowserKey)) {
            if ($Candidate.Path -and (Test-Path -LiteralPath $Candidate.Path)) {
                $Candidate | Add-Member -NotePropertyName Exe -NotePropertyValue $Candidate.Path -Force
                return $Candidate
            }

            if ($Candidate.Command) {
                $Command = Get-Command $Candidate.Command -ErrorAction SilentlyContinue
                if ($Command) {
                    $Candidate | Add-Member -NotePropertyName Exe -NotePropertyValue $Command.Source -Force
                    return $Candidate
                }
            }
        }
    }

    throw "Edge, Firefox, or Chrome was not found."
}

function Initialize-BrowserProfile {
    param(
        [object] $Browser,
        [string] $ProfileDir,
        [int] $SocksPort
    )

    if (Test-Path -LiteralPath $ProfileDir) {
        [void](Remove-BrowserProfile -ProfileDir $ProfileDir)
        if (Test-Path -LiteralPath $ProfileDir) {
            throw "Temporary browser profile is still in use: $ProfileDir"
        }
    }

    New-Item -ItemType Directory -Path $ProfileDir | Out-Null

    if ($Browser.Kind -ne "firefox") {
        return
    }

    $UserJs = @"
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", $SocksPort);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "");
user_pref("browser.shell.checkDefaultBrowser", false);
"@

    Set-Content -Path (Join-Path $ProfileDir "user.js") -Value $UserJs -Encoding ASCII
}

function Get-BrowserArgs {
    param(
        [object] $Browser,
        [string] $ProfileDir,
        [string] $TargetUrl,
        [int] $SocksPort
    )

    if ($Browser.Kind -eq "firefox") {
        return @(
            "--no-remote",
            "--profile", $ProfileDir,
            $TargetUrl
        )
    }

    return @(
        "--user-data-dir=$ProfileDir",
        "--no-first-run",
        "--no-default-browser-check",
        "--proxy-server=socks5://$SocksHost`:$SocksPort",
        $TargetUrl
    )
}

function Wait-BrowserOrEnter {
    param(
        [object] $Browser,
        [System.Diagnostics.Process] $Process
    )

    Write-Host ""
    Write-Host "$($Browser.Name) has started."
    Start-Sleep -Seconds 2

    if ($Process.HasExited) {
        Write-Host "The browser launcher process already exited, so window-close detection is not reliable."
        Write-Host "Finish portal login, then press any key here."
        [void][Console]::ReadKey($true)
        return
    }

    Write-Host "Finish portal login, then close the browser or press any key here."
    while (-not $Process.HasExited) {
        if ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
            break
        }
        Start-Sleep -Milliseconds 500
    }
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "Error: ssh command was not found."
    Write-Host "Please install OpenSSH Client and make sure ssh.exe is available in PATH."
    Write-Host "On Windows, install it from Settings -> System -> Optional features."
    exit 1
}

$SshProcess = $null
$ProfileDir = $null

try {
    $Browser = Find-Browser
    $ProfileDir = "$ProfileRoot-$($Browser.Key)"
    Initialize-BrowserProfile -Browser $Browser -ProfileDir $ProfileDir -SocksPort $Port

    Write-Host "Starting SSH SOCKS5 proxy on ${SocksHost}:$Port"
    Write-Host "If SSH asks for a password, type it in the SSH window."
    $SshProcess = Start-Process -FilePath "ssh" -ArgumentList @(
        "-o", "ExitOnForwardFailure=yes",
        "-N",
        "-D", "${SocksHost}:$Port",
        $SshTarget
    ) -WindowStyle Normal -PassThru

    Write-Host "Waiting for proxy port..."
    $Deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (-not (Test-LocalPort -HostName $SocksHost -PortNumber $Port)) {
        if ($SshProcess.HasExited) {
            throw "SSH proxy failed to start."
        }

        if ((Get-Date) -gt $Deadline) {
            throw "SSH SOCKS5 proxy did not become ready. Check SSH login, network reachability, and whether port $Port is already in use."
        }

        Start-Sleep -Milliseconds 500
    }

    Write-Host "Starting $($Browser.Name)..."
    $BrowserProcess = Start-Process -FilePath $Browser.Exe -ArgumentList (Get-BrowserArgs -Browser $Browser -ProfileDir $ProfileDir -TargetUrl $Url -SocksPort $Port) -PassThru
    Wait-BrowserOrEnter -Browser $Browser -Process $BrowserProcess
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($SshProcess) {
        Stop-LoginProxy -Process $SshProcess
    }

    if ($ProfileDir) {
        Start-Sleep -Seconds 1
        [void](Remove-BrowserProfile -ProfileDir $ProfileDir)
    }
}
