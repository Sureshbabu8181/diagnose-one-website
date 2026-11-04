#Requires -Version 5.1
<#
.SYNOPSIS
ShareChat Windows x64 onboarding: Chrome, Slack, OneLogin Desktop Pro, NinjaOne.
.DESCRIPTION
Run in elevated 64-bit Windows PowerShell 5.1, or as SYSTEM through an RMM.
Chrome and Slack use rolling official downloads. OneLogin and NinjaOne are pinned.
Wi-Fi cleanup is scheduled 20 minutes after the app pass, including partial failure.
No Sophos installer is included. No automatic reboot is performed.
.EXAMPLE
.\AppOnboarding.ps1 -Check
.EXAMPLE
.\AppOnboarding.ps1 -DryRun
.EXAMPLE
.\AppOnboarding.ps1 -NoUser
.EXAMPLE
$password = Read-Host 'Local administrator password' -AsSecureString
.\AppOnboarding.ps1 -AdminPassword $password
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet('chrome', 'slack', 'onelogin', 'ninja')][string[]]$Skip = @(),
    [switch]$NoUser,
    [string]$AdminUser = 'Admin',
    [Security.SecureString]$AdminPassword,
    [switch]$ResetAdminPassword,
    [ValidatePattern('^[a-zA-Z0-9-]+$')][string]$OneLoginSubdomain = 'sharechat',
    [switch]$NoWifiCleanup
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Run in 64-bit Windows PowerShell on an x64 Windows PC; ARM64 is not supported by this package set.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.' }
if ($Check -and $DryRun) { throw 'Choose either -Check or -DryRun.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator, or run as SYSTEM through NinjaOne.'
}
$Apps = @(
    [pscustomobject]@{ Key='chrome'; Label='Google Chrome'; Pattern='^Google Chrome$'; Publisher='Google (LLC|Inc)'; Url='https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' },
    [pscustomobject]@{ Key='slack'; Label='Slack (MSIX)'; Pattern=''; Publisher=''; Url='https://slack.com/api/desktop.latestRelease?arch=x64&redirect=true&variant=msix' },
    [pscustomobject]@{ Key='onelogin'; Label='OneLogin Desktop Pro'; Pattern='^OneLogin Desktop'; Publisher='OneLogin|One Identity'; Url='https://app.onelogin.com/onelogin-downloads/desktop/windows/OneLoginDesktopProInstaller-3.4.4.1106.msi' },
    [pscustomobject]@{ Key='ninja'; Label='NinjaOne agent'; Pattern='^Ninja(RMM|One)'; Publisher='Ninja(RMM|One)'; Url='https://oc.ninjarmm.com/agent/installer/3591ee18-6d91-48e5-8fa4-acf8fe81159f/15.0.10212/NinjaOne-Agent-ShareChat-BLR-WINDOWSLAPTOP-x86-64.msi' }
)
$TaskName = 'ShareChat-AppOnboarding-ForgetWifi'
$Results = New-Object 'System.Collections.Generic.List[object]'
$script:RebootNeeded = $false

function Get-AppVersion($App) {
    if ($App.Key -eq 'slack') {
        # Provisioning is the desired machine-wide state, not a per-user EXE install.
        $packages = @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'com.tinyspeck.slackdesktop')
        return ($packages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1 -ExpandProperty Version)
    }
    $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    # Avoid Win32_Product: querying it can trigger MSI repair operations.
    $entries = @(Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object {
        $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $App.Pattern -and
        $_.PSObject.Properties['DisplayVersion']
    })
    return ($entries | Sort-Object {
        try { [version]$_.DisplayVersion } catch { [version]'0.0' }
    } -Descending | Select-Object -First 1 -ExpandProperty DisplayVersion)
}

function Add-Result([string]$Name, [string]$State, [string]$Detail) {
    $Results.Add([pscustomobject]@{Step=$Name; Status=$State; Detail=$Detail})
    Write-Host "[$State] ${Name}: $Detail"
}

