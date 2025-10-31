# Manage-RestorePoints.ps1

Comprehensive Windows System Restore Point management script with automated creation, monitoring, email notifications, and logging.

## Features

- ✅ **Automated Configuration** - Enables and configures System Restore with customizable disk space allocation (8-10%)
- ✅ **Automatic Scheduled Task Creation** - Creates Windows Scheduled Task automatically during configuration
- ✅ **Initial Restore Point** - Creates an initial restore point immediately after configuration
- ✅ **Scheduled Creation** - Creates restore points automatically on a configurable schedule (default: daily)
- ✅ **Intelligent Maintenance** - Maintains a minimum number of restore points (default: 10)
- ✅ **Email Notifications** - Sends notifications when restore points are created, deleted, or applied
- ✅ **Comprehensive Logging** - Logs all activities to a configurable file location
- ✅ **Error Handling** - Robust error handling with fallback mechanisms
- ✅ **Task Status Monitoring** - View scheduled task status with `-Action List`
- ✅ **Scriptable** - Can be triggered by other scripts for automated workflows

## Requirements

- **PowerShell**: 5.1 or later
- **Operating System**: Windows 10, Windows 11, Windows Server 2016/2019/2022
- **Privileges**: Administrator rights required
- **Modules**: No external modules required (uses built-in cmdlets)

## Installation

1. Clone or download the repository:
```powershell
git clone https://github.com/mytech-today-now/PowerShellScripts.git
cd PowerShellScripts/RestorePoints
```

2. Review and customize the configuration file:
```powershell
notepad config.json
```

3. Run the script with administrator privileges to configure System Restore:
```powershell
.\Manage-RestorePoints.ps1 -Action Configure
```

This will:
- Enable System Restore on the system drive
- Configure disk space allocation (default: 10%)
- Create an initial restore point
- Set up a Windows Scheduled Task for automatic monitoring (runs daily by default)
- Send email notification (if configured)

## Configuration

The script uses a JSON configuration file (`config.json`) with the following structure:

```json
{
  "RestorePoint": {
    "DiskSpacePercent": 10,
    "MinimumCount": 10,
    "MaximumCount": 20,
    "CreateOnSchedule": true,
    "ScheduleIntervalMinutes": 1440
  },
  "Email": {
    "Enabled": false,
    "SmtpServer": "smtp.example.com",
    "SmtpPort": 587,
    "UseSsl": true,
    "From": "restorepoint@example.com",
    "To": ["admin@example.com"],
    "Username": "",
    "PasswordEncrypted": ""
  },
  "Logging": {
    "LogPath": "Logs\\RestorePoint.log",
    "MaxLogSizeMB": 10,
    "RetentionDays": 30
  }
}
```

### Configuration Options

#### RestorePoint Settings
- **DiskSpacePercent** (8-100): Percentage of disk space allocated for restore points
- **MinimumCount** (1-100): Minimum number of restore points to maintain
- **MaximumCount** (1-100): Maximum number of restore points before cleanup
- **CreateOnSchedule** (true/false): Enable automatic restore point creation
- **ScheduleIntervalMinutes** (1-43200): Interval between automatic restore points (in minutes)

#### Email Settings
- **Enabled** (true/false): Enable email notifications
- **SmtpServer**: SMTP server address
- **SmtpPort**: SMTP server port (typically 587 for TLS, 25 for non-TLS)
- **UseSsl** (true/false): Use SSL/TLS encryption
- **From**: Sender email address
- **To**: Array of recipient email addresses
- **Username**: SMTP authentication username (optional)
- **PasswordEncrypted**: Encrypted password (use `ConvertFrom-SecureString`)

#### Logging Settings

**Note:** This script follows myTech.Today standards and logs to `C:\mytech.today\logs\` regardless of the config.json LogPath setting. Logs are written in markdown format with monthly rotation.

- **LogPath**: *(Deprecated - logs now written to `C:\mytech.today\logs\Manage-RestorePoints-yyyy-MM.md`)*
- **MaxLogSizeMB**: Maximum log file size before archiving
- **RetentionDays**: Number of days to retain archived logs

**Log File Location:**
- All logs are written to: `C:\mytech.today\logs\`
- Log file name format: `Manage-RestorePoints-yyyy-MM.md` (e.g., `Manage-RestorePoints-2025-10.md`)
- Logs are in markdown table format with icons (ℹ️ INFO, ⚠️ WARNING, ❌ ERROR, ✅ SUCCESS)
- Monthly rotation - one file per month
- Logs are never overwritten, always appended

### Encrypting Email Password

To encrypt your email password for the configuration file:

```powershell
# Create encrypted password
$password = Read-Host "Enter SMTP password" -AsSecureString
$encryptedPassword = ConvertFrom-SecureString $password

