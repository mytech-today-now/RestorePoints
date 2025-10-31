<#
.SYNOPSIS
    Manages Windows System Restore Points with automated creation, monitoring, and notification.

.DESCRIPTION
    This script provides comprehensive management of Windows System Restore Points including:
    - Configuring System Restore settings (enable, disk space allocation)
    - Creating restore points on demand or on schedule
    - Maintaining a minimum number of restore points
    - Sending email notifications for restore point events
    - Logging all activities to a configurable log file
    - Error handling and fallback mechanisms

.PARAMETER Action
    The action to perform. Valid values: Configure, Create, List, Cleanup, Monitor

.PARAMETER ConfigPath
    Path to the configuration file. Defaults to .\config.json in the script directory.

.PARAMETER Description
    Description for the restore point when using -Action Create.

.PARAMETER Force
    Force the operation even if a restore point was recently created.

.EXAMPLE
    .\Manage-RestorePoints.ps1 -Action Configure
    Configures System Restore settings according to the configuration file.

.EXAMPLE
    .\Manage-RestorePoints.ps1 -Action Create -Description "Pre-Update Backup"
    Creates a new restore point with the specified description.

.EXAMPLE
    .\Manage-RestorePoints.ps1 -Action Monitor
    Monitors restore points and performs cleanup if needed.

.NOTES
    File Name      : Manage-RestorePoints.ps1
    Author         : PowerShell Scripts Project
    Prerequisite   : PowerShell 5.1 or later, Administrator privileges
    Copyright      : (c) 2025. All rights reserved.
    Version        : 1.2.0

.LINK
    https://github.com/mytech-today-now/PowerShellScripts
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Configure', 'Create', 'List', 'Cleanup', 'Monitor')]
    [string]$Action = 'Monitor',
    
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath,
    
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Description = "Automated Restore Point - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#Requires -Version 5.1
#Requires -RunAsAdministrator

# Script variables
$script:ScriptVersion = '1.2.0'
$script:ScriptPath = $PSScriptRoot
$script:DefaultConfigPath = Join-Path $script:ScriptPath 'config.json'
$script:Config = $null
$script:LogPath = $null
$script:ScheduledTaskName = "System Restore Point - Daily Monitoring"
$script:ScheduledTaskPath = "\myTech.Today\"
$script:CentralLogPath = "C:\mytech.today\logs\"

#region Helper Functions

function ConvertTo-DateTime {
    <#
    .SYNOPSIS
        Converts a value to DateTime, handling various input types including WMI datetime format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    if ($Value -is [DateTime]) {
        return $Value
    }
    elseif ($Value -is [string]) {
        # Check if it's a WMI datetime format (e.g., "20251029133027.347135-000")
        if ($Value -match '^\d{14}\.\d+[\+\-]\d{3}$') {
            try {
                # WMI datetime format: yyyyMMddHHmmss.ffffff+/-zzz
                # Extract the datetime part (first 14 characters)
                $year = $Value.Substring(0, 4)
                $month = $Value.Substring(4, 2)
                $day = $Value.Substring(6, 2)
                $hour = $Value.Substring(8, 2)
                $minute = $Value.Substring(10, 2)
                $second = $Value.Substring(12, 2)

                return [DateTime]::ParseExact(
                    "$year-$month-$day $hour`:$minute`:$second",
                    "yyyy-MM-dd HH:mm:ss",
                    $null
                )
            }
            catch {
                Write-Verbose "Failed to parse WMI date string: $Value - $_"
            }
        }

        # Try standard date parsing
        try {
            return [DateTime]::Parse($Value)
        }
        catch {
            Write-Verbose "Failed to parse date string: $Value"
            return $null
        }
    }
    else {
        # Try to convert to DateTime
        try {
            return [DateTime]$Value
        }
        catch {
            Write-Verbose "Failed to convert to DateTime: $Value"
            return $null
        }
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to the log file and console in markdown format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

        # Create markdown-formatted log entry
        $icon = switch ($Level) {
            'INFO'    { 'ℹ️' }
            'WARNING' { '⚠️' }
            'ERROR'   { '❌' }
            'SUCCESS' { '✅' }
        }

        $logEntry = "| $timestamp | $icon **$Level** | $Message |"

        # Write to log file in markdown table format
        if ($script:LogPath -and (Test-Path $script:LogPath)) {
            Add-Content -Path $script:LogPath -Value $logEntry -ErrorAction SilentlyContinue
        }

        # Write to console
        switch ($Level) {
            'INFO'    {
                Write-Verbose $Message
                # Also write INFO to console for better user feedback
                Write-Host "INFO: $Message" -ForegroundColor Cyan
            }
            'WARNING' { Write-Warning $Message }
            'ERROR'   { Write-Error $Message }
            'SUCCESS' { Write-Host "SUCCESS: $Message" -ForegroundColor Green }
        }
    }
    catch {
        Write-Warning "Failed to write log: $_"
    }
}

