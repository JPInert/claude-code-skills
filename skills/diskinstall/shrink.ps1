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
$ShrinkBy           = 51GB   # how much to take from C: (Linux space + 1 GiB staging + slack)
$RecoveryPartNumber = 4      # the recovery partition right after C:

function Fail($m){ "ABORT: $m"; exit 1 }
$d = Get-Disk -Number $DiskNumber
if ($d.BusType -ne $DiskBus -or $d.FriendlyName -notmatch $DiskModel) { Fail "disk $DiskNumber is not the expected $DiskBus ($DiskModel)" }
$bl = (bcdedit /store $BcdBackup /enum all 2>&1 | Out-String)
if ($bl -notmatch 'Windows Boot Manager' -or $bl -notmatch 'winload\.efi') { Fail "BCD backup does not list the Windows entries" }
"bcd backup LISTED: has Windows Boot Manager + winload.efi"
if ((Get-Item $PartSnapshot).Length -lt 10000) { Fail "partition snapshot too small" }
$c = Get-Partition -DriveLetter C
$s = Get-PartitionSupportedSize -DriveLetter C
$target = [int64]([math]::Floor(($c.Size - $ShrinkBy)/1MB)*1MB)
"current=$($c.Size) SizeMin=$($s.SizeMin) target=$target"
if ($target -lt ($s.SizeMin + 3GB)) { Fail "target below SizeMin+3GiB" }
if ($target -gt $c.Size) { Fail "target larger than current" }
Resize-Partition -DriveLetter C -Size $target
$c2 = Get-Partition -DriveLetter C
"READBACK C: size=$($c2.Size) (GiB $([math]::Round($c2.Size/1GB,2)))"
if ($c2.Size -ne $target) { Fail "C: size does not match target after resize" }
"== layout"
Get-Partition -DiskNumber $DiskNumber | Sort-Object Offset | % { "p$($_.PartitionNumber) off=$($_.Offset) size=$($_.Size) end=$($_.Offset+$_.Size)" }
$rec = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $RecoveryPartNumber
"GAP between C: end and recovery start = $($rec.Offset - ($c2.Offset+$c2.Size)) bytes ($([math]::Round(($rec.Offset - ($c2.Offset+$c2.Size))/1GB,2)) GiB)"
"post-shrink scan: " + (Repair-Volume -DriveLetter C -Scan)
"C: free GB=" + [math]::Round((Get-Volume -DriveLetter C).SizeRemaining/1GB,1)
