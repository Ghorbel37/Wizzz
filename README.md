<h1 align="center">Welcome to Wizzz 👋</h1>
<p>
  <a href="#" target="_blank">
    <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" />
  </a>
</p>

## Backup filesystem tree like a wizzz
> This script makes a copy of filesystem tree using WizTree and exports each drive tree to CSV,
> then compresses the files in a single archive
> and copies the backup to multiple locations

## Requirements
* Windows with PowerShell 5.1 or PowerShell 7
* [WizTree](https://diskanalyzer.com/) installed
* [7-Zip](https://www.7-zip.org/) (optional). It is used when installed, giving smaller archives.
  Otherwise the built-in Zip compression is used.
* Administrator privileges. The script restarts itself as administrator if needed.

The script finds WizTree in its own folder or in the WizTree installation folder.
Use `-WizTreePath` if WizTree is installed somewhere else.

## Install
This will create a scheduled task that runs the backup every Sunday at 23:12.
If the computer is off at that time, the backup runs as soon as possible afterwards.
Make sure to run it from an elevated PowerShell prompt.

```powershell
.\Wizzz_create_task.ps1
```

## Uninstall
Remove the scheduled task from an elevated PowerShell prompt.

```powershell
Unregister-ScheduledTask -TaskName "Wiztree Filesystem Backup"
```

## Usage
This will run the script and make a backup.

```powershell
.\Wizzz_backup.ps1 -Silent
```

| Option | Description |
| --- | --- |
| `-Silent` | Accept all prompts automatically |
| `-NoCopy` | Do not copy the backup to the other drives |
| `-ForceZip` | Use the built-in Zip compression even if 7-Zip is installed |
| `-BackupRoot <path>` | Full path of the folder where the backup is saved (default: `C:\Backup`) |
| `-WizTreePath <path>` | Full path of `WizTree.exe` |

Each local fixed drive is exported to a CSV file and all the files are compressed into
`Backup_<date>_<time>.7z` (or `.zip`) in the backup folder.
The archive is then copied to the same folder on every other local fixed drive.
Virtual drives that are not on a disk partition, such as the Google Drive drive, are skipped.

Each run is logged to `<BackupRoot>\Logs`. The script exits with code 1 when something failed.

## Reading a backup
Extract the archive and open the CSV file of a drive in WizTree (`File > Open`)
to browse the filesystem tree as it was at the time of the backup.
The CSV files can also be opened in any spreadsheet program.

## Author

* Github: [@Ghorbel37](https://github.com/Ghorbel37)

## Show your support

Give a ⭐️ if this project helped you!

***
_This README was generated with ❤️ by [readme-md-generator](https://github.com/kefranabg/readme-md-generator)_