# Update config.json with the encrypted password
$config = Get-Content config.json | ConvertFrom-Json
$config.Email.PasswordEncrypted = $encryptedPassword
$config | ConvertTo-Json -Depth 10 | Set-Content config.json
```

## Usage

### Command-Line Parameters

```powershell
.\Manage-RestorePoints.ps1 [-Action <String>] [-ConfigPath <String>] [-Description <String>] [-Force]
```

#### Parameters

- **Action** (Configure | Create | List | Cleanup | Monitor)
  - `Configure`: Configures System Restore settings
  - `Create`: Creates a new restore point
  - `List`: Lists all available restore points
  - `Cleanup`: Performs cleanup of old restore points
  - `Monitor`: Monitors and maintains restore points (default)

- **ConfigPath** (optional): Path to custom configuration file
- **Description** (optional): Description for the restore point (used with `-Action Create`)
- **Force** (optional): Force creation even if a recent restore point exists

### Examples

#### Configure System Restore
```powershell
# Configure System Restore with default settings
.\Manage-RestorePoints.ps1 -Action Configure

# Configure with custom config file
.\Manage-RestorePoints.ps1 -Action Configure -ConfigPath "C:\Config\custom-config.json"
```

#### Create Restore Point
```powershell
# Create restore point with default description
.\Manage-RestorePoints.ps1 -Action Create

# Create restore point with custom description
.\Manage-RestorePoints.ps1 -Action Create -Description "Pre-Windows Update"

# Force creation even if recent restore point exists
.\Manage-RestorePoints.ps1 -Action Create -Description "Critical Backup" -Force
```

#### List Restore Points
```powershell
# List all available restore points
.\Manage-RestorePoints.ps1 -Action List
```

#### Cleanup Old Restore Points
```powershell
# Manually trigger cleanup
.\Manage-RestorePoints.ps1 -Action Cleanup
```

#### Monitor and Maintain
```powershell
# Run monitoring (creates restore points on schedule, performs cleanup)
.\Manage-RestorePoints.ps1 -Action Monitor

# This is the default action, so you can also just run:
.\Manage-RestorePoints.ps1
```

## Scheduled Task

### Automatic Setup (Recommended)

The script **automatically creates a Windows Scheduled Task** when you run:

```powershell
.\Manage-RestorePoints.ps1 -Action Configure
```

This creates a scheduled task at:
- **Task Path**: `\myTech.Today\`
- **Task Name**: `System Restore Point - Daily Monitoring`
- **Schedule**: Configurable via `ScheduleIntervalMinutes` in config.json (default: daily at midnight)
- **Runs As**: SYSTEM account with highest privileges
- **Action**: Executes the script with `-Action Monitor`

**Note:** All myTech.Today scripts create scheduled tasks in the `\myTech.Today\` folder for easy management.

### View Scheduled Task Status

```powershell
# View task status along with restore points
.\Manage-RestorePoints.ps1 -Action List
```

This displays:
- Task state (Ready, Running, Disabled)
- Last run time and result
- Next scheduled run time
- Trigger details

### Manual Setup (Advanced)

If you need to manually create a scheduled task with custom settings:

```powershell
# Create scheduled task with custom interval (e.g., every 6 hours)
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\Manage-RestorePoints.ps1" -Action Monitor'

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration ([TimeSpan]::MaxValue)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettings -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName "Custom Restore Point Task" `
    -TaskPath "\MyTasks\" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Custom System Restore Point management"
```

