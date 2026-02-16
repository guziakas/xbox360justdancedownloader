# Just Dance FULL Video Downloader - Auto-Discovery with fallback
# Scans ALL storage locations, profiles, title IDs, and files via FTP listing
# Falls back to known targets if FTP directory listing is not supported

$xboxIP = "192.168.0.186" # CHANGE THIS to your Xbox 360's IP address
$ftpUser = "xbox"
$ftpPass = "xbox"
$outputFolder = "JustDance_Videos_ALL"

# Known Just Dance title IDs for Xbox 360 (Ubisoft)
# Only files from these titles will be downloaded
$justDanceTitleIds = @(
    "555308C3",  # Just Dance 3
    "55530886",  # Just Dance 2014
    "555308CC",  # Just Dance 2015
    "555308CD",  # Just Dance 2016
    "555308D3",  # Just Dance 2017
    "555308D5",  # Just Dance 2018
    "555308D7",  # Just Dance 2019
    "555308D9"   # Just Dance 2020
)

if (!(Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder | Out-Null }

# List an FTP directory and return entry names (directories or files)
# Uses NLST (--list-only) for maximum compatibility with Xbox 360 FTP servers
function List-FtpDir {
    param([string]$remotePath)
    
    $url = "ftp://$xboxIP$remotePath/"
    
    # Try NLST first (just filenames, most compatible)
    $raw = & curl --user "$($ftpUser):$($ftpPass)" "$url" --list-only --silent --show-error --connect-timeout 30 --max-time 60 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        # Fallback: try regular LIST
        $raw = & curl --user "$($ftpUser):$($ftpPass)" "$url" --silent --show-error --connect-timeout 30 --max-time 60 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }
    }
    
    $entries = @()
    foreach ($line in ($raw -split "`r?`n")) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # If it's just a filename (NLST), use as-is; if LIST format, take last token
        if ($line -match '^\S+$') {
            $name = $line
        } else {
            $parts = $line -split '\s+'
            $name = $parts[-1]
        }
        if ($name -ne "." -and $name -ne "..") {
            $entries += $name
        }
    }
    return $entries
}

function Download-File {
    param([string]$remotePath, [string]$localFile)
    
    $localDir = Split-Path $localFile -Parent
    
    # Skip existing
    if (Test-Path $localFile) {
        return "skip"
    }
    
    if (!(Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
    
    # Try up to 3 times with delay
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "      Retry $attempt..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 3
        }
        & curl --user "$($ftpUser):$($ftpPass)" "ftp://$xboxIP$remotePath" -o $localFile --show-error --fail --connect-timeout 60 --max-time 300 --progress-bar 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $localFile) -and (Get-Item $localFile).Length -gt 0) {
            return "ok"
        }
        if (Test-Path $localFile) { Remove-Item $localFile -Force }
    }
    return "fail"
}

function Download-Slot {
    param([string]$storage, [string]$profile, [string]$titleId, [string]$slotName)
    
    $remotePath = "/$storage/Content/$profile/$titleId/00000001/$slotName"
    $localDir = Join-Path $outputFolder "${storage}_${profile}" | Join-Path -ChildPath $titleId | Join-Path -ChildPath "00000001"
    $localFile = Join-Path $localDir $slotName
    
    return Download-File -remotePath $remotePath -localFile $localFile
}

Write-Host "`n============================================" -ForegroundColor Yellow
Write-Host "  Just Dance FULL Downloader (Auto-Scan)" -ForegroundColor Yellow
Write-Host "============================================`n" -ForegroundColor Yellow

$stats = @{ ok=0; skip=0; fail=0 }

# ─── Test FTP connectivity first ───

Write-Host "Testing FTP connection to $xboxIP ..." -ForegroundColor Yellow
$testRaw = & curl --user "$($ftpUser):$($ftpPass)" "ftp://$xboxIP/" --list-only --silent --show-error --connect-timeout 15 --max-time 30 2>&1
$ftpConnected = ($LASTEXITCODE -eq 0)

