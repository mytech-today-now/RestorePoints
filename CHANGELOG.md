# Changelog

All notable changes to the Manage-RestorePoints.ps1 project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2025-10-31

### Added - Restore Point Creation Frequency Control â±ï¸

- **Registry Configuration** ðŸ"§
  - Added `Set-RestorePointFrequency` function to configure Windows restore point creation frequency
  - Sets `SystemRestorePointCreationFrequency` registry value in `HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore`
  - Default frequency changed from 1440 minutes (24 hours) to 120 minutes (2 hours)
  - Allows more frequent restore point creation for better system protection

- **Configuration Parameter** âš™ï¸
  - Added `CreationFrequencyMinutes` parameter to `config.json`
  - Default value: 120 minutes (2 hours)
  - Configurable to any desired interval
  - Applied automatically during `Configure` action

### Changed

- **Enable-SystemRestore Function** ðŸ"
  - Added `FrequencyMinutes` parameter (default: 120)
  - Now calls `Set-RestorePointFrequency` during configuration
  - Improved error handling for frequency setting

- **Configuration Summary** ðŸ"Š
  - Added "Creation Frequency" to configuration summary output
  - Shows frequency in hours for better readability
  - Included in email notifications

### Technical Details

- Registry Path: `HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore`
- Registry Value: `SystemRestorePointCreationFrequency` (DWORD)
- Default Windows Value: 1440 minutes (24 hours)
- New Default Value: 120 minutes (2 hours)
- Value Type: DWORD (32-bit integer)

### Impact

âœ… **More Frequent Protection** - Restore points can be created every 2 hours instead of 24 hours
âœ… **Better Recovery Options** - More restore points available for system recovery
âœ… **Configurable** - Frequency can be adjusted via config.json
âœ… **Automatic Setup** - Applied during Configure action
âœ… **Backward Compatible** - Defaults to 120 minutes if not specified in config

### Configuration Example

```json
{
  "RestorePoint": {
    "DiskSpacePercent": 10,
    "MinimumCount": 10,
    "MaximumCount": 20,
    "CreateOnSchedule": true,
    "ScheduleIntervalMinutes": 1440,
    "CreationFrequencyMinutes": 120
  }
}
```

### Usage

The frequency is automatically configured when running:
```powershell
.\Manage-RestorePoints.ps1 -Action Configure
```

Output will include:
```
âœ… SUCCESS: Restore point creation frequency set to 120 minutes
â„¹ï¸ INFO: Windows will now allow restore points to be created every 2 hours
```

## [1.2.1] - 2025-10-31

### Fixed - ScheduledTasks Module Import ðŸ"§
- **Module Import Error** âŒ â†' âœ…
  - Added explicit import of ScheduledTasks module at script startup
  - Fixed error: "The term 'New-ScheduledTaskSettings' is not recognized"
  - Added graceful error handling if ScheduledTasks module is not available
  - Added module availability check before creating scheduled tasks
  - Script now works on systems where ScheduledTasks module may not be loaded by default

### Changed
- **Error Handling** ðŸ›¡ï¸
  - Improved error messages for scheduled task creation failures
  - Added informative warnings when ScheduledTasks module is unavailable
  - Better user feedback about module requirements (Windows Server 2012 R2 / Windows 8.1+)

### Technical Details
- Added `Import-Module ScheduledTasks` with try-catch error handling
- Added module availability check in `New-RestorePointScheduledTask` function
- Updated script version to 1.2.1
- Updated author to myTech.Today in script header

### Impact
- âœ… Scheduled task creation now works reliably on all supported Windows versions
- âœ… Better error messages help users understand module requirements
- âœ… Script continues to function even if scheduled tasks cannot be created
- âœ… No breaking changes - all existing functionality preserved

## [1.2.0] - 2025-10-30

