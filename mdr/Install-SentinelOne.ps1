<#
.SYNOPSIS
  Install SentinelOne if it is not already installed.
.DESCRIPTION
  Exit codes:
    0     already installed, or installed successfully
    3010  installed, reboot required to finish
    1618  another install is running (Windows Installer busy / this script already running), try later
    10    OS not supported by the current agent (Win7 / 2008 R2 / older: needs the legacy agent, manual)
    11    32-bit Windows and no -InstallerPath32 given
    20    missing site token or installer path
    21    installer could not be copied/downloaded
    22    installer hash mismatch
    30    installer ran but the SentinelAgent service is not present afterwards
#>
[CmdletBinding()]
param(
    [string]$SiteToken     = $(if ($env:S1_SITE_TOKEN) { $env:S1_SITE_TOKEN } else { $env:SiteToken }),
    [string]$InstallerPath = $(if ($env:S1_INSTALLER)  { $env:S1_INSTALLER }  else { $env:InstallerPath }),
    [string]$InstallerPath32,          # optional 32-bit installer for x86 Windows
    [string]$LogDir = "$env:ProgramData\Tenax\S1Install",
    [int]$ServiceWaitSeconds = 180
)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $LogDir -Force
$Log = Join-Path $LogDir 'Install-SentinelOne.log'

function Write-Log([string]$Msg) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $Msg
    Add-Content -Path $Log -Value $line
    Write-Output $line
}
function Exit-With([int]$Code, [string]$Msg) {
    Write-Log "RESULT=$Code $Msg"
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
    exit $Code
}

function Get-S1Agent {
    $svc = Get-CimInstance Win32_Service -Filter "Name='SentinelAgent'" -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $exe = $svc.PathName.Trim('"')
    $ver = try { (Get-Item $exe -ErrorAction Stop).VersionInfo.FileVersion } catch { 'unknown' }
    [pscustomobject]@{ State = $svc.State; Version = $ver; Path = $exe }
}

# --- 1. Checks if the S1 agent is installed. If it is, script exits here. --------------------------------------------------
$agent = Get-S1Agent
if ($agent) {
    if ($agent.State -ne 'Running') {
        Write-Log "WARNING: Sentinel Agent $($agent.Version) is installed but service state = $($agent.State)"
    }
    Exit-With 0 "already installed (version $($agent.Version), service $($agent.State))"
}

# --- 2. Verifies agent compatibility and script arguments. ---------------------------------------------------------------------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\Tenax-Install-SentinelOne')
if (-not $script:Mutex.WaitOne(0)) { $script:Mutex = $null; Exit-With 1618 'another copy of this script is running' }

$os = Get-CimInstance Win32_OperatingSystem
if ([version]$os.Version -lt [version]'6.2') {
    Exit-With 10 "unsupported OS for current agent: $($os.Caption) $($os.Version)"
}

if (-not [Environment]::Is64BitOperatingSystem) {
    if (-not $InstallerPath32) { Exit-With 11 '32-bit Windows and no -InstallerPath32 supplied' }
    $InstallerPath = $InstallerPath32
}
if (-not $SiteToken)     { Exit-With 20 'no site token (-SiteToken or $env:S1_SITE_TOKEN)' }
if (-not $InstallerPath) { Exit-With 20 'no installer (-InstallerPath or $env:S1_INSTALLER)' }

# --- 3. Grabs the S1 agent installer package. --------------------------------------------------
$name  = Split-Path ($InstallerPath -split '\?')[0] -Leaf
$local = Join-Path $LogDir $name
try {
    if ($InstallerPath -match '^https?://') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "downloading $($InstallerPath -replace '\?.*','?<redacted>')"
        (New-Object Net.WebClient).DownloadFile($InstallerPath, $local)
    } else {
        Write-Log "copying $InstallerPath"
        Copy-Item -Path $InstallerPath -Destination $local -Force
    }
} catch { Exit-With 21 "could not download installer locally: $($_.Exception.Message)" }

# --- 4. Installs the S1 agent. --------------------------------------------------------------------------
$ext = [IO.Path]::GetExtension($local).ToLower()
if ($ext -eq '.msi') {
    $msiLog = Join-Path $LogDir 'msiexec-S1.log'
    $file = "$env:WINDIR\System32\msiexec.exe"
    $instArgs = "/i `"$local`" SITE_TOKEN=`"$SiteToken`" /qn /norestart /l*v `"$msiLog`""
} elseif ($ext -eq '.exe') {
    $file = $local
    $instArgs = "-t `"$SiteToken`" -q"
} else {
    Exit-With 21 "unrecognised installer type '$ext' (expected .msi or .exe)"
}

Write-Log "installing $name (OS $($os.Caption) $($os.Version))"
$p = Start-Process -FilePath $file -ArgumentList $instArgs -Wait -PassThru -WindowStyle Hidden
$rc = $p.ExitCode
Write-Log "installer exit code $rc"
if ($rc -eq 1618) { Exit-With 1618 'Windows Installer busy with another install, try later' }

# --- 5. Verifies S1 agent installed and running. -----------------------------------------------------------------------------
$deadline = (Get-Date).AddSeconds($ServiceWaitSeconds)
do { $agent = Get-S1Agent; if ($agent) { break }; Start-Sleep 10 } while ((Get-Date) -lt $deadline)

Remove-Item $local -Force -ErrorAction SilentlyContinue

if (-not $agent) {
    $code = if ($rc -ne 0) { $rc } else { 30 }
    Exit-With $code 'Install FAILED: SentinelAgent service not present (see msiexec-S1.log)'
}
if ($rc -in 3010, 1641) { Exit-With 3010 "installed $($agent.Version), reboot required" }
Exit-With 0 "installed $($agent.Version), service $($agent.State)"