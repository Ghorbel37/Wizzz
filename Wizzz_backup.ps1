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
#   -ConfigPath  Configuration file (default: Wizzz.config.json next to this script)
#                It overrides the default configuration Wizzz.config.default.json.
#                Options given on the command line override both.
#   -Configure   Edit the configuration file interactively, then exit
#
# Scheduled task
#   -InstallTask    Register a scheduled task that runs the backup with the configuration file
#                   and the other options given on the command line, then exit.
#                   Running it again replaces the task.
#   -UninstallTask  Remove the scheduled task, then exit
#   -TaskDay        Day of the week the task runs (default: Sunday)
#   -TaskTime       Time the task runs (default: 23:12)
param(
    [switch]$Silent,
    [switch]$NoCopy,
    [switch]$ForceZip,
    [string]$BackupRoot,
    [string]$WizTreePath,
    [string[]]$SkipScan = @(),
    [string[]]$SkipCopy = @(),
    [string[]]$CopyTo = @(),
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [string]$TaskDay,
    [string]$TaskTime,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "Wizzz.config.json"),
    [switch]$Configure
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

# Get the free space in bytes of the drive of a path, or $null if it cannot be read
function GetFreeSpace([string]$Path) {
    try {
        ([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
    }
    catch {
        $null
    }
}

# Free space needed on the backup drive before exporting
$MinFreeSpace = 1GB

# Name of the scheduled task
$TaskName = "Wiztree Filesystem Backup"

# Folders excluded from the export: they contain too many files that are not useful in a backup
# Uses the WizTree filter syntax: * is a wildcard and folders end with a backslash.
# Environment variables like %LOCALAPPDATA% are expanded.
$DefaultExclusions = @(
    '%WINDIR%\',
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

# Default settings, used when the default configuration file is missing, e.g. when only the script was copied.
# Overridden by the default configuration file, the configuration file, then the command line.
$DefaultSettings = [ordered]@{
    BackupRoot  = "C:\Backup"
    WizTreePath = ""
    NoCopy      = $false
    ForceZip    = $false
    SkipScan    = @()
    SkipCopy    = @()
    CopyTo      = @()
    Exclusions  = $DefaultExclusions
    TaskDay     = "Sunday"
    TaskTime    = "23:12"
}
$WeekDays = "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"

# Default configuration shipped with the script, it overrides the default settings above.
# The configuration file (-ConfigPath) only contains the local changes and overrides it.
$DefaultConfigPath = Join-Path $PSScriptRoot "Wizzz.config.default.json"

# Read the configuration file, returns the settings it contains
function ReadConfig([string]$Path) {
    $config = [ordered]@{}
    if (-not (Test-Path $Path -PathType Leaf)) {
        return $config
    }
    try {
        $json = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$($Path): $_"
    }
    foreach ($property in $json.PSObject.Properties) {
        if ($property.Name -in $DefaultSettings.Keys) {
            $config[$property.Name] = $property.Value
        }
        else {
            Write-Warning "Unknown setting '$($property.Name)' in $Path"
        }
    }
    return $config
}

# Build the WizTree exclusion filter, separated with pipe "|"
# The whole filter is double quoted and each pattern is quoted with single quotes, which WizTree
# reads as double quotes. Double quotes around each pattern do not work, the backslash before
# the closing quote of a folder escapes it and the filter is ignored.
# A single quote inside a pattern is written as two single quotes.
# Folders get a trailing * so their content is excluded too: when scanning a whole drive,
# WizTree does not always exclude the subfolders of a folder that only ends with a backslash.
function GetExclusionFilter([string[]]$Patterns) {
    $quoted = $Patterns | ForEach-Object {
        $pattern = [Environment]::ExpandEnvironmentVariables($_)
        if ($pattern.EndsWith("\")) { $pattern += "*" }
        "'" + $pattern.Replace("'", "''") + "'"
    }
    "`"$($quoted -join "|")`""
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

# Write an entry to the Windows Application event log, under the "Wizzz" source
# Event IDs: 1 = backup succeeded, 2 = backup completed with errors, 3 = backup failed
function WriteEvent([string]$EntryType, [int]$EventId, [string]$Message) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("Wizzz")) {
            [System.Diagnostics.EventLog]::CreateEventSource("Wizzz", "Application")
        }
        [System.Diagnostics.EventLog]::WriteEntry("Wizzz", $Message, $EntryType, $EventId)
    }
    catch {
        Write-Warning "Could not write to the event log: $_"
    }
}

# Stop the backup after an error: log it to the event log and exit
function FailBackup([string]$Message) {
    Write-Error $Message
    WriteEvent -EntryType "Error" -EventId 3 -Message "Backup failed: $Message`nLog: $LogPath"
    ExitScript 1
}

# Get local fixed drives only (DriveType 3), skipping optical, removable and network drives
function GetLocalDrives([switch]$Quiet) {
    $localDrives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" | Select-Object DeviceID, VolumeName, Size, FreeSpace, FileSystem

    # Keep only drives on a real disk partition. Virtual drives such as Google Drive,
    # subst drives or RAM disks are reported as fixed drives but have no partition.
    $partitionLetters = Get-Partition -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter }
    if ($partitionLetters) {
        $virtualDrives = $localDrives | Where-Object { $_.DeviceID[0] -notin $partitionLetters }
        if (-not $Quiet) {
            foreach ($drive in $virtualDrives) {
                Write-Host "Skipping $($drive.DeviceID) $($drive.VolumeName): not on a disk partition (virtual drive)"
            }
        }
        $localDrives = $localDrives | Where-Object { $_.DeviceID[0] -in $partitionLetters }
    }
    elseif (-not $Quiet) {
        Write-Warning "Could not list the disk partitions, virtual drives will not be skipped."
    }
    $localDrives
}

# Register the scheduled task, returns $true on success
# The task runs this script silently with the configuration file and the given extra arguments.
# The configuration file is read on each run, so it can be changed later without reinstalling the task.
function InstallScheduledTask([string]$ExtraArguments) {
    $taskCommand = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent -ConfigPath `"$ConfigPath`" $ExtraArguments".TrimEnd()
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskCommand
        $trigger = New-ScheduledTaskTrigger -Weekly -At $TaskTime -DaysOfWeek $TaskDay -ErrorAction Stop

        # Run as the current user whether they are logged on or not, without storing a password (S4U)
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest

        # Run as soon as possible if the computer was off at the scheduled time, and also on battery
        $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        # Register the task, replacing it if it already exists
        $null = Register-ScheduledTask -TaskName $TaskName -Description "Takes a copy of filesystem structure using WizTree and saves it in $BackupRoot" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to register the scheduled task: $_"
        return $false
    }
    Write-Host "Scheduled task '$TaskName' registered: every $TaskDay at $TaskTime"
    Write-Host "Command: powershell.exe $taskCommand"
    return $true
}

# Ask a yes/no question, Enter means yes
function ConfirmChoice([string]$Question) {
    $answer = Read-Host "$Question (Y/n)"
    return (-not $answer -or $answer -eq "Y")
}

# Format a list for display
function FormatList($Items) {
    if (@($Items).Count) { @($Items) -join ", " } else { "(none)" }
}

# Edit a list interactively, returns the new list
function EditList([string]$Title, [string[]]$Items, [string[]]$Defaults) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Items) { $list.Add($item) }
    while ($true) {
        Write-Host "`n$Title" -ForegroundColor Cyan
        if ($list.Count) {
            for ($i = 0; $i -lt $list.Count; $i++) {
                Write-Host ("  {0,2}. {1}" -f ($i + 1), $list[$i])
            }
        }
        else {
            Write-Host "  (none)"
        }
        $prompt = "A = add, R = remove"
        if ($Defaults) { $prompt += ", D = reset to defaults" }
        $choice = Read-Host "$prompt, Enter = done"
        switch ($choice) {
            "A" {
                $value = (Read-Host "Value to add").Trim()
                if ($value) { $list.Add($value) }
            }
            "R" {
                $number = Read-Host "Number to remove"
                if ($number -match "^\d+$" -and [int]$number -ge 1 -and [int]$number -le $list.Count) {
                    $list.RemoveAt([int]$number - 1)
                }
                else {
                    Write-Host "Invalid number." -ForegroundColor Yellow
                }
            }
            "D" {
                if ($Defaults) {
                    $list.Clear()
                    foreach ($item in $Defaults) { $list.Add($item) }
                }
            }
            "" { return , $list.ToArray() }
            default { Write-Host "Invalid choice." -ForegroundColor Yellow }
        }
    }
}

# Ask for a list of drives, showing the available drives, returns the new list
function ReadDrives([string]$Title, [string[]]$Current, $AvailableDrives) {
    Write-Host "`nAvailable drives:" -ForegroundColor Cyan
    foreach ($drive in $AvailableDrives) {
        Write-Host ("  {0}  {1,-20} {2,6} GB" -f $drive.DeviceID, $drive.VolumeName, [int]($drive.Size / 1GB))
    }
    $value = Read-Host "$Title, separated by commas, - for none [$(FormatList $Current)]"
    if (-not $value) {
        return , @($Current)
    }
    if ($value.Trim() -eq "-") {
        return , @()
    }
    return , @(GetDriveLetters $value | Where-Object { $_ -match "^[A-Z]$" } | ForEach-Object { "$($_):" } | Select-Object -Unique)
}

# Edit the configuration interactively and save it to the configuration file
function EditConfiguration {
    $edited = [ordered]@{}
    foreach ($key in $Settings.Keys) { $edited[$key] = $Settings[$key] }
    # Normalize the values, they can come from the command line
    $edited.NoCopy = [bool]$edited.NoCopy
    $edited.ForceZip = [bool]$edited.ForceZip
    $edited.SkipScan = @(GetDriveLetters $edited.SkipScan | ForEach-Object { "$($_):" } | Select-Object -Unique)
    $edited.SkipCopy = @(GetDriveLetters $edited.SkipCopy | ForEach-Object { "$($_):" } | Select-Object -Unique)
    $edited.CopyTo = @(SplitList $edited.CopyTo)
    $edited.Exclusions = @($edited.Exclusions)
    $availableDrives = GetLocalDrives -Quiet

    while ($true) {
        Clear-Host
        Write-Host "Wizzz configuration" -ForegroundColor Cyan
        Write-Host "$ConfigPath`n"
        $wizTreeDisplay = if ($edited.WizTreePath) { $edited.WizTreePath } else { "(automatic)" }
        $copyDisplay = if ($edited.NoCopy) { "No" } else { "Yes" }
        $zipDisplay = if ($edited.ForceZip) { "Built-in Zip" } else { "7-Zip when installed" }
        Write-Host "  1. Backup folder          $($edited.BackupRoot)"
        Write-Host "  2. WizTree path           $wizTreeDisplay"
        Write-Host "  3. Copy to other drives   $copyDisplay"
        Write-Host "  4. Compression            $zipDisplay"
        Write-Host "  5. Skip scanning          $(FormatList $edited.SkipScan)"
        Write-Host "  6. Skip copying           $(FormatList $edited.SkipCopy)"
        Write-Host "  7. Extra copy folders     $(FormatList $edited.CopyTo)"
        Write-Host "  8. Exclusions             $(@($edited.Exclusions).Count) folders"
        Write-Host "  9. Schedule               every $($edited.TaskDay) at $($edited.TaskTime)"
        Write-Host ""
        Write-Host "  S. Save and exit"
        Write-Host "  Q. Quit without saving"
        Write-Host ""

        switch (Read-Host "Choice") {
            "1" {
                $value = Read-Host "Backup folder, full path [$($edited.BackupRoot)]"
                if ($value) {
                    if ($value -match "^[A-Za-z]:\\") {
                        $edited.BackupRoot = $value.Trim()
                    }
                    else {
                        Write-Host "Use a full path such as C:\Backup" -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    }
                }
            }
            "2" {
                $value = Read-Host "Full path of WizTree.exe, - for automatic [$wizTreeDisplay]"
                if ($value -eq "-") {
                    $edited.WizTreePath = ""
                }
                elseif ($value) {
                    if (-not (Test-Path $value -PathType Leaf)) {
                        Write-Host "Warning: $value does not exist" -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    }
                    $edited.WizTreePath = $value.Trim()
                }
            }
            "3" { $edited.NoCopy = -not $edited.NoCopy }
            "4" { $edited.ForceZip = -not $edited.ForceZip }
            "5" { $edited.SkipScan = ReadDrives -Title "Drives not to scan" -Current $edited.SkipScan -AvailableDrives $availableDrives }
            "6" { $edited.SkipCopy = ReadDrives -Title "Drives not to copy the backup to" -Current $edited.SkipCopy -AvailableDrives $availableDrives }
            "7" { $edited.CopyTo = EditList -Title "Extra folders the backup is copied to, e.g. G:\My Drive\Backup" -Items $edited.CopyTo }
            "8" { $edited.Exclusions = EditList -Title "Excluded folders (* is a wildcard, folders end with \)" -Items $edited.Exclusions -Defaults $DefaultSettings.Exclusions }
            "9" {
                $day = Read-Host "Day of the week [$($edited.TaskDay)]"
                if ($day) {
                    $match = $WeekDays | Where-Object { $_ -like "$($day.Trim())*" } | Select-Object -First 1
                    if ($match) { $edited.TaskDay = $match } else { Write-Host "Invalid day." -ForegroundColor Yellow; Start-Sleep -Seconds 2 }
                }
                $time = Read-Host "Time, e.g. 23:12 [$($edited.TaskTime)]"
                if ($time) {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParseExact($time.Trim(), "H:mm", [System.Globalization.CultureInfo]::InvariantCulture, "None", [ref]$parsed)) {
                        $edited.TaskTime = $parsed.ToString("HH:mm")
                    }
                    else {
                        Write-Host "Invalid time." -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    }
                }
            }
            "S" {
                # Only save the settings that are different from the defaults,
                # so new default values (e.g. exclusions) are used for the other ones
                $toSave = [ordered]@{}
                foreach ($key in $edited.Keys) {
                    if ((ConvertTo-Json -InputObject $edited[$key] -Compress) -ne (ConvertTo-Json -InputObject $DefaultSettings[$key] -Compress)) {
                        $toSave[$key] = $edited[$key]
                    }
                }
                try {
                    ConvertTo-Json -InputObject $toSave -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8 -ErrorAction Stop
                }
                catch {
                    Write-Error "Could not save the configuration file: $_"
                    return $false
                }
                Write-Host "`nConfiguration saved to $ConfigPath" -ForegroundColor Green

                # Install the task, or update it when the schedule changed
                $script:BackupRoot = $edited.BackupRoot
                $script:TaskDay = $edited.TaskDay
                $script:TaskTime = $edited.TaskTime
                $taskExists = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
                $scheduleChanged = $edited.TaskDay -ne $Settings.TaskDay -or $edited.TaskTime -ne $Settings.TaskTime
                if (-not $taskExists) {
                    if (ConfirmChoice "Install the scheduled task to run the backup every $TaskDay at $($TaskTime)?") {
                        return (InstallScheduledTask)
                    }
                }
                elseif ($scheduleChanged) {
                    if (ConfirmChoice "Update the scheduled task to run every $TaskDay at $($TaskTime)?") {
                        return (InstallScheduledTask)
                    }
                }
                return $true
            }
            "Q" { return $true }
        }
    }
}