function Get-Configuration {
    <#
    .SYNOPSIS
        Loads the configuration file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    try {
        if (-not $Path) {
            $Path = $script:DefaultConfigPath
        }
        
        if (-not (Test-Path $Path)) {
            Write-Log "Configuration file not found at $Path. Creating default configuration." -Level WARNING
            $config = New-DefaultConfiguration
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
            Write-Log "Default configuration created at $Path" -Level SUCCESS
        }
        else {
            $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
            Write-Log "Configuration loaded from $Path" -Level INFO
        }
        
        return $config
    }
    catch {
        Write-Log "Failed to load configuration: $_" -Level ERROR
        throw
    }
}

function New-DefaultConfiguration {
    <#
    .SYNOPSIS
        Creates a default configuration object.
    #>
    [CmdletBinding()]
    param()
    
    return [PSCustomObject]@{
        RestorePoint = [PSCustomObject]@{
            DiskSpacePercent = 10
            MinimumCount = 10
            MaximumCount = 30
            CreateOnSchedule = $true
            ScheduleIntervalMinutes = 1440  # Daily
        }
        Email = [PSCustomObject]@{
            Enabled = $false
            SmtpServer = 'smtp.example.com'
            SmtpPort = 587
            UseSsl = $true
            From = 'restorepoint@example.com'
            To = @('admin@example.com')
            Username = ''
            PasswordEncrypted = ''
        }
        Logging = [PSCustomObject]@{
            LogPath = (Join-Path $script:ScriptPath 'Logs\RestorePoint.log')
            MaxLogSizeMB = 10
            RetentionDays = 30
        }
    }
}

function Send-EmailNotification {
    <#
    .SYNOPSIS
        Sends an email notification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,
        
        [Parameter(Mandatory = $true)]
        [string]$Body,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Create', 'Delete', 'Apply')]
        [string]$EventType
    )
    
    try {
        if (-not $script:Config.Email.Enabled) {
            Write-Log "Email notifications are disabled" -Level INFO
            return
        }
        
        $mailParams = @{
            SmtpServer = $script:Config.Email.SmtpServer
            Port = $script:Config.Email.SmtpPort
            UseSsl = $script:Config.Email.UseSsl
            From = $script:Config.Email.From
            To = $script:Config.Email.To
            Subject = $Subject
            Body = $Body
            BodyAsHtml = $true
        }
        
        # Add credentials if provided
        if ($script:Config.Email.Username -and $script:Config.Email.PasswordEncrypted) {
            $securePassword = ConvertTo-SecureString $script:Config.Email.PasswordEncrypted
            $credential = New-Object System.Management.Automation.PSCredential($script:Config.Email.Username, $securePassword)
            $mailParams.Credential = $credential
        }
        
        Send-MailMessage @mailParams -ErrorAction Stop
        Write-Log "Email notification sent: $Subject" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to send email notification: $_" -Level ERROR
    }
}

