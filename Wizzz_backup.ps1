# Command-line parameters
#   -Silent    Accept all prompts automatically
#   -NoCopy    Do not copy the backup to other drives
#   -ForceZip  Use the built-in Zip compression even if 7-Zip is installed
#   -BackupRoot   Full path of the folder where the backup is saved (default: C:\Backup)
#                 The backup is copied to the same folder on the other drives
#   -WizTreePath  Full path of WizTree.exe (default: looked up in the script folder,
#                 then in the WizTree installation folder)
#   -SkipScan  Drives that are not exported, e.g. -SkipScan "E:","F:"
#   -SkipCopy  Drives the backup is not copied to, e.g. -SkipCopy "D:"
#   -CopyTo    Extra folders the backup is copied to, e.g. -CopyTo "G:\My Drive\Backup"
#              They are added to the automatic copies (use -NoCopy to only copy to them)
# Lists can also be given as a single comma separated value, e.g. -SkipScan "E:,F:"
#
# Scheduled task
#   -InstallTask    Register a scheduled task that runs the backup with the other options
#                   given on the command line, then exit. Running it again replaces the task.
#   -UninstallTask  Remove the scheduled task, then exit
#   -TaskDay        Day of the week the task runs (default: Sunday)
#   -TaskTime       Time the task runs (default: 23:12)
param(
    [switch]$Silent,
    [switch]$NoCopy,
    [switch]$ForceZip,
    [string]$BackupRoot = "C:\Backup",
    [string]$WizTreePath,
    [string[]]$SkipScan = @(),
    [string[]]$SkipCopy = @(),
    [string[]]$CopyTo = @(),
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [ValidateSet("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")]
    [string]$TaskDay = "Sunday",
    [string]$TaskTime = "23:12"
)

##########################
#####Global variables#####
##########################