# Display script information
DisplayScriptInformation

# Use the full path of the configuration file, the elevated instance and the task start in another folder
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
if ($PSBoundParameters.ContainsKey("ConfigPath")) {
    $PSBoundParameters["ConfigPath"] = $ConfigPath
}


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

# Load the settings: defaults, then the default configuration, then the configuration file, then the command line
try {
    if ($ConfigPath -ne $DefaultConfigPath) {
        $config = ReadConfig $DefaultConfigPath
        foreach ($key in $config.Keys) { $DefaultSettings[$key] = $config[$key] }
    }
    $config = ReadConfig $ConfigPath
}
catch {
    Write-Error "Could not read the configuration file $_"
    ExitScript 1
}
$Settings = [ordered]@{}
foreach ($key in $DefaultSettings.Keys) {
    if ($PSBoundParameters.ContainsKey($key)) {
        $Settings[$key] = $PSBoundParameters[$key]
    }
    elseif ($config.Contains($key)) {
        $Settings[$key] = $config[$key]
    }
    else {
        $Settings[$key] = $DefaultSettings[$key]
    }
}
if ($config.Count) {
    Write-Output "Using configuration file $ConfigPath`n"
}
$BackupRoot = $Settings.BackupRoot
$WizTreePath = $Settings.WizTreePath
$NoCopy = [bool]$Settings.NoCopy
$ForceZip = [bool]$Settings.ForceZip
$SkipScan = @($Settings.SkipScan)
$SkipCopy = @($Settings.SkipCopy)
$CopyTo = @($Settings.CopyTo)
$Exclusions = @($Settings.Exclusions)
$TaskDay = $Settings.TaskDay
$TaskTime = $Settings.TaskTime
if ($TaskDay -notin $WeekDays) {
    Write-Error "Invalid TaskDay '$TaskDay', use one of: $($WeekDays -join ', ')"
    ExitScript 1
}