### Using Task Scheduler GUI
1. Open Task Scheduler (`taskschd.msc`)
2. Create Basic Task
3. Name: "Manage Restore Points"
4. Trigger: Daily (or your preferred schedule)
5. Action: Start a program
   - Program: `PowerShell.exe`
   - Arguments: `-ExecutionPolicy Bypass -File "C:\Path\To\Manage-RestorePoints.ps1" -Action Monitor`
6. Check "Run with highest privileges"

## Integration with Other Scripts

You can call this script from other automation scripts:

```powershell
# Example: Create restore point before software installation
& "C:\Scripts\Manage-RestorePoints.ps1" -Action Create -Description "Pre-Software Install" -Force

# Install software
Install-Software.ps1

# Verify installation
if ($LASTEXITCODE -eq 0) {
    Write-Host "Installation successful"
} else {
    Write-Host "Installation failed - restore point available for rollback"
}
```

## Logging

All script activities are logged to the file specified in the configuration. Log entries include:

- Timestamp
- Log level (INFO, WARNING, ERROR, SUCCESS)
- Detailed message

Example log output:
```
[2025-01-15 10:30:00] [INFO] === Manage-RestorePoints.ps1 v1.0.0 Started ===
[2025-01-15 10:30:00] [INFO] Action: Monitor
[2025-01-15 10:30:01] [INFO] Configuration loaded from config.json
[2025-01-15 10:30:01] [INFO] Starting restore point monitoring
[2025-01-15 10:30:02] [INFO] Current restore point count: 8 (Minimum: 10)
[2025-01-15 10:30:02] [WARNING] No restore points exist. Creating initial restore point.
[2025-01-15 10:30:05] [SUCCESS] Restore point created successfully: Scheduled Restore Point - 2025-01-15 10:30:02
[2025-01-15 10:30:05] [INFO] === Manage-RestorePoints.ps1 Completed ===
```

## Email Notifications

When email notifications are enabled, the script sends HTML-formatted emails for the following events:

### Restore Point Created
- Subject: "Restore Point Created - [COMPUTERNAME]"
- Includes: Computer name, date/time, description, status

### Restore Point Deleted
- Subject: "Restore Point Deleted - [COMPUTERNAME]"
- Includes: Computer name, date/time, description, creation date, reason

### Configuration Changed
- Subject: "System Restore Configured - [COMPUTERNAME]"
- Includes: Computer name, date/time, disk space allocated, status

## Troubleshooting

### Script requires administrator privileges
**Error**: "This script requires administrator privileges"

**Solution**: Run PowerShell as Administrator or run the script with elevated privileges

### System Restore is disabled
**Error**: "System Restore is not enabled"

**Solution**: Run with `-Action Configure` to enable and configure System Restore

### Cannot create restore point (24-hour limit)
**Error**: "A restore point was created X hours ago"

**Solution**: Use the `-Force` parameter to override the 24-hour Windows limitation

### Email notifications not working
**Error**: "Failed to send email notification"

**Solutions**:
- Verify SMTP server settings in config.json
- Check firewall rules for SMTP port
- Verify credentials (username/password)
- Test SMTP connectivity: `Test-NetConnection -ComputerName smtp.server.com -Port 587`

### Log file not created
**Error**: Log file path not accessible

**Solution**: Ensure the log directory exists and the script has write permissions

## Testing

The script includes comprehensive Pester tests for quality assurance.

### Running Tests
```powershell
# Install Pester if not already installed
Install-Module -Name Pester -Force -SkipPublisherCheck

# Run tests
Invoke-Pester -Path .\Tests\Manage-RestorePoints.Tests.ps1

# Run tests with code coverage
$config = New-PesterConfiguration
$config.Run.Path = '.\Tests\Manage-RestorePoints.Tests.ps1'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = '.\Manage-RestorePoints.ps1'
Invoke-Pester -Configuration $config
```

## Version History

### 1.0.0 (2025-01-15)
- Initial release
- System Restore configuration
- Automated restore point creation
- Email notifications
- Comprehensive logging
- Scheduled task support
- Error handling and fallback mechanisms

## Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

See LICENSE file in the repository root.

## Support

For issues, questions, or contributions:
- GitHub Issues: https://github.com/mytech-today-now/PowerShellScripts/issues
- Documentation: See `.augment/` folder for development guidelines

## Author

PowerShell Scripts Project
https://github.com/mytech-today-now/PowerShellScripts

