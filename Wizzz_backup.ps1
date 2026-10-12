<#
.SYNOPSIS
    Backs up the filesystem tree of each drive with WizTree.

.DESCRIPTION
    Exports the filesystem tree of each local fixed drive to a CSV file with WizTree,
    compresses the CSV files in a single archive (7-Zip when installed, otherwise Zip)
    and copies the archive to the same folder on the other drives and to extra folders.

    The settings come from, by order of priority: the command line, the configuration file
    (Wizzz.config.json), the default configuration (Wizzz.config.default.json),
    then the default values in this script.

    The script restarts itself as administrator when needed. Each run is logged to
    <BackupRoot>\Logs and to the Windows Application event log under the "Wizzz" source
    (event ID 1 = success, 2 = completed with errors, 3 = failed).
    The script exits with code 1 when something failed.

    Lists can be given as several values or as a single comma separated value,
    e.g. -SkipScan "E:","F:" or -SkipScan "E:,F:".

.PARAMETER Silent
    Accept all prompts automatically.

.PARAMETER NoCopy
    Do not copy the backup to the other drives. The -CopyTo folders are still used.

.PARAMETER ForceZip
    Use the built-in Zip compression even if 7-Zip is installed.

.PARAMETER BackupRoot
    Full path of the folder where the backup is saved (default: C:\Backup).
    The backup is copied to the same folder on the other drives.

.PARAMETER WizTreePath
    Full path of WizTree.exe (default: looked up in the script folder,
    then in the WizTree installation folder).

.PARAMETER SkipScan
    Drives that are not exported, e.g. -SkipScan "E:","F:".

.PARAMETER SkipCopy
    Drives the backup is not copied to, e.g. -SkipCopy "D:".

.PARAMETER CopyTo
    Extra folders the backup is copied to, e.g. -CopyTo "G:\My Drive\Backup".
    They are added to the automatic copies (use -NoCopy to only copy to them).

.PARAMETER InstallTask
    Register a scheduled task that runs the backup with the configuration file
    and the other options given on the command line, then exit.
    Running it again replaces the task.

.PARAMETER UninstallTask
    Remove the scheduled task, then exit.

.PARAMETER TaskDay
    Day of the week the scheduled task runs (default: Sunday).

.PARAMETER TaskTime
    Time the scheduled task runs (default: 23:12).

.PARAMETER ConfigPath
    Configuration file (default: Wizzz.config.json next to this script).
    It overrides the default configuration Wizzz.config.default.json.

.PARAMETER Configure
    Edit the configuration file interactively, then exit.

.EXAMPLE
    .\Wizzz_backup.ps1 -Configure
    Sets up the backup and offers to install the scheduled task.

.EXAMPLE
    .\Wizzz_backup.ps1 -Silent
    Makes a backup without any prompt.

.EXAMPLE
    .\Wizzz_backup.ps1 -InstallTask -TaskDay Friday -TaskTime 02:00 -SkipScan "E:" -CopyTo "G:\My Drive\Backup"
    Runs the backup every Friday at 02:00, without scanning E: and with a copy in Google Drive.

.LINK
    https://github.com/Ghorbel37/Wizzz
#>
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

#region Settings

# Free space needed on the backup drive before exporting
$MinFreeSpace = 1GB

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

# Default configuration shipped with the script, it overrides the default settings above.
# The configuration file (-ConfigPath) only contains the local changes and overrides it.
$DefaultConfigPath = Join-Path $PSScriptRoot "Wizzz.config.default.json"

$WeekDays = "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"

#endregion

#region Lists and drive letters