### Changed - myTech.Today Standardization
- **Scheduled Task Location** ðŸ"
  - Tasks now created in `\myTech.Today\` folder at root of Task Scheduler
  - Changed from `\Microsoft\Windows\SystemRestore\` to align with repository standards
  - Easier to find and manage all myTech.Today tasks in one location
- **Centralized Logging** ðŸ"
  - All logs now written to `C:\mytech.today\logs\` directory
  - Script-specific log files: `Manage-RestorePoints-yyyy-MM.md`
  - Monthly log rotation (one file per month)
  - Logs never overwritten - always appended
- **Markdown Log Format** âœ¨
  - Logs now written in markdown table format with icons
  - Better readability and formatting
  - Icons: â„¹ï¸ INFO, âš ï¸ WARNING, âŒ ERROR, âœ… SUCCESS
  - Log files include header with script version, computer name, user, etc.
  - Example log entry: `| 2025-10-30 12:00:01 | âœ… **SUCCESS** | Operation completed |`

### Added
- `$script:CentralLogPath` variable for centralized log directory
- Automatic creation of `C:\mytech.today\logs\` directory if it doesn't exist
- Markdown log file initialization with formatted header and table structure
- Monthly log file naming convention

### Updated
- Script version to 1.2.0
- `$script:ScheduledTaskPath` changed to `\myTech.Today\`
- `Write-Log` function to output markdown-formatted table rows with icons
- Log initialization to create markdown header with metadata
- `.augment/guidelines.md` with myTech.Today project standards for:
  - Scheduled task folder location
  - Centralized logging requirements
  - Markdown log format specifications

### Impact
- âœ… All myTech.Today tasks in one Task Scheduler folder
- âœ… All myTech.Today logs in one central directory
- âœ… Logs are human-readable markdown files
- âœ… Easy to view logs in any markdown viewer
- âœ… Monthly log rotation prevents files from growing too large
- âœ… No breaking changes to functionality
- âœ… Existing tasks will be recreated in new location on next configuration

## [1.1.0] - 2025-10-29

### Added
- **Automatic Scheduled Task Creation** ðŸŽ¯
  - `Invoke-ConfigureRestorePoint` now automatically creates a Windows Scheduled Task
  - Task runs the script with `-Action Monitor` on a configurable schedule
  - Default: Daily at midnight (configurable via `ScheduleIntervalMinutes` in config.json)
  - Task runs as SYSTEM with highest privileges
  - Task path: `\Microsoft\Windows\SystemRestore\System Restore Point - Daily Monitoring`
  - Automatically removes and recreates task if it already exists
- **Initial Restore Point Creation** ðŸ"
  - `Invoke-ConfigureRestorePoint` now creates an initial restore point immediately after configuration
  - Description: "Initial Restore Point - Configuration Complete"
  - Uses `-Force` flag to bypass 24-hour restriction
- **New Functions**
  - `New-RestorePointScheduledTask` - Creates the scheduled task
  - `Remove-RestorePointScheduledTask` - Removes the scheduled task
  - `Get-RestorePointScheduledTaskStatus` - Displays scheduled task status and details
- **Enhanced List Action**
  - Now displays scheduled task status when listing restore points
  - Shows task state, last run time, next run time, and trigger details
- **Configuration Summary**
  - `Invoke-ConfigureRestorePoint` now displays a comprehensive summary:
    - System Restore status
    - Disk space allocation
    - Initial restore point creation status
    - Scheduled task creation status
    - Schedule interval

### Changed
- Updated version to 1.1.0
- Enhanced `Invoke-ConfigureRestorePoint` to be a complete setup function
- Email notification now includes initial restore point and scheduled task status
- Script variables now include `$script:ScheduledTaskName` and `$script:ScheduledTaskPath`

### Improved
- Better error handling for scheduled task operations
- More informative console output during configuration
- Scheduled task includes config path in arguments for proper configuration loading

## [1.0.2] - 2025-10-29

### Fixed
- Fixed WMI datetime format parsing (format: `20251029133027.347135-000`)
  - Enhanced `ConvertTo-DateTime` to detect and parse WMI datetime strings
  - Extracts year, month, day, hour, minute, second from WMI format
  - Converts to standard .NET DateTime object for arithmetic operations

### Improved
- Enhanced user feedback and console output
  - INFO messages now display to console by default (not just with -Verbose)
  - Added detailed progress messages during monitoring
  - Shows time until next scheduled restore point
  - Displays whether scheduled creation is enabled/disabled
  - Better feedback when no action is needed
- Improved `Invoke-ListRestorePoints` output
  - Displays formatted table with restore point details
  - Shows "time ago" for each restore point (e.g., "2.5 hours ago", "3 days ago")
  - Color-coded output for better readability
  - Helpful message when no restore points exist
- Enhanced `Invoke-MonitorRestorePoints` feedback
  - Shows schedule interval and time since last restore point
  - Displays time until next scheduled restore point
  - Indicates when cleanup is being checked
  - More informative completion messages

## [1.0.1] - 2025-10-29

### Fixed
- Fixed "Multiple ambiguous overloads found for 'op_Subtraction'" error when performing date arithmetic
  - Added `ConvertTo-DateTime` helper function to safely convert CreationTime values
  - Updated `Invoke-CreateRestorePoint` to use the new conversion function
  - Updated `Invoke-MonitorRestorePoints` to use the new conversion function
  - Now works correctly across different PowerShell versions (5.1, 7.x) and Windows versions
- Improved error handling for date conversion failures

### Changed
- MaximumCount default changed from 20 to 30 (user configuration)

## [1.0.0] - 2025-10-29

### Added
- Initial release of Manage-RestorePoints.ps1
- System Restore configuration functionality
  - Enable System Restore on Windows system drive
  - Configure disk space allocation (8-10% minimum, configurable)
  - Verify and update existing configurations
- Automated restore point creation
  - Manual creation with custom descriptions
  - Scheduled automatic creation (configurable intervals)
  - Force creation option to override 24-hour Windows limitation
- Restore point maintenance
  - Maintain minimum number of restore points (default: 10)
  - Automatic cleanup of oldest points when exceeding maximum (default: 20)
  - Intelligent monitoring and maintenance
- Email notification system
  - HTML-formatted email templates
  - Notifications for restore point creation
  - Notifications for restore point deletion
  - Notifications for System Restore configuration changes
  - Configurable SMTP settings with SSL/TLS support
  - Support for encrypted password storage
- Comprehensive logging system
  - Configurable log file location
  - Timestamp and log level for each entry (INFO, WARNING, ERROR, SUCCESS)
  - Automatic log rotation when size limit exceeded
  - Configurable log retention
- Error handling and fallback mechanisms
  - Try-catch blocks for all critical operations
  - Graceful degradation on failures
  - Detailed error logging
- Integration support
  - Can be triggered by other scripts
  - Support for scheduled task execution
  - Command-line parameter support
- Configuration management
  - JSON-based configuration file
  - Default configuration auto-generation
  - Customizable settings for all features
- Five action modes
  - Configure: Set up System Restore settings
  - Create: Create a new restore point
  - List: Display all available restore points
  - Cleanup: Manually trigger cleanup of old restore points
  - Monitor: Automated monitoring and maintenance (default)
- Comprehensive documentation
  - Complete README.md with installation and usage instructions
  - Comment-based help for all functions
  - Configuration guide with examples
  - Troubleshooting section
  - Integration examples
- Testing infrastructure
  - Comprehensive Pester test suite (300+ lines)
  - Test runner script (Run-Tests.ps1)
  - Code coverage reporting
  - Target: 98% code coverage
- PowerShell best practices compliance
  - Approved verb usage (Get, Set, New, Invoke, etc.)
  - Comment-based help for all functions
  - Parameter validation
  - ShouldProcess support for destructive operations
  - Pipeline support where applicable
  - Proper error handling with ErrorAction
  - Verbose and debug output support

### Security
- Secure credential storage using encrypted passwords
- Input validation for all parameters
- Administrator privilege verification
- No hardcoded credentials
- Secure SMTP authentication support

### Platform Support
- Windows 10 (1809 or later)
- Windows 11
- Windows Server 2016
- Windows Server 2019
- Windows Server 2022
- PowerShell 5.1 or later
- Requires Administrator privileges

### Files
- `Manage-RestorePoints.ps1` - Main script (648 lines)
- `config.json` - Configuration file
- `README.md` - Comprehensive documentation
- `CHANGELOG.md` - Version history (this file)
- `Run-Tests.ps1` - Test execution script
- `Tests/Manage-RestorePoints.Tests.ps1` - Pester test suite

### Related Issues
- GitHub Issue #1: Enhancement: Implement Manage-RestorePoints.ps1 - Automated System Restore Point Management

[Unreleased]: https://github.com/mytech-today-now/PowerShellScripts/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/mytech-today-now/PowerShellScripts/releases/tag/v1.0.0

