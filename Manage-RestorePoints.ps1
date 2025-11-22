<#
.SYNOPSIS
    Manages Windows System Restore Points with automated creation, monitoring, and notification.

.DESCRIPTION
    This script provides comprehensive management of Windows System Restore Points including:
    - Interactive GUI configuration dialog shown before each run (can be skipped with -SkipGUI)
    - Review and modify settings before any action
    - Option to skip email notifications for individual runs
    - Configuring System Restore settings (enable, disk space allocation)
    - Creating restore points on demand or on schedule
    - Maintaining a minimum number of restore points
    - Sending email notifications for restore point events
    - Logging all activities to a configurable log file
    - Error handling and fallback mechanisms

.PARAMETER Action
    The action to perform. Valid values: Configure, Create, List, Cleanup, Monitor
    Default: Monitor

.PARAMETER ConfigPath
    Path to the configuration file. Defaults to .\config.json in the script directory.

.PARAMETER Description
    Description for the restore point when using -Action Create.

.PARAMETER Force
    Force the operation even if a restore point was recently created.

.PARAMETER SkipGUI
    Skip the interactive configuration GUI. Useful for automated/scheduled tasks.
    When omitted, the GUI will show before each run, allowing you to review and modify settings.

.EXAMPLE
    .\Manage-RestorePoints.ps1 -Action Create -Description "Pre-Update Backup"
    Shows GUI for configuration review, then creates a new restore point with the specified description.

.EXAMPLE
    .\Manage-RestorePoints.ps1 -Action Monitor -SkipGUI
    Monitors restore points and performs cleanup without showing the GUI (for scheduled tasks).

.EXAMPLE
    .\Manage-RestorePoints.ps1 -Action Configure
    Shows GUI to configure all settings, then proceeds with System Restore configuration.

.NOTES
    File Name      : Manage-RestorePoints.ps1
    Author         : myTech.Today
    Prerequisite   : PowerShell 5.1 or later, Administrator privileges
    Copyright      : (c) 2025 myTech.Today. All rights reserved.
    Version        : 1.5.0

    Changelog v1.5.0:
    - Fixed memory leaks by properly disposing of IDisposable objects
    - Added Invoke-SafeDispose helper function for safe resource cleanup
    - Fixed GUI form and control disposal in Show-ConfigurationDialog
    - Fixed SecureString disposal in password handling
    - Fixed WebRequest disposal when loading responsive GUI helper
    - Fixed SaveFileDialog disposal in event handlers
    - Improved memory management for sensitive credential data
    - Enhanced error logging with Write-DetailedError function
    - Added comprehensive error capture including exception types, HRESULT codes, and stack traces
    - Implemented transcript logging to capture all console output and Windows errors
    - Improved error handling in all major functions with detailed context
    - Added error logging for external commands (vssadmin, Checkpoint-Computer, etc.)
    - Enhanced Write-Log to accept ErrorRecord objects for detailed error information

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
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGUI
)

#Requires -Version 5.1
#Requires -RunAsAdministrator

# Load Windows Forms assemblies for GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Load responsive GUI helper
# This provides automatic DPI scaling and responsive control creation for all screen resolutions
Write-Host "[INFO] Loading responsive GUI helper..." -ForegroundColor Cyan

# Try to load from local scripts directory first (for development/testing)
$localResponsivePath = Join-Path $PSScriptRoot "..\scripts\responsive.ps1"
$responsiveLoaded = $false

if (Test-Path $localResponsivePath) {
    try {
        . $localResponsivePath
        Write-Host "[OK] Responsive GUI helper loaded from local file" -ForegroundColor Green
        $responsiveLoaded = $true
    }
    catch {
        Write-Warning "Failed to load responsive GUI helper from local file: $_"
    }
}

# Fallback to GitHub if local file not found or failed to load
if (-not $responsiveLoaded) {
    $responsiveUrl = 'https://raw.githubusercontent.com/mytech-today-now/scripts/refs/heads/main/responsive.ps1'
    try {
        $webRequest = Invoke-WebRequest -Uri $responsiveUrl -UseBasicParsing
        Invoke-Expression $webRequest.Content
        # Dispose of the web request object to free memory
        if ($webRequest -is [IDisposable]) {
            $webRequest.Dispose()
        }
        Write-Host "[OK] Responsive GUI helper loaded from GitHub" -ForegroundColor Green
        $responsiveLoaded = $true
    }
    catch {
        Write-Warning "Failed to load responsive GUI helper from GitHub: $_"
        Write-Warning "GUI features may not work correctly. Please check your internet connection."
        # Continue execution - the script can still work without the GUI helper for non-GUI operations
    }
}

# Import required modules (ScheduledTasks module for scheduled task management)
# Note: ScheduledTasks module is available on Windows Server 2012 R2 / Windows 8.1 and later
try {
    Import-Module ScheduledTasks -ErrorAction Stop
}
catch {
    Write-Warning "ScheduledTasks module could not be loaded. Scheduled task features will be disabled."
    Write-Warning "This module is required for Windows Server 2012 R2 / Windows 8.1 and later."
}

# Script variables
$script:ScriptVersion = '1.5.0'
$script:OriginalScriptPath = $PSScriptRoot
$script:SystemInstallPath = "$env:USERPROFILE\myTech.Today\RestorePoints"
$script:ScriptPath = $script:SystemInstallPath  # Will be updated after copy
$script:DefaultConfigPath = "$env:USERPROFILE\myTech.Today\RestorePoints\config.json"
$script:Config = $null
$script:LogPath = $null
$script:ScheduledTaskName = "System Restore Point - Daily Monitoring"
$script:ScheduledTaskPath = "\myTech.Today\"
$script:CentralLogPath = "$env:USERPROFILE\myTech.Today\logs\"
$script:SkipEmailForThisRun = $false

#region Self-Installation to System Location

