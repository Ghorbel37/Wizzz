##########################
#####Global variables#####
##########################

# Set the running location
$RunLocation = $PSScriptRoot
$BackupRoot = "C:\Backup"

# Set the excluded folders ( Folders that have too many files )
#Separate with pipe "|"
$Excluded = """$env:WINDIR""|""$env:LOCALAPPDATA\Yarn\"""

# Locations that should have backup folder
# Separate with comma ","

# $destinationDrives = "D:", "E:", "F:" 

##########################
###Global variables end###
##########################


# Parse command-line arguments
foreach ($arg in $args) {
    switch ($arg) {
        "-silent" { $silentMode = $true }
    }
}

# Function to display script information
function DisplayScriptInformation() {
    Clear-Host
    Write-Host "`n`nWelcome to the Backup Script" -ForegroundColor Cyan
    Write-Host "This script exports filesystem structure to csv using WizTree," -ForegroundColor Cyan
    Write-Host "compresses the exported files, and copies the backup to multiple locations." -ForegroundColor Cyan
    if ($silentMode) {
        Write-Host "Script is running in silent mode" -ForegroundColor Yellow
    }
    Write-Host "`n`n"
}

# Display script information
DisplayScriptInformation


# Check if the script is running with elevated privileges and restart it if not
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Output "This script needs to run as an administrator"
    Write-Output "It will restart itself with administrator privileges."
    Write-Output "Press any key to continue..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Check if the WizTree executable exists
$WizTreeExePath = Join-Path $RunLocation "WizTree.exe"
if (-not (Test-Path $WizTreeExePath -PathType Leaf)) {
    Write-Output "WizTree.exe not found. Make sure it is in the script directory."
    Write-Output "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# Get the current date and time for creating a unique folder
$BackupFolderName = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupLocation = Join-Path $BackupRoot $BackupFolderName


# Display all drives in a table with additional information
Write-Host "Available drives:`n"
$drives = Get-WmiObject Win32_LogicalDisk | Select-Object DeviceID, VolumeName, Size, FreeSpace, FileSystem
$drives | Format-Table -AutoSize


# Ask for confirmation
if (-not $silentMode) {
    $confirmation = Read-Host "Do you want to proceed with the backup? (Y/n)"
    if (-not $confirmation) {
        $confirmation = 'Y'
    }
    if ($confirmation -ne 'Y') {
        Write-Host "Backup aborted."
        Write-Output "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }
}

# Create a new folder for each backup
Write-Output "`nCreating temporary backup folder"
$null = New-Item -ItemType Directory -Path $BackupLocation -Force
Write-Output "Done.`n"



# Get all logical drives
$drives = Get-WmiObject Win32_LogicalDisk | Select-Object DeviceID

# Display the list
foreach ($drive in $drives) {
    # Get DriveName And CsvName
    $DriveName = $drive.DeviceID
    $CsvName = ( $drive.DeviceID[0] + "_%d_%t.csv")
    # System drive
    if ($drive.DeviceID -eq $env:SystemDrive) {
        Write-Output "Saving backup for $DriveName"
        Start-Process -FilePath "$RunLocation\WizTree.exe" -ArgumentList "$DriveName /export=""$BackupLocation\$CsvName"" /admin=1 /filterexclude=$Excluded" -Wait
            
    }
    # Other drives
    else {
        Write-Output "Saving backup for $DriveName"
        Start-Process -FilePath "$RunLocation\WizTree.exe" -ArgumentList "$DriveName /export=""$BackupLocation\$CsvName"" /admin=1 /filterexclude=$Excluded" -Wait
    }
}
Write-Output "Backup complete`n"

# Check if 7-Zip is installed
$sevenZipPath = "C:\Program Files\7-Zip\7z.exe"
$use7Zip = Test-Path $sevenZipPath

# Compressing all files
if ($use7Zip) {
    Write-Output "7-Zip found. Compressing using 7-Zip"
    $ArchiveName = "Backup_$BackupFolderName.7z"
    $ArchivePath = Join-Path $BackupRoot $ArchiveName
    & $sevenZipPath a -t7z $ArchivePath "$BackupLocation\*.csv" -mx=9
}
else {
    Write-Output "7-Zip not found. Compressing using built-in Zip"
    $ArchiveName = "Backup_$BackupFolderName.zip"
    $ArchivePath = Join-Path $BackupRoot $ArchiveName
    Compress-Archive -Path "$BackupLocation\*.csv" -DestinationPath $ArchivePath -CompressionLevel "Optimal" -Force
}
Write-Output "Compression done.`n"

# Copy the backup to all drives
foreach ($drive in $drives) {
    $destinationPath = Join-Path $drive.DeviceID "Backup"
    $destinationFilePath = Join-Path $destinationPath $ArchiveName

    # Create Backup folder if it doesn't exist
    if (-not (Test-Path $destinationPath -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationPath -Force
    }

    Write-Output "Copying backup to $($drive.DeviceID)"
    Copy-Item -Path $ArchivePath -Destination $destinationFilePath -Force
}
Write-Output "Copied backup to all drives.`n"

# Cleanup temp CSV files
Write-Output "Cleaning temp CSV folder"

# Check if silent flag is set
if (-not $silentMode) {
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



# Prompt to press any key to exit
Write-Host "Backup completed successfully."
Write-Host "Saved file to: *:\Backup\$ArchiveName `n"
if (-not $silentMode) {
    Write-Output "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# End of script