<#
.SYNOPSIS
    Runs Pester tests for Manage-RestorePoints.ps1 with code coverage analysis.

.DESCRIPTION
    This script installs Pester if needed and runs the test suite with code coverage reporting.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$InstallPester
)

# Check if Pester is installed
$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1

if (-not $pesterModule -or $InstallPester) {
    Write-Host "Installing Pester module..." -ForegroundColor Cyan
    try {
        Install-Module -Name Pester -Force -SkipPublisherCheck -Scope CurrentUser -MinimumVersion 5.0.0
        Write-Host "Pester installed successfully" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to install Pester: $_"
        exit 1
    }
}
else {
    Write-Host "Pester version $($pesterModule.Version) is installed" -ForegroundColor Green
}

# Import Pester
Import-Module Pester -MinimumVersion 5.0.0

# Configure Pester
$config = New-PesterConfiguration

# Set paths
$config.Run.Path = Join-Path $PSScriptRoot 'Tests\Manage-RestorePoints.Tests.ps1'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = Join-Path $PSScriptRoot 'Manage-RestorePoints.ps1'
$config.CodeCoverage.OutputPath = Join-Path $PSScriptRoot 'Tests\coverage.xml'
$config.Output.Verbosity = 'Detailed'

# Test results
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'Tests\testResults.xml'

Write-Host "`nRunning Pester tests..." -ForegroundColor Cyan
Write-Host "Test Path: $($config.Run.Path)" -ForegroundColor Gray
Write-Host "Code Coverage Path: $($config.CodeCoverage.Path)" -ForegroundColor Gray

# Run tests
$result = Invoke-Pester -Configuration $config

# Display results
Write-Host "`n=== Test Results ===" -ForegroundColor Cyan
Write-Host "Total Tests: $($result.TotalCount)" -ForegroundColor White
Write-Host "Passed: $($result.PassedCount)" -ForegroundColor Green
Write-Host "Failed: $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Skipped: $($result.SkippedCount)" -ForegroundColor Yellow

if ($result.CodeCoverage) {
    $coveragePercent = [math]::Round(($result.CodeCoverage.CoveragePercent), 2)
    Write-Host "`n=== Code Coverage ===" -ForegroundColor Cyan
    Write-Host "Coverage: $coveragePercent%" -ForegroundColor $(if ($coveragePercent -ge 98) { 'Green' } elseif ($coveragePercent -ge 80) { 'Yellow' } else { 'Red' })
    Write-Host "Covered Commands: $($result.CodeCoverage.CommandsExecutedCount) / $($result.CodeCoverage.CommandsAnalyzedCount)" -ForegroundColor White
    
    if ($coveragePercent -lt 98) {
        Write-Host "`nWARNING: Code coverage is below 98% target" -ForegroundColor Yellow
        
        # Show missed commands
        if ($result.CodeCoverage.CommandsMissed) {
            Write-Host "`nMissed Commands:" -ForegroundColor Yellow
            $result.CodeCoverage.CommandsMissed | 
                Select-Object -First 10 File, Line, Function |
                Format-Table -AutoSize
        }
    }
    else {
        Write-Host "`nâœ" Code coverage meets 98% target!" -ForegroundColor Green
    }
}

# Exit with appropriate code
if ($result.FailedCount -gt 0) {
    Write-Host "`nâœ— Tests failed" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`nâœ" All tests passed" -ForegroundColor Green
    exit 0
}