function Test-AdministratorPrivilege {
    <#
    .SYNOPSIS
        Checks if the script is running with administrator privileges.
    #>
    [CmdletBinding()]
    param()
    
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-SystemRestore {
    <#
    .SYNOPSIS
        Enables System Restore on the system drive and configures disk space.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [int]$DiskSpacePercent = 10
    )
    
    try {
        $systemDrive = $env:SystemDrive
        Write-Log "Configuring System Restore for drive $systemDrive" -Level INFO
        
        # Enable System Restore
        if ($PSCmdlet.ShouldProcess($systemDrive, "Enable System Restore")) {
            Enable-ComputerRestore -Drive $systemDrive -ErrorAction Stop
            Write-Log "System Restore enabled on $systemDrive" -Level SUCCESS
        }
        
        # Configure disk space using VSSAdmin
        $diskSpacePercent = [Math]::Max(8, [Math]::Min(100, $DiskSpacePercent))
        
        if ($PSCmdlet.ShouldProcess($systemDrive, "Set disk space to $diskSpacePercent%")) {
            $vssOutput = vssadmin Resize ShadowStorage /For=$systemDrive /On=$systemDrive /MaxSize="${diskSpacePercent}%" 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Disk space configured to $diskSpacePercent% for System Restore" -Level SUCCESS
            }
            else {
                Write-Log "VSSAdmin output: $vssOutput" -Level WARNING
                Write-Log "Attempting alternative configuration method" -Level INFO
                
                # Alternative: Use WMI
                $wmi = Get-CimInstance -ClassName Win32_ShadowStorage -Filter "Volume='\\\\?\\$($systemDrive)\\'" -ErrorAction SilentlyContinue
                if ($wmi) {
                    $maxSpace = [Math]::Floor((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$systemDrive'").Size * ($diskSpacePercent / 100))
                    Set-CimInstance -InputObject $wmi -Property @{MaxSpace = $maxSpace} -ErrorAction Stop
                    Write-Log "Disk space configured using WMI" -Level SUCCESS
                }
            }
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to configure System Restore: $_" -Level ERROR
        return $false
    }
}

#endregion

#region Main Functions

function New-RestorePointScheduledTask {
    <#
    .SYNOPSIS
        Creates a Windows Scheduled Task to run restore point monitoring.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [int]$IntervalMinutes = 1440  # Default: 24 hours (1 day)
    )

    try {
        $taskName = $script:ScheduledTaskName
        $taskPath = $script:ScheduledTaskPath

        Write-Log "Creating scheduled task: $taskName" -Level INFO

        # Check if task already exists
        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Log "Scheduled task already exists. Removing old task..." -Level INFO
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        }

        # Define the action (run the script with Monitor action)
        $scriptPath = $PSCommandPath
        $configPath = if ($script:Config) { $ConfigPath } else { $script:DefaultConfigPath }
        $actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action Monitor -ConfigPath `"$configPath`""
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $actionArgs

        # Define the trigger (daily or custom interval)
        if ($IntervalMinutes -ge 1440) {
            # Daily trigger
            $trigger = New-ScheduledTaskTrigger -Daily -At "12:00AM"
        }
        else {
            # Repetition trigger
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
        }

        # Define settings
        $settings = New-ScheduledTaskSettings `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable:$false `
            -DontStopOnIdleEnd `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1)

        # Define principal (run as SYSTEM with highest privileges)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        # Register the task
        if ($PSCmdlet.ShouldProcess($taskName, "Register Scheduled Task")) {
            $null = Register-ScheduledTask `
                -TaskName $taskName `
                -TaskPath $taskPath `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Principal $principal `
                -Description "Monitors and maintains Windows System Restore Points. Creates restore points on schedule and performs cleanup." `
                -ErrorAction Stop

            Write-Log "Scheduled task created successfully: $taskPath$taskName" -Level SUCCESS
            Write-Log "Task will run every $([Math]::Round($IntervalMinutes / 60, 2)) hours" -Level INFO
            return $true
        }

        return $false
    }
    catch {
        Write-Log "Failed to create scheduled task: $_" -Level ERROR
        return $false
    }
}

function Remove-RestorePointScheduledTask {
    <#
    .SYNOPSIS
        Removes the Windows Scheduled Task for restore point monitoring.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    try {
        $taskName = $script:ScheduledTaskName
        $taskPath = $script:ScheduledTaskPath

        Write-Log "Checking for scheduled task: $taskName" -Level INFO

        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($existingTask) {
            if ($PSCmdlet.ShouldProcess($taskName, "Remove Scheduled Task")) {
                Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
                Write-Log "Scheduled task removed successfully" -Level SUCCESS
                return $true
            }
        }
        else {
            Write-Log "Scheduled task does not exist" -Level INFO
            return $false
        }

        return $false
    }
    catch {
        Write-Log "Failed to remove scheduled task: $_" -Level ERROR
        return $false
    }
}

