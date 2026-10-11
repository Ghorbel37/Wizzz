# Check if the script is running with elevated privileges, registering a task with highest privileges requires it
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Output "This script needs to run from an elevated PowerShell prompt."
    exit 1
}

# Define the script path
$scriptPath = "$PSScriptRoot\Wizzz_backup.ps1"
$taskName = "Wiztree Filesystem Backup"
$taskDescription = "Takes a copy of filesystem structure and saves it in zip files in *:\Backup\"
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Define the action to be performed by the task (run PowerShell)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Silent"

# Define the trigger (every Sunday at 23:12)
$trigger = New-ScheduledTaskTrigger -Weekly -At "23:12" -DaysOfWeek Sunday

# Run as the current user whether they are logged on or not, without storing a password (S4U)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest

# Run as soon as possible if the computer was off at the scheduled time, and also on battery
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# Register the scheduled task, replacing it if it already exists
Register-ScheduledTask -TaskName $taskName -Description $taskDescription -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
