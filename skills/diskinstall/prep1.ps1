$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
# ---- EDIT ME for your machine: these values are the guards. Edit them, never delete them. ----
$DiskNumber   = 0                 # Get-Disk: the internal disk Windows is on
$DiskModel    = 'CHANGE-ME'       # a substring of that disk's FriendlyName (Get-Disk | ft Number,FriendlyName,BusType)
$DiskBus      = 'NVMe'
$CPartNumber  = 3                 # Get-Partition -DriveLetter C | ft PartitionNumber
$WorkDir      = 'C:\Users\Public' # where the BCD backup and partition snapshot live
$BcdBackup    = "$WorkDir\bcd-backup"
$PartSnapshot = "$WorkDir\partition-snapshot.xml"   # Get-Partition -DiskNumber 0 | Export-Clixml <this>, taken BEFORE prep1
# ------------------------------------------------------------------------------------------------
function Fail($m){ "ABORT: $m"; exit 1 }
$d = Get-Disk -Number $DiskNumber
if ($d.BusType -ne $DiskBus -or $d.FriendlyName -notmatch $DiskModel) { Fail "disk $DiskNumber is not the expected $DiskBus ($DiskModel): $($d.FriendlyName)" }
$c = Get-Partition -DriveLetter C
if ($c.DiskNumber -ne $DiskNumber -or $c.PartitionNumber -ne $CPartNumber) { Fail "C: is not disk$DiskNumber/part$CPartNumber" }
$bl = (manage-bde -status C: 2>&1 | Out-String)
if ($bl -notmatch 'Protection Off' -or $bl -notmatch 'Fully Decrypted') { Fail "BitLocker not off" }
"guards ok: disk$DiskNumber $DiskBus $DiskModel, C: = part$CPartNumber, BitLocker off"
$scan = Repair-Volume -DriveLetter C -Scan
"chkdsk scan (read-only) result: $scan"
if ("$scan" -ne 'NoErrorsFound') { Fail "C: scan not clean" }
$bcd=$BcdBackup
if (Test-Path $bcd) { Remove-Item $bcd -Force }
bcdedit /export $bcd | Out-Null
"bcd backup bytes=" + (Get-Item $bcd).Length
if (-not (Test-Path $PartSnapshot)) { Fail "take the partition snapshot first: Get-Partition -DiskNumber $DiskNumber | Export-Clixml $PartSnapshot" }
"partition snapshot bytes=" + (Get-Item $PartSnapshot).Length
powercfg /h off
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0
"READBACK HiberbootEnabled=" + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled
"READBACK HibernateEnabled=" + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power').HibernateEnabled
"hiberfil present=" + (Test-Path C:\hiberfil.sys -PathType Leaf)
$s = Get-PartitionSupportedSize -DriveLetter C
"C: size=$($c.Size)  SizeMin=$($s.SizeMin)  (GiB: $([math]::Round($c.Size/1GB,2)) / $([math]::Round($s.SizeMin/1GB,2)))"
"battery status (1=discharging,2=AC)=" + (Get-CimInstance Win32_Battery).BatteryStatus
