$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$NodeVersion = '24.14.0'
$NodeArchiveName = "node-v$NodeVersion-win-x64.zip"
$NodeSha256 = '313fa40c0d7b18575821de8cb17483031fe07d95de5994f6f435f3b345f85c66'
$NodeUrl = "https://nodejs.org/dist/v$NodeVersion/$NodeArchiveName"
$RepoUrl = 'https://codeload.github.com/scampf/gods-eye-view/zip/refs/heads/main'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'A2zz\GodsEyeView'
$AppDir = Join-Path $InstallRoot 'app'
$NodeDir = Join-Path $InstallRoot "node-v$NodeVersion-win-x64"
$LogPath = Join-Path $InstallRoot 'install.log'
$StartScript = Join-Path $InstallRoot 'Start-GodsEyeView.ps1'
$Url = 'http://localhost:4173'

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Stop-WithMessage([string]$Text) {
    Write-Host "`nINSTALL STOPPED: $Text" -ForegroundColor Red
    Write-Host "Log: $LogPath" -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit 1
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This installer is for Windows only.' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows installation is required.' }

    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    try { Start-Transcript -Path $LogPath -Append -Force | Out-Null } catch {}

    Write-Host "God's Eye View - A2zz Windows installer" -ForegroundColor Green
    Write-Host "Install location: $InstallRoot"
    Write-Host 'No administrator rights are required.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Step 'Preparing a private Node.js runtime'
    $nodeExe = Join-Path $NodeDir 'node.exe'
    $npmCmd = Join-Path $NodeDir 'npm.cmd'
    if (-not (Test-Path $nodeExe) -or -not (Test-Path $npmCmd)) {
        $nodeZip = Join-Path $env:TEMP $NodeArchiveName
        Remove-Item $nodeZip -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -UseBasicParsing -Uri $NodeUrl -OutFile $nodeZip

        $actualHash = (Get-FileHash -Algorithm SHA256 -Path $nodeZip).Hash.ToLowerInvariant()
        if ($actualHash -ne $NodeSha256) {
            throw "Node.js download failed SHA-256 verification. Expected $NodeSha256, got $actualHash."
        }

        Remove-Item $NodeDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $nodeZip -DestinationPath $InstallRoot -Force
        Remove-Item $nodeZip -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $nodeExe) -or -not (Test-Path $npmCmd)) {
        throw 'Portable Node.js did not install correctly.'
    }

    $nodeReported = (& $nodeExe --version).Trim()
    Write-Host "Node runtime ready: $nodeReported" -ForegroundColor Green
    $env:Path = "$NodeDir;$env:Path"

    Write-Step 'Downloading your GitHub fork'
    $repoZip = Join-Path $env:TEMP 'gods-eye-view-main.zip'
    $stageDir = Join-Path $env:TEMP ("gev-stage-" + [Guid]::NewGuid().ToString('N'))
    Remove-Item $repoZip -Force -ErrorAction SilentlyContinue
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $RepoUrl -OutFile $repoZip
    Expand-Archive -LiteralPath $repoZip -DestinationPath $stageDir -Force
    Remove-Item $repoZip -Force -ErrorAction SilentlyContinue

    $sourceDir = Get-ChildItem -LiteralPath $stageDir -Directory | Select-Object -First 1
    if ($null -eq $sourceDir -or -not (Test-Path (Join-Path $sourceDir.FullName 'package.json'))) {
        throw 'The GitHub download did not contain the expected application files.'
    }

    # Preserve local provider keys/settings if this installer is run again later.
    $envBackupDir = Join-Path $InstallRoot 'env-backup'
    Remove-Item $envBackupDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $AppDir) {
        $envFiles = @(Get-ChildItem -LiteralPath $AppDir -Force -File -Filter '.env*' -ErrorAction SilentlyContinue)
        if ($envFiles.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $envBackupDir | Out-Null
            foreach ($file in $envFiles) { Copy-Item -LiteralPath $file.FullName -Destination $envBackupDir -Force }
        }
        Remove-Item $AppDir -Recurse -Force
    }

    Move-Item -LiteralPath $sourceDir.FullName -Destination $AppDir
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path $envBackupDir) {
        Get-ChildItem -LiteralPath $envBackupDir -Force -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $AppDir -Force
        }
        Remove-Item $envBackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'Installing application dependencies'
    Push-Location $AppDir
    try {
        & $npmCmd ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE." }

        Write-Step 'Running the project setup doctor'
        & $nodeExe scripts/setup-doctor.mjs
        if ($LASTEXITCODE -ne 0) { throw "The project's setup doctor reported a problem (exit code $LASTEXITCODE)." }
    }
    finally {
        Pop-Location
    }

    Write-Step 'Creating one-click launcher'
    $escapedNodeDir = $NodeDir.Replace("'", "''")
    $escapedAppDir = $AppDir.Replace("'", "''")
    $escapedNpmCmd = $npmCmd.Replace("'", "''")
    $startTemplate = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$nodeDir = '__NODEDIR__'
$appDir = '__APPDIR__'
$npmCmd = '__NPMCMD__'
$url = 'http://localhost:4173'
$env:Path = "$nodeDir;$env:Path"

function Test-GevPort {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', 4173, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(500, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

if (Test-GevPort) {
    Start-Process $url
    exit 0
}

if (-not (Test-Path $npmCmd) -or -not (Test-Path $appDir)) {
    [System.Windows.Forms.MessageBox]::Show("God's Eye View installation files are missing. Run INSTALL_WINDOWS.bat again.", "God's Eye View") | Out-Null
    exit 1
}

$cmdLine = '""{0}" run dev"' -f $npmCmd
$server = Start-Process -FilePath $env:ComSpec -ArgumentList @('/k', $cmdLine) -WorkingDirectory $appDir -PassThru

for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    if (Test-GevPort) {
        Start-Process $url
        exit 0
    }
    if ($server.HasExited) { break }
}

[System.Windows.Forms.MessageBox]::Show("The local server did not open on port 4173. Leave the server window open and send ChatGPT a screenshot of the error shown there.", "God's Eye View - startup problem") | Out-Null
exit 1
'@
    $startContents = $startTemplate.Replace('__NODEDIR__', $escapedNodeDir).Replace('__APPDIR__', $escapedAppDir).Replace('__NPMCMD__', $escapedNpmCmd)
    Set-Content -LiteralPath $StartScript -Value $startContents -Encoding UTF8

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop "God's Eye View.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$StartScript`""
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.Description = "Start God's Eye View"
    $shortcut.Save()

    Write-Host "`nINSTALLATION COMPLETE" -ForegroundColor Green
    Write-Host "Desktop shortcut created: $shortcutPath"
    Write-Host "Application URL: $Url"
    Write-Host 'Starting it now...'

    try { Stop-Transcript | Out-Null } catch {}
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript
    exit $LASTEXITCODE
}
catch {
    try { $_ | Out-String | Add-Content -LiteralPath $LogPath } catch {}
    try { Stop-Transcript | Out-Null } catch {}
    Stop-WithMessage $_.Exception.Message
}
