$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
function Fail($m){ "ABORT: $m"; exit 1 }
$desc = 'Debian installer (one-shot)'
if ((bcdedit /enum firmware | Out-String) -match [regex]::Escape($desc)) { Fail "entry already exists" }
$vol = Get-Volume -FileSystemLabel DEBINST
if (-not $vol -or $vol.FileSystem -ne 'FAT32') { Fail "DEBINST volume not found" }
if (-not (Test-Path C:\debinst-mnt\EFI\debinst\grubx64.efi)) { Fail "grubx64.efi missing on DEBINST" }
Add-Type -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern uint QueryDosDevice(string lpDeviceName, System.Text.StringBuilder lpTargetPath, int ucchMax);' -Name Native -Namespace K
$name = ($vol.Path.TrimEnd('\') -replace '^\\\\\?\\','')
$sb = New-Object System.Text.StringBuilder 512
if ([K.Native]::QueryDosDevice($name, $sb, 512) -eq 0) { Fail "QueryDosDevice failed for $name" }
$nt = $sb.ToString()
"NT device for DEBINST = $nt"
if ($nt -notmatch '^\\Device\\HarddiskVolume\d+$') { Fail "unexpected device name" }
$o = bcdedit /copy '{bootmgr}' /d $desc | Out-String
if ($o -notmatch '(\{[0-9a-fA-F-]{36}\})') { Fail "could not parse guid from: $o" }
$g = $Matches[1]
"new entry = $g"
bcdedit /set $g device "partition=$nt" | Out-Null
bcdedit /set $g path '\EFI\debinst\grubx64.efi' | Out-Null
bcdedit /set '{fwbootmgr}' displayorder $g /addlast | Out-Null
Set-Content "$env:USERPROFILE\debinst-guid.txt" $g
"== READBACK entry"
bcdedit /enum $g
"== READBACK fwbootmgr"
bcdedit /enum '{fwbootmgr}'