if ($ftpConnected) {
    Write-Host "  Connected! Root listing:" -ForegroundColor Green
    Write-Host "  $testRaw" -ForegroundColor DarkCyan
} else {
    Write-Host "  Connection failed (exit code $LASTEXITCODE): $testRaw" -ForegroundColor Red
    Write-Host "  Make sure the Xbox 360 is powered on, FTP is running, and IP is correct." -ForegroundColor Red
    Write-Host "  Trying regular LIST..." -ForegroundColor DarkYellow
    $testRaw = & curl --user "$($ftpUser):$($ftpPass)" "ftp://$xboxIP/" --silent --show-error --connect-timeout 15 --max-time 30 2>&1
    $ftpConnected = ($LASTEXITCODE -eq 0)
    if ($ftpConnected) {
        Write-Host "  Connected with LIST! Root:" -ForegroundColor Green
        Write-Host "  $testRaw" -ForegroundColor DarkCyan
    } else {
        Write-Host "  Still failed: $testRaw" -ForegroundColor Red
    }
}

# ─── Phase 1: Try auto-discovery via FTP listing ───

$discoveryWorked = $false

if ($ftpConnected) {
    Write-Host "`nPhase 1: Auto-discovery via FTP listing..." -ForegroundColor Yellow
    
    # Parse root entries
    $storageRoots = @()
    foreach ($line in ($testRaw -split "`r?`n")) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\S+$') { $name = $line } else { $parts = $line -split '\s+'; $name = $parts[-1] }
        if ($name -ne "." -and $name -ne "..") { $storageRoots += $name }
    }
    
    if ($storageRoots.Count -eq 0) {
        # Root listing returned data but no parseable entries - try hardcoded roots
        $storageRoots = @("Hdd1", "USBMU0", "USBMU1", "USBMU2")
    }
    
    Write-Host "  Storage roots to scan: $($storageRoots -join ', ')" -ForegroundColor Cyan

    foreach ($storage in $storageRoots) {
        Write-Host "`nScanning $storage/Content/ ..." -ForegroundColor Yellow
        
        $profiles = List-FtpDir -remotePath "/$storage/Content"
        if ($profiles.Count -eq 0) {
            Write-Host "  (not found or empty)" -ForegroundColor DarkGray
            continue
        }
        
        $discoveryWorked = $true
        Write-Host "  Found $($profiles.Count) profile(s)" -ForegroundColor Green
        
        foreach ($profile in $profiles) {
            Write-Host "`n--- $storage / $profile ---" -ForegroundColor Magenta
            
            $titleIds = List-FtpDir -remotePath "/$storage/Content/$profile"
            if ($titleIds.Count -eq 0) {
                Write-Host "  (no title IDs)" -ForegroundColor DarkGray
                continue
            }
            
            Write-Host "  Found $($titleIds.Count) title ID(s): $($titleIds -join ', ')" -ForegroundColor Cyan
            
            # Filter to Just Dance titles only
            $jdTitles = $titleIds | Where-Object { $_ -in $justDanceTitleIds }
            $skippedCount = $titleIds.Count - $jdTitles.Count
            if ($skippedCount -gt 0) {
                Write-Host "  (skipping $skippedCount non-Just-Dance title(s))" -ForegroundColor DarkGray
            }
            
            foreach ($titleId in $jdTitles) {
                Write-Host "  $titleId" -ForegroundColor Cyan
                
                # List content packs under the title (e.g., 00000001, 00000002, etc.)
                $contentPacks = List-FtpDir -remotePath "/$storage/Content/$profile/$titleId"
                if ($contentPacks.Count -eq 0) {
                    Write-Host "    (empty)" -ForegroundColor DarkGray
                    continue
                }
                
                foreach ($pack in $contentPacks) {
                    # List actual files/slots inside each content pack
                    $files = List-FtpDir -remotePath "/$storage/Content/$profile/$titleId/$pack"
                    if ($files.Count -eq 0) { continue }
                    
                    Write-Host "    /$pack/ -> $($files.Count) file(s)" -ForegroundColor DarkCyan
                    
                    foreach ($fileName in $files) {
                        $remotePath = "/$storage/Content/$profile/$titleId/$pack/$fileName"
                        $localDir = Join-Path $outputFolder "${storage}_${profile}" | Join-Path -ChildPath $titleId | Join-Path -ChildPath $pack
                        $localFile = Join-Path $localDir $fileName
                        
                        $result = Download-File -remotePath $remotePath -localFile $localFile
                        
                        if ($result -eq "ok") {
                            $sz = [math]::Round((Get-Item $localFile).Length/1MB,2)
                            Write-Host "      $fileName -> $sz MB" -ForegroundColor Green
                            $stats.ok++
                        }
                        elseif ($result -eq "skip") {
                            $sz = [math]::Round((Get-Item $localFile).Length/1MB,2)
                            Write-Host "      $fileName -> exists ($sz MB)" -ForegroundColor DarkGray
                            $stats.skip++
                        }
                        else {
                            Write-Host "      $fileName -> FAILED" -ForegroundColor Red
                            $stats.fail++
                        }
                    }
                }
            }
        }
    }
} # end if ($ftpConnected)