# Edit the configuration interactively, then exit
if ($Configure) {
    if ($Silent) {
        Write-Output "-Configure cannot be used with -Silent."
        ExitScript 1
    }
    ExitScript ([int](-not (EditConfiguration)))
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
    # Pass the options given on the command line, except the task options
    $taskArgs = GetForwardedArguments $PSBoundParameters -Exclude "InstallTask", "UninstallTask", "TaskDay", "TaskTime", "Silent", "ConfigPath", "Configure"
    ExitScript ([int](-not (InstallScheduledTask "$taskArgs")))
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
    $message = "WizTree not found. Searched:`n$(($wizTreeCandidates | ForEach-Object { "  $_" }) -join "`n")`n"
    $message += "Download and install WizTree from https://diskanalyzer.com/download or place this script in the WizTree folder.`n"
    if ($WizTreePath) {
        $message += "Check the WizTree path given with -WizTreePath or in the configuration (-Configure), or remove it to find WizTree automatically."
    }
    else {
        $message += "If WizTree is somewhere else, give the full path of WizTree.exe with -WizTreePath or in the configuration (-Configure)."
    }
    FailBackup $message
}
Write-Output "Using WizTree: $WizTreeExePath"

# Check if 7-Zip is installed, using its registry entry, the usual install folders or the PATH
$sevenZipCandidates = @(
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\7-Zip" -Name Path -ErrorAction SilentlyContinue).Path,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
) | Where-Object { $_ } | ForEach-Object { Join-Path $_ "7z.exe"; Join-Path $_ "7-Zip\7z.exe" }
$sevenZipCandidates += (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
$sevenZipPath = $sevenZipCandidates | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
$use7Zip = [bool]$sevenZipPath -and -not $ForceZip
if ($use7Zip) {
    Write-Output "Using 7-Zip: $sevenZipPath`n"
}
elseif ($ForceZip) {
    Write-Output "Using the built-in Zip compression (-ForceZip)`n"
}
else {
    Write-Warning "7-Zip is not installed, the built-in Zip compression is used. Install 7-Zip from https://www.7-zip.org/ for archives about half the size."
    Write-Output ""
}


# Get the drives to back up
$drives = GetLocalDrives

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

# Make sure there is room for the exported CSV files
$backupFreeSpace = GetFreeSpace $BackupRoot
if ($null -ne $backupFreeSpace -and $backupFreeSpace -lt $MinFreeSpace) {
    FailBackup "Not enough free space in $BackupRoot ($([math]::Round($backupFreeSpace / 1GB, 2)) GB free, $($MinFreeSpace / 1GB) GB needed)"
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
    FailBackup "No drive was exported."
}
Write-Output "Backup complete`n"

# Compressing all files
if ($use7Zip) {
    Write-Output "Compressing using 7-Zip"
    $ArchiveName = "Backup_$BackupFolderName.7z"
    $ArchivePath = Join-Path $BackupRoot $ArchiveName
    # PPMd compresses the CSV text about 30% smaller than the default LZMA2 and faster.
    # Order 10 with 256 MB of memory gave the smallest archives, extracting needs the same memory.
    # Pipe through Out-Host so the 7-Zip output also goes to the log
    & $sevenZipPath a -t7z $ArchivePath "$BackupLocation\*.csv" -m0=PPMd:o=10:mem=256m | Out-Host
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
    FailBackup "Compression failed. The exported CSV files were kept in $BackupLocation"
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

    # Make sure the archive fits on the destination drive
    $archiveSize = (Get-Item $ArchivePath).Length
    $destinationFreeSpace = GetFreeSpace $destinationPath
    if ($null -ne $destinationFreeSpace -and $destinationFreeSpace -lt $archiveSize) {
        Write-Warning "Not enough free space to copy backup to $destinationPath ($([math]::Round($destinationFreeSpace / 1MB)) MB free, $([math]::Round($archiveSize / 1MB)) MB needed)"
        $failures += "Copy to $destinationPath (not enough free space)"
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
    WriteEvent -EntryType "Warning" -EventId 2 -Message "Backup completed with errors:`n$($failures -join "`n")`n`nArchive: $ArchivePath`nLog: $LogPath"
}
else {
    Write-Host "Backup completed successfully."
    WriteEvent -EntryType "Information" -EventId 1 -Message "Backup completed successfully.`n`nArchive: $ArchivePath`nLog: $LogPath"
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