function Copy-ScriptToSystemLocation {
    <#
    .SYNOPSIS
        Copies the restore point script and configuration to the system location.

    .DESCRIPTION
        Ensures the script is always available in a known system location:
        %USERPROFILE%\myTech.Today\RestorePoints\

        This allows scheduled tasks and other automation to reliably find the script
        regardless of where it was originally run from.

        Configuration: %USERPROFILE%\myTech.Today\RestorePoints\config.json
        Logs: %USERPROFILE%\myTech.Today\logs\Manage-RestorePoints-YYYY-MM.md
    #>
    [CmdletBinding()]
    param()

    try {
        # Define paths
        $systemPath = $script:SystemInstallPath
        $sourcePath = $script:OriginalScriptPath

        # Check if we're already running from the system location
        if ($sourcePath -eq $systemPath) {
            Write-Verbose "Already running from system location: $systemPath"
            return $true
        }

        Write-Verbose "Installing to system location..."
        Write-Verbose "  Source: $sourcePath"
        Write-Verbose "  Target: $systemPath"

        # Create system directory if it doesn't exist
        if (-not (Test-Path $systemPath)) {
            Write-Verbose "  Creating directory: $systemPath"
            New-Item -Path $systemPath -ItemType Directory -Force | Out-Null
        }

        # Copy main Manage-RestorePoints.ps1 script
        $sourceScript = Join-Path $sourcePath "Manage-RestorePoints.ps1"
        $targetScript = Join-Path $systemPath "Manage-RestorePoints.ps1"

        if (Test-Path $sourceScript) {
            Write-Verbose "  Copying Manage-RestorePoints.ps1..."
            Copy-Item -Path $sourceScript -Destination $targetScript -Force -ErrorAction Stop
        }

        # Copy config.json if it exists
        $sourceConfig = Join-Path $sourcePath "config.json"
        $targetConfig = Join-Path $systemPath "config.json"

        if (Test-Path $sourceConfig) {
            # Only copy if target doesn't exist (preserve existing configuration)
            if (-not (Test-Path $targetConfig)) {
                Write-Verbose "  Copying config.json..."
                Copy-Item -Path $sourceConfig -Destination $targetConfig -Force -ErrorAction Stop
            }
            else {
                Write-Verbose "  Preserving existing config.json"
            }
        }

        # Copy documentation files (optional but helpful)
        $docFiles = @("GUI_CONFIGURATION_SUMMARY.md", "README.md")
        foreach ($docFile in $docFiles) {
            $sourceDoc = Join-Path $sourcePath $docFile
            $targetDoc = Join-Path $systemPath $docFile

            if (Test-Path $sourceDoc) {
                Copy-Item -Path $sourceDoc -Destination $targetDoc -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Verbose "  Installation to system location complete!"
        Write-Verbose "  Location: $systemPath"

        return $true
    }
    catch {
        Write-Warning "Failed to copy to system location: $_"
        Write-Warning "Continuing with current location..."

        # Fall back to original location
        $script:ScriptPath = $script:OriginalScriptPath
        $script:DefaultConfigPath = Join-Path $script:ScriptPath 'config.json'

        return $false
    }
}

# Copy script to system location (first thing the script does)
$copiedToSystem = Copy-ScriptToSystemLocation

# Update script paths to use system location
if ($copiedToSystem) {
    $script:ScriptPath = $script:SystemInstallPath
    $script:DefaultConfigPath = Join-Path $script:ScriptPath 'config.json'
}

#endregion Self-Installation to System Location

#region Helper Functions

function Invoke-SafeDispose {
    <#
    .SYNOPSIS
        Safely disposes of IDisposable objects to prevent memory leaks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object]$Object,

        [Parameter(Mandatory = $false)]
        [switch]$SuppressErrors
    )

    if ($null -eq $Object) {
        return
    }

    try {
        if ($Object -is [IDisposable]) {
            $Object.Dispose()
        }
        elseif ($Object -is [System.Security.SecureString]) {
            $Object.Dispose()
        }
    }
    catch {
        if (-not $SuppressErrors) {
            Write-Verbose "Failed to dispose object: $_"
        }
    }
}

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
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

        # Create markdown-formatted log entry
        $icon = switch ($Level) {
            'INFO'    { '[i]' }
            'WARNING' { '[!]' }
            'ERROR'   { '[X]' }
            'SUCCESS' { '[OK]' }
        }

        $logEntry = "| $timestamp | $icon **$Level** | $Message |"

        # Write to log file in markdown table format
        if ($script:LogPath -and (Test-Path $script:LogPath)) {
            Add-Content -Path $script:LogPath -Value $logEntry -ErrorAction SilentlyContinue

            # If ErrorRecord is provided, log detailed error information
            if ($ErrorRecord) {
                $errorDetails = @"
| $timestamp | $icon **ERROR DETAILS** | Exception Type: $($ErrorRecord.Exception.GetType().FullName) |
| $timestamp | $icon **ERROR DETAILS** | Error Message: $($ErrorRecord.Exception.Message) |
| $timestamp | $icon **ERROR DETAILS** | Category: $($ErrorRecord.CategoryInfo.Category) - $($ErrorRecord.CategoryInfo.Reason) |
| $timestamp | $icon **ERROR DETAILS** | Target Object: $($ErrorRecord.TargetObject) |
| $timestamp | $icon **ERROR DETAILS** | Script Location: $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber) |
| $timestamp | $icon **ERROR DETAILS** | Command: $($ErrorRecord.InvocationInfo.MyCommand) |
"@
                if ($ErrorRecord.Exception.InnerException) {
                    $errorDetails += "`n| $timestamp | $icon **ERROR DETAILS** | Inner Exception: $($ErrorRecord.Exception.InnerException.Message) |"
                }
                if ($ErrorRecord.ScriptStackTrace) {
                    $errorDetails += "`n| $timestamp | $icon **ERROR DETAILS** | Stack Trace: $($ErrorRecord.ScriptStackTrace -replace "`n", " >> ") |"
                }
                Add-Content -Path $script:LogPath -Value $errorDetails -ErrorAction SilentlyContinue
            }
        }

        # Write to console
        switch ($Level) {
            'INFO'    {
                Write-Verbose $Message
                # Also write INFO to console for better user feedback
                Write-Host "INFO: $Message" -ForegroundColor Cyan
            }
            'WARNING' { Write-Warning $Message }
            'ERROR'   {
                Write-Error $Message
                if ($ErrorRecord) {
                    Write-Host "  Exception: $($ErrorRecord.Exception.GetType().Name)" -ForegroundColor Red
                    Write-Host "  Category: $($ErrorRecord.CategoryInfo.Category)" -ForegroundColor Red
                }
            }
            'SUCCESS' { Write-Host "SUCCESS: $Message" -ForegroundColor Green }
        }
    }
    catch {
        Write-Warning "Failed to write log: $_"
    }
}

function Write-DetailedError {
    <#
    .SYNOPSIS
        Writes detailed error information to the log file.
    .DESCRIPTION
        Captures comprehensive error details including exception type, message,
        stack trace, inner exceptions, and Windows error codes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalContext
    )

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

        # Build comprehensive error report
        $errorReport = @"

---
### ERROR REPORT - $timestamp
**Operation:** $Operation
**Exception Type:** $($ErrorRecord.Exception.GetType().FullName)
**Error Message:** $($ErrorRecord.Exception.Message)
**Category:** $($ErrorRecord.CategoryInfo.Category) - $($ErrorRecord.CategoryInfo.Reason)
**Error ID:** $($ErrorRecord.FullyQualifiedErrorId)
**Target Object:** $($ErrorRecord.TargetObject)
**Script Location:** $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)
**Command:** $($ErrorRecord.InvocationInfo.MyCommand)
**Position:** $($ErrorRecord.InvocationInfo.PositionMessage)
"@

        # Add inner exception if present
        if ($ErrorRecord.Exception.InnerException) {
            $errorReport += "`n**Inner Exception:** $($ErrorRecord.Exception.InnerException.GetType().FullName)"
            $errorReport += "`n**Inner Message:** $($ErrorRecord.Exception.InnerException.Message)"
        }

        # Add Windows error code if available (HRESULT)
        if ($ErrorRecord.Exception.HResult) {
            $errorReport += "`n**HRESULT:** 0x$($ErrorRecord.Exception.HResult.ToString('X8'))"
        }

        # Add native error code if available
        if ($ErrorRecord.Exception.NativeErrorCode) {
            $errorReport += "`n**Native Error Code:** $($ErrorRecord.Exception.NativeErrorCode)"
        }

        # Add additional context if provided
        if ($AdditionalContext) {
            $errorReport += "`n**Additional Context:**"
            foreach ($key in $AdditionalContext.Keys) {
                $errorReport += "`n  - $key`: $($AdditionalContext[$key])"
            }
        }

        # Add stack trace
        if ($ErrorRecord.ScriptStackTrace) {
            $errorReport += "`n**Stack Trace:**`n``````"
            $errorReport += "`n$($ErrorRecord.ScriptStackTrace)"
            $errorReport += "`n``````"
        }

        $errorReport += "`n---`n"

        # Write to log file
        if ($script:LogPath) {
            Add-Content -Path $script:LogPath -Value $errorReport -ErrorAction SilentlyContinue
        }

        # Also write summary to standard log
        Write-Log -Message "DETAILED ERROR: $Operation - $($ErrorRecord.Exception.Message)" -Level ERROR -ErrorRecord $ErrorRecord
    }
    catch {
        Write-Warning "Failed to write detailed error log: $_"
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
            try {
                $config = New-DefaultConfiguration
                $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -ErrorAction Stop
                Write-Log "Default configuration created at $Path" -Level SUCCESS
            }
            catch {
                Write-DetailedError -Operation "Create default configuration file" -ErrorRecord $_ -AdditionalContext @{
                    ConfigPath = $Path
                }
                throw
            }
        }
        else {
            try {
                $config = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                Write-Log "Configuration loaded from $Path" -Level INFO
            }
            catch {
                Write-DetailedError -Operation "Load configuration from file" -ErrorRecord $_ -AdditionalContext @{
                    ConfigPath = $Path
                }
                throw
            }
        }

        return $config
    }
    catch {
        Write-Log "Failed to load configuration: $_" -Level ERROR -ErrorRecord $_
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
            ScheduleIntervalMinutes = 1440  # Daily (deprecated - kept for backward compatibility)
            CreationFrequencyMinutes = 120  # Minimum time between restore points
            # New scheduling properties
            ScheduleFrequency = 'Daily'  # Hourly, Daily, EveryXDays, Weekly, Monthly, Yearly
            ScheduleInterval = 1  # For "Every X Days" option
            ScheduleTime = '00:00'  # Time of day (HH:mm format) for Daily, Weekly, Monthly, Yearly
            ScheduleDayOfWeek = 'Sunday'  # For Weekly: Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday
            ScheduleDayOfMonth = 1  # For Monthly: 1-31
            ScheduleMonth = 'January'  # For Yearly: January, February, March, April, May, June, July, August, September, October, November, December
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
            LogPath = "$env:USERPROFILE\myTech.Today\logs\Manage-RestorePoints-$(Get-Date -Format 'yyyy-MM').md"
            MaxLogSizeMB = 10
            RetentionDays = 30
        }
    }
}

