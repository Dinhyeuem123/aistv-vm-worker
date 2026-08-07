$ErrorActionPreference = 'Continue'
$tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
function Install-NetworkPkg {
  if (Test-Path -LiteralPath $tsExe) { Write-Host "Network: da cai san"; return $true }
  $exe = Join-Path $env:RUNNER_TEMP "tailscale-setup.exe"
  try {
    Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-full-1.98.4.exe" -OutFile $exe -UseBasicParsing -TimeoutSec 120
    if (Test-Path -LiteralPath $exe) {
      $p = Start-Process -FilePath $exe -ArgumentList @("/quiet") -Wait -PassThru -NoNewWindow
      for ($w = 0; $w -lt 20; $w++) { if (Test-Path -LiteralPath $tsExe) { break }; Start-Sleep -Seconds 2 }
    }
  } catch { Write-Host "Network EXE loi: $($_.Exception.Message)" }
  if (Test-Path -LiteralPath $tsExe) { return $true }
  return $false
}
Install-NetworkPkg | Out-Null
$null = New-Item -Path 'C:\AISTV' -ItemType Directory -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $tsExe) {
  $ip = 'pending'
  for ($t = 0; $t -lt 18; $t++) {
    try {
      $j = & $tsExe status --json 2>$null | ConvertFrom-Json
      if ($j.Self.Online -eq $true -and $j.Self.TailscaleIPs) {
        foreach ($a in $j.Self.TailscaleIPs) { $s = "$a".Trim(); if ($s -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $s; break } }
      }
    } catch {}
    if ($ip -ne 'pending') { break }
    Start-Sleep -Seconds 5
  }
} else {
  $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 30).ip
}
$vmUser = 'AISTV'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VmAuth {
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool LogonUser(string u, string d, string p, int t, int l, out IntPtr h);
  [DllImport("kernel32.dll")]
  public static extern bool CloseHandle(IntPtr h);
}
"@ -ErrorAction SilentlyContinue
function New-VmPassword {
  return -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 52 | ForEach-Object { [char]$_ })
}
function Test-VmPassword([string]$u, [string]$p) {
  try {
    $h = [IntPtr]::Zero
    if ([VmAuth]::LogonUser($u, '.', $p, 2, 0, [ref]$h)) {
      [VmAuth]::CloseHandle($h) | Out-Null
      return $true
    }
  } catch {}
  return $false
}
function Set-VmUser([string]$u, [string]$p) {
  $sec = ConvertTo-SecureString $p -AsPlainText -Force
  if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $u -Password $sec -PasswordNeverExpires $true -ErrorAction SilentlyContinue
  } else {
    New-LocalUser -Name $u -Password $sec -FullName 'AI STV User' -PasswordNeverExpires -ErrorAction SilentlyContinue
  }
  $lu = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
  if ($lu) { $lu | Enable-LocalUser -ErrorAction SilentlyContinue }
  Add-LocalGroupMember -Group 'Administrators' -Member $u -ErrorAction SilentlyContinue
  Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $u -ErrorAction SilentlyContinue
  # Fallback: neu module LocalAccounts loi thi dung net user
  if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) {
    & net.exe user $u $p /add /expires:never /passwordchg:no /y 2>$null | Out-Null
    & net.exe localgroup Administrators $u /add 2>$null | Out-Null
    & net.exe localgroup "Remote Desktop Users" $u /add 2>$null | Out-Null
  }
}
$password = ''
foreach ($try in 1..3) {
  $password = New-VmPassword
  Set-VmUser $vmUser $password
  if (Test-VmPassword $vmUser $password) { break }
  Write-Host "Password verify failed (try $try), regenerating..."
  Start-Sleep -Seconds 2
}
Write-Host "Password OK: $([bool](Test-VmPassword $vmUser $password))"
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' | Out-Null
# Fix RDP Windows Server 2025: baseline chan local account (dac biet local admin) dang nhap RDP
# -> bao 'sai username/password' du mat khau dung. Bo deny S-1-5-113/S-1-5-114, them AISTV vao allow, tat NLA.
$vmSid = (Get-LocalUser -Name $vmUser -ErrorAction SilentlyContinue).SID.Value
try {
  $cfgFile = Join-Path $env:RUNNER_TEMP 'rdp-secpol.cfg'
  secedit /export /cfg $cfgFile /areas USER_RIGHTS 2>$null | Out-Null
  if (Test-Path -LiteralPath $cfgFile) {
    $txt = Get-Content -LiteralPath $cfgFile -Raw
    $lines = $txt -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
      if ($line -match '^\s*SeDenyRemoteInteractiveLogonRight\s*=') {
        $out.Add('SeDenyRemoteInteractiveLogonRight = *S-1-5-32-546')
      } elseif ($line -match '^\s*SeRemoteInteractiveLogonRight\s*=') {
        $val = ($line -split '=', 2)[1].Trim()
        if ($vmSid -and $val -notmatch [regex]::Escape($vmSid)) {
          $val = ($val.TrimEnd(',') + ",*$vmSid")
        }
        $out.Add("SeRemoteInteractiveLogonRight = $val")
      } else {
        $out.Add($line)
      }
    }
    $newTxt = ($out -join "`r`n")
    if ($newTxt -ne $txt) {
      Set-Content -LiteralPath $cfgFile $newTxt -NoNewline -Encoding ASCII
      secedit /configure /db secedit.sdb /cfg $cfgFile /areas USER_RIGHTS 2>$null | Out-Null
      Write-Host "RDP policy fixed: local-account deny removed, AISTV added to RDP allow"
    }
  }
} catch { Write-Host "RDP secedit loi: $($_.Exception.Message)" }
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'RestrictRemoteLogon' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue
# Tat NLA (UserAuthentication=0): tranh loi CredSSP/NLA lam RDP bao 'sai mat khau' du nhap dung
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue
Restart-Service TermService -Force -ErrorAction SilentlyContinue
# Set up wallpaper & account picture
$ws2 = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$wpSrc = Join-Path $ws2 "img19.png"
$avSrc = Join-Path $ws2 "user.png"
$lsSrc = Join-Path $ws2 "img0.png"
$wpDst = "C:\AISTV\wallpaper.png"
$avDst = "C:\AISTV\user.png"
$lsDst = "C:\AISTV\lockscreen.png"
if (Test-Path -LiteralPath $wpSrc) { Copy-Item -LiteralPath $wpSrc -Destination $wpDst -Force; Write-Host "Wallpaper image copied" }
if (Test-Path -LiteralPath $avSrc) { Copy-Item -LiteralPath $avSrc -Destination $avDst -Force; Write-Host "Avatar image copied" }
if (Test-Path -LiteralPath $lsSrc) { Copy-Item -LiteralPath $lsSrc -Destination $lsDst -Force; Write-Host "Lockscreen image copied" }
if (Test-Path -LiteralPath $wpDst) {
  try {
    & reg.exe load "HKU\_AISTV_DEF" "C:\Users\Default\NTUSER.DAT" 2>$null
    $null = New-Item -Path "HKU:\_AISTV_DEF\Control Panel\Desktop" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKU:\_AISTV_DEF\Control Panel\Desktop" -Name 'Wallpaper' -Value $wpDst -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKU:\_AISTV_DEF\Control Panel\Desktop" -Name 'WallpaperStyle' -Value '10' -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKU:\_AISTV_DEF\Control Panel\Desktop" -Name 'TileWallpaper' -Value '0' -Force -ErrorAction SilentlyContinue
    & reg.exe unload "HKU\_AISTV_DEF" 2>$null
  } catch { Write-Host "Wallpaper reg error: $($_.Exception.Message)" }
  try {
    $null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name 'DesktopWallpaper' -Value $wpDst -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name 'DesktopWallpaperStyle' -Value '10' -Force -ErrorAction SilentlyContinue
  } catch { Write-Host "Wallpaper policy error: $($_.Exception.Message)" }
}
if (Test-Path -LiteralPath $avDst) {
  try {
    $sid = (Get-LocalUser -Name $vmUser -ErrorAction SilentlyContinue).SID.Value
    if ($sid) {
      $null = New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid" -Force -ErrorAction SilentlyContinue
      Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid" -Name 'Image128' -Value $avDst -Force -ErrorAction SilentlyContinue
      Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid" -Name 'Image240' -Value $avDst -Force -ErrorAction SilentlyContinue
      Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid" -Name 'Image48' -Value $avDst -Force -ErrorAction SilentlyContinue
      Write-Host "Account picture set for SID $sid"
    }
  } catch { Write-Host "Avatar reg error: $($_.Exception.Message)" }
}

$runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { '0' }
$tsHostname = "STV-VM-$runId"
Write-Host "Hostname: $tsHostname"
Write-Host "IP: $ip"
Write-Host "Username: $vmUser"
Write-Host "Password: $password"
$ws = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$credsPath = Join-Path $ws 'vm-creds.json'
@{ hostname = $tsHostname; ip = $ip; username = $vmUser; password = $password; login = $vmUser; instance_id = $env:INSTANCE_ID; discord_id = $env:DISCORD_ID; kind = 'windows'; run_id = $runId } | ConvertTo-Json | Set-Content -LiteralPath $credsPath -Encoding utf8
if (-not (Test-Path -LiteralPath $credsPath)) { Write-Error "vm-creds.json not created"; exit 1 }
exit 0