function Get-RestorePointScheduledTaskStatus {
    <#
    .SYNOPSIS
        Gets the status of the restore point scheduled task.
    #>
    [CmdletBinding()]
    param()

    try {
        $taskName = $script:ScheduledTaskName
        $taskPath = $script:ScheduledTaskPath

        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue

        if ($task) {
            Write-Host "`n=== Scheduled Task Status ===" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Task Name: $taskName" -ForegroundColor Yellow
            Write-Host "Task Path: $taskPath"
            Write-Host "State: $($task.State)"
            Write-Host "Enabled: $($task.Settings.Enabled)"
            Write-Host "Last Run Time: $($task.TaskInfo.LastRunTime)"
            Write-Host "Last Result: $($task.TaskInfo.LastTaskResult)"
            Write-Host "Next Run Time: $($task.TaskInfo.NextRunTime)"
            Write-Host ""

            # Show trigger details
            foreach ($trigger in $task.Triggers) {
                if ($trigger.Repetition.Interval) {
                    Write-Host "Trigger: Repeats every $($trigger.Repetition.Interval)"
                }
                else {
                    Write-Host "Trigger: $($trigger.CimClass.CimClassName)"
                }
            }
            Write-Host ""

            return $task
        }
        else {
            Write-Host "`nScheduled task '$taskName' does not exist." -ForegroundColor Yellow
            Write-Host "Run with -Action Configure to create the scheduled task." -ForegroundColor Yellow
            return $null
        }
    }
    catch {
        Write-Log "Failed to get scheduled task status: $_" -Level ERROR
        return $null
    }
}

function Invoke-ConfigureRestorePoint {
    <#
    .SYNOPSIS
        Configures System Restore settings, creates initial restore point, and sets up scheduled task.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    try {
        Write-Log "Starting System Restore configuration" -Level INFO

        # Step 1: Enable and configure System Restore
        $diskSpacePercent = $script:Config.RestorePoint.DiskSpacePercent
        $result = Enable-SystemRestore -DiskSpacePercent $diskSpacePercent

        if (-not $result) {
            throw "System Restore configuration failed"
        }

        Write-Log "System Restore configuration completed successfully" -Level SUCCESS

        # Step 2: Create initial restore point
        Write-Log "Creating initial restore point..." -Level INFO
        $initialRPDescription = "Initial Restore Point - Configuration Complete"
        $rpCreated = Invoke-CreateRestorePoint -Description $initialRPDescription -Force

        if ($rpCreated) {
            Write-Log "Initial restore point created successfully" -Level SUCCESS
        }
        else {
            Write-Log "Failed to create initial restore point, but continuing with configuration" -Level WARNING
        }

        # Step 3: Create scheduled task
        if ($script:Config.RestorePoint.CreateOnSchedule) {
            Write-Log "Setting up scheduled task for automatic restore point creation..." -Level INFO
            $intervalMinutes = $script:Config.RestorePoint.ScheduleIntervalMinutes
            $taskCreated = New-RestorePointScheduledTask -IntervalMinutes $intervalMinutes

            if ($taskCreated) {
                Write-Log "Scheduled task created successfully" -Level SUCCESS
            }
            else {
                Write-Log "Failed to create scheduled task" -Level WARNING
            }
        }
        else {
            Write-Log "Scheduled creation is disabled in configuration. Skipping scheduled task creation." -Level INFO
        }

        # Step 4: Send notification
        $subject = "System Restore Configured - $env:COMPUTERNAME"
        $body = @"
<html>
<body>
<h2>System Restore Configuration Complete</h2>
<p><strong>Computer:</strong> $env:COMPUTERNAME</p>
<p><strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><strong>Disk Space Allocated:</strong> $diskSpacePercent%</p>
<p><strong>Initial Restore Point:</strong> $(if ($rpCreated) { 'Created' } else { 'Failed' })</p>
<p><strong>Scheduled Task:</strong> $(if ($taskCreated) { 'Created' } else { 'Disabled or Failed' })</p>
<p><strong>Schedule Interval:</strong> $([Math]::Round($script:Config.RestorePoint.ScheduleIntervalMinutes / 60, 2)) hours</p>
<p><strong>Status:</strong> Success</p>
</body>
</html>
"@
        Send-EmailNotification -Subject $subject -Body $body

        Write-Log "=== Configuration Summary ===" -Level SUCCESS
        Write-Log "System Restore: Enabled" -Level INFO
        Write-Log "Disk Space: $diskSpacePercent%" -Level INFO
        Write-Log "Initial Restore Point: $(if ($rpCreated) { 'Created' } else { 'Failed' })" -Level INFO
        Write-Log "Scheduled Task: $(if ($taskCreated) { 'Created' } else { 'Disabled or Failed' })" -Level INFO
        Write-Log "Configuration completed successfully!" -Level SUCCESS
    }
    catch {
        Write-Log "Configuration failed: $_" -Level ERROR
        throw
    }
}

