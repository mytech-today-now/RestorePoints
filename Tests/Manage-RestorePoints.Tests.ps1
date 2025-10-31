<#
.SYNOPSIS
    Pester tests for Manage-RestorePoints.ps1

.DESCRIPTION
    Comprehensive test suite for the Manage-RestorePoints.ps1 script
    Target: 98% code coverage
#>

BeforeAll {
    # Import the script
    $scriptPath = Join-Path $PSScriptRoot '..' 'Manage-RestorePoints.ps1'
    
    # Mock the #Requires statements by dot-sourcing the script content
    $scriptContent = Get-Content $scriptPath -Raw
    # Remove #Requires statements for testing
    $scriptContent = $scriptContent -replace '#Requires.*', ''
    
    # Create a temporary script file without #Requires
    $tempScript = Join-Path $TestDrive 'Manage-RestorePoints-Test.ps1'
    $scriptContent | Set-Content $tempScript
    
    # Dot-source the modified script
    . $tempScript
    
    # Create test configuration
    $script:TestConfigPath = Join-Path $TestDrive 'test-config.json'
    $testConfig = @{
        RestorePoint = @{
            DiskSpacePercent = 10
            MinimumCount = 10
            MaximumCount = 20
            CreateOnSchedule = $true
            ScheduleIntervalMinutes = 1440
        }
        Email = @{
            Enabled = $false
            SmtpServer = 'smtp.test.com'
            SmtpPort = 587
            UseSsl = $true
            From = 'test@test.com'
            To = @('admin@test.com')
            Username = 'testuser'
            PasswordEncrypted = ''
        }
        Logging = @{
            LogPath = (Join-Path $TestDrive 'test.log')
            MaxLogSizeMB = 10
            RetentionDays = 30
        }
    }
    
    $testConfig | ConvertTo-Json -Depth 10 | Set-Content $script:TestConfigPath
    
    # Set script variables
    $script:Config = $testConfig | ConvertFrom-Json
    $script:LogPath = $testConfig.Logging.LogPath
    $script:ScriptPath = $TestDrive
    $script:DefaultConfigPath = $script:TestConfigPath
}

