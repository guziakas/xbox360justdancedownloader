# Just Dance Video Downloader & Converter

Download and extract Just Dance video recordings from Xbox 360 save files via FTP, then convert them to standard WebM format.

## What This Does

These PowerShell scripts allow you to:

1. **Download** Just Dance save files from your Xbox 360 via FTP (contains video recordings of your gameplay)
2. **Convert** those files from Xbox 360 STFS container format to standard WebM videos you can watch

## Requirements

- **Windows** with PowerShell 5.1+ (built into Windows 10/11)
- **curl** (built into Windows 10/11)
- **Xbox 360** with:
  - Custom dashboard (Aurora, FreeStyle Dash, or similar) with FTP server enabled
  - Just Dance games installed (2014-2020, or Just Dance 3)
  - Video recordings saved to the console or USB drive

## Setup

### 1. Configure Your Xbox 360 IP Address

Edit `download_all_direct.ps1` and change line 5:

```powershell
$xboxIP = "192.168.0.186"  # CHANGE THIS to your Xbox 360's IP address
```

**To find your Xbox IP:**
- On Aurora/FSD dashboard, go to Settings → Network Settings
- Note the IP address shown

### 2. Ensure FTP is Running

- The Xbox 360 must be powered on
- Aurora/FSD FTP server must be enabled in settings
- Default credentials are usually `xbox` / `xbox` (already configured in the script)

## Usage

### Step 1: Download Videos from Xbox 360

Open PowerShell in this folder and run:

```powershell
.\download_all_direct.ps1
```

**What it does:**
- Connects to your Xbox 360 via FTP
- Automatically discovers all Just Dance save files
- Downloads them to `JustDance_Videos_ALL/` folder
- Skips files that were already downloaded
- Shows progress bar for each file

**Supported games:**
- Just Dance 3 (2011)
- Just Dance 2014
- Just Dance 2015
- Just Dance 2016
- Just Dance 2017
- Just Dance 2018
- Just Dance 2019
- Just Dance 2020

Other games/saves are automatically skipped.

**Output structure:**
```
JustDance_Videos_ALL/
  Hdd1_E0000043BD442A9E/
    555308D7/
      00000001/
        slot_0
        slot_1
        ...
```

### Step 2: Convert to WebM Videos

After downloading, run:

```powershell
.\convert_all_to_webm.ps1
```

**What it does:**
- Scans all downloaded files
- Extracts WebM video from Xbox 360 STFS container
- Organizes by game name in `JustDance_WebM_ALL/` folder
- Skips already-converted files

**Output structure:**
```
JustDance_WebM_ALL/
  Just Dance 2019/
    Hdd1_E0000043BD442A9E_555308D7_slot_0.webm
    Hdd1_E0000043BD442A9E_555308D7_slot_1.webm
  Just Dance 2017/
    Hdd1_E000000A52C161B5_555308D3_slot_0.webm
  ...
```

### Step 3: Watch Your Videos!

The `.webm` files can be played in:
- VLC Media Player
- Windows Media Player (Windows 10/11)
- Web browsers (Chrome, Firefox, Edge)
- Any modern video player

## Troubleshooting

### "Xbox not reachable" Error

**Check:**
- Xbox 360 is powered on
- FTP server is running (Aurora/FSD settings)
- IP address in script matches Xbox IP
- Xbox and PC are on the same network
- Windows Firewall isn't blocking FTP (port 21)

**Test connection manually:**
```powershell
curl --user "xbox:xbox" "ftp://YOUR_XBOX_IP/" --list-only
```

### "FTP listing not supported" Message

If auto-discovery fails, the script automatically falls back to known profile/title IDs and downloads via direct file access. This is normal for some Xbox FTP server configurations.

### No Videos Found

- Not all Just Dance save slots contain videos — the game only saves recordings when you explicitly save them
- Check that you have recorded videos in-game (usually accessed via "Just Dance Video" or similar menu)
- Older games (pre-2014) may not have video recording features

### Conversion Fails

If `convert_all_to_webm.ps1` shows "FAILED" errors:
- The file may not be a valid STFS package
- The file may not contain embedded video data
- The file may be corrupted

These are typically non-video save files (settings, profiles, etc.) and can be safely ignored.

## Re-running Scripts

Both scripts are safe to re-run:
- **Download script:** Skips files that already exist locally
- **Conversion script:** Skips WebM files that were already created

This allows you to:
- Resume interrupted downloads
- Add new recordings from Xbox without re-downloading everything
- Re-convert if you delete output files

## Technical Details

### File Formats

- **Input:** Xbox 360 STFS/CON packages (container format with interleaved hash tables)
- **Output:** WebM video (VP8 video + Vorbis audio, standard web format)

### How It Works

1. **Download:** Uses curl to fetch files via FTP from Xbox 360 storage paths
2. **Extraction:** Parses STFS block structure, extracts data blocks in correct order
3. **Conversion:** Finds embedded EBML/WebM stream, writes to standalone file

### Storage Locations Scanned

- `Hdd1/Content/` (internal hard drive)
- `USBMU0/Content/` through `USBMU2/Content/` (USB drives)
- All user profiles under each storage device
- All Just Dance title IDs under each profile

## Credits

Created for archiving Just Dance video recordings from Xbox 360 consoles.

STFS format parsing based on documentation from Xbox 360 homebrew community.
