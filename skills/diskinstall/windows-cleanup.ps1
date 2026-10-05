# Run ON WINDOWS (one staged .ps1, over ssh) after booting into it once from Debian. FIRST action = a guaranteed way back to Debian.
$ErrorActionPreference='Continue'; $ProgressPreference='SilentlyContinue'
$fw = bcdedit /enum firmware | Out-String
$deb = $null
foreach ($blk in ($fw -split "(\r?\n){2,}")) { if ($blk -match '(?im)^description\s+debian\s*$' -and $blk -match '(\{[0-9a-fA-F-]{36}\})') { $deb = $Matches[1] } }
if (-not $deb) { "NO debian firmware entry found in BCD -> NOT restarting (stay in Windows, tell the user)"; bcdedit /enum firmware | Select-String 'description|identifier'; exit 1 }
bcdedit /set '{fwbootmgr}' bootsequence $deb | Out-Null
$rb = bcdedit /enum '{fwbootmgr}' | Out-String
if ($rb -notmatch [regex]::Escape($deb)) { "bootsequence readback missing the debian entry -> NOT restarting"; exit 1 }
"one-shot back to Debian armed: $deb"
"== WinRE"; reagentc /info | Select-String 'Status|Location'
if ((reagentc /info | Out-String) -match 'Disabled') { reagentc /enable | Out-Null; "re-enabled; now:"; reagentc /info | Select-String 'Status|Location' }
"== old installer BCD entry"
$g = (Get-Content "$env:USERPROFILE\debinst-guid.txt" -EA SilentlyContinue | Select-Object -First 1)   # written by bcdentry.ps1
if (-not $g) { $g = '{00000000-0000-0000-0000-000000000000}' }   # EDIT ME if the guid file is gone: bcdedit /enum firmware
if ((bcdedit /enum all | Out-String) -match [regex]::Escape($g)) { bcdedit /set '{fwbootmgr}' displayorder $g /remove | Out-Null; bcdedit /delete $g /f | Out-Null; "deleted $g" } else { "already gone: $g" }
"still present: " + ((bcdedit /enum all | Out-String) -match [regex]::Escape($g))
"== leftovers"
cmd /c rmdir C:\debinst-mnt 2>$null; "C:\debinst-mnt exists: " + (Test-Path C:\debinst-mnt)
$left = @("$env:USERPROFILE\debinst-guid.txt")
Remove-Item $left -Force -EA SilentlyContinue
"leftover files: " + (@($left | ? { Test-Path $_ }).Count)
"restarting into Debian in 5 s"; shutdown /r /t 5 /c "Back to Debian (one-shot)"