function Invoke-CreateRestorePoint {
    <#
    .SYNOPSIS
        Creates a new System Restore Point.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    try {
        Write-Log "Attempting to create restore point: $Description" -Level INFO

        # Check if a restore point was created recently (within 24 hours)
        if (-not $Force) {
            $recentRestorePoints = Get-ComputerRestorePoint |
                Sort-Object CreationTime -Descending |
                Select-Object -First 1

            if ($recentRestorePoints) {
                # Convert CreationTime to DateTime
                $creationTime = ConvertTo-DateTime -Value $recentRestorePoints.CreationTime

                if ($creationTime) {
                    $timeSinceLastRP = (Get-Date) - $creationTime

                    if ($timeSinceLastRP.TotalHours -lt 24) {
                        Write-Log "A restore point was created $([Math]::Round($timeSinceLastRP.TotalHours, 2)) hours ago. Use -Force to override." -Level WARNING
                        return $false
                    }
                }
            }
        }

        # Create the restore point
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Create Restore Point: $Description")) {
            Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-Log "Restore point created successfully: $Description" -Level SUCCESS

            # Send notification
            $subject = "Restore Point Created - $env:COMPUTERNAME"
            $body = @"
<html>
<body>
<h2>Restore Point Created</h2>
<p><strong>Computer:</strong> $env:COMPUTERNAME</p>
<p><strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><strong>Description:</strong> $Description</p>
<p><strong>Status:</strong> Success</p>
</body>
</html>
"@
            Send-EmailNotification -Subject $subject -Body $body -EventType Create

            return $true
        }
    }
    catch {
        Write-Log "Failed to create restore point: $_" -Level ERROR

        # Send error notification
        $subject = "Restore Point Creation Failed - $env:COMPUTERNAME"
        $body = @"
<html>
<body>
<h2>Restore Point Creation Failed</h2>
<p><strong>Computer:</strong> $env:COMPUTERNAME</p>
<p><strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><strong>Description:</strong> $Description</p>
<p><strong>Error:</strong> $_</p>
</body>
</html>
"@
        Send-EmailNotification -Subject $subject -Body $body -EventType Create

        return $false
    }
}

function Invoke-ListRestorePoints {
    <#
    .SYNOPSIS
        Lists all available restore points.
    #>
    [CmdletBinding()]
    param()

    try {
        Write-Log "Retrieving restore points" -Level INFO

        $restorePoints = Get-ComputerRestorePoint | Sort-Object CreationTime -Descending

        if ($restorePoints) {
            Write-Log "Found $($restorePoints.Count) restore point(s)" -Level SUCCESS

            # Display detailed information
            Write-Host "`n=== System Restore Points ===" -ForegroundColor Cyan
            Write-Host ""

            foreach ($rp in $restorePoints) {
                $creationTime = ConvertTo-DateTime -Value $rp.CreationTime
                $timeAgo = if ($creationTime) {
                    $span = (Get-Date) - $creationTime
                    if ($span.TotalDays -ge 1) {
                        "$([Math]::Round($span.TotalDays, 1)) days ago"
                    }
                    elseif ($span.TotalHours -ge 1) {
                        "$([Math]::Round($span.TotalHours, 1)) hours ago"
                    }
                    else {
                        "$([Math]::Round($span.TotalMinutes, 0)) minutes ago"
                    }
                }
                else {
                    "Unknown"
                }

                Write-Host "Sequence #$($rp.SequenceNumber)" -ForegroundColor Yellow
                Write-Host "  Description: $($rp.Description)"
                Write-Host "  Created: $creationTime ($timeAgo)"
                Write-Host "  Type: $($rp.RestorePointType)"
                Write-Host ""
            }

            # Also show scheduled task status
            Get-RestorePointScheduledTaskStatus | Out-Null

            return $restorePoints
        }
        else {
            Write-Log "No restore points found" -Level WARNING
            Write-Host "`nNo restore points are currently available on this system." -ForegroundColor Yellow
            Write-Host "Run with -Action Configure to enable System Restore." -ForegroundColor Yellow

            # Still show scheduled task status
            Get-RestorePointScheduledTaskStatus | Out-Null

            return @()
        }
    }
    catch {
        Write-Log "Failed to retrieve restore points: $_" -Level ERROR
        return @()
    }
}