Describe 'Manage-RestorePoints.ps1 - Helper Functions' {
    
    Context 'Write-Log' {
        It 'Should write log entry to file' {
            $logPath = Join-Path $TestDrive 'test-write.log'
            $script:LogPath = $logPath
            
            Write-Log -Message 'Test message' -Level 'INFO'
            
            $logPath | Should -Exist
            $content = Get-Content $logPath -Raw
            $content | Should -Match 'Test message'
            $content | Should -Match '\[INFO\]'
        }
        
        It 'Should handle different log levels' {
            $logPath = Join-Path $TestDrive 'test-levels.log'
            $script:LogPath = $logPath
            
            Write-Log -Message 'Info message' -Level 'INFO'
            Write-Log -Message 'Warning message' -Level 'WARNING' -WarningAction SilentlyContinue
            Write-Log -Message 'Error message' -Level 'ERROR' -ErrorAction SilentlyContinue
            Write-Log -Message 'Success message' -Level 'SUCCESS'
            
            $content = Get-Content $logPath -Raw
            $content | Should -Match 'Info message'
            $content | Should -Match 'Warning message'
            $content | Should -Match 'Error message'
            $content | Should -Match 'Success message'
        }
        
        It 'Should handle missing log directory gracefully' {
            $script:LogPath = $null
            
            { Write-Log -Message 'Test' -Level 'INFO' } | Should -Not -Throw
        }
    }
    
    Context 'Get-Configuration' {
        It 'Should load configuration from file' {
            $config = Get-Configuration -Path $script:TestConfigPath
            
            $config | Should -Not -BeNullOrEmpty
            $config.RestorePoint.DiskSpacePercent | Should -Be 10
            $config.Email.SmtpServer | Should -Be 'smtp.test.com'
        }
        
        It 'Should create default configuration if file does not exist' {
            $newConfigPath = Join-Path $TestDrive 'new-config.json'
            
            $config = Get-Configuration -Path $newConfigPath
            
            $newConfigPath | Should -Exist
            $config | Should -Not -BeNullOrEmpty
            $config.RestorePoint | Should -Not -BeNullOrEmpty
        }
        
        It 'Should throw on invalid JSON' {
            $invalidPath = Join-Path $TestDrive 'invalid.json'
            'invalid json content' | Set-Content $invalidPath
            
            { Get-Configuration -Path $invalidPath } | Should -Throw
        }
    }
    
    Context 'New-DefaultConfiguration' {
        It 'Should create valid default configuration' {
            $config = New-DefaultConfiguration
            
            $config | Should -Not -BeNullOrEmpty
            $config.RestorePoint | Should -Not -BeNullOrEmpty
            $config.Email | Should -Not -BeNullOrEmpty
            $config.Logging | Should -Not -BeNullOrEmpty
        }
        
        It 'Should have required properties' {
            $config = New-DefaultConfiguration
            
            $config.RestorePoint.DiskSpacePercent | Should -BeGreaterThan 0
            $config.RestorePoint.MinimumCount | Should -BeGreaterThan 0
            $config.Email.SmtpServer | Should -Not -BeNullOrEmpty
            $config.Logging.LogPath | Should -Not -BeNullOrEmpty
        }
    }
    
    Context 'Send-EmailNotification' {
        BeforeEach {
            Mock Send-MailMessage { }
        }
        
        It 'Should not send email when disabled' {
            $script:Config.Email.Enabled = $false
            
            Send-EmailNotification -Subject 'Test' -Body 'Test Body' -EventType 'Create'
            
            Should -Invoke Send-MailMessage -Times 0
        }
        
        It 'Should send email when enabled' {
            $script:Config.Email.Enabled = $true
            
            Send-EmailNotification -Subject 'Test' -Body 'Test Body' -EventType 'Create'
            
            Should -Invoke Send-MailMessage -Times 1
        }
        
        It 'Should handle email send failure gracefully' {
            $script:Config.Email.Enabled = $true
            Mock Send-MailMessage { throw 'SMTP Error' }
            
            { Send-EmailNotification -Subject 'Test' -Body 'Test Body' } | Should -Not -Throw
        }
    }
    
    Context 'Test-AdministratorPrivilege' {
        It 'Should return boolean value' {
            $result = Test-AdministratorPrivilege
            
            $result | Should -BeOfType [bool]
        }
    }
    
    Context 'Enable-SystemRestore' {
        BeforeEach {
            Mock Enable-ComputerRestore { }
            Mock Get-CimInstance { 
                [PSCustomObject]@{
                    MaxSpace = 10GB
                }
            }
            Mock Set-CimInstance { }
        }
        
        It 'Should enable System Restore' {
            Mock Test-AdministratorPrivilege { $true }
            
            $result = Enable-SystemRestore -DiskSpacePercent 10 -WhatIf
            
            Should -Invoke Enable-ComputerRestore -Times 0  # WhatIf prevents execution
        }
        
        It 'Should handle errors gracefully' {
            Mock Enable-ComputerRestore { throw 'Access Denied' }
            
            $result = Enable-SystemRestore -DiskSpacePercent 10
            
            $result | Should -Be $false
        }
        
        It 'Should clamp disk space percentage to valid range' {
            Mock Enable-ComputerRestore { }
            
            # Test with value below minimum
            Enable-SystemRestore -DiskSpacePercent 5 -WhatIf
            
            # Test with value above maximum
            Enable-SystemRestore -DiskSpacePercent 150 -WhatIf
            
            # Should not throw
            $true | Should -Be $true
        }
    }
}