# Split comma separated values and remove empty entries
function SplitList([string[]]$Values) {
    $Values | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Get the drive letters, accepting "E", "E:" or "E:\"
function GetDriveLetters([string[]]$Values) {
    SplitList $Values | ForEach-Object { $_.Substring(0, 1).ToUpper() }
}

# Build the command line arguments for the given parameters, except the excluded ones
function GetForwardedArguments($Parameters, [string[]]$Exclude = @()) {
    foreach ($param in $Parameters.GetEnumerator()) {
        if ($param.Key -in $Exclude) {
            continue
        }
        if ($param.Value -is [switch]) {
            if ($param.Value) { "-$($param.Key)" }
        }
        else {
            # Lists are passed as a single comma separated value
            $value = @($param.Value) -join ","
            # A trailing backslash would escape the closing quote, double it
            if ($value.EndsWith("\")) { $value += "\" }
            "-$($param.Key) `"$value`""
        }
    }
}

# Name of the scheduled task
$TaskName = "Wiztree Filesystem Backup"

# Folders excluded from the export: they contain too many files that are not useful in a backup
# Uses the WizTree filter syntax: * is a wildcard and folders end with a backslash.
# Environment variables like %LOCALAPPDATA% are expanded.
$DefaultExclusions = @(
    '%WINDIR%',
    '*\$Recycle.Bin\',
    '*\System Volume Information\',
    # Temporary files and caches
    '*\AppData\Local\Temp\',
    '*\AppData\Local\Microsoft\Windows\INetCache\',
    # Package managers
    '%LOCALAPPDATA%\Yarn\',
    '*\AppData\Local\npm-cache\',
    '*\AppData\Local\pip\cache\',
    '*\.nuget\packages\',
    '*\.gradle\caches\',
    '*\.m2\repository\',
    '*\.cargo\registry\',
    # Dependencies and build files inside projects
    '*\node_modules\',
    '*\.git\',
    '*\__pycache__\',
    '*\.venv\'
)
$Exclusions = $DefaultExclusions

# Build the WizTree exclusion filter, separated with pipe "|"
function GetExclusionFilter([string[]]$Patterns) {
    ($Patterns | ForEach-Object { "`"$([Environment]::ExpandEnvironmentVariables($_))`"" }) -join "|"
}

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
    $forwardedArgs = GetForwardedArguments $PSBoundParameters
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $forwardedArgs" -Verb RunAs
    exit
}

# Register or remove the scheduled task, then exit
if ($InstallTask -and $UninstallTask) {
    Write-Output "Use either -InstallTask or -UninstallTask, not both."
    ExitScript 1
}
if ($UninstallTask) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "Scheduled task '$TaskName' removed."
    }
    else {
        Write-Output "Scheduled task '$TaskName' does not exist."
    }
    ExitScript
}
if ($InstallTask) {
    # The task runs this script silently with the same options, except the task options
    $taskArgs = GetForwardedArguments $PSBoundParameters -Exclude "InstallTask", "UninstallTask", "TaskDay", "TaskTime", "Silent"
    $taskCommand = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent $taskArgs".TrimEnd()
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskCommand
        $trigger = New-ScheduledTaskTrigger -Weekly -At $TaskTime -DaysOfWeek $TaskDay -ErrorAction Stop

        # Run as the current user whether they are logged on or not, without storing a password (S4U)
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest

        # Run as soon as possible if the computer was off at the scheduled time, and also on battery
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        # Register the task, replacing it if it already exists
        $null = Register-ScheduledTask -TaskName $TaskName -Description "Takes a copy of filesystem structure using WizTree and saves it in $BackupRoot" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to register the scheduled task: $_"
        ExitScript 1
    }
    Write-Output "Scheduled task '$TaskName' registered: every $TaskDay at $TaskTime"
    Write-Output "Command: powershell.exe $taskCommand"
    ExitScript
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

# Keep only drives on a real disk partition. Virtual drives such as Google Drive,
# subst drives or RAM disks are reported as fixed drives but have no partition.
$partitionLetters = Get-Partition -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter }
if ($partitionLetters) {
    $virtualDrives = $drives | Where-Object { $_.DeviceID[0] -notin $partitionLetters }
    foreach ($drive in $virtualDrives) {
        Write-Output "Skipping $($drive.DeviceID) $($drive.VolumeName): not on a disk partition (virtual drive)"
    }
    $drives = $drives | Where-Object { $_.DeviceID[0] -in $partitionLetters }
}
else {
    Write-Warning "Could not list the disk partitions, virtual drives will not be skipped."
}

# Normalize the drive and folder lists
$SkipScan = @(GetDriveLetters $SkipScan)
$SkipCopy = @(GetDriveLetters $SkipCopy)
$CopyTo = @(SplitList $CopyTo)

# Warn about skipped drives that are not in the list, probably a typo
$driveLetters = $drives | ForEach-Object { $_.DeviceID.Substring(0, 1) }
foreach ($letter in ($SkipScan + $SkipCopy | Select-Object -Unique)) {
    if ($letter -notin $driveLetters) {
        Write-Warning "Drive $($letter): is skipped but is not one of the drives to back up"
    }
}

# Drives to export with WizTree
$scanDrives = $drives | Where-Object { $_.DeviceID.Substring(0, 1) -notin $SkipScan }

# Folders the backup is copied to: the backup folder on the other drives, then the -CopyTo folders
$backupDriveLetter = [System.IO.Path]::GetPathRoot($BackupRoot).Substring(0, 1)
$copyTargets = @()
if (-not $NoCopy) {
    foreach ($drive in $drives) {
        $letter = $drive.DeviceID.Substring(0, 1)
        if ($letter -ne $backupDriveLetter -and $letter -notin $SkipCopy) {
            $copyTargets += Join-Path $drive.DeviceID (Split-Path $BackupRoot -NoQualifier)
        }
    }
}
$copyTargets += $CopyTo | Where-Object { $_.TrimEnd("\") -ne $BackupRoot.TrimEnd("\") }
# Remove duplicates, ignoring case and trailing backslashes
$copyTargets = @($copyTargets | Group-Object { $_.TrimEnd("\") } | ForEach-Object { $_.Group[0] })

# Display the drives in a table with additional information
Write-Host "Drives:"
$drives | Select-Object @{ Name = "Drive"; Expression = { $_.DeviceID } },
    @{ Name = "Name"; Expression = { $_.VolumeName } },
    @{ Name = "Size (GB)"; Expression = { [int]($_.Size / 1GB) } },
    @{ Name = "Free (GB)"; Expression = { [int]($_.FreeSpace / 1GB) } },
    @{ Name = "Scan"; Expression = { if ($_.DeviceID.Substring(0, 1) -in $SkipScan) { "No" } else { "Yes" } } },
    @{ Name = "Copy"; Expression = {
            $deviceId = $_.DeviceID
            if ($deviceId.Substring(0, 1) -eq $backupDriveLetter) { "Backup folder" }
            elseif ($copyTargets | Where-Object { $_.StartsWith($deviceId, [System.StringComparison]::OrdinalIgnoreCase) }) { "Yes" }
            else { "No" }
        }
    } | Format-Table -AutoSize | Out-Host

Write-Host "Backup folder: $BackupRoot"
if ($copyTargets) {
    Write-Host "Copies:"
    $copyTargets | ForEach-Object { Write-Host "  $_" }
}
else {
    Write-Host "Copies: none"
}
Write-Host ""


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
foreach ($drive in $scanDrives) {
    # Get DriveName And CsvName
    $DriveName = $drive.DeviceID
    $CsvName = ($drive.DeviceID[0] + "_%d_%t.csv")
    # Save backup
    Write-Output "Saving backup for $DriveName"
    $wizTree = Start-Process -FilePath $WizTreeExePath -ArgumentList "$DriveName /export=""$BackupLocation\$CsvName"" /admin=1 /filterexclude=$(GetExclusionFilter $Exclusions)" -Wait -PassThru

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

# Copy the backup to the other drives and the -CopyTo folders
$copiedTo = @()
$notConnected = @()
foreach ($destinationPath in $copyTargets) {
    # Skip destinations on a drive that is not connected, e.g. an unplugged external drive
    $destinationRoot = [System.IO.Path]::GetPathRoot($destinationPath)
    if (-not (Test-Path $destinationRoot)) {
        Write-Output "Skipping $($destinationPath): drive $destinationRoot is not connected"
        $notConnected += $destinationPath
        continue
    }

    $destinationFilePath = Join-Path $destinationPath $ArchiveName
    Write-Output "Copying backup to $destinationPath"
    try {
        # Create the destination folder if it doesn't exist
        if (-not (Test-Path $destinationPath -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $destinationPath -Force -ErrorAction Stop
        }
        Copy-Item -Path $ArchivePath -Destination $destinationFilePath -Force -ErrorAction Stop
        $copiedTo += $destinationFilePath
    }
    catch {
        Write-Warning "Failed to copy backup to $($destinationPath): $_"
        $failures += "Copy to $destinationPath"
    }
}
if ($copyTargets) {
    Write-Output "Copying done.`n"
}
else {
    Write-Output "No copies to make.`n"
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
if ($notConnected) {
    Write-Host "Not copied, drive not connected: $($notConnected -join ', ')"
}
Write-Host ""
ExitScript ([int][bool]$failures)

# End of script