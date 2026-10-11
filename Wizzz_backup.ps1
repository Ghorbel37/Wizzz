# Command-line parameters
#   -Silent    Accept all prompts automatically
#   -NoCopy    Do not copy the backup to other drives
#   -ForceZip  Use the built-in Zip compression even if 7-Zip is installed
#   -BackupRoot   Full path of the folder where the backup is saved (default: C:\Backup)
#                 The backup is copied to the same folder on the other drives
#   -WizTreePath  Full path of WizTree.exe (default: looked up in the script folder,
#                 then in the WizTree installation folder)
param(
    [switch]$Silent,
    [switch]$NoCopy,
    [switch]$ForceZip,
    [string]$BackupRoot = "C:\Backup",
    [string]$WizTreePath
)

##########################
#####Global variables#####
##########################

# Set the excluded folders ( Folders that have too many files )
#Separate with pipe "|"
$Excluded = """$env:WINDIR""|""$env:LOCALAPPDATA\Yarn\"""

# Locations that should have backup folder
# Separate with comma ","

# $destinationDrives = "D:", "E:", "F:"

##########################
###Global variables end###
##########################


# Function to display script information
function DisplayScriptInformation() {
    Clear-Host
    Write-Host "`n`nWelcome to the Backup Script" -ForegroundColor Cyan
    Write-Host "This script exports filesystem structure to csv using WizTree," -ForegroundColor Cyan
    Write-Host "compresses the exported files, and copies the backup to multiple locations." -ForegroundColor Cyan
    if ($Silent) {
        Write-Host "Script is running in silent mode" -ForegroundColor Yellow
    }
    Write-Host "`n`n"
}

# Wait for a key press, unless running in silent mode (e.g. from the scheduled task)
function WaitForKeyPress([string]$Message = "Press any key to continue...") {
    if (-not $Silent) {
        Write-Output $Message
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# Exit the script with the given exit code
function ExitScript([int]$ExitCode = 0) {
    try { $null = Stop-Transcript } catch { Write-Verbose "No transcript to stop" }
    WaitForKeyPress "Press any key to exit..."
    exit $ExitCode
}

# Display script information
DisplayScriptInformation


# Check if the script is running with elevated privileges and restart it if not
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Output "This script needs to run as an administrator"
    Write-Output "It will restart itself with administrator privileges."
    WaitForKeyPress
    # Forward the parameters so the elevated instance behaves the same way
    $forwardedArgs = foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Value -is [switch]) {
            if ($param.Value) { "-$($param.Key)" }
        }
        else {
            "-$($param.Key) `"$($param.Value)`""
        }
    }
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $forwardedArgs" -Verb RunAs
    exit
}

# Get the current date and time for creating a unique folder
$BackupFolderName = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupLocation = Join-Path $BackupRoot $BackupFolderName

# Log everything to a file so unattended runs can be checked later
$LogFolder = Join-Path $BackupRoot "Logs"
$LogPath = Join-Path $LogFolder "Wizzz_$BackupFolderName.log"
$null = New-Item -ItemType Directory -Path $LogFolder -Force
$null = Start-Transcript -Path $LogPath
Write-Output "Logging to $LogPath`n"

# Find the WizTree executable
if ($WizTreePath) {
    $wizTreeCandidates = @($WizTreePath)
}
else {
    $wizTreeCandidates = @(
        (Join-Path $PSScriptRoot "WizTree.exe"),
        (Join-Path $PSScriptRoot "WizTree64.exe"),
        (Join-Path $env:ProgramFiles "WizTree\WizTree.exe"),
        (Join-Path $env:ProgramFiles "WizTree\WizTree64.exe")
    )
}
$WizTreeExePath = $wizTreeCandidates | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
if (-not $WizTreeExePath) {
    Write-Output "WizTree not found. Place the script in the WizTree folder, install WizTree or use -WizTreePath."
    ExitScript 1
}
Write-Output "Using WizTree: $WizTreeExePath`n"


# Get local fixed drives only (DriveType 3), skipping optical, removable and network drives
$drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" | Select-Object DeviceID, VolumeName, Size, FreeSpace, FileSystem

# Display the drives in a table with additional information
Write-Host "Drives to back up:`n"
$drives | Format-Table -AutoSize


# Ask for confirmation
if (-not $Silent) {
    $confirmation = Read-Host "Do you want to proceed with the backup? (Y/n)"
    if (-not $confirmation) {
        $confirmation = 'Y'
    }
    if ($confirmation -ne 'Y') {
        Write-Host "Backup aborted."
        ExitScript
    }
}

# Create a new folder for each backup
Write-Output "`nCreating temporary backup folder"
$null = New-Item -ItemType Directory -Path $BackupLocation -Force
Write-Output "Done.`n"



# Drives or locations that failed, reported at the end of the script
$failures = @()

# Export each drive
foreach ($drive in $drives) {
    # Get DriveName And CsvName
    $DriveName = $drive.DeviceID
    $CsvName = ($drive.DeviceID[0] + "_%d_%t.csv")
    # Save backup
    Write-Output "Saving backup for $DriveName"
    $wizTree = Start-Process -FilePath $WizTreeExePath -ArgumentList "$DriveName /export=""$BackupLocation\$CsvName"" /admin=1 /filterexclude=$Excluded" -Wait -PassThru

    # Make sure WizTree exported a CSV for this drive
    $exportedCsv = Get-ChildItem -Path $BackupLocation -Filter ($drive.DeviceID[0] + "_*.csv") -ErrorAction SilentlyContinue
    if (-not $exportedCsv) {
        Write-Warning "WizTree failed to export $DriveName (exit code $($wizTree.ExitCode))"
        $failures += "Export of $DriveName"
    }
}

# Stop if nothing was exported, there is nothing to compress
if (-not (Get-ChildItem -Path $BackupLocation -Filter "*.csv")) {
    Write-Error "No drive was exported, aborting."
    ExitScript 1
}
Write-Output "Backup complete`n"

# Check if 7-Zip is installed, using its registry entry, the usual install folders or the PATH
$sevenZipCandidates = @(
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\7-Zip" -Name Path -ErrorAction SilentlyContinue).Path,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
) | Where-Object { $_ } | ForEach-Object { Join-Path $_ "7z.exe"; Join-Path $_ "7-Zip\7z.exe" }
$sevenZipCandidates += (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
$sevenZipPath = $sevenZipCandidates | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
$use7Zip = [bool]$sevenZipPath

# Compressing all files
if ($use7Zip -and -not $ForceZip) {
    Write-Output "7-Zip found. Compressing using 7-Zip"
    $ArchiveName = "Backup_$BackupFolderName.7z"
    $ArchivePath = Join-Path $BackupRoot $ArchiveName
    # Pipe through Out-Host so the 7-Zip output also goes to the log
    & $sevenZipPath a -t7z $ArchivePath "$BackupLocation\*.csv" -mx=9 | Out-Host
    # 7-Zip exit codes: 0 = success, 1 = warning, 2 and above = error
    $compressionFailed = $LASTEXITCODE -ge 2
}
else {
    Write-Output "Compressing using built-in Zip"
    $ArchiveName = "Backup_$BackupFolderName.zip"
    $ArchivePath = Join-Path $BackupRoot $ArchiveName
    try {
        Compress-Archive -Path "$BackupLocation\*.csv" -DestinationPath $ArchivePath -CompressionLevel "Optimal" -Force -ErrorAction Stop
        $compressionFailed = $false
    }
    catch {
        Write-Warning $_
        $compressionFailed = $true
    }
}

# Keep the exported CSV files if the compression failed
if ($compressionFailed -or -not (Test-Path $ArchivePath -PathType Leaf)) {
    Write-Error "Compression failed. The exported CSV files were kept in $BackupLocation"
    ExitScript 1
}
Write-Output "Compression done.`n"

# Copy the backup to all drives unless -NoCopy argument is passed
if (-not $NoCopy) {
    $copiedTo = @()

    # Fetch drive in $BackupRoot
    $backupDrive = [System.IO.Path]::GetPathRoot($BackupRoot)

    foreach ($drive in $drives) {
        if ($drive.DeviceID + "\" -ne $backupDrive) {
            $destinationPath = Join-Path $drive.DeviceID (Split-Path $BackupRoot -NoQualifier)
            $destinationFilePath = Join-Path $destinationPath $ArchiveName

            # Create Backup folder if it doesn't exist
            if (-not (Test-Path $destinationPath -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $destinationPath -Force
            }

            Write-Output "Copying backup to $($drive.DeviceID)"
            try {
                Copy-Item -Path $ArchivePath -Destination $destinationFilePath -Force -ErrorAction Stop
                $copiedTo += $destinationFilePath
            }
            catch {
                Write-Warning "Failed to copy backup to $($drive.DeviceID): $_"
                $failures += "Copy to $($drive.DeviceID)"
            }
        }
    }
    Write-Output "Copying done.`n"
}
else {
    Write-Output "Skipping backup copy to other drives as '-NoCopy' argument was used."
}

# Cleanup temp CSV files
Write-Output "Cleaning temp CSV folder"

# Check if silent flag is set
if (-not $Silent) {
    $confirmationDelete = Read-Host "Do you want to clean temporary backup files? (Y/n)"
    if (-not $confirmationDelete) {
        $confirmationDelete = 'Y'
    }
}
else {
    $confirmationDelete = 'Y'
}
if ($confirmationDelete -eq 'Y') {
    Remove-Item -Path $BackupLocation -Recurse -Force
    Write-Output "Cleaning temp CSV folder completed.`n"
}
else {
    Write-Output "Cleanup cancelled.`n"
}



# Report the result and exit
if ($failures) {
    Write-Warning "Backup completed with errors:"
    $failures | ForEach-Object { Write-Warning " - $_" }
}
else {
    Write-Host "Backup completed successfully."
}
Write-Host "Saved file to: $ArchivePath"
if ($copiedTo) {
    Write-Host "Copied to: $($copiedTo -join ', ')"
}
Write-Host ""
ExitScript ([int][bool]$failures)

# End of script