# Split comma separated values and remove empty entries
function Split-List([string[]]$Values) {
    $Values | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Get the drive letters, accepting "E", "E:" or "E:\"
function Get-DriveLetter([string[]]$Values) {
    Split-List $Values | ForEach-Object { $_.Substring(0, 1).ToUpper() }
}

# Get the drives as a list of unique "E:" values, ignoring invalid ones
function ConvertTo-DriveList([string[]]$Values) {
    , @(Get-DriveLetter $Values | Where-Object { $_ -match "^[A-Z]$" } | ForEach-Object { "$($_):" } | Select-Object -Unique)
}

# Format a list for display
function Format-ItemList($Items) {
    if (@($Items).Count) { @($Items) -join ", " } else { "(none)" }
}

#endregion

#region Console

function Show-Header {
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
function Wait-KeyPress([string]$Message = "Press any key to continue...") {
    if (-not $Silent) {
        Write-Host $Message
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# Ask a yes/no question, Enter means yes
function Confirm-Choice([string]$Question) {
    $answer = Read-Host "$Question (Y/n)"
    return (-not $answer -or $answer -eq "Y")
}

# Stop the transcript and exit the script with the given exit code
function Exit-Script([int]$ExitCode = 0) {
    try { $null = Stop-Transcript } catch { Write-Verbose "No transcript to stop" }
    Wait-KeyPress "Press any key to exit..."
    exit $ExitCode
}

#endregion

#region Event log

# Write an entry to the Windows Application event log, under the "Wizzz" source
# Event IDs: 1 = backup succeeded, 2 = backup completed with errors, 3 = backup failed
function Write-BackupEvent([string]$EntryType, [int]$EventId, [string]$Message) {
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
function Exit-BackupWithError([string]$Message) {
    Write-Error $Message
    Write-BackupEvent -EntryType "Error" -EventId 3 -Message "Backup failed: $Message`nLog: $LogPath"
    Exit-Script 1
}

#endregion

#region Administrator privileges

function Test-Administrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Build the command line arguments for the given parameters, except the excluded ones
function Get-ForwardedArgument($Parameters, [string[]]$Exclude = @()) {
    foreach ($parameter in $Parameters.GetEnumerator()) {
        if ($parameter.Key -in $Exclude) {
            continue
        }
        if ($parameter.Value -is [switch]) {
            if ($parameter.Value) { "-$($parameter.Key)" }
        }
        else {
            # Lists are passed as a single comma separated value
            $value = @($parameter.Value) -join ","
            # A trailing backslash would escape the closing quote, double it
            if ($value.EndsWith("\")) { $value += "\" }
            "-$($parameter.Key) `"$value`""
        }
    }
}

# Start this script again as administrator with the same parameters
function Invoke-AsAdministrator($Parameters) {
    Write-Host "This script needs to run as an administrator"
    Write-Host "It will restart itself with administrator privileges."
    Wait-KeyPress
    $forwardedArguments = Get-ForwardedArgument $Parameters
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $forwardedArguments" -Verb RunAs
}

#endregion

#region Configuration

# Read a configuration file, returns the settings it contains
function Read-ConfigFile([string]$Path) {
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

# Get the settings: the defaults, then the default configuration, the configuration file and the command line
# The default configuration replaces the values in $DefaultSettings, so -Configure compares with it.
function Get-Configuration($Parameters) {
    try {
        if ($ConfigPath -ne $DefaultConfigPath) {
            $defaultConfig = Read-ConfigFile $DefaultConfigPath
            foreach ($key in $defaultConfig.Keys) { $DefaultSettings[$key] = $defaultConfig[$key] }
        }
        $config = Read-ConfigFile $ConfigPath
    }
    catch {
        Write-Error "Could not read the configuration file $_"
        Exit-Script 1
    }

    $settings = [ordered]@{}
    foreach ($key in $DefaultSettings.Keys) {
        if ($Parameters.ContainsKey($key)) {
            $settings[$key] = $Parameters[$key]
        }
        elseif ($config.Contains($key)) {
            $settings[$key] = $config[$key]
        }
        else {
            $settings[$key] = $DefaultSettings[$key]
        }
    }
    if ($config.Count) {
        Write-Host "Using configuration file $ConfigPath`n"
    }
    return $settings
}

# Save the settings that are different from the defaults to the configuration file, returns $true on success
# The other settings are left out, so new default values (e.g. exclusions) are used for them.
function Save-Configuration($Edited) {
    $toSave = [ordered]@{}
    foreach ($key in $Edited.Keys) {
        if ((ConvertTo-Json -InputObject $Edited[$key] -Compress) -ne (ConvertTo-Json -InputObject $DefaultSettings[$key] -Compress)) {
            $toSave[$key] = $Edited[$key]
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
    return $true
}

#endregion

#region Interactive configuration (-Configure)

# Edit a list interactively, returns the new list
function Edit-ItemList([string]$Title, [string[]]$Items, [string[]]$Defaults) {
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
        switch (Read-Host "$prompt, Enter = done") {
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
function Read-DriveList([string]$Title, [string[]]$Current, $AvailableDrives) {
    Write-Host "`nAvailable drives:" -ForegroundColor Cyan
    foreach ($drive in $AvailableDrives) {
        Write-Host ("  {0}  {1,-20} {2,6} GB" -f $drive.DeviceID, $drive.VolumeName, [int]($drive.Size / 1GB))
    }
    $value = Read-Host "$Title, separated by commas, - for none [$(Format-ItemList $Current)]"
    if (-not $value) {
        return , @($Current)
    }
    if ($value.Trim() -eq "-") {
        return , @()
    }
    return , (ConvertTo-DriveList $value)
}

# Show a warning and leave time to read it before the menu is shown again
function Write-MenuWarning([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

# Ask for the backup folder, returns the new value
function Read-BackupFolder([string]$Current) {
    $value = Read-Host "Backup folder, full path [$Current]"
    if (-not $value) {
        return $Current
    }
    if ($value -notmatch "^[A-Za-z]:\\") {
        Write-MenuWarning "Use a full path such as C:\Backup"
        return $Current
    }
    return $value.Trim()
}

# Ask for the path of WizTree.exe, returns the new value ("" means automatic)
function Read-WizTreePath([string]$Current, [string]$CurrentDisplay) {
    $value = Read-Host "Full path of WizTree.exe, - for automatic [$CurrentDisplay]"
    if ($value -eq "-") {
        return ""
    }
    if (-not $value) {
        return $Current
    }
    if (-not (Test-Path $value -PathType Leaf)) {
        Write-MenuWarning "Warning: $value does not exist"
    }
    return $value.Trim()
}

# Ask for the day and time of the scheduled task, updates the edited settings
function Read-Schedule($Edited) {
    $day = Read-Host "Day of the week [$($Edited.TaskDay)]"
    if ($day) {
        $matchingDay = $WeekDays | Where-Object { $_ -like "$($day.Trim())*" } | Select-Object -First 1
        if ($matchingDay) { $Edited.TaskDay = $matchingDay } else { Write-MenuWarning "Invalid day." }
    }
    $time = Read-Host "Time, e.g. 23:12 [$($Edited.TaskTime)]"
    if ($time) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($time.Trim(), "H:mm", [System.Globalization.CultureInfo]::InvariantCulture, "None", [ref]$parsed)) {
            $Edited.TaskTime = $parsed.ToString("HH:mm")
        }
        else {
            Write-MenuWarning "Invalid time."
        }
    }
}

function Show-ConfigurationMenu($Edited) {
    Clear-Host
    Write-Host "Wizzz configuration" -ForegroundColor Cyan
    Write-Host "$ConfigPath`n"
    $copyDisplay = if ($Edited.NoCopy) { "No" } else { "Yes" }
    $zipDisplay = if ($Edited.ForceZip) { "Built-in Zip" } else { "7-Zip when installed" }
    Write-Host "  1. Backup folder          $($Edited.BackupRoot)"
    Write-Host "  2. WizTree path           $(Get-WizTreePathDisplay $Edited.WizTreePath)"
    Write-Host "  3. Copy to other drives   $copyDisplay"
    Write-Host "  4. Compression            $zipDisplay"
    Write-Host "  5. Skip scanning          $(Format-ItemList $Edited.SkipScan)"
    Write-Host "  6. Skip copying           $(Format-ItemList $Edited.SkipCopy)"
    Write-Host "  7. Extra copy folders     $(Format-ItemList $Edited.CopyTo)"
    Write-Host "  8. Exclusions             $(@($Edited.Exclusions).Count) folders"
    Write-Host "  9. Schedule               every $($Edited.TaskDay) at $($Edited.TaskTime)"
    Write-Host ""
    Write-Host "  S. Save and exit"
    Write-Host "  Q. Quit without saving"
    Write-Host ""
}

function Get-WizTreePathDisplay([string]$Path) {
    if ($Path) { $Path } else { "(automatic)" }
}

# Install the scheduled task after saving, or update it when the schedule changed, returns $true on success
function Confirm-BackupTask($Edited, $Settings) {
    $taskExists = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    $scheduleChanged = $Edited.TaskDay -ne $Settings.TaskDay -or $Edited.TaskTime -ne $Settings.TaskTime
    if (-not $taskExists) {
        $question = "Install the scheduled task to run the backup every $($Edited.TaskDay) at $($Edited.TaskTime)?"
    }
    elseif ($scheduleChanged) {
        $question = "Update the scheduled task to run every $($Edited.TaskDay) at $($Edited.TaskTime)?"
    }
    else {
        return $true
    }
    if (Confirm-Choice $question) {
        return (Install-BackupTask -Day $Edited.TaskDay -Time $Edited.TaskTime -Root $Edited.BackupRoot)
    }
    return $true
}

# Edit the configuration interactively and save it to the configuration file, returns $true on success
function Edit-Configuration($Settings) {
    # Work on a copy, normalizing the values that can come from the command line
    $edited = [ordered]@{}
    foreach ($key in $Settings.Keys) { $edited[$key] = $Settings[$key] }
    $edited.NoCopy = [bool]$edited.NoCopy
    $edited.ForceZip = [bool]$edited.ForceZip
    $edited.SkipScan = ConvertTo-DriveList $edited.SkipScan
    $edited.SkipCopy = ConvertTo-DriveList $edited.SkipCopy
    $edited.CopyTo = @(Split-List $edited.CopyTo)
    $edited.Exclusions = @($edited.Exclusions)
    $availableDrives = Get-LocalDrive -Quiet

    while ($true) {
        Show-ConfigurationMenu $edited
        switch (Read-Host "Choice") {
            "1" { $edited.BackupRoot = Read-BackupFolder $edited.BackupRoot }
            "2" { $edited.WizTreePath = Read-WizTreePath $edited.WizTreePath (Get-WizTreePathDisplay $edited.WizTreePath) }
            "3" { $edited.NoCopy = -not $edited.NoCopy }
            "4" { $edited.ForceZip = -not $edited.ForceZip }
            "5" { $edited.SkipScan = Read-DriveList -Title "Drives not to scan" -Current $edited.SkipScan -AvailableDrives $availableDrives }
            "6" { $edited.SkipCopy = Read-DriveList -Title "Drives not to copy the backup to" -Current $edited.SkipCopy -AvailableDrives $availableDrives }
            "7" { $edited.CopyTo = Edit-ItemList -Title "Extra folders the backup is copied to, e.g. G:\My Drive\Backup" -Items $edited.CopyTo }
            "8" { $edited.Exclusions = Edit-ItemList -Title "Excluded folders (* is a wildcard, folders end with \)" -Items $edited.Exclusions -Defaults $DefaultSettings.Exclusions }
            "9" { Read-Schedule $edited }
            "S" {
                if (-not (Save-Configuration $edited)) {
                    return $false
                }
                return (Confirm-BackupTask -Edited $edited -Settings $Settings)
            }
            "Q" { return $true }
        }
    }
}

#endregion

#region Scheduled task

# Register the scheduled task, returns $true on success
# The task runs this script silently with the configuration file and the given extra arguments.
# The configuration file is read on each run, so it can be changed later without reinstalling the task.
function Install-BackupTask([string]$Day, [string]$Time, [string]$Root, [string]$ExtraArguments) {
    $taskCommand = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent -ConfigPath `"$ConfigPath`" $ExtraArguments".TrimEnd()
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskCommand
        $trigger = New-ScheduledTaskTrigger -Weekly -At $Time -DaysOfWeek $Day -ErrorAction Stop

        # Run as the current user whether they are logged on or not, without storing a password (S4U)
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest

        # Run as soon as possible if the computer was off at the scheduled time, and also on battery
        $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        # Register the task, replacing it if it already exists
        $null = Register-ScheduledTask -TaskName $TaskName -Description "Takes a copy of filesystem structure using WizTree and saves it in $Root" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to register the scheduled task: $_"
        return $false
    }
    Write-Host "Scheduled task '$TaskName' registered: every $Day at $Time"
    Write-Host "Command: powershell.exe $taskCommand"
    return $true
}

function Uninstall-BackupTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed."
    }
    else {
        Write-Host "Scheduled task '$TaskName' does not exist."
    }
}

#endregion

#region Tools

# Find WizTree.exe, stops the backup with instructions when it is not found
function Find-WizTree([string]$Path) {
    if ($Path) {
        $candidates = @($Path)
    }
    else {
        $candidates = @(
            (Join-Path $PSScriptRoot "WizTree.exe"),
            (Join-Path $PSScriptRoot "WizTree64.exe"),
            (Join-Path $env:ProgramFiles "WizTree\WizTree.exe"),
            (Join-Path $env:ProgramFiles "WizTree\WizTree64.exe")
        )
    }
    $found = $candidates | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
    if ($found) {
        return $found
    }

    $message = "WizTree not found. Searched:`n$(($candidates | ForEach-Object { "  $_" }) -join "`n")`n"
    $message += "Download and install WizTree from https://diskanalyzer.com/download or place this script in the WizTree folder.`n"
    if ($Path) {
        $message += "Check the WizTree path given with -WizTreePath or in the configuration (-Configure), or remove it to find WizTree automatically."
    }
    else {
        $message += "If WizTree is somewhere else, give the full path of WizTree.exe with -WizTreePath or in the configuration (-Configure)."
    }
    Exit-BackupWithError $message
}

# Find 7z.exe, using its registry entry, the usual install folders or the PATH, returns $null when not found
function Find-SevenZip {
    $candidates = @(
        (Get-ItemProperty -Path "HKLM:\SOFTWARE\7-Zip" -Name Path -ErrorAction SilentlyContinue).Path,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ } | ForEach-Object { Join-Path $_ "7z.exe"; Join-Path $_ "7-Zip\7z.exe" }
    $candidates += (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
    $candidates | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
}

# Choose the compression and show it, returns the path of 7z.exe, or $null to use the built-in Zip
function Select-Compression([bool]$ForceZip) {
    if ($ForceZip) {
        Write-Host "Using the built-in Zip compression (-ForceZip)`n"
        return $null
    }
    $sevenZipPath = Find-SevenZip
    if ($sevenZipPath) {
        Write-Host "Using 7-Zip: $sevenZipPath`n"
        return $sevenZipPath
    }
    Write-Warning "7-Zip is not installed, the built-in Zip compression is used. Install 7-Zip from https://www.7-zip.org/ for archives about half the size."
    Write-Host ""
    return $null
}

#endregion

#region Drives

# Get local fixed drives only (DriveType 3), skipping optical, removable and network drives
function Get-LocalDrive([switch]$Quiet) {
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

# Get the free space in bytes of the drive of a path, or $null if it cannot be read
function Get-FreeSpace([string]$Path) {
    try {
        ([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
    }
    catch {
        $null
    }
}

# Warn about skipped drives that are not in the list, probably a typo
function Write-UnknownDriveWarning($Drives, [string[]]$Letters) {
    $driveLetters = $Drives | ForEach-Object { $_.DeviceID.Substring(0, 1) }
    foreach ($letter in ($Letters | Select-Object -Unique)) {
        if ($letter -notin $driveLetters) {
            Write-Warning "Drive $($letter): is skipped but is not one of the drives to back up"
        }
    }
}

# Get the folders the backup is copied to: the backup folder on the other drives, then the -CopyTo folders
function Get-CopyTarget($Drives, [string]$Root, [bool]$NoCopy, [string[]]$SkipCopy, [string[]]$CopyTo) {
    $backupDriveLetter = [System.IO.Path]::GetPathRoot($Root).Substring(0, 1)
    $targets = @()
    if (-not $NoCopy) {
        foreach ($drive in $Drives) {
            $letter = $drive.DeviceID.Substring(0, 1)
            if ($letter -ne $backupDriveLetter -and $letter -notin $SkipCopy) {
                $targets += Join-Path $drive.DeviceID (Split-Path $Root -NoQualifier)
            }
        }
    }
    $targets += $CopyTo | Where-Object { $_.TrimEnd("\") -ne $Root.TrimEnd("\") }
    # Remove duplicates, ignoring case and trailing backslashes
    , @($targets | Group-Object { $_.TrimEnd("\") } | ForEach-Object { $_.Group[0] })
}

# Show the drives, what is scanned and where the backup is copied
function Show-BackupPlan($Drives, [string]$Root, [string[]]$SkipScan, [string[]]$CopyTargets) {
    $backupDriveLetter = [System.IO.Path]::GetPathRoot($Root).Substring(0, 1)
    Write-Host "Drives:"
    $Drives | Select-Object @{ Name = "Drive"; Expression = { $_.DeviceID } },
        @{ Name = "Name"; Expression = { $_.VolumeName } },
        @{ Name = "Size (GB)"; Expression = { [int]($_.Size / 1GB) } },
        @{ Name = "Free (GB)"; Expression = { [int]($_.FreeSpace / 1GB) } },
        @{ Name = "Scan"; Expression = { if ($_.DeviceID.Substring(0, 1) -in $SkipScan) { "No" } else { "Yes" } } },
        @{ Name = "Copy"; Expression = {
                $deviceId = $_.DeviceID
                if ($deviceId.Substring(0, 1) -eq $backupDriveLetter) { "Backup folder" }
                elseif ($CopyTargets | Where-Object { $_.StartsWith($deviceId, [System.StringComparison]::OrdinalIgnoreCase) }) { "Yes" }
                else { "No" }
            }
        } | Format-Table -AutoSize | Out-Host

    Write-Host "Backup folder: $Root"
    if ($CopyTargets) {
        Write-Host "Copies:"
        $CopyTargets | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host "Copies: none"
    }
    Write-Host ""
}

#endregion

#region Backup steps

# Build the WizTree exclusion filter, separated with pipe "|"
# The whole filter is double quoted and each pattern is quoted with single quotes, which WizTree
# reads as double quotes. Double quotes around each pattern do not work, the backslash before
# the closing quote of a folder escapes it and the filter is ignored.
# A single quote inside a pattern is written as two single quotes.
# Folders get a trailing * so their content is excluded too: when scanning a whole drive,
# WizTree does not always exclude the subfolders of a folder that only ends with a backslash.
function Get-ExclusionFilter([string[]]$Patterns) {
    $quoted = $Patterns | ForEach-Object {
        $pattern = [Environment]::ExpandEnvironmentVariables($_)
        if ($pattern.EndsWith("\")) { $pattern += "*" }
        "'" + $pattern.Replace("'", "''") + "'"
    }
    "`"$($quoted -join "|")`""
}

# Export the filesystem tree of a drive to a CSV file with WizTree, returns $true on success
function Export-Drive($Drive, [string]$WizTreeExePath, [string]$Destination, [string[]]$Exclusions) {
    $driveName = $Drive.DeviceID
    $csvName = $driveName[0] + "_%d_%t.csv"
    Write-Host "Saving backup for $driveName"
    $wizTree = Start-Process -FilePath $WizTreeExePath -ArgumentList "$driveName /export=""$Destination\$csvName"" /admin=1 /filterexclude=$(Get-ExclusionFilter $Exclusions)" -Wait -PassThru

    # Make sure WizTree exported a CSV for this drive
    if (-not (Get-ChildItem -Path $Destination -Filter ($driveName[0] + "_*.csv") -ErrorAction SilentlyContinue)) {
        Write-Warning "WizTree failed to export $driveName (exit code $($wizTree.ExitCode))"
        return $false
    }
    return $true
}

# Compress the exported CSV files into an archive, returns the archive path, or $null if it failed
function Compress-Backup([string]$Source, [string]$ArchiveBasePath, [string]$SevenZipPath) {
    if ($SevenZipPath) {
        Write-Host "Compressing using 7-Zip"
        $archivePath = "$ArchiveBasePath.7z"
        # PPMd compresses the CSV text about 30% smaller than the default LZMA2 and faster.
        # Order 10 with 256 MB of memory gave the smallest archives, extracting needs the same memory.
        # Pipe through Out-Host so the 7-Zip output also goes to the log
        & $SevenZipPath a -t7z $archivePath "$Source\*.csv" -m0=PPMd:o=10:mem=256m | Out-Host
        # 7-Zip exit codes: 0 = success, 1 = warning, 2 and above = error
        $failed = $LASTEXITCODE -ge 2
    }
    else {
        Write-Host "Compressing using built-in Zip"
        $archivePath = "$ArchiveBasePath.zip"
        try {
            Compress-Archive -Path "$Source\*.csv" -DestinationPath $archivePath -CompressionLevel "Optimal" -Force -ErrorAction Stop
            $failed = $false
        }
        catch {
            Write-Warning $_
            $failed = $true
        }
    }
    if ($failed -or -not (Test-Path $archivePath -PathType Leaf)) {
        return $null
    }
    return $archivePath
}

# Copy the archive to each target folder
# Returns the copied files, the targets on drives that are not connected and the failures
function Copy-Backup([string]$ArchivePath, [string[]]$Targets) {
    $result = [pscustomobject]@{ CopiedTo = @(); NotConnected = @(); Failures = @() }
    $archiveName = Split-Path $ArchivePath -Leaf
    $archiveSize = (Get-Item $ArchivePath).Length

    foreach ($target in $Targets) {
        # Skip targets on a drive that is not connected, e.g. an unplugged external drive
        $targetRoot = [System.IO.Path]::GetPathRoot($target)
        if (-not (Test-Path $targetRoot)) {
            Write-Host "Skipping $($target): drive $targetRoot is not connected"
            $result.NotConnected += $target
            continue
        }

        # Make sure the archive fits on the target drive
        $freeSpace = Get-FreeSpace $target
        if ($null -ne $freeSpace -and $freeSpace -lt $archiveSize) {
            Write-Warning "Not enough free space to copy backup to $target ($([math]::Round($freeSpace / 1MB)) MB free, $([math]::Round($archiveSize / 1MB)) MB needed)"
            $result.Failures += "Copy to $target (not enough free space)"
            continue
        }

        Write-Host "Copying backup to $target"
        try {
            if (-not (Test-Path $target -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop
            }
            $destination = Join-Path $target $archiveName
            Copy-Item -Path $ArchivePath -Destination $destination -Force -ErrorAction Stop
            $result.CopiedTo += $destination
        }
        catch {
            Write-Warning "Failed to copy backup to $($target): $_"
            $result.Failures += "Copy to $target"
        }
    }

    if ($Targets) {
        Write-Host "Copying done.`n"
    }
    else {
        Write-Host "No copies to make.`n"
    }
    return $result
}

# Delete the folder of the exported CSV files, after confirmation unless running silently
function Clear-ExportFolder([string]$Path) {
    Write-Host "Cleaning temp CSV folder"
    if ($Silent -or (Confirm-Choice "Do you want to clean temporary backup files?")) {
        Remove-Item -Path $Path -Recurse -Force
        Write-Host "Cleaning temp CSV folder completed.`n"
    }
    else {
        Write-Host "Cleanup cancelled.`n"
    }
}

# Show the result of the backup and write it to the event log
function Write-BackupResult([string]$ArchivePath, $CopyResult, [string[]]$Failures) {
    if ($Failures) {
        Write-Warning "Backup completed with errors:"
        $Failures | ForEach-Object { Write-Warning " - $_" }
        Write-BackupEvent -EntryType "Warning" -EventId 2 -Message "Backup completed with errors:`n$($Failures -join "`n")`n`nArchive: $ArchivePath`nLog: $LogPath"
    }
    else {
        Write-Host "Backup completed successfully."
        Write-BackupEvent -EntryType "Information" -EventId 1 -Message "Backup completed successfully.`n`nArchive: $ArchivePath`nLog: $LogPath"
    }
    Write-Host "Saved file to: $ArchivePath"
    if ($CopyResult.CopiedTo) {
        Write-Host "Copied to: $($CopyResult.CopiedTo -join ', ')"
    }
    if ($CopyResult.NotConnected) {
        Write-Host "Not copied, drive not connected: $($CopyResult.NotConnected -join ', ')"
    }
    Write-Host ""
}

#endregion

#region Main

Show-Header

# Use the full path of the configuration file, the elevated instance and the task start in another folder
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
if ($PSBoundParameters.ContainsKey("ConfigPath")) {
    $PSBoundParameters["ConfigPath"] = $ConfigPath
}

if (-not (Test-Administrator)) {
    Invoke-AsAdministrator $PSBoundParameters
    exit
}

# Load the settings
$Settings = Get-Configuration $PSBoundParameters
$BackupRoot = $Settings.BackupRoot
$NoCopy = [bool]$Settings.NoCopy
$ForceZip = [bool]$Settings.ForceZip
$SkipScan = @(Get-DriveLetter $Settings.SkipScan)
$SkipCopy = @(Get-DriveLetter $Settings.SkipCopy)
$CopyTo = @(Split-List $Settings.CopyTo)
$Exclusions = @($Settings.Exclusions)
$TaskDay = $Settings.TaskDay
$TaskTime = $Settings.TaskTime
if ($TaskDay -notin $WeekDays) {
    Write-Error "Invalid TaskDay '$TaskDay', use one of: $($WeekDays -join ', ')"
    Exit-Script 1
}

# Commands that do something else than a backup, then exit
if ($Configure) {
    if ($Silent) {
        Write-Host "-Configure cannot be used with -Silent."
        Exit-Script 1
    }
    Exit-Script ([int](-not (Edit-Configuration $Settings)))
}
if ($InstallTask -and $UninstallTask) {
    Write-Host "Use either -InstallTask or -UninstallTask, not both."
    Exit-Script 1
}
if ($UninstallTask) {
    Uninstall-BackupTask
    Exit-Script
}
if ($InstallTask) {
    # Pass the options given on the command line, except the task options
    $taskArguments = Get-ForwardedArgument $PSBoundParameters -Exclude "InstallTask", "UninstallTask", "TaskDay", "TaskTime", "Silent", "ConfigPath", "Configure"
    Exit-Script ([int](-not (Install-BackupTask -Day $TaskDay -Time $TaskTime -Root $BackupRoot -ExtraArguments "$taskArguments")))
}

# Each backup gets its own folder for the exported CSV files, and its own log
$BackupName = Get-Date -Format "yyyyMMdd_HHmmss"
$ExportFolder = Join-Path $BackupRoot $BackupName
$LogFolder = Join-Path $BackupRoot "Logs"
$LogPath = Join-Path $LogFolder "Wizzz_$BackupName.log"
$null = New-Item -ItemType Directory -Path $LogFolder -Force
$null = Start-Transcript -Path $LogPath
Write-Host "Logging to $LogPath`n"

# Find the tools
$WizTreeExePath = Find-WizTree $Settings.WizTreePath
Write-Host "Using WizTree: $WizTreeExePath"
$SevenZipPath = Select-Compression $ForceZip

# Show what will be backed up and where, and ask for confirmation
$drives = Get-LocalDrive
Write-UnknownDriveWarning $drives ($SkipScan + $SkipCopy)
$scanDrives = $drives | Where-Object { $_.DeviceID.Substring(0, 1) -notin $SkipScan }
$copyTargets = Get-CopyTarget -Drives $drives -Root $BackupRoot -NoCopy $NoCopy -SkipCopy $SkipCopy -CopyTo $CopyTo
Show-BackupPlan -Drives $drives -Root $BackupRoot -SkipScan $SkipScan -CopyTargets $copyTargets
if (-not $Silent -and -not (Confirm-Choice "Do you want to proceed with the backup?")) {
    Write-Host "Backup aborted."
    Exit-Script
}

# Make sure there is room for the exported CSV files
$backupFreeSpace = Get-FreeSpace $BackupRoot
if ($null -ne $backupFreeSpace -and $backupFreeSpace -lt $MinFreeSpace) {
    Exit-BackupWithError "Not enough free space in $BackupRoot ($([math]::Round($backupFreeSpace / 1GB, 2)) GB free, $($MinFreeSpace / 1GB) GB needed)"
}

Write-Host "`nCreating temporary backup folder"
$null = New-Item -ItemType Directory -Path $ExportFolder -Force
Write-Host "Done.`n"

# Export each drive, the failures are reported at the end
$failures = @()
foreach ($drive in $scanDrives) {
    if (-not (Export-Drive -Drive $drive -WizTreeExePath $WizTreeExePath -Destination $ExportFolder -Exclusions $Exclusions)) {
        $failures += "Export of $($drive.DeviceID)"
    }
}
if (-not (Get-ChildItem -Path $ExportFolder -Filter "*.csv")) {
    Exit-BackupWithError "No drive was exported."
}
Write-Host "Backup complete`n"

$archivePath = Compress-Backup -Source $ExportFolder -ArchiveBasePath (Join-Path $BackupRoot "Backup_$BackupName") -SevenZipPath $SevenZipPath
if (-not $archivePath) {
    Exit-BackupWithError "Compression failed. The exported CSV files were kept in $ExportFolder"
}
Write-Host "Compression done.`n"

$copyResult = Copy-Backup -ArchivePath $archivePath -Targets $copyTargets
$failures += $copyResult.Failures

Clear-ExportFolder $ExportFolder

Write-BackupResult -ArchivePath $archivePath -CopyResult $copyResult -Failures $failures
Exit-Script ([int][bool]$failures)

#endregion
