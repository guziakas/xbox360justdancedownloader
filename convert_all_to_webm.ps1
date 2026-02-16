# Just Dance Video Converter - STFS-aware extraction
# Properly parses Xbox 360 CON/STFS packages, extracts data blocks with
# correct block mapping, then extracts the embedded WebM video.

$inputFolder = "JustDance_Videos_ALL"
$outputFolder = "JustDance_WebM_ALL"

# ─── STFS extraction helpers ───

$HEADER_SIZE = 0xA000
$BLOCK_SIZE  = 0x1000
$BLOCKS_PER_GROUP = 170

function Get-DataBlockRaw([int]$BlockNum) {
    $group = [Math]::Floor($BlockNum / $BLOCKS_PER_GROUP)
    $l0Adjust = ($group + 1) * 2
    $l1Adjust = if ($group -ge 1) { 2 } else { 0 }
    return $BlockNum + $l0Adjust + $l1Adjust
}

function Read-EbmlVint([byte[]]$Data, [int]$Pos) {
    $byte = $Data[$Pos]
    $width = 0
    for ($i = 0; $i -lt 8; $i++) {
        if ($byte -band (0x80 -shr $i)) {
            $width = $i + 1
            break
        }
    }
    [long]$value = 0
    for ($i = 0; $i -lt $width; $i++) {
        $value = ($value -shl 8) -bor $Data[$Pos + $i]
    }
    $mask = (1L -shl (7 * $width)) - 1
    $value = $value -band $mask
    return @{ Value = $value; Width = $width }
}

function Read-UInt24LE([byte[]]$Data, [int]$Pos) {
    return [int]$Data[$Pos] + ([int]$Data[$Pos+1] -shl 8) + ([int]$Data[$Pos+2] -shl 16)
}

function Read-UInt32BE([byte[]]$Data, [int]$Pos) {
    return ([long]$Data[$Pos] -shl 24) -bor ([long]$Data[$Pos+1] -shl 16) -bor ([long]$Data[$Pos+2] -shl 8) -bor [long]$Data[$Pos+3]
}

function Find-BytePattern([byte[]]$Data, [byte[]]$Pattern, [int]$Start = 0) {
    for ($i = $Start; $i -le $Data.Length - $Pattern.Length; $i++) {
        $found = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Data[$i + $j] -ne $Pattern[$j]) {
                $found = $false
                break
            }
        }
        if ($found) { return $i }
    }
    return -1
}

function Extract-WebmFromStfs {
    # Extract WebM video from an Xbox 360 CON/STFS package file.
    # Returns $true on success, $false on failure.
    param([string]$InputFile, [string]$OutputFile)

    $data = [System.IO.File]::ReadAllBytes($InputFile)

    # Parse file table (STFS block 0)
    $ftRaw = Get-DataBlockRaw 0
    $ftOffset = $HEADER_SIZE + $ftRaw * $BLOCK_SIZE

    $flags = $data[$ftOffset + 0x28]
    $nameLength = $flags -band 0x3F
    $consecutive = [bool]($flags -band 0x40)
    $name = [System.Text.Encoding]::ASCII.GetString($data, $ftOffset, $nameLength)
    $validBlocks = Read-UInt24LE $data ($ftOffset + 0x29)
    $firstBlock  = Read-UInt24LE $data ($ftOffset + 0x2F)
    $fileSize    = Read-UInt32BE $data ($ftOffset + 0x34)

    if (-not $consecutive) {
        Write-Warning "Non-consecutive block layout not supported: $InputFile"
        return $false
    }

    # Read save data blocks
    $ms = [System.IO.MemoryStream]::new($validBlocks * $BLOCK_SIZE)
    for ($blockNum = $firstBlock; $blockNum -lt ($firstBlock + $validBlocks); $blockNum++) {
        $raw = Get-DataBlockRaw $blockNum
        $offset = $HEADER_SIZE + $raw * $BLOCK_SIZE
        if (($offset + $BLOCK_SIZE) -gt $data.Length) { break }
        $ms.Write($data, $offset, $BLOCK_SIZE)
    }
    $saveData = $ms.ToArray()
    $ms.Dispose()

    # Trim to actual file size
    if ($saveData.Length -gt $fileSize) {
        $trimmed = [byte[]]::new($fileSize)
        [Array]::Copy($saveData, $trimmed, $fileSize)
        $saveData = $trimmed
    }

    # Find EBML/WebM signature: 1A 45 DF A3
    $ebmlSig = [byte[]]@(0x1A, 0x45, 0xDF, 0xA3)
    $ebmlOffset = Find-BytePattern $saveData $ebmlSig
    if ($ebmlOffset -lt 0) { return $false }

    # Parse EBML header size
    $pos = $ebmlOffset + 4
    $result = Read-EbmlVint $saveData $pos
    $pos += $result.Width + $result.Value

    # Parse Segment element (18 53 80 67)
    $segSig = [byte[]]@(0x18, 0x53, 0x80, 0x67)
    $match = $true
    for ($i = 0; $i -lt 4; $i++) {
        if ($saveData[$pos + $i] -ne $segSig[$i]) { $match = $false; break }
    }
    if (-not $match) { return $false }

    $pos += 4
    $result = Read-EbmlVint $saveData $pos
    $segmentSize = $result.Value
    $pos += $result.Width

    $totalWebm = $pos + $segmentSize - $ebmlOffset

    # Write output
    $outDir = Split-Path $OutputFile -Parent
    if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $fs = [System.IO.FileStream]::new($OutputFile, [System.IO.FileMode]::Create)
    $fs.Write($saveData, $ebmlOffset, $totalWebm)
    $fs.Close()
    return $true
}