function Invoke-CleanupRestorePoints {
    <#
    .SYNOPSIS
        Cleans up old restore points while maintaining minimum count.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    try {
        Write-Log "Starting restore point cleanup" -Level INFO

        $restorePoints = Get-ComputerRestorePoint | Sort-Object CreationTime -Descending
        $currentCount = $restorePoints.Count
        $minCount = $script:Config.RestorePoint.MinimumCount
        $maxCount = $script:Config.RestorePoint.MaximumCount

        Write-Log "Current restore points: $currentCount, Min: $minCount, Max: $maxCount" -Level INFO

        if ($currentCount -le $maxCount) {
            Write-Log "Restore point count ($currentCount) is within limits. No cleanup needed." -Level INFO
            return
        }

        # Calculate how many to delete
        $deleteCount = $currentCount - $minCount
        $pointsToDelete = $restorePoints | Select-Object -Last $deleteCount

        foreach ($point in $pointsToDelete) {
            try {
                if ($PSCmdlet.ShouldProcess("Restore Point: $($point.Description)", "Delete")) {
                    # Note: PowerShell doesn't have a built-in cmdlet to delete specific restore points
                    # We'll use WMI to delete them
                    $wmi = Get-CimInstance -ClassName SystemRestore -Namespace root\default -Filter "SequenceNumber=$($point.SequenceNumber)" -ErrorAction SilentlyContinue

                    if ($wmi) {
                        Remove-CimInstance -InputObject $wmi -ErrorAction Stop
                        Write-Log "Deleted restore point: $($point.Description) (Sequence: $($point.SequenceNumber))" -Level SUCCESS

                        # Send notification
                        $subject = "Restore Point Deleted - $env:COMPUTERNAME"
                        $body = @"
<html>
<body>
<h2>Restore Point Deleted</h2>
<p><strong>Computer:</strong> $env:COMPUTERNAME</p>
<p><strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><strong>Description:</strong> $($point.Description)</p>
<p><strong>Created:</strong> $($point.CreationTime)</p>
<p><strong>Reason:</strong> Automatic cleanup (maintaining $minCount restore points)</p>
</body>
</html>
"@
                        Send-EmailNotification -Subject $subject -Body $body -EventType Delete
                    }
                }
            }
            catch {
                Write-Log "Failed to delete restore point $($point.SequenceNumber): $_" -Level ERROR
            }
        }

        Write-Log "Cleanup completed" -Level SUCCESS
    }
    catch {
        Write-Log "Cleanup failed: $_" -Level ERROR
    }
}