function Receive-Installer([string]$Url, [string]$Path) {
    for ($attempt=1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600
            if ((Get-Item -LiteralPath $Path).Length -eq 0) { throw 'Downloaded file is empty.' }
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Get-MsiVersion([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    $view = $database.OpenView("SELECT Value FROM Property WHERE Property = 'ProductVersion'")
    try {
        $view.Execute()
        $record = $view.Fetch()
        if ($null -eq $record) { throw 'MSI ProductVersion is missing.' }
        return [version]$record.StringData(1)
    } finally {
        $view.Close()
        foreach ($obj in @($view, $database, $installer)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)
        }
    }
}

function Install-Msi($App, [string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $App.Publisher) {
        throw "MSI signature/publisher verification failed for $($App.Label): $($signature.Status)"
    }
    if ($App.Key -eq 'chrome') {
        $available = Get-MsiVersion $Path
        $installed = Get-AppVersion $App
        if ($installed -and [version]$installed -ge $available) {
            Write-Host "Chrome $installed is already at or above the downloaded release $available."
            return
        }
    }
    $msiLog = Join-Path $RunDir "$($App.Key)-msi.log"
    $arguments = "/i `"$Path`" /qn /norestart REBOOT=ReallySuppress /L*v `"$msiLog`""
    if ($App.Key -eq 'onelogin') { $arguments += " SUBDOMAIN=$OneLoginSubdomain" }
    for ($attempt=1; $attempt -le 3; $attempt++) {
        $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 1618 -or $attempt -eq 3) { break }
        Start-Sleep -Seconds 15
    }
    if ($process.ExitCode -notin @(0, 1641, 3010)) { throw "MSI exit code $($process.ExitCode). See $msiLog" }
    if ($process.ExitCode -in @(1641, 3010)) { $script:RebootNeeded = $true }
}

function Install-Slack([string]$Path) {
    # DISM validates the package signature; check its identity before provisioning.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry) { throw 'Slack MSIX manifest is missing.' }
        $stream = $entry.Open()
        try {
            $manifest = New-Object System.Xml.XmlDocument
            $manifest.XmlResolver = $null
            $manifest.Load($stream)
        } finally { $stream.Dispose() }
        if ($manifest.Package.Identity.Name -ne 'com.tinyspeck.slackdesktop') { throw 'Unexpected MSIX package identity.' }
        $available = [version]$manifest.Package.Identity.Version
    } finally { $archive.Dispose() }
    $installed = Get-AppVersion ($Apps | Where-Object Key -eq 'slack')
    if ($installed -and [version]$installed -ge $available) {
        Write-Host "Slack $installed is already at or above the downloaded release $available."
        return
    }
    Add-AppxProvisionedPackage -Online -PackagePath $Path -SkipLicense -Regions 'all' | Out-Null
}

function Set-OnboardingAdmin {
    $user = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
    if (-not $user -or $ResetAdminPassword) {
        if ($null -eq $AdminPassword -or $AdminPassword.Length -eq 0) {
            if ($identity.User.Value -eq 'S-1-5-18' -or -not [Environment]::UserInteractive) {
                throw 'Supply -AdminPassword as a SecureString via your RMM, or use -NoUser.'
            }
            $AdminPassword = Read-Host "Password for local administrator $AdminUser" -AsSecureString
        }
        if ($null -eq $AdminPassword -or $AdminPassword.Length -eq 0) { throw 'An empty administrator password is not allowed.' }
        if ($user) { Set-LocalUser -Name $AdminUser -Password $AdminPassword }
        else { $user = New-LocalUser -Name $AdminUser -Password $AdminPassword -Description 'IT local administrator' }
    }
    if (-not $user.Enabled) { Enable-LocalUser -Name $AdminUser }
    $group = Get-LocalGroup -SID 'S-1-5-32-544'
    $member = @(Get-LocalGroupMember -Group $group | Where-Object { $_.SID.Value -eq $user.SID.Value })
    if ($member.Count -eq 0) { Add-LocalGroupMember -Group $group -Member $user }
}