# ─── Batch conversion ───

# Title ID -> Game name mapping
$gameNames = @{
    "555308C3" = "Just Dance 3"
    "55530886" = "Just Dance 2014"
    "555308CC" = "Just Dance 2015"
    "555308CD" = "Just Dance 2016"
    "555308D3" = "Just Dance 2017"
    "555308D5" = "Just Dance 2018"
    "555308D7" = "Just Dance 2019"
    "555308D9" = "Just Dance 2020"
}

if (!(Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder | Out-Null }

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Just Dance WebM Converter (STFS extraction)" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

$totalConverted = 0
$totalSkipped = 0
$totalFailed = 0
$totalNotStfs = 0

# Track file numbering per game to avoid collisions across profiles
$gameFileCount = @{}

# Walk all downloaded files: profile dirs -> title dirs -> content pack dirs -> files
$profileDirs = Get-ChildItem -Path $inputFolder -Directory | Sort-Object Name

foreach ($profileDir in $profileDirs) {
    Write-Host "Profile: $($profileDir.Name)" -ForegroundColor Magenta
    $titleDirs = Get-ChildItem -Path $profileDir.FullName -Directory | Sort-Object Name
    foreach ($titleDir in $titleDirs) {
        $titleId = $titleDir.Name
        $gameName = if ($gameNames.ContainsKey($titleId)) { $gameNames[$titleId] } else { $titleId }
        
        # Collect all files recursively (handles content pack subdirs like 00000001/)
        $slotFiles = Get-ChildItem -Path $titleDir.FullName -File -Recurse | Sort-Object FullName
        $convertedCount = 0
        $skippedCount = 0
        Write-Host "  $gameName ($titleId): " -NoNewline -ForegroundColor Cyan
        
        $gameOutDir = Join-Path $outputFolder $gameName
        
        foreach ($slotFile in $slotFiles) {
            # Quick check: is this a CON/STFS file?
            try {
                $header = [byte[]]::new(4)
                $fs = [System.IO.File]::OpenRead($slotFile.FullName)
                $fs.Read($header, 0, 4) | Out-Null
                $fs.Close()
                $magic = [System.Text.Encoding]::ASCII.GetString($header, 0, 4)
                if ($magic -notin @('CON ', 'LIVE', 'PIRS')) {
                    $totalNotStfs++
                    continue
                }
            } catch {
                $totalNotStfs++
                continue
            }

            # Generate output filename: GameName/video_001.webm, video_002.webm, etc.
            if (-not $gameFileCount.ContainsKey($gameName)) { $gameFileCount[$gameName] = 0 }
            
            # Use a stable name based on source to allow skip detection
            $sourceKey = "$($profileDir.Name)_${titleId}_$($slotFile.Name)"
            $outFile = Join-Path $gameOutDir "$sourceKey.webm"
            
            # Skip if already converted
            if (Test-Path $outFile) {
                $skippedCount++
                $totalSkipped++
                continue
            }

            if (!(Test-Path $gameOutDir)) { New-Item -ItemType Directory -Path $gameOutDir -Force | Out-Null }

            try {
                $ok = Extract-WebmFromStfs -InputFile $slotFile.FullName -OutputFile $outFile
                if ($ok -and (Test-Path $outFile) -and (Get-Item $outFile).Length -gt 0) {
                    $sz = [math]::Round((Get-Item $outFile).Length/1MB, 2)
                    $gameFileCount[$gameName]++
                    Write-Host "    $($slotFile.Name) -> $gameName/$sourceKey.webm ($sz MB)" -ForegroundColor Green
                    $convertedCount++
                    $totalConverted++
                } else {
                    if (Test-Path $outFile) { Remove-Item $outFile -Force }
                    Write-Host "    $($slotFile.Name) -> FAILED" -ForegroundColor Red
                    $totalFailed++
                }
            } catch {
                Write-Host "    $($slotFile.Name) -> ERROR: $_" -ForegroundColor Red
                if (Test-Path $outFile) { Remove-Item $outFile -Force }
                $totalFailed++
            }
        }
        if ($convertedCount -gt 0 -or $skippedCount -gt 0) {
            $existingWebm = 0
            if (Test-Path $gameOutDir) {
                $existingWebm = @(Get-ChildItem $gameOutDir -File -Filter "*.webm" -ErrorAction SilentlyContinue).Count
            }
            Write-Host "    $convertedCount new, $skippedCount skipped, $existingWebm total in '$gameName'" -ForegroundColor Green
        } else {
            Write-Host "(no video packages)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Conversion Complete!" -ForegroundColor Green
Write-Host "  Converted: $totalConverted" -ForegroundColor Cyan
Write-Host "  Skipped (existing): $totalSkipped" -ForegroundColor DarkGray
if ($totalFailed -gt 0) { Write-Host "  Failed: $totalFailed" -ForegroundColor Red }
Write-Host "  Not STFS (metadata etc): $totalNotStfs" -ForegroundColor DarkGray

$allWebm = Get-ChildItem -Path $outputFolder -Recurse -File -Filter "*.webm" -ErrorAction SilentlyContinue
if ($allWebm -and $allWebm.Count -gt 0) {
    $totalSize = ($allWebm | Measure-Object -Property Length -Sum).Sum
    Write-Host "`n  TOTAL: $($allWebm.Count) WebM videos" -ForegroundColor Yellow
    Write-Host "  SIZE: $([math]::Round($totalSize/1MB,2)) MB ($([math]::Round($totalSize/1GB,2)) GB)" -ForegroundColor Yellow
}
Write-Host "  Output: $outputFolder\" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Yellow
