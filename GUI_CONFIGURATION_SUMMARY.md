# Manage-RestorePoints.ps1 - Feature Summary

## Overview
Enhanced `Manage-RestorePoints.ps1` with:
- **Self-installation** to system location (`%SystemDrive%\mytech.today\RestorePoints\`)
- **Interactive GUI** configuration dialog that appears before every run (unless `-SkipGUI` is specified)
- **Centralized logging** to `%SystemDrive%\mytech.today\logs\`
- **Consistent organization** following the same pattern as `app_installer\install.ps1`

## Version Update
- **Previous Version:** 1.3.0
- **New Version:** 1.4.0

## New Features

### 1. Self-Installation to System Location
The script automatically copies itself to a centralized system location on first run:
- **System Location:** `%SystemDrive%\mytech.today\RestorePoints\`
- **Automatic Copy:** Script, config.json, and documentation files
- **Preserves Configuration:** Existing config.json is never overwritten
- **Fallback:** If copy fails, continues from original location
- **Consistent Path:** Scheduled tasks and automation always use the system location
- **Centralized Logs:** All logs go to `%SystemDrive%\mytech.today\logs\`

**Benefits:**
- ✅ Reliable path for scheduled tasks
- ✅ Consistent with `app_installer\install.ps1` organization
- ✅ Easy to find and manage
- ✅ Survives user profile changes
- ✅ Works across all system drives (not hardcoded to C:)

### 2. Interactive GUI Before Every Run
By default, the GUI configuration dialog appears **before any action** is executed, allowing you to:
- Review current settings
- Modify configuration if needed
- Skip email notifications for this specific run
- Choose to save changes or continue without saving
- Cancel the operation entirely

To skip the GUI (for automated/scheduled tasks), use the `-SkipGUI` parameter.

### 2. GUI Configuration Dialog
The modal dialog window has three tabs for comprehensive configuration:

#### **Email Settings Tab**
Configure email notifications:
- **Enable Email Notifications** - Checkbox to enable/disable email alerts
- **SMTP Server** - Mail server address (e.g., smtp.gmail.com)
- **SMTP Port** - Port number (default: 587)
- **Use SSL/TLS** - Checkbox for secure connection
- **From Email** - Sender email address
- **To Email(s)** - Recipient email addresses (comma-separated for multiple)
- **Username** - SMTP authentication username
- **Password** - Masked password field (encrypted before saving)

#### **Restore Point Settings Tab**
Configure restore point behavior:
- **Disk Space Percent** - Percentage of disk space allocated (1-100%)
- **Minimum Restore Points** - Minimum number to maintain (1-100)
- **Maximum Restore Points** - Maximum number to keep (1-100)
- **Create On Schedule** - Checkbox to enable scheduled creation
- **Schedule Interval (minutes)** - How often to run monitoring (60-10080)
- **Creation Frequency (minutes)** - Minimum time between restore points (1-1440)

#### **Logging Settings Tab**
Configure logging behavior:
- **Log File Path** - Location of log file (with Browse button)
- **Max Log Size (MB)** - Maximum log file size before rotation (1-1000 MB)
- **Retention Days** - How long to keep logs (1-365 days)

### 2. Password Encryption
- Passwords are automatically encrypted using `ConvertFrom-SecureString` before saving
- Existing encrypted passwords are decrypted for display in the GUI
- Passwords are masked with asterisks (*) in the input field

### 3. Configuration Persistence
- All settings are saved to `config.json` in the script directory
- Configuration is automatically reloaded after saving
- Changes take effect immediately

### 4. Skip Email for This Run
A new checkbox at the bottom of the GUI allows you to skip email notifications for the current run only:
- **Checkbox:** "Skip Email Notification for This Run"
- **Temporary:** Only affects the current execution
- **Persistent Settings Unchanged:** Email configuration in config.json remains enabled
- **Useful For:** Testing, maintenance, or when you don't want to be notified for a specific action

### 5. Three Action Buttons
The GUI now has three buttons instead of two:
- **Save & Continue** - Saves configuration to config.json and proceeds with the action
- **Continue Without Saving** - Proceeds with current configuration without saving changes
- **Cancel** - Exits the script without performing any action

### 6. User Experience Improvements
- **Modal Dialog** - Blocks script execution until user makes a choice
- **Auto-Focus** - Form automatically brought to foreground and activated
- **TopMost Window** - Temporarily set as topmost to ensure visibility
- **Flexible Workflow** - Choose to save or not save changes
- **Browse Button** - File dialog for selecting log file path
- **Tab Navigation** - Organized settings into logical groups
- **Input Validation** - Numeric fields use spinners with min/max limits

## Technical Implementation

### Self-Installation Function: `Copy-ScriptToSystemLocation`
```powershell
function Copy-ScriptToSystemLocation {
    # Copies script to %SystemDrive%\mytech.today\RestorePoints\
    # Copies config.json (preserves existing)
    # Copies documentation files
    # Returns $true if successful, $false if failed
}
```

**Execution Flow:**
1. Script starts from any location
2. `Copy-ScriptToSystemLocation` is called immediately
3. Script and files are copied to system location
4. `$script:ScriptPath` is updated to system location
5. All subsequent operations use system location paths
6. Scheduled tasks reference system location

**Path Variables:**
```powershell
$script:OriginalScriptPath = $PSScriptRoot  # Where script was run from
$script:SystemInstallPath = "$env:SystemDrive\mytech.today\RestorePoints"
$script:ScriptPath = $script:SystemInstallPath  # Updated after copy
$script:CentralLogPath = "$env:SystemDrive\mytech.today\logs\"
```

### New Function: `Show-ConfigurationDialog`
```powershell
function Show-ConfigurationDialog {
    param([PSCustomObject]$CurrentConfig)
    # Creates Windows Forms GUI
    # Returns updated configuration object or $null if cancelled
}
```

### Focus Management
To ensure the GUI appears and gets focus properly:
```powershell
# Set form as topmost temporarily
$form.TopMost = $true

# Add event handler to activate and remove topmost when shown
$form.Add_Shown({
    $form.Activate()
    $form.TopMost = $false
})

# Show the dialog
$result = $form.ShowDialog()
```

This ensures:
- Form appears on top of all other windows initially
- Form gets keyboard focus when shown
- TopMost is removed after activation (so it doesn't stay on top)

### Modified Function: `Invoke-ConfigureRestorePoint`
- Now calls `Show-ConfigurationDialog` first
- Saves updated configuration to config.json
- Reloads configuration before proceeding
- Continues with System Restore setup after GUI closes

### Assembly Loading
Added at script initialization:
```powershell
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
```

## Usage Examples

### Interactive Run (Default - Shows GUI)
```powershell
# Create a restore point with GUI review
.\Manage-RestorePoints.ps1 -Action Create -Description "Before Update"
```

This will:
1. Show GUI configuration dialog
2. Allow you to review/modify settings
3. Allow you to skip email for this run
4. Choose to save changes or continue without saving
5. Create the restore point with the specified description

### Automated Run (Skip GUI)
```powershell
# For scheduled tasks or automation
.\Manage-RestorePoints.ps1 -Action Monitor -SkipGUI
```

This will:
1. Skip the GUI dialog
2. Use current configuration from config.json
3. Perform the Monitor action
4. Send email notifications (if enabled in config)

### Configure System Restore
```powershell
.\Manage-RestorePoints.ps1 -Action Configure
```

This will:
1. Show GUI dialog for configuration review
2. Save configuration if requested
3. Enable and configure System Restore
4. Create initial restore point
5. Set up scheduled task (with -SkipGUI parameter)

### Other Actions
```powershell
# List all restore points (with GUI review)
.\Manage-RestorePoints.ps1 -Action List

# List all restore points (without GUI)
.\Manage-RestorePoints.ps1 -Action List -SkipGUI

# Cleanup old restore points (with GUI review)
.\Manage-RestorePoints.ps1 -Action Cleanup

# Cleanup old restore points (without GUI)
.\Manage-RestorePoints.ps1 -Action Cleanup -SkipGUI
```

## Configuration File Format
The `config.json` file structure remains unchanged:

```json
{
  "RestorePoint": {
    "DiskSpacePercent": 10,
    "MinimumCount": 10,
    "MaximumCount": 20,
    "CreateOnSchedule": true,
    "ScheduleIntervalMinutes": 1440,
    "CreationFrequencyMinutes": 120
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

## Benefits

### For End Users
- **No manual JSON editing** - All settings configurable through GUI
- **Visual feedback** - See all settings at once in organized tabs
- **Password security** - Passwords are masked and encrypted
- **Error prevention** - Input validation prevents invalid values
- **Ease of use** - Point-and-click interface instead of text editing

### For Administrators
- **Faster deployment** - Quick setup on multiple machines
- **Reduced errors** - GUI prevents syntax errors in config file
- **Better documentation** - Field labels explain each setting
- **Consistent configuration** - Standardized interface across deployments

## Backward Compatibility
- Existing config.json files are fully compatible
- Command-line usage remains unchanged for other actions
- No breaking changes to existing functionality
- Script can still be run non-interactively for automation

## Testing Recommendations

1. **Test GUI Display**
   ```powershell
   .\Manage-RestorePoints.ps1 -Action Configure
   ```

2. **Test Configuration Save**
   - Modify settings in GUI
   - Click Save
   - Verify config.json contains new values

3. **Test Password Encryption**
   - Enter password in GUI
   - Save configuration
   - Check config.json shows encrypted password
   - Reopen GUI to verify password is decrypted correctly

4. **Test Cancel Functionality**
   - Open GUI
   - Modify settings
   - Click Cancel
   - Verify config.json is unchanged

5. **Test All Tabs**
   - Navigate through all three tabs
   - Verify all fields load correctly
   - Verify all fields save correctly

## Future Enhancements (Optional)

- **Test Email Button** - Send test email to verify SMTP settings
- **Validation Messages** - Show warnings for invalid combinations
- **Help Tooltips** - Hover tooltips explaining each field
- **Import/Export** - Load/save configuration from different files
- **Presets** - Common configuration templates (Gmail, Outlook, etc.)
- **Dark Mode** - Theme support for better visibility

## Files Modified

1. **RestorePoints/Manage-RestorePoints.ps1**
   - Added Windows Forms assembly loading
   - Added `Show-ConfigurationDialog` function (167 lines)
   - Modified `Invoke-ConfigureRestorePoint` function
   - Updated version from 1.3.0 to 1.4.0
   - Updated synopsis and description

## Lines of Code Added
- **GUI Function:** ~167 lines
- **Assembly Loading:** 2 lines
- **Configuration Logic:** ~30 lines
- **Documentation Updates:** ~10 lines
- **Total:** ~209 lines added

## Conclusion
The GUI configuration feature significantly improves the user experience for setting up the Restore Point Manager script. It eliminates the need for manual JSON editing and provides a professional, user-friendly interface for all configuration options.

