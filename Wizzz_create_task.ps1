# Define the script path
$scriptPath = "$PSScriptRoot\Wizzz_Backup.ps1"
$taskName = "Wiztree Filesystem Backup"
$taskDescription = "Takes a copy of filesystem structure and saves it in zip files in *:\Backup\"
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

# Define the action to be performed by the task (run PowerShell)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -silent"

# Define the trigger (e.g., run daily at 2:00 AM)
$currentDateTime = Get-Date

# Define the trigger (weekly starting from January 1, 1999, 00:00)
$trigger = New-ScheduledTaskTrigger -Weekly -At "23:12" -DaysOfWeek Sunday

# Register the scheduled task with the action and trigger
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskName -Description $taskDescription -RunLevel Highest -User $user