function Invoke-MonitorRestorePoints {
    <#
    .SYNOPSIS
        Monitors restore points and performs maintenance.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    try {
        Write-Log "Starting restore point monitoring" -Level INFO

        # Get current restore points
        $restorePoints = Get-ComputerRestorePoint | Sort-Object CreationTime -Descending
        $currentCount = $restorePoints.Count
        $minCount = $script:Config.RestorePoint.MinimumCount

        Write-Log "Current restore point count: $currentCount (Minimum: $minCount)" -Level INFO

        # Check if we need to create a restore point
        $shouldCreate = $false

        if ($currentCount -eq 0) {
            Write-Log "No restore points exist. Creating initial restore point." -Level WARNING
            $shouldCreate = $true
        }
        elseif ($script:Config.RestorePoint.CreateOnSchedule) {
            $lastRestorePoint = $restorePoints | Select-Object -First 1

            # Convert CreationTime to DateTime
            $creationTime = ConvertTo-DateTime -Value $lastRestorePoint.CreationTime

            if ($creationTime) {
                $timeSinceLastRP = (Get-Date) - $creationTime
                $intervalMinutes = $script:Config.RestorePoint.ScheduleIntervalMinutes
                $intervalHours = [Math]::Round($intervalMinutes / 60, 2)
                $hoursSinceLastRP = [Math]::Round($timeSinceLastRP.TotalHours, 2)

                Write-Log "Last restore point created $hoursSinceLastRP hours ago (Schedule interval: $intervalHours hours)" -Level INFO

                if ($timeSinceLastRP.TotalMinutes -ge $intervalMinutes) {
                    Write-Log "Schedule interval exceeded. Creating new restore point." -Level INFO
                    $shouldCreate = $true
                }
                else {
                    $hoursUntilNext = [Math]::Round(($intervalMinutes - $timeSinceLastRP.TotalMinutes) / 60, 2)
                    Write-Log "Next scheduled restore point in $hoursUntilNext hours" -Level INFO
                }
            }
            else {
                Write-Log "Could not determine last restore point time. Creating new restore point." -Level WARNING
                $shouldCreate = $true
            }
        }
        else {
            Write-Log "Scheduled creation is disabled in configuration" -Level INFO
        }

        # Create restore point if needed
        if ($shouldCreate) {
            $description = "Scheduled Restore Point - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Invoke-CreateRestorePoint -Description $description -Force
        }
        else {
            Write-Log "No new restore point needed at this time" -Level INFO
        }

        # Perform cleanup if needed
        Write-Log "Checking if cleanup is needed..." -Level INFO
        Invoke-CleanupRestorePoints

        Write-Log "Monitoring completed successfully" -Level SUCCESS
    }
    catch {
        Write-Log "Monitoring failed: $_" -Level ERROR
    }
}

#endregion

#region Main Script Execution

try {
    # Check administrator privileges
    if (-not (Test-AdministratorPrivilege)) {
        throw "This script requires administrator privileges. Please run as administrator."
    }

    # Load configuration
    if ($ConfigPath) {
        $script:Config = Get-Configuration -Path $ConfigPath
    }
    else {
        $script:Config = Get-Configuration
    }

    # Set up logging - Use central log path
    # Create central log directory if it doesn't exist
    if (-not (Test-Path $script:CentralLogPath)) {
        New-Item -Path $script:CentralLogPath -ItemType Directory -Force | Out-Null
        Write-Verbose "Created central log directory: $script:CentralLogPath"
    }

    # Use script-specific log file in central location
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
    $logFileName = "$scriptName-$(Get-Date -Format 'yyyy-MM').md"
    $script:LogPath = Join-Path $script:CentralLogPath $logFileName

    # Initialize markdown log file if it doesn't exist
    if (-not (Test-Path $script:LogPath)) {
        $logHeader = @"
# $scriptName Log

**Script Version:** $script:ScriptVersion
**Log Started:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**Computer:** $env:COMPUTERNAME
**User:** $env:USERNAME

---

## Activity Log

| Timestamp | Level | Message |
|-----------|-------|---------|

"@
        Set-Content -Path $script:LogPath -Value $logHeader -Force
    }

    Write-Log "=== Manage-RestorePoints.ps1 v$script:ScriptVersion Started ===" -Level INFO
    Write-Log "Action: $Action" -Level INFO

    # Execute the requested action
    switch ($Action) {
        'Configure' {
            Invoke-ConfigureRestorePoint
        }
        'Create' {
            Invoke-CreateRestorePoint -Description $Description -Force:$Force
        }
        'List' {
            $points = Invoke-ListRestorePoints
            if ($points) {
                $points | Format-Table -AutoSize
            }
        }
        'Cleanup' {
            Invoke-CleanupRestorePoints
        }
        'Monitor' {
            Invoke-MonitorRestorePoints
        }
    }

    Write-Log "=== Manage-RestorePoints.ps1 Completed ===" -Level INFO
    exit 0
}
catch {
    Write-Log "Script execution failed: $_" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
finally {
    # Cleanup
    if ($script:LogPath -and (Test-Path $script:LogPath)) {
        $logSize = (Get-Item $script:LogPath).Length / 1MB
        $maxSize = $script:Config.Logging.MaxLogSizeMB

        if ($logSize -gt $maxSize) {
            $archivePath = $script:LogPath -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item -Path $script:LogPath -Destination $archivePath -Force
            Write-Log "Log file archived to $archivePath" -Level INFO
        }
    }
}

#endregion