# ─── Phase 2: Fallback to known targets if FTP not reachable or listing failed ───

if (-not $discoveryWorked) {
    if (-not $ftpConnected) {
        Write-Host "`n--------------------------------------------" -ForegroundColor Red
        Write-Host "Xbox not reachable! Check that:" -ForegroundColor Red
        Write-Host "  - Xbox 360 is powered on" -ForegroundColor Red
        Write-Host "  - FTP server is running (Aurora/FSD)" -ForegroundColor Red
        Write-Host "  - IP address is correct: $xboxIP" -ForegroundColor Red
        Write-Host "  - Xbox and PC are on the same network" -ForegroundColor Red
        Write-Host "--------------------------------------------" -ForegroundColor Red
    } else {
        Write-Host "`n--------------------------------------------" -ForegroundColor DarkYellow
        Write-Host "FTP listing returned no content folders." -ForegroundColor DarkYellow
        Write-Host "--------------------------------------------" -ForegroundColor DarkYellow
    }
    Write-Host "Falling back to known targets (direct download)..." -ForegroundColor DarkYellow
    
    $targets = @(
        @("Hdd1","E0000043BD442A9E","555308D7", 10),
        @("Hdd1","E0000043BD442A9E","555308D3", 10),
        @("Hdd1","E0000043BD442A9E","555308D5", 10),
        @("Hdd1","E0000043BD442A9E","555308D9", 10),
        @("Hdd1","E0000043BD442A9E","555308CD", 10),
        @("Hdd1","E0000043BD442A9E","555308C3", 10),
        @("Hdd1","E0000043BD442A9E","55530886", 10),

        @("Hdd1","E000000A52C161B5","555308D7", 30),
        @("Hdd1","E000000A52C161B5","555308D3", 30),
        @("Hdd1","E000000A52C161B5","555308D5", 30),
        @("Hdd1","E000000A52C161B5","555308D9", 30),
        @("Hdd1","E000000A52C161B5","555308CD", 30),
        @("Hdd1","E000000A52C161B5","555308CC", 30),
        @("Hdd1","E000000A52C161B5","555308C3", 10),
        @("Hdd1","E000000A52C161B5","55530886", 10),

        @("Hdd1","E000017252C161B5","555308C3", 10),
        @("Hdd1","E000017252C161B5","555308CD", 30),
        @("Hdd1","E000017252C161B5","555308D7", 30),
        @("Hdd1","E000017252C161B5","555308D3", 30),
        @("Hdd1","E000017252C161B5","555308D9", 30),
        @("Hdd1","E000017252C161B5","555308D5", 30),

        @("Hdd1","E000023E52C161B5","555308C3", 10),
        @("Hdd1","E000023E52C161B5","555308CD", 30),
        @("Hdd1","E000023E52C161B5","555308D5", 30),
        @("Hdd1","E000023E52C161B5","555308D9", 30),
        @("Hdd1","E000023E52C161B5","555308D7", 30),
        @("Hdd1","E000023E52C161B5","555308D3", 30),

        @("Hdd1","E00004D652C161B5","555308D3", 10),
        @("Hdd1","E00004D652C161B5","555308D7", 10),
        @("Hdd1","E00004D652C161B5","555308D9", 10),
        @("Hdd1","E00004D652C161B5","555308D5", 10),
        @("Hdd1","E00004D652C161B5","555308CD", 10),

        @("USBMU0","E000000A52C161B5","555308D7", 30),
        @("USBMU0","E000000A52C161B5","555308CD", 30),

        @("USBMU0","E000017252C161B5","555308CC", 30),
        @("USBMU0","E000017252C161B5","555308CD", 30)
    )

    $currentProfile = ""
    foreach ($t in $targets) {
        $storage = $t[0]; $profile = $t[1]; $titleId = $t[2]; $maxSlots = $t[3]
        
        $profileKey = "${storage}_${profile}"
        if ($profileKey -ne $currentProfile) {
            Write-Host "`n--- $storage / $profile ---" -ForegroundColor Magenta
            $currentProfile = $profileKey
        }
        
        Write-Host "  $titleId " -NoNewline -ForegroundColor Cyan
        
        $foundAny = $false
        $consecutiveFails = 0
        
        for ($i = 0; $i -lt $maxSlots; $i++) {
            $slotName = "slot_$i"
            $result = Download-Slot -storage $storage -profile $profile -titleId $titleId -slotName $slotName
            
            if ($result -eq "ok") {
                $localDir = Join-Path $outputFolder "${storage}_${profile}" | Join-Path -ChildPath $titleId | Join-Path -ChildPath "00000001"
                $localFile = Join-Path $localDir $slotName
                $sz = [math]::Round((Get-Item $localFile).Length/1MB,2)
                Write-Host "    $slotName -> $sz MB" -ForegroundColor Green
                $stats.ok++
                $foundAny = $true
                $consecutiveFails = 0
            }
            elseif ($result -eq "skip") {
                $localDir = Join-Path $outputFolder "${storage}_${profile}" | Join-Path -ChildPath $titleId | Join-Path -ChildPath "00000001"
                $localFile = Join-Path $localDir $slotName
                $sz = [math]::Round((Get-Item $localFile).Length/1MB,2)
                Write-Host "    $slotName -> exists ($sz MB)" -ForegroundColor DarkGray
                $stats.skip++
                $foundAny = $true
                $consecutiveFails = 0
            }
            else {
                $consecutiveFails++
                if ((!$foundAny -and $consecutiveFails -ge 2) -or ($consecutiveFails -ge 3)) {
                    if ($foundAny) {
                        Write-Host "    (no more slots)" -ForegroundColor DarkGray
                    } else {
                        Write-Host "(empty)" -ForegroundColor DarkGray
                    }
                    break
                }
                $stats.fail++
            }
        }
        
        if ($foundAny -and $consecutiveFails -lt 3) {
            Write-Host "    (scanned $maxSlots slots)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n============================================" -ForegroundColor Yellow
Write-Host "Download Complete!" -ForegroundColor Green
Write-Host "  New: $($stats.ok) | Skipped: $($stats.skip) | Failed: $($stats.fail)" -ForegroundColor Cyan

$allFiles = Get-ChildItem -Path $outputFolder -Recurse -File
$total = ($allFiles | Measure-Object -Property Length -Sum).Sum
Write-Host "  TOTAL: $($allFiles.Count) files, $([math]::Round($total/1MB,2)) MB ($([math]::Round($total/1GB,2)) GB)" -ForegroundColor Yellow
Write-Host "============================================`n" -ForegroundColor Yellow