function Show-ConfigurationDialog {
    <#
    .SYNOPSIS
        Displays a modern, responsive GUI dialog for configuring the script settings.

    .DESCRIPTION
        Shows a responsive GUI configuration dialog with modern flat/glassomorphic design.
        Adapts to screen resolution from VGA through 8K UHD with proper DPI scaling.
        Uses responsive.ps1 helper functions for consistent, modern UI design.
        Follows myTech.Today GUI responsiveness standards from .augment/ files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$CurrentConfig
    )

    # Get DPI scaling information
    $scaleInfo = Get-ResponsiveDPIScale
    $scaleFactor = $scaleInfo.TotalScale
    $resolutionName = $scaleInfo.ResolutionName

    Write-Log "Configuration Dialog - Resolution: $resolutionName, Scale Factor: $scaleFactor" -Level INFO

    # Create the main form using responsive helper - Microsoft Professional Standards
    $form = New-ResponsiveForm -Title "Restore Point Manager - Configuration" -Width 670 -Height 580 -Resizable $true

    # Define base dimensions for layout - Microsoft Professional Standards
    # All dimensions follow Windows Forms design guidelines
    $leftMargin = 12
    $labelWidth = 220  # Increased to prevent label text clipping for longer labels
    $inputX = 238  # leftMargin + labelWidth + 6px spacing (12 + 220 + 6)
    $inputWidth = 300  # Increased for better visibility and consistency
    $yStart = 12
    $ySpacing = 26  # 20px control height + 6px spacing
    $ySpacingSmall = 24  # Slightly tighter spacing for related controls

    # Create TabControl using responsive helper
    $tabControl = New-ResponsiveTabControl -X 8 -Y 8 -Width 640 -Height 440

    #region Email Settings Tab
    $tabEmail = New-ResponsiveTabPage -Text "Email Settings"
    $yPos = $yStart

    # Enable Email Notifications
    $chkEmailEnabled = New-ResponsiveCheckBox -Text "Enable Email Notifications" -X $leftMargin -Y $yPos -Width 250 -Checked $CurrentConfig.Email.Enabled
    $tabEmail.Controls.Add($chkEmailEnabled)
    $yPos += $ySpacing

    # SMTP Server and Port on same line for compact layout
    $lblSmtpServer = New-ResponsiveLabel -Text "SMTP Server:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $txtSmtpServer = New-ResponsiveTextBox -X $inputX -Y $yPos -Width 200 -Text $CurrentConfig.Email.SmtpServer

    # SMTP Port on same line, to the right of SMTP Server
    $portLabelX = $inputX + 210  # Position after SMTP Server input with spacing
    $portInputX = $portLabelX + 85  # Position after Port label
    $lblSmtpPort = New-ResponsiveLabel -Text "Port:" -X $portLabelX -Y $yPos -Width 80 -Height 20
    $numSmtpPort = New-ResponsiveNumericUpDown -X $portInputX -Y $yPos -Width 80 -Minimum 1 -Maximum 65535 -Value $CurrentConfig.Email.SmtpPort

    $tabEmail.Controls.AddRange(@($lblSmtpServer, $txtSmtpServer, $lblSmtpPort, $numSmtpPort))
    $yPos += $ySpacing

    # Use SSL/TLS
    $chkUseSsl = New-ResponsiveCheckBox -Text "Use SSL/TLS" -X $leftMargin -Y $yPos -Width 200 -Checked $CurrentConfig.Email.UseSsl
    $tabEmail.Controls.Add($chkUseSsl)
    $yPos += $ySpacing

    # From Email
    $lblFrom = New-ResponsiveLabel -Text "From Email:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $txtFrom = New-ResponsiveTextBox -X $inputX -Y $yPos -Width $inputWidth -Text $CurrentConfig.Email.From
    $tabEmail.Controls.AddRange(@($lblFrom, $txtFrom))
    $yPos += $ySpacing

    # To Email(s)
    $lblTo = New-ResponsiveLabel -Text "To Email(s):" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $txtTo = New-ResponsiveTextBox -X $inputX -Y $yPos -Width $inputWidth -Text ($CurrentConfig.Email.To -join ', ')
    $tabEmail.Controls.AddRange(@($lblTo, $txtTo))
    $yPos += $ySpacing

    # Username
    $lblUsername = New-ResponsiveLabel -Text "Username:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $txtUsername = New-ResponsiveTextBox -X $inputX -Y $yPos -Width $inputWidth -Text $CurrentConfig.Email.Username
    $tabEmail.Controls.AddRange(@($lblUsername, $txtUsername))
    $yPos += $ySpacing

    # Password
    $lblPassword = New-ResponsiveLabel -Text "Password:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $txtPassword = New-ResponsiveMaskedTextBox -X $inputX -Y $yPos -Width $inputWidth -PasswordChar '*'
    # Decrypt password if it exists
    if ($CurrentConfig.Email.PasswordEncrypted) {
        $securePass = $null
        $bstr = [IntPtr]::Zero
        try {
            $securePass = ConvertTo-SecureString $CurrentConfig.Email.PasswordEncrypted
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
            $txtPassword.Text = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        catch {
            # If decryption fails, leave empty
        }
        finally {
            # Always clean up sensitive memory
            if ($bstr -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            if ($null -ne $securePass) {
                Invoke-SafeDispose -Object $securePass -SuppressErrors
            }
        }
    }
    $tabEmail.Controls.AddRange(@($lblPassword, $txtPassword))
    $yPos += $ySpacing + 6  # Extra spacing before link

    # Gmail SMTP Relay Setup Instructions Link
    $gmailUrl = 'https://support.google.com/a/answer/176600?hl=en'
    $linkGmailSetup = New-ResponsiveLinkLabel -Text 'Click here for Gmail SMTP Relay Setup Instructions' -X $leftMargin -Y $yPos -Width 550 -Height 24 -LinkUrl $gmailUrl
    $tabEmail.Controls.Add($linkGmailSetup)

    $tabControl.TabPages.Add($tabEmail)
    #endregion

    #region Restore Point Settings Tab
    $tabRestorePoint = New-ResponsiveTabPage -Text "Restore Point Settings"
    $yPos = $yStart

    # Disk Space Percent
    $lblDiskSpace = New-ResponsiveLabel -Text "Disk Space Percent:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $numDiskSpace = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 100 -Value $CurrentConfig.RestorePoint.DiskSpacePercent
    $tabRestorePoint.Controls.AddRange(@($lblDiskSpace, $numDiskSpace))
    $yPos += $ySpacing

    # Minimum Restore Points
    $lblMinCount = New-ResponsiveLabel -Text "Minimum Restore Points:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $numMinCount = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 100 -Value $CurrentConfig.RestorePoint.MinimumCount
    $tabRestorePoint.Controls.AddRange(@($lblMinCount, $numMinCount))
    $yPos += $ySpacing

    # Maximum Restore Points
    $lblMaxCount = New-ResponsiveLabel -Text "Maximum Restore Points:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $numMaxCount = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 100 -Value $CurrentConfig.RestorePoint.MaximumCount
    $tabRestorePoint.Controls.AddRange(@($lblMaxCount, $numMaxCount))
    $yPos += $ySpacing

    # Create Restore Points on Schedule
    $chkCreateOnSchedule = New-ResponsiveCheckBox -Text "Create Restore Points on Schedule" -X $leftMargin -Y $yPos -Width 400 -Checked $CurrentConfig.RestorePoint.CreateOnSchedule
    $tabRestorePoint.Controls.Add($chkCreateOnSchedule)
    $yPos += $ySpacingSmall

    # Schedule Frequency
    $lblScheduleFrequency = New-ResponsiveLabel -Text "Schedule Frequency:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $cmbScheduleFrequency = New-ResponsiveComboBox -X $inputX -Y $yPos -Width 150 -Items @('Hourly', 'Daily', 'Every X Days', 'Weekly', 'Monthly', 'Yearly') -SelectedIndex 0
    # Set the selected frequency from config
    $frequencyIndex = switch ($CurrentConfig.RestorePoint.ScheduleFrequency) {
        'Hourly' { 0 }
        'Daily' { 1 }
        'EveryXDays' { 2 }
        'Weekly' { 3 }
        'Monthly' { 4 }
        'Yearly' { 5 }
        default { 1 }  # Default to Daily
    }
    $cmbScheduleFrequency.SelectedIndex = $frequencyIndex
    $tabRestorePoint.Controls.AddRange(@($lblScheduleFrequency, $cmbScheduleFrequency))
    $yPos += $ySpacing

    # Schedule Time (for Daily, Weekly, Monthly, Yearly)
    $lblScheduleTime = New-ResponsiveLabel -Text "Schedule Time:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $dtpScheduleTime = New-Object System.Windows.Forms.DateTimePicker
    $dtpScheduleTime.Format = [System.Windows.Forms.DateTimePickerFormat]::Time
    $dtpScheduleTime.ShowUpDown = $true
    $dtpScheduleTime.Width = 100
    # Parse time from config (HH:mm format)
    try {
        $timeValue = [DateTime]::ParseExact($CurrentConfig.RestorePoint.ScheduleTime, 'HH:mm', $null)
        $dtpScheduleTime.Value = $timeValue
    }
    catch {
        $dtpScheduleTime.Value = [DateTime]::Today
    }
    # Apply responsive scaling
    $scaleInfo = Get-ResponsiveDPIScale
    $scaleFactor = $scaleInfo.TotalScale
    $dtpScheduleTime.Location = New-Object System.Drawing.Point(
        (Get-ResponsiveScaledValue -BaseValue $inputX -ScaleFactor $scaleFactor),
        (Get-ResponsiveScaledValue -BaseValue $yPos -ScaleFactor $scaleFactor)
    )
    $dtpScheduleTime.Width = Get-ResponsiveScaledValue -BaseValue 100 -ScaleFactor $scaleFactor
    $baseDims = Get-ResponsiveBaseDimensions
    $fontSize = Get-ResponsiveScaledValue -BaseValue $baseDims.BaseFontSize -MinValue $baseDims.MinFontSize
    $dtpScheduleTime.Font = New-Object System.Drawing.Font("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Regular)
    $tabRestorePoint.Controls.AddRange(@($lblScheduleTime, $dtpScheduleTime))
    $yPos += $ySpacing

    # Schedule Interval (for "Every X Days")
    $lblScheduleInterval = New-ResponsiveLabel -Text "Interval (Days):" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    # Ensure valid value for NumericUpDown (must be >= Minimum)
    $scheduleIntervalValue = if ($CurrentConfig.RestorePoint.ScheduleInterval -and $CurrentConfig.RestorePoint.ScheduleInterval -ge 1) {
        [Math]::Min($CurrentConfig.RestorePoint.ScheduleInterval, 365)
    } else {
        1
    }
    $numScheduleInterval = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 365 -Value $scheduleIntervalValue
    $tabRestorePoint.Controls.AddRange(@($lblScheduleInterval, $numScheduleInterval))
    $yPos += $ySpacing

    # Schedule Day of Week (for Weekly)
    $lblScheduleDayOfWeek = New-ResponsiveLabel -Text "Day of Week:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $cmbScheduleDayOfWeek = New-ResponsiveComboBox -X $inputX -Y $yPos -Width 150 -Items @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') -SelectedIndex 0
    # Set the selected day from config
    $dayIndex = switch ($CurrentConfig.RestorePoint.ScheduleDayOfWeek) {
        'Sunday' { 0 }
        'Monday' { 1 }
        'Tuesday' { 2 }
        'Wednesday' { 3 }
        'Thursday' { 4 }
        'Friday' { 5 }
        'Saturday' { 6 }
        default { 0 }
    }
    $cmbScheduleDayOfWeek.SelectedIndex = $dayIndex
    $tabRestorePoint.Controls.AddRange(@($lblScheduleDayOfWeek, $cmbScheduleDayOfWeek))
    $yPos += $ySpacing

    # Schedule Day of Month (for Monthly)
    $lblScheduleDayOfMonth = New-ResponsiveLabel -Text "Day of Month:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    # Ensure valid value for NumericUpDown (must be >= Minimum)
    $scheduleDayOfMonthValue = if ($CurrentConfig.RestorePoint.ScheduleDayOfMonth -and $CurrentConfig.RestorePoint.ScheduleDayOfMonth -ge 1) {
        [Math]::Min($CurrentConfig.RestorePoint.ScheduleDayOfMonth, 31)
    } else {
        1
    }
    $numScheduleDayOfMonth = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 31 -Value $scheduleDayOfMonthValue
    $tabRestorePoint.Controls.AddRange(@($lblScheduleDayOfMonth, $numScheduleDayOfMonth))
    $yPos += $ySpacing

    # Schedule Month (for Yearly)
    $lblScheduleMonth = New-ResponsiveLabel -Text "Month:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $cmbScheduleMonth = New-ResponsiveComboBox -X $inputX -Y $yPos -Width 150 -Items @('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December') -SelectedIndex 0
    # Set the selected month from config
    $monthIndex = switch ($CurrentConfig.RestorePoint.ScheduleMonth) {
        'January' { 0 }
        'February' { 1 }
        'March' { 2 }
        'April' { 3 }
        'May' { 4 }
        'June' { 5 }
        'July' { 6 }
        'August' { 7 }
        'September' { 8 }
        'October' { 9 }
        'November' { 10 }
        'December' { 11 }
        default { 0 }
    }
    $cmbScheduleMonth.SelectedIndex = $monthIndex
    $tabRestorePoint.Controls.AddRange(@($lblScheduleMonth, $cmbScheduleMonth))
    $yPos += $ySpacing

    # Creation Frequency (minutes) - Minimum time between points
    $lblCreationFreq = New-ResponsiveLabel -Text "Creation Frequency (min):" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $numCreationFreq = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 1440 -Value $CurrentConfig.RestorePoint.CreationFrequencyMinutes
    $tabRestorePoint.Controls.AddRange(@($lblCreationFreq, $numCreationFreq))
    $yPos += $ySpacingSmall

    # Note about creation frequency - on separate line, left-aligned with label
    $lblCreationFreqNote = New-ResponsiveLabel -Text "(Minimum time between Restore Points)" -X $leftMargin -Y $yPos -Width 400 -Height 20
    $lblCreationFreqNote.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)  # Gray text
    $tabRestorePoint.Controls.Add($lblCreationFreqNote)

    # Function to update control visibility based on selected frequency
    $updateScheduleControlsVisibility = {
        $selectedFrequency = $cmbScheduleFrequency.SelectedItem.ToString()

        # Hide all conditional controls first
        $lblScheduleTime.Visible = $false
        $dtpScheduleTime.Visible = $false
        $lblScheduleInterval.Visible = $false
        $numScheduleInterval.Visible = $false
        $lblScheduleDayOfWeek.Visible = $false
        $cmbScheduleDayOfWeek.Visible = $false
        $lblScheduleDayOfMonth.Visible = $false
        $numScheduleDayOfMonth.Visible = $false
        $lblScheduleMonth.Visible = $false
        $cmbScheduleMonth.Visible = $false

        # Show relevant controls based on frequency
        switch ($selectedFrequency) {
            'Hourly' {
                # No additional controls needed for hourly
            }
            'Daily' {
                $lblScheduleTime.Visible = $true
                $dtpScheduleTime.Visible = $true
            }
            'Every X Days' {
                $lblScheduleTime.Visible = $true
                $dtpScheduleTime.Visible = $true
                $lblScheduleInterval.Visible = $true
                $numScheduleInterval.Visible = $true
            }
            'Weekly' {
                $lblScheduleTime.Visible = $true
                $dtpScheduleTime.Visible = $true
                $lblScheduleDayOfWeek.Visible = $true
                $cmbScheduleDayOfWeek.Visible = $true
            }
            'Monthly' {
                $lblScheduleTime.Visible = $true
                $dtpScheduleTime.Visible = $true
                $lblScheduleDayOfMonth.Visible = $true
                $numScheduleDayOfMonth.Visible = $true
            }
            'Yearly' {
                $lblScheduleTime.Visible = $true
                $dtpScheduleTime.Visible = $true
                $lblScheduleDayOfMonth.Visible = $true
                $numScheduleDayOfMonth.Visible = $true
                $lblScheduleMonth.Visible = $true
                $cmbScheduleMonth.Visible = $true
            }
        }
    }

    # Add event handler for frequency selection change
    $cmbScheduleFrequency.Add_SelectedIndexChanged($updateScheduleControlsVisibility)

    # Initialize control visibility based on current selection
    & $updateScheduleControlsVisibility

    $tabControl.TabPages.Add($tabRestorePoint)
    #endregion

    #region Logging Settings Tab
    $tabLogging = New-ResponsiveTabPage -Text "Logging Settings"
    $yPos = $yStart

    # Log File Path
    $lblLogPath = New-ResponsiveLabel -Text "Log File Path:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $txtLogPath = New-ResponsiveTextBox -X $inputX -Y $yPos -Width ($inputWidth - 40) -Text $CurrentConfig.Logging.LogPath
    $btnBrowse = New-ResponsiveButton -Text "..." -X ($inputX + $inputWidth - 35) -Y $yPos -Width 35
    # Reduce button font size by 1 point
    $btnBrowse.Font = New-Object System.Drawing.Font($btnBrowse.Font.FontFamily, ($btnBrowse.Font.Size - 1), $btnBrowse.Font.Style)
    $btnBrowse.Add_Click({
        $saveDialog = $null
        try {
            $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
            $saveDialog.Filter = "Markdown Files (*.md)|*.md|Log Files (*.log)|*.log|All Files (*.*)|*.*"
            $saveDialog.FileName = [System.IO.Path]::GetFileName($txtLogPath.Text)

            # Set initial directory to %USERPROFILE%\myTech.Today\logs\
            $defaultLogDir = "$env:USERPROFILE\myTech.Today\logs"
            if (Test-Path $defaultLogDir) {
                $saveDialog.InitialDirectory = $defaultLogDir
            } else {
                # Create the directory if it doesn't exist
                try {
                    New-Item -Path $defaultLogDir -ItemType Directory -Force | Out-Null
                    $saveDialog.InitialDirectory = $defaultLogDir
                } catch {
                    # Fallback to current directory if creation fails
                    $saveDialog.InitialDirectory = $env:USERPROFILE
                }
            }

            if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtLogPath.Text = $saveDialog.FileName
            }
        }
        finally {
            # Dispose of the dialog to free resources
            Invoke-SafeDispose -Object $saveDialog -SuppressErrors
        }
    })
    $tabLogging.Controls.AddRange(@($lblLogPath, $txtLogPath, $btnBrowse))
    $yPos += $ySpacing

    # Max Log Size (MB)
    $lblMaxLogSize = New-ResponsiveLabel -Text "Max Log Size (MB):" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $numMaxLogSize = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 1000 -Value $CurrentConfig.Logging.MaxLogSizeMB
    $tabLogging.Controls.AddRange(@($lblMaxLogSize, $numMaxLogSize))
    $yPos += $ySpacing

    # Retention Days
    $lblRetentionDays = New-ResponsiveLabel -Text "Retention Days:" -X $leftMargin -Y $yPos -Width $labelWidth -Height 20
    $numRetentionDays = New-ResponsiveNumericUpDown -X $inputX -Y $yPos -Width 100 -Minimum 1 -Maximum 365 -Value $CurrentConfig.Logging.RetentionDays
    $tabLogging.Controls.AddRange(@($lblRetentionDays, $numRetentionDays))

    $tabControl.TabPages.Add($tabLogging)
    #endregion

    $form.Controls.Add($tabControl)

    # Bottom controls - Action buttons (Microsoft Professional Standards)
    # All buttons same width to accommodate longest text without wrapping
    $buttonY = 470
    $buttonWidth = 180  # Width to accommodate "Continue Without Saving" text
    $buttonSpacing = 8

    # Action Buttons - Horizontally aligned with consistent spacing
    $btnSaveAndContinue = New-ResponsiveButton -Text "Save && Continue" -X $leftMargin -Y $buttonY -Width $buttonWidth
    $btnSaveAndContinue.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnSaveAndContinue.Tag = "SaveAndContinue"
    $form.Controls.Add($btnSaveAndContinue)
    $form.AcceptButton = $btnSaveAndContinue

    $btnContinueWithoutSaving = New-ResponsiveButton -Text "Continue Without Saving" -X ($leftMargin + $buttonWidth + $buttonSpacing) -Y $buttonY -Width $buttonWidth
    $btnContinueWithoutSaving.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $btnContinueWithoutSaving.Tag = "ContinueWithoutSaving"
    $form.Controls.Add($btnContinueWithoutSaving)

    $btnCancel = New-ResponsiveButton -Text "Cancel" -X ($leftMargin + ($buttonWidth * 2) + ($buttonSpacing * 2)) -Y $buttonY -Width $buttonWidth
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    # Ensure form is brought to focus
    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })

    # Show dialog and return result
    $result = $null
    $returnValue = $null
    $securePassword = $null

    try {
        $result = $form.ShowDialog()

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            # Save & Continue button clicked
            # Build updated configuration object
            try {
                $passwordEncrypted = ''
                if ($txtPassword.Text) {
                    $securePassword = ConvertTo-SecureString $txtPassword.Text -AsPlainText -Force
                    $passwordEncrypted = ConvertFrom-SecureString $securePassword
                }

                # Convert frequency selection to internal format
                $scheduleFrequency = switch ($cmbScheduleFrequency.SelectedItem.ToString()) {
                    'Hourly' { 'Hourly' }
                    'Daily' { 'Daily' }
                    'Every X Days' { 'EveryXDays' }
                    'Weekly' { 'Weekly' }
                    'Monthly' { 'Monthly' }
                    'Yearly' { 'Yearly' }
                    default { 'Daily' }
                }

                # Format schedule time as HH:mm
                $scheduleTime = $dtpScheduleTime.Value.ToString('HH:mm')

                $updatedConfig = [PSCustomObject]@{
                    RestorePoint = [PSCustomObject]@{
                        DiskSpacePercent = [int]$numDiskSpace.Value
                        MinimumCount = [int]$numMinCount.Value
                        MaximumCount = [int]$numMaxCount.Value
                        CreateOnSchedule = $chkCreateOnSchedule.Checked
                        ScheduleIntervalMinutes = [int]$numScheduleInterval.Value  # Deprecated - kept for backward compatibility
                        CreationFrequencyMinutes = [int]$numCreationFreq.Value
                        # New scheduling properties
                        ScheduleFrequency = $scheduleFrequency
                        ScheduleInterval = [int]$numScheduleInterval.Value
                        ScheduleTime = $scheduleTime
                        ScheduleDayOfWeek = $cmbScheduleDayOfWeek.SelectedItem.ToString()
                        ScheduleDayOfMonth = [int]$numScheduleDayOfMonth.Value
                        ScheduleMonth = $cmbScheduleMonth.SelectedItem.ToString()
                    }
                    Email = [PSCustomObject]@{
                        Enabled = $chkEmailEnabled.Checked
                        SmtpServer = $txtSmtpServer.Text
                        SmtpPort = [int]$numSmtpPort.Value
                        UseSsl = $chkUseSsl.Checked
                        From = $txtFrom.Text
                        To = @($txtTo.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        Username = $txtUsername.Text
                        PasswordEncrypted = $passwordEncrypted
                    }
                    Logging = [PSCustomObject]@{
                        LogPath = $txtLogPath.Text
                        MaxLogSizeMB = [int]$numMaxLogSize.Value
                        RetentionDays = [int]$numRetentionDays.Value
                    }
                }

                $returnValue = [PSCustomObject]@{
                    Action = 'SaveAndContinue'
                    Config = $updatedConfig
                    SkipEmail = $false  # Always use the "Enable Email Notifications" checkbox from Email Settings tab
                }
            }
            finally {
                # Dispose of SecureString
                Invoke-SafeDispose -Object $securePassword -SuppressErrors
            }
        }
        elseif ($result -eq [System.Windows.Forms.DialogResult]::Ignore) {
            # Continue Without Saving button clicked
            $returnValue = [PSCustomObject]@{
                Action = 'ContinueWithoutSaving'
                Config = $CurrentConfig
                SkipEmail = $false  # Always use the "Enable Email Notifications" checkbox from Email Settings tab
            }
        }
    }
    finally {
        # Dispose of all form controls and the form itself to prevent memory leaks
        Invoke-SafeDispose -Object $form -SuppressErrors
    }

    # Cancel button clicked or dialog closed
    return $returnValue
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

    $securePassword = $null
    $credential = $null

    try {
        # Check if email should be skipped for this run
        if ($script:SkipEmailForThisRun) {
            Write-Log "Email notification skipped (user preference for this run)" -Level INFO
            return
        }

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
    finally {
        # Dispose of sensitive objects to prevent memory leaks
        Invoke-SafeDispose -Object $securePassword -SuppressErrors
        # Note: PSCredential doesn't implement IDisposable, but we dispose its SecureString
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

function Set-RestorePointFrequency {
    <#
    .SYNOPSIS
        Sets the minimum time interval between restore point creation.
    .DESCRIPTION
        Configures the SystemRestorePointCreationFrequency registry value which controls
        the minimum time interval (in minutes) between two restore point creations.
        Default Windows value is 1440 minutes (24 hours).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [int]$FrequencyMinutes = 120  # Default: 2 hours
    )

    try {
        $registryPath = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore"
        $registryName = "SystemRestorePointCreationFrequency"

        Write-Log "Configuring restore point creation frequency to $FrequencyMinutes minutes ($([Math]::Round($FrequencyMinutes / 60, 2)) hours)" -Level INFO

        # Ensure the registry path exists
        if (-not (Test-Path $registryPath)) {
            Write-Log "Registry path does not exist: $registryPath" -Level WARNING
            return $false
        }

        # Set the registry value
        if ($PSCmdlet.ShouldProcess($registryPath, "Set $registryName to $FrequencyMinutes")) {
            Set-ItemProperty -Path $registryPath -Name $registryName -Value $FrequencyMinutes -Type DWord -ErrorAction Stop
            Write-Log "Restore point creation frequency set to $FrequencyMinutes minutes" -Level SUCCESS
            Write-Log "Windows will now allow restore points to be created every $([Math]::Round($FrequencyMinutes / 60, 2)) hours" -Level INFO
            return $true
        }

        return $false
    }
    catch {
        Write-Log "Failed to set restore point creation frequency: $_" -Level ERROR
        return $false
    }
}

function Enable-SystemRestore {
    <#
    .SYNOPSIS
        Enables System Restore on the system drive and configures disk space.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [int]$DiskSpacePercent = 10,

        [Parameter(Mandatory = $false)]
        [int]$FrequencyMinutes = 120
    )

    try {
        $systemDrive = $env:SystemDrive
        Write-Log "Configuring System Restore for drive $systemDrive" -Level INFO

        # Enable System Restore
        if ($PSCmdlet.ShouldProcess($systemDrive, "Enable System Restore")) {
            try {
                Enable-ComputerRestore -Drive $systemDrive -ErrorAction Stop
                Write-Log "System Restore enabled on $systemDrive" -Level SUCCESS
            }
            catch {
                Write-DetailedError -Operation "Enable System Restore via Enable-ComputerRestore" -ErrorRecord $_ -AdditionalContext @{
                    Drive = $systemDrive
                }
                throw
            }
        }

        # Configure restore point creation frequency
        $frequencySet = Set-RestorePointFrequency -FrequencyMinutes $FrequencyMinutes
        if (-not $frequencySet) {
            Write-Log "Failed to set restore point creation frequency, but continuing" -Level WARNING
        }

        # Configure disk space using VSSAdmin
        $diskSpacePercent = [Math]::Max(8, [Math]::Min(100, $DiskSpacePercent))

        if ($PSCmdlet.ShouldProcess($systemDrive, "Set disk space to $diskSpacePercent%")) {
            try {
                $vssOutput = vssadmin Resize ShadowStorage /For=$systemDrive /On=$systemDrive /MaxSize="${diskSpacePercent}%" 2>&1
                $vssExitCode = $LASTEXITCODE

                if ($vssExitCode -eq 0) {
                    Write-Log "Disk space configured to $diskSpacePercent% for System Restore" -Level SUCCESS
                }
                else {
                    Write-Log "VSSAdmin failed with exit code: $vssExitCode" -Level WARNING
                    Write-Log "VSSAdmin output: $vssOutput" -Level WARNING
                    Write-Log "Attempting alternative configuration method" -Level INFO

                    # Alternative: Use WMI
                    try {
                        $wmi = Get-CimInstance -ClassName Win32_ShadowStorage -Filter "Volume='\\\\?\\$($systemDrive)\\'" -ErrorAction Stop
                        if ($wmi) {
                            $maxSpace = [Math]::Floor((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$systemDrive'").Size * ($diskSpacePercent / 100))
                            Set-CimInstance -InputObject $wmi -Property @{MaxSpace = $maxSpace} -ErrorAction Stop
                            Write-Log "Disk space configured using WMI" -Level SUCCESS
                        }
                        else {
                            Write-Log "No shadow storage found for $systemDrive" -Level WARNING
                        }
                    }
                    catch {
                        Write-DetailedError -Operation "Configure disk space via WMI" -ErrorRecord $_ -AdditionalContext @{
                            Drive = $systemDrive
                            DiskSpacePercent = $diskSpacePercent
                        }
                        throw
                    }
                }
            }
            catch {
                Write-DetailedError -Operation "Configure disk space via VSSAdmin" -ErrorRecord $_ -AdditionalContext @{
                    Drive = $systemDrive
                    DiskSpacePercent = $diskSpacePercent
                    VSSOutput = $vssOutput
                    ExitCode = $vssExitCode
                }
                throw
            }
        }

        return $true
    }
    catch {
        Write-Log "Failed to configure System Restore: $_" -Level ERROR -ErrorRecord $_
        Write-DetailedError -Operation "Configure System Restore" -ErrorRecord $_ -AdditionalContext @{
            SystemDrive = $env:SystemDrive
            DiskSpacePercent = $DiskSpacePercent
            FrequencyMinutes = $FrequencyMinutes
        }
        return $false
    }
}

#endregion

#region Main Functions

function New-RestorePointScheduledTask {
    <#
    .SYNOPSIS
        Creates a Windows Scheduled Task to run restore point monitoring.

    .DESCRIPTION
        Creates a scheduled task with flexible scheduling options including hourly, daily,
        weekly, monthly, and yearly frequencies. Supports backward compatibility with
        IntervalMinutes parameter.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false)]
        [int]$IntervalMinutes = 1440,  # Default: 24 hours (1 day) - deprecated, kept for backward compatibility

        [Parameter(Mandatory = $false)]
        [PSCustomObject]$ScheduleConfig = $null  # New scheduling configuration object
    )

    try {
        # Check if ScheduledTasks module is available
        if (-not (Get-Module -Name ScheduledTasks -ListAvailable)) {
            Write-Log "ScheduledTasks module is not available. Scheduled task creation skipped." -Level WARNING
            Write-Log "This module is required for Windows Server 2012 R2 / Windows 8.1 and later." -Level INFO
            return $false
        }

        $taskName = $script:ScheduledTaskName
        $taskPath = $script:ScheduledTaskPath

        Write-Log "Creating scheduled task: $taskName" -Level INFO

        # Check if task already exists
        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Log "Scheduled task already exists. Removing old task..." -Level INFO
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        }

        # Define the action (run the script with Monitor action and -SkipGUI)
        $scriptPath = $PSCommandPath
        $configPath = if ($script:Config) { $ConfigPath } else { $script:DefaultConfigPath }
        $actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action Monitor -ConfigPath `"$configPath`" -SkipGUI"
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $actionArgs

        # Define the trigger based on schedule configuration
        $trigger = $null
        $scheduleDescription = ""

        if ($null -ne $ScheduleConfig) {
            # Use new scheduling configuration
            $frequency = $ScheduleConfig.ScheduleFrequency
            $scheduleTime = $ScheduleConfig.ScheduleTime

            # Parse time (HH:mm format)
            $timeValue = try {
                [DateTime]::ParseExact($scheduleTime, 'HH:mm', $null)
            }
            catch {
                [DateTime]::Today
            }

            switch ($frequency) {
                'Hourly' {
                    # Hourly: Use repetition interval
                    $trigger = New-ScheduledTaskTrigger -Once -At $timeValue -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::MaxValue)
                    $scheduleDescription = "hourly"
                }
                'Daily' {
                    # Daily: Run once per day at specified time
                    $trigger = New-ScheduledTaskTrigger -Daily -At $timeValue
                    $scheduleDescription = "daily at $scheduleTime"
                }
                'EveryXDays' {
                    # Every X Days: Use DaysInterval parameter
                    $interval = $ScheduleConfig.ScheduleInterval
                    $trigger = New-ScheduledTaskTrigger -Daily -At $timeValue -DaysInterval $interval
                    $scheduleDescription = "every $interval day$(if ($interval -gt 1) { 's' }) at $scheduleTime"
                }
                'Weekly' {
                    # Weekly: Run on specific day of week
                    $dayOfWeek = $ScheduleConfig.ScheduleDayOfWeek
                    $trigger = New-ScheduledTaskTrigger -Weekly -At $timeValue -DaysOfWeek $dayOfWeek
                    $scheduleDescription = "weekly on $dayOfWeek at $scheduleTime"
                }
                'Monthly' {
                    # Monthly: Run on specific day of month
                    $dayOfMonth = $ScheduleConfig.ScheduleDayOfMonth
                    # Note: New-ScheduledTaskTrigger doesn't have a direct -Monthly parameter with -DaysOfMonth
                    # We need to use CIM class for monthly triggers
                    $trigger = New-ScheduledTaskTrigger -Daily -At $timeValue
                    # We'll need to modify the trigger after creation using CIM
                    $scheduleDescription = "monthly on day $dayOfMonth at $scheduleTime"
                }
                'Yearly' {
                    # Yearly: Run on specific month and day
                    $month = $ScheduleConfig.ScheduleMonth
                    $dayOfMonth = $ScheduleConfig.ScheduleDayOfMonth
                    # For yearly, we'll use a daily trigger and modify it
                    $trigger = New-ScheduledTaskTrigger -Daily -At $timeValue
                    $scheduleDescription = "yearly on $month $dayOfMonth at $scheduleTime"
                }
                default {
                    # Fallback to daily
                    $trigger = New-ScheduledTaskTrigger -Daily -At $timeValue
                    $scheduleDescription = "daily at $scheduleTime"
                }
            }
        }
        else {
            # Backward compatibility: Use IntervalMinutes parameter
            if ($IntervalMinutes -ge 1440) {
                # Daily trigger
                $trigger = New-ScheduledTaskTrigger -Daily -At "12:00AM"
                $scheduleDescription = "daily at midnight"
            }
            else {
                # Repetition trigger
                $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
                $scheduleDescription = "every $([Math]::Round($IntervalMinutes / 60, 2)) hours"
            }
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
            Write-Log "Task will run $scheduleDescription" -Level INFO
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

        # Show configuration GUI
        Write-Host "`nOpening configuration dialog..." -ForegroundColor Cyan
        $guiResult = Show-ConfigurationDialog -CurrentConfig $script:Config

        if ($null -eq $guiResult) {
            Write-Log "Configuration cancelled by user" -Level WARNING
            Write-Host "Configuration cancelled." -ForegroundColor Yellow
            return
        }

        # Set skip email flag
        $script:SkipEmailForThisRun = $guiResult.SkipEmail

        # Save configuration if requested
        if ($guiResult.Action -eq 'SaveAndContinue') {
            $configPath = if ($ConfigPath) { $ConfigPath } else { $script:DefaultConfigPath }
            try {
                $guiResult.Config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Force -ErrorAction Stop
                Write-Log "Configuration saved to $configPath" -Level SUCCESS
                Write-Host "Configuration saved successfully!" -ForegroundColor Green

                # Reload configuration
                $script:Config = $guiResult.Config
            }
            catch {
                Write-Log "Failed to save configuration: $_" -Level ERROR -ErrorRecord $_
                Write-DetailedError -Operation "Save configuration to file" -ErrorRecord $_ -AdditionalContext @{
                    ConfigPath = $configPath
                }
                Write-Host "Error saving configuration: $_" -ForegroundColor Red
                throw
            }
        }
        else {
            Write-Host "Continuing with current configuration (not saved)." -ForegroundColor Yellow
        }

        # Step 1: Enable and configure System Restore
        $diskSpacePercent = $script:Config.RestorePoint.DiskSpacePercent
        $frequencyMinutes = if ($script:Config.RestorePoint.CreationFrequencyMinutes) {
            $script:Config.RestorePoint.CreationFrequencyMinutes
        } else {
            120  # Default: 2 hours
        }

        $result = Enable-SystemRestore -DiskSpacePercent $diskSpacePercent -FrequencyMinutes $frequencyMinutes

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

            # Use new scheduling configuration if available, otherwise fall back to IntervalMinutes
            if ($script:Config.RestorePoint.ScheduleFrequency) {
                # New scheduling configuration
                $scheduleConfig = [PSCustomObject]@{
                    ScheduleFrequency = $script:Config.RestorePoint.ScheduleFrequency
                    ScheduleInterval = $script:Config.RestorePoint.ScheduleInterval
                    ScheduleTime = $script:Config.RestorePoint.ScheduleTime
                    ScheduleDayOfWeek = $script:Config.RestorePoint.ScheduleDayOfWeek
                    ScheduleDayOfMonth = $script:Config.RestorePoint.ScheduleDayOfMonth
                    ScheduleMonth = $script:Config.RestorePoint.ScheduleMonth
                }
                $taskCreated = New-RestorePointScheduledTask -ScheduleConfig $scheduleConfig
            }
            else {
                # Backward compatibility: Use IntervalMinutes
                $intervalMinutes = $script:Config.RestorePoint.ScheduleIntervalMinutes
                $taskCreated = New-RestorePointScheduledTask -IntervalMinutes $intervalMinutes
            }

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
<p><strong>Creation Frequency:</strong> $([Math]::Round($frequencyMinutes / 60, 2)) hours</p>
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
        Write-Log "Creation Frequency: $([Math]::Round($frequencyMinutes / 60, 2)) hours" -Level INFO
        Write-Log "Initial Restore Point: $(if ($rpCreated) { 'Created' } else { 'Failed' })" -Level INFO
        Write-Log "Scheduled Task: $(if ($taskCreated) { 'Created' } else { 'Disabled or Failed' })" -Level INFO
        Write-Log "Configuration completed successfully!" -Level SUCCESS
    }
    catch {
        Write-Log "Configuration failed: $_" -Level ERROR -ErrorRecord $_
        Write-DetailedError -Operation "Configure Restore Point System" -ErrorRecord $_ -AdditionalContext @{
            DiskSpacePercent = $diskSpacePercent
            FrequencyMinutes = $frequencyMinutes
        }
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
            try {
                $recentRestorePoints = Get-ComputerRestorePoint -ErrorAction Stop |
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
            catch {
                Write-DetailedError -Operation "Check recent restore points" -ErrorRecord $_ -AdditionalContext @{
                    Description = $Description
                }
                # Continue with creation even if check fails
                Write-Log "Could not check recent restore points, proceeding with creation" -Level WARNING
            }
        }

        # Create the restore point
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Create Restore Point: $Description")) {
            try {
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
            catch {
                Write-DetailedError -Operation "Create restore point via Checkpoint-Computer" -ErrorRecord $_ -AdditionalContext @{
                    Description = $Description
                    ComputerName = $env:COMPUTERNAME
                    RestorePointType = 'MODIFY_SETTINGS'
                }
                throw
            }
        }
    }
    catch {
        Write-Log "Failed to create restore point: $_" -Level ERROR -ErrorRecord $_

        # Send error notification
        $subject = "Restore Point Creation Failed - $env:COMPUTERNAME"
        $body = @"
<html>
<body>
<h2>Restore Point Creation Failed</h2>
<p><strong>Computer:</strong> $env:COMPUTERNAME</p>
<p><strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><strong>Description:</strong> $Description</p>
<p><strong>Error:</strong> $($_.Exception.Message)</p>
<p><strong>Error Type:</strong> $($_.Exception.GetType().FullName)</p>
<p><strong>Category:</strong> $($_.CategoryInfo.Category)</p>
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

        try {
            $restorePoints = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending
        }
        catch {
            Write-DetailedError -Operation "Retrieve restore points via Get-ComputerRestorePoint" -ErrorRecord $_
            throw
        }

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
        Write-Log "Failed to retrieve restore points: $_" -Level ERROR -ErrorRecord $_
        Write-DetailedError -Operation "List restore points" -ErrorRecord $_
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

        # Update the registry setting to allow restore points at the configured frequency
        # This ensures Windows doesn't block restore point creation due to the default 24-hour restriction
        $frequencyMinutes = if ($script:Config.RestorePoint.CreationFrequencyMinutes) {
            $script:Config.RestorePoint.CreationFrequencyMinutes
        } else {
            0  # 0 = No restriction (allow restore points to be created anytime)
        }

        Write-Log "Configuring Windows to allow restore points every $frequencyMinutes minutes" -Level INFO
        $frequencySet = Set-RestorePointFrequency -FrequencyMinutes $frequencyMinutes
        if (-not $frequencySet) {
            Write-Log "Failed to update restore point creation frequency registry setting" -Level WARNING
        }

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

    # Set up logging - Use config log path or default
    if ($script:Config.Logging.LogPath) {
        $script:LogPath = $script:Config.Logging.LogPath
    } else {
        # Fallback to central log path if config doesn't specify
        $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
        $logFileName = "$scriptName-$(Get-Date -Format 'yyyy-MM').md"
        $script:LogPath = Join-Path $script:CentralLogPath $logFileName
    }

    # Create log directory if it doesn't exist
    $logDir = Split-Path $script:LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created log directory: $logDir"
    }

    # Initialize markdown log file if it doesn't exist
    if (-not (Test-Path $script:LogPath)) {
        $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
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

    # Start transcript logging to capture all console output and errors
    $transcriptPath = $script:LogPath -replace '\.(md|log)$', "_transcript_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    try {
        Start-Transcript -Path $transcriptPath -Append -ErrorAction Stop
        Write-Verbose "Transcript logging started: $transcriptPath"
    }
    catch {
        Write-Warning "Failed to start transcript logging: $_"
    }

    Write-Log "=== Manage-RestorePoints.ps1 v$script:ScriptVersion Started ===" -Level INFO
    Write-Log "Action: $Action" -Level INFO
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)" -Level INFO
    Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)" -Level INFO
    Write-Log "Running as: $env:USERNAME" -Level INFO
    Write-Log "Transcript: $transcriptPath" -Level INFO

    # Show configuration GUI (unless -SkipGUI is specified)
    if (-not $SkipGUI) {
        Write-Host "`nOpening configuration dialog..." -ForegroundColor Cyan
        Write-Host "You can review and modify settings before proceeding." -ForegroundColor Gray

        $guiResult = Show-ConfigurationDialog -CurrentConfig $script:Config

        if ($null -eq $guiResult) {
            Write-Log "Script cancelled by user from configuration dialog" -Level WARNING
            Write-Host "`nScript cancelled." -ForegroundColor Yellow
            exit 0
        }

        # Set skip email flag
        $script:SkipEmailForThisRun = $guiResult.SkipEmail
        if ($script:SkipEmailForThisRun) {
            Write-Log "Email notifications skipped for this run (user preference)" -Level INFO
            Write-Host "Email notifications will be skipped for this run." -ForegroundColor Yellow
        }

        # Save configuration if requested
        if ($guiResult.Action -eq 'SaveAndContinue') {
            $configPath = if ($ConfigPath) { $ConfigPath } else { $script:DefaultConfigPath }
            try {
                $guiResult.Config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Force
                Write-Log "Configuration saved to $configPath" -Level SUCCESS
                Write-Host "Configuration saved successfully!" -ForegroundColor Green

                # Reload configuration
                $script:Config = $guiResult.Config
            }
            catch {
                Write-Log "Failed to save configuration: $_" -Level ERROR
                Write-Host "Error saving configuration: $_" -ForegroundColor Red
                throw
            }
        }
        else {
            Write-Host "Continuing with current configuration (not saved)." -ForegroundColor Yellow
        }

        Write-Host "`nProceeding with action: $Action" -ForegroundColor Cyan
    }

    # Execute the requested action
    switch ($Action) {
        'Configure' {
            Invoke-ConfigureRestorePoint
        }
        'Create' {
            # Update registry to allow restore point creation at configured frequency
            $frequencyMinutes = if ($script:Config.RestorePoint.CreationFrequencyMinutes) {
                $script:Config.RestorePoint.CreationFrequencyMinutes
            } else {
                0  # 0 = No restriction
            }
            Write-Log "Configuring Windows to allow restore points every $frequencyMinutes minutes" -Level INFO
            $frequencySet = Set-RestorePointFrequency -FrequencyMinutes $frequencyMinutes
            if (-not $frequencySet) {
                Write-Log "Failed to update restore point creation frequency registry setting" -Level WARNING
            }

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
    Write-Log "Script execution failed: $_" -Level ERROR -ErrorRecord $_
    Write-DetailedError -Operation "Main script execution" -ErrorRecord $_ -AdditionalContext @{
        Action = $Action
        ConfigPath = $ConfigPath
        Description = $Description
        Force = $Force.IsPresent
        SkipGUI = $SkipGUI.IsPresent
    }

    # Log any additional errors from the error stream
    if ($Error.Count -gt 0) {
        Write-Log "Additional errors in error stream: $($Error.Count)" -Level ERROR
        for ($i = 0; $i -lt [Math]::Min(5, $Error.Count); $i++) {
            Write-Log "Error [$i]: $($Error[$i].Exception.Message)" -Level ERROR
        }
    }

    exit 1
}
finally {
    # Stop transcript logging
    try {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        Write-Verbose "Transcript logging stopped"
    }
    catch {
        # Silently ignore transcript stop errors
    }

    # Cleanup and log rotation
    if ($script:LogPath -and (Test-Path $script:LogPath)) {
        $logFile = Get-Item $script:LogPath
        $logSize = $logFile.Length / 1MB
        $maxSize = $script:Config.Logging.MaxLogSizeMB
        $retentionDays = $script:Config.Logging.RetentionDays

        # Get file extension for archive naming
        $extension = $logFile.Extension

        # Check if rotation is needed (size-based)
        $needsRotation = $logSize -gt $maxSize

        # Check if rotation is needed (schedule-based - daily)
        if (-not $needsRotation -and $retentionDays -gt 0) {
            $logAge = (Get-Date) - $logFile.LastWriteTime
            if ($logAge.TotalDays -ge 1) {
                $needsRotation = $true
            }
        }

        if ($needsRotation) {
            $archivePath = $script:LogPath -replace "\$extension$", "_$(Get-Date -Format 'yyyyMMdd_HHmmss')$extension"
            Move-Item -Path $script:LogPath -Destination $archivePath -Force
            Write-Log "Log file archived to $archivePath" -Level INFO

            # Clean up old archived logs based on retention policy
            if ($retentionDays -gt 0) {
                $logDir = Split-Path $script:LogPath -Parent
                $logBaseName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogPath)
                $archivePattern = "$logBaseName`_*$extension"

                Get-ChildItem -Path $logDir -Filter $archivePattern -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
                    ForEach-Object {
                        Remove-Item $_.FullName -Force
                        Write-Log "Deleted old log archive: $($_.Name)" -Level INFO
                    }
            }
        }
    }
}

#endregion