function Register-WifiCleanup {
    # Native Wi-Fi APIs match the actual SSID, even when the profile has another name.
    # They also avoid localized netsh output and wildcard profile deletion.
    $worker = @'
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot 'wifi-cleanup.log') -Append | Out-Null
try {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Xml;
public static class OnboardingWifi {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 struct InterfaceInfo { public Guid Id; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Description; public int State; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 struct ProfileInfo { [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Name; public uint Flags; }
 [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
 [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
 [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
 [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
 [DllImport("wlanapi.dll")] static extern uint WlanGetProfileList(IntPtr handle, ref Guid id, IntPtr reserved, out IntPtr list);
 [DllImport("wlanapi.dll", CharSet=CharSet.Unicode)] static extern uint WlanGetProfile(IntPtr handle, ref Guid id, string name, IntPtr reserved, out IntPtr xml, ref uint flags, out uint access);
 [DllImport("wlanapi.dll", CharSet=CharSet.Unicode)] static extern uint WlanDeleteProfile(IntPtr handle, ref Guid id, string name, IntPtr reserved);
 static void Check(uint result) { if(result != 0) throw new Win32Exception((int)result); }
 public static void Forget(string[] ssids) {
  uint version; IntPtr handle; Check(WlanOpenHandle(2, IntPtr.Zero, out version, out handle));
  try {
   IntPtr interfaces; Check(WlanEnumInterfaces(handle, IntPtr.Zero, out interfaces));
   try {
    int count=Marshal.ReadInt32(interfaces); if(count==0) throw new Exception("No Wi-Fi interfaces; retrying later.");
    var errors=new List<string>();
    for(int i=0;i<count;i++) {
     var info=(InterfaceInfo)Marshal.PtrToStructure(IntPtr.Add(interfaces,8+i*Marshal.SizeOf(typeof(InterfaceInfo))),typeof(InterfaceInfo));
     Guid id=info.Id; IntPtr profiles; Check(WlanGetProfileList(handle,ref id,IntPtr.Zero,out profiles));
     try {
      int n=Marshal.ReadInt32(profiles);
      for(int j=0;j<n;j++) {
       var profile=(ProfileInfo)Marshal.PtrToStructure(IntPtr.Add(profiles,8+j*Marshal.SizeOf(typeof(ProfileInfo))),typeof(ProfileInfo));
       IntPtr xml; uint flags=0,access; Check(WlanGetProfile(handle,ref id,profile.Name,IntPtr.Zero,out xml,ref flags,out access));
       string ssid;
       try {
        var doc=new XmlDocument(); doc.XmlResolver=null; doc.LoadXml(Marshal.PtrToStringUni(xml));
        var ns=new XmlNamespaceManager(doc.NameTable); ns.AddNamespace("w","http://www.microsoft.com/networking/WLAN/profile/v1");
        var node=doc.SelectSingleNode("/w:WLANProfile/w:SSIDConfig/w:SSID/w:name",ns);
        ssid=node==null ? null : node.InnerText;
       } finally { WlanFreeMemory(xml); }
       if(Array.IndexOf(ssids,ssid)<0) continue;
       uint result=WlanDeleteProfile(handle,ref id,profile.Name,IntPtr.Zero);
       if(result!=0) errors.Add(profile.Name+": "+new Win32Exception((int)result).Message);
       else Console.WriteLine("Forgot SSID: "+ssid+" (profile "+profile.Name+")");
      }
     } finally { WlanFreeMemory(profiles); }
    }
    if(errors.Count>0) throw new Exception(String.Join("; ",errors));
   } finally { WlanFreeMemory(interfaces); }
  } finally { WlanCloseHandle(handle,IntPtr.Zero); }
 }
}
"@
[OnboardingWifi]::Forget(@('IT Resources', 'Guest-SC', 'Guest-External'))
Write-Host "Wi-Fi cleanup complete: $(Get-Date -Format o)"
Unregister-ScheduledTask -TaskName 'ShareChat-AppOnboarding-ForgetWifi' -Confirm:$false
} catch { Write-Output $_; exit 1 }
finally { Stop-Transcript | Out-Null }
Remove-Item -LiteralPath $PSCommandPath -Force
'@
    $workerPath = Join-Path $RunDir 'Forget-Wifi.ps1'
    Set-Content -LiteralPath $workerPath -Value $worker -Encoding UTF8
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$workerPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(20)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Stop a previous cleanup before replacing it, so it cannot unregister the new task.
    $previous = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($previous) { Stop-ScheduledTask -TaskName $TaskName }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal -Force | Out-Null
}

if ($Check -or $DryRun) {
    if (-not $NoUser) {
        $user = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
        $state = if ($user) { "Exists; enabled=$($user.Enabled)" } else { 'Missing; would create' }
        Write-Host "Local account ${AdminUser}: $state"
        if ($user) {
            $group = Get-LocalGroup -SID 'S-1-5-32-544'
            $isAdmin = @(Get-LocalGroupMember -Group $group | Where-Object { $_.SID.Value -eq $user.SID.Value }).Count -gt 0
            Write-Host "Administrator membership: $isAdmin"
        }
        if ($DryRun -and $ResetAdminPassword) { Write-Host 'Would reset the configured local administrator password.' }
    }
    foreach ($app in $Apps) {
        $version = Get-AppVersion $app
        $state = if ($Skip -contains $app.Key) { 'SKIP' } elseif ($DryRun -and $app.Key -in @('chrome','slack')) { 'Fetch current release; install/update if newer' } elseif ($DryRun -and ($Force -or -not $version)) { 'INSTALL' } elseif ($version) { 'Present' } else { 'Missing' }
        Write-Host "$($app.Label): $state $version"
    }
    if ($DryRun -and -not $NoWifiCleanup) { Write-Host 'Would schedule Wi-Fi cleanup 20 minutes after the app pass: IT Resources, Guest-SC, Guest-External.' }
    if ($Check) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) { Write-Host "Wi-Fi cleanup task: $($task.State)" } else { Write-Host 'Wi-Fi cleanup task: not scheduled' }
    }
    exit 0
}

# Restrict scripts executed later as SYSTEM to administrators and SYSTEM.
$Root = Join-Path $env:ProgramData 'ShareChat-AppOnboarding'
if ((Test-Path -LiteralPath $Root) -and ((Get-Item -LiteralPath $Root).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'The onboarding directory must not be a junction or symbolic link.'
}
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $Root -AclObject $acl
$RunDir = Join-Path $Root ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $RunDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Start-Transcript -Path (Join-Path $RunDir 'onboarding.log') | Out-Null
try {
    if ($NoUser) { Add-Result 'Admin account' 'SKIP' '-NoUser' }
    else {
        try { Set-OnboardingAdmin; Add-Result 'Admin account' 'OK' "$AdminUser is enabled and an administrator" }
        catch { Add-Result 'Admin account' 'FAILED' $_.Exception.Message }
    }
    foreach ($app in $Apps) {
        if ($Skip -contains $app.Key) { Add-Result $app.Label 'SKIP' '-Skip'; continue }
        try {
            $existing = Get-AppVersion $app
            if ($app.Key -in @('onelogin','ninja') -and $existing -and -not $Force) {
                Add-Result $app.Label 'PRESENT' "$existing (use -Force to rerun the pinned installer)"
                continue
            }
            $extension = if ($app.Key -eq 'slack') { 'msix' } else { 'msi' }
            $path = Join-Path $RunDir "$($app.Key).$extension"
            Write-Host "Downloading $($app.Label)"
            Receive-Installer $app.Url $path
            if ($app.Key -eq 'slack') { Install-Slack $path } else { Install-Msi $app $path }
            $version = Get-AppVersion $app
            if (-not $version) { throw 'Installer finished, but machine-wide installation could not be verified.' }
            Add-Result $app.Label 'OK' "$version"
            Remove-Item -LiteralPath $path -Force
        } catch { Add-Result $app.Label 'FAILED' $_.Exception.Message }
    }
    if ($NoWifiCleanup) { Add-Result 'Wi-Fi cleanup' 'SKIP' 'No new task scheduled; an existing task is not cancelled' }
    else {
        try { Register-WifiCleanup; Add-Result 'Wi-Fi cleanup' 'SCHEDULED' '20 minutes from now; includes runs with app failures' }
        catch { Add-Result 'Wi-Fi cleanup' 'FAILED' $_.Exception.Message }
    }
    $Results | Format-Table -AutoSize -Wrap | Out-Host
    Write-Host "Logs and retained failed downloads: $RunDir"
    Write-Host 'Slack MSIX becomes available for users at their next sign-in. Complete OneLogin sign-in setup as the employee.'
    if ($script:RebootNeeded) { Write-Warning 'An installer requested a restart. No restart was initiated.' }
} finally { Stop-Transcript | Out-Null }
if (@($Results | Where-Object Status -eq 'FAILED').Count -gt 0) { exit 1 }
if ($script:RebootNeeded) { exit 3010 }
exit 0