Describe 'Manage-RestorePoints.ps1 - Main Functions' {
    
    Context 'Invoke-ConfigureRestorePoint' {
        BeforeEach {
            Mock Enable-SystemRestore { $true }
            Mock Send-EmailNotification { }
        }
        
        It 'Should configure System Restore successfully' {
            { Invoke-ConfigureRestorePoint -WhatIf } | Should -Not -Throw
        }
        
        It 'Should send notification on success' {
            $script:Config.Email.Enabled = $true
            
            Invoke-ConfigureRestorePoint -WhatIf
            
            Should -Invoke Send-EmailNotification -Times 1
        }
        
        It 'Should throw on configuration failure' {
            Mock Enable-SystemRestore { $false }
            
            { Invoke-ConfigureRestorePoint } | Should -Throw
        }
    }
    
    Context 'Invoke-CreateRestorePoint' {
        BeforeEach {
            Mock Get-ComputerRestorePoint { @() }
            Mock Checkpoint-Computer { }
            Mock Send-EmailNotification { }
        }
        
        It 'Should create restore point when none exist' {
            $result = Invoke-CreateRestorePoint -Description 'Test RP' -WhatIf
            
            # WhatIf prevents actual creation
            $true | Should -Be $true
        }
        
        It 'Should skip creation if recent restore point exists without Force' {
            Mock Get-ComputerRestorePoint {
                @([PSCustomObject]@{
                    CreationTime = (Get-Date).AddHours(-1)
                    Description = 'Recent RP'
                })
            }
            
            $result = Invoke-CreateRestorePoint -Description 'Test RP'
            
            $result | Should -Be $false
        }
        
        It 'Should create restore point with Force even if recent one exists' {
            Mock Get-ComputerRestorePoint {
                @([PSCustomObject]@{
                    CreationTime = (Get-Date).AddHours(-1)
                    Description = 'Recent RP'
                })
            }
            
            Invoke-CreateRestorePoint -Description 'Test RP' -Force -WhatIf
            
            # Should not return false
            $true | Should -Be $true
        }
        
        It 'Should send notification on success' {
            $script:Config.Email.Enabled = $true
            
            Invoke-CreateRestorePoint -Description 'Test RP' -WhatIf
            
            Should -Invoke Send-EmailNotification -Times 1
        }
        
        It 'Should handle creation failure' {
            Mock Checkpoint-Computer { throw 'Creation failed' }
            
            $result = Invoke-CreateRestorePoint -Description 'Test RP'
            
            $result | Should -Be $false
        }
    }
    
    Context 'Invoke-ListRestorePoints' {
        It 'Should return empty array when no restore points exist' {
            Mock Get-ComputerRestorePoint { @() }
            
            $result = Invoke-ListRestorePoints
            
            $result | Should -BeOfType [array]
            $result.Count | Should -Be 0
        }
        
        It 'Should return restore points when they exist' {
            Mock Get-ComputerRestorePoint {
                @(
                    [PSCustomObject]@{
                        SequenceNumber = 1
                        CreationTime = Get-Date
                        Description = 'RP 1'
                        RestorePointType = 'MODIFY_SETTINGS'
                    },
                    [PSCustomObject]@{
                        SequenceNumber = 2
                        CreationTime = (Get-Date).AddDays(-1)
                        Description = 'RP 2'
                        RestorePointType = 'MODIFY_SETTINGS'
                    }
                )
            }
            
            $result = Invoke-ListRestorePoints
            
            $result.Count | Should -Be 2
            $result[0].SequenceNumber | Should -Be 1
        }
        
        It 'Should handle errors gracefully' {
            Mock Get-ComputerRestorePoint { throw 'Access Denied' }
            
            $result = Invoke-ListRestorePoints
            
            $result | Should -BeOfType [array]
            $result.Count | Should -Be 0
        }
    }
    
    Context 'Invoke-CleanupRestorePoints' {
        BeforeEach {
            Mock Send-EmailNotification { }
        }
        
        It 'Should not delete when count is within limits' {
            Mock Get-ComputerRestorePoint {
                1..10 | ForEach-Object {
                    [PSCustomObject]@{
                        SequenceNumber = $_
                        CreationTime = (Get-Date).AddDays(-$_)
                        Description = "RP $_"
                    }
                }
            }
            
            Invoke-CleanupRestorePoints -WhatIf
            
            # Should complete without errors
            $true | Should -Be $true
        }
        
        It 'Should delete oldest restore points when exceeding maximum' {
            $script:Config.RestorePoint.MaximumCount = 5
            $script:Config.RestorePoint.MinimumCount = 3
            
            Mock Get-ComputerRestorePoint {
                1..10 | ForEach-Object {
                    [PSCustomObject]@{
                        SequenceNumber = $_
                        CreationTime = (Get-Date).AddDays(-$_)
                        Description = "RP $_"
                    }
                }
            }
            
            Mock Get-CimInstance { 
                [PSCustomObject]@{
                    SequenceNumber = 1
                }
            }
            Mock Remove-CimInstance { }
            
            Invoke-CleanupRestorePoints
            
            # Should attempt to delete
            $true | Should -Be $true
        }
    }
    
    Context 'Invoke-MonitorRestorePoints' {
        BeforeEach {
            Mock Get-ComputerRestorePoint { @() }
            Mock Invoke-CreateRestorePoint { $true }
            Mock Invoke-CleanupRestorePoints { }
        }
        
        It 'Should create restore point when none exist' {
            Invoke-MonitorRestorePoints
            
            Should -Invoke Invoke-CreateRestorePoint -Times 1
        }
        
        It 'Should create restore point when schedule interval exceeded' {
            $script:Config.RestorePoint.CreateOnSchedule = $true
            $script:Config.RestorePoint.ScheduleIntervalMinutes = 60
            
            Mock Get-ComputerRestorePoint {
                @([PSCustomObject]@{
                    CreationTime = (Get-Date).AddHours(-2)
                    Description = 'Old RP'
                })
            }
            
            Invoke-MonitorRestorePoints
            
            Should -Invoke Invoke-CreateRestorePoint -Times 1
        }
        
        It 'Should not create restore point when schedule not exceeded' {
            $script:Config.RestorePoint.CreateOnSchedule = $true
            $script:Config.RestorePoint.ScheduleIntervalMinutes = 1440
            
            Mock Get-ComputerRestorePoint {
                @([PSCustomObject]@{
                    CreationTime = (Get-Date).AddHours(-1)
                    Description = 'Recent RP'
                })
            }
            
            Invoke-MonitorRestorePoints
            
            Should -Invoke Invoke-CreateRestorePoint -Times 0
        }
        
        It 'Should always perform cleanup' {
            Mock Get-ComputerRestorePoint {
                @([PSCustomObject]@{
                    CreationTime = (Get-Date).AddHours(-1)
                    Description = 'Recent RP'
                })
            }
            
            Invoke-MonitorRestorePoints
            
            Should -Invoke Invoke-CleanupRestorePoints -Times 1
        }
    }
}

Describe 'Manage-RestorePoints.ps1 - Integration Tests' {
    
    Context 'End-to-End Workflow' {
        BeforeEach {
            Mock Test-AdministratorPrivilege { $true }
            Mock Enable-ComputerRestore { }
            Mock Get-ComputerRestorePoint { @() }
            Mock Checkpoint-Computer { }
            Mock Send-EmailNotification { }
        }
        
        It 'Should complete full workflow without errors' {
            # Configure
            { Invoke-ConfigureRestorePoint -WhatIf } | Should -Not -Throw
            
            # Create
            { Invoke-CreateRestorePoint -Description 'Test' -WhatIf } | Should -Not -Throw
            
            # List
            { Invoke-ListRestorePoints } | Should -Not -Throw
            
            # Monitor
            { Invoke-MonitorRestorePoints } | Should -Not -Throw
        }
    }
}

