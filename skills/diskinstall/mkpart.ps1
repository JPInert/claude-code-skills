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
$RecoveryPartNumber = 4               # the recovery partition right after C:
$NewPartNumber      = 5               # the number Windows will give the new staging partition
$PostShrinkCSize    = 0               # EXACT C: size in bytes that shrink.ps1 read back (READBACK line)
$MinLinuxGap        = 49GB            # refuse if less than this is left for Linux

function Fail($m){ "ABORT: $m"; exit 1 }
$d = Get-Disk -Number $DiskNumber
if ($d.BusType -ne $DiskBus -or $d.FriendlyName -notmatch $DiskModel) { Fail "disk $DiskNumber is not the expected $DiskBus ($DiskModel)" }
if (-not ((Get-Command New-Partition).Parameters.Keys -contains 'Offset')) { Fail "New-Partition has no -Offset" }
if (Get-Partition -DiskNumber $DiskNumber | ? { $_.PartitionNumber -eq $NewPartNumber }) { Fail "partition $NewPartNumber already exists" }
$c = Get-Partition -DriveLetter C
$rec = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $RecoveryPartNumber
$cEnd = $c.Offset + $c.Size
if ($c.Size -ne $PostShrinkCSize) { Fail "C: size is not the post-shrink value" }
$off = [int64]([math]::Floor(($rec.Offset - 1GB)/1MB)*1MB)
$free = $off - $cEnd
"DEBINST offset=$off ; free for Debian between C: end and DEBINST = $free bytes ($([math]::Round($free/1GB,2)) GiB)"
if ($free -lt $MinLinuxGap) { Fail "gap for Debian would be under $($MinLinuxGap/1GB) GiB" }
$p = New-Partition -DiskNumber $DiskNumber -Size 1GB -Offset $off -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$null = Format-Volume -Partition $p -FileSystem FAT32 -NewFileSystemLabel DEBINST -Confirm:$false
New-Item -ItemType Directory -Path C:\debinst-mnt -Force | Out-Null
Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath C:\debinst-mnt
"== READBACK"
Get-Partition -DiskNumber $DiskNumber | Sort-Object Offset | % { "p$($_.PartitionNumber) off=$($_.Offset) size=$($_.Size) letter=[$($_.DriveLetter)] type=$($_.GptType)" }
$v = Get-Volume -FileSystemLabel DEBINST
"volume: label=$($v.FileSystemLabel) fs=$($v.FileSystem) sizeMB=$([math]::Round($v.Size/1MB)) letter=[$($v.DriveLetter)]"
"mount path exists: " + (Test-Path C:\debinst-mnt)
New-Item -ItemType Directory -Path C:\debinst-mnt\debinst, C:\debinst-mnt\EFI\debinst -Force | Out-Null
"subdirs: " + ((Get-ChildItem C:\debinst-mnt -Recurse -Directory).FullName -join ', ')
