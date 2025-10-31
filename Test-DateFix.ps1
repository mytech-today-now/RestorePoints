#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Tests the date conversion fix for Manage-RestorePoints.ps1
#>

Write-Host "Testing date conversion fix..." -ForegroundColor Cyan

# Test the ConvertTo-DateTime function
function ConvertTo-DateTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )
    
    if ($Value -is [DateTime]) {
        return $Value
    }
    elseif ($Value -is [string]) {
        try {
            return [DateTime]::Parse($Value)
        }
        catch {
            Write-Warning "Failed to parse date string: $Value"
            return $null
        }
    }
    else {
        # Try to convert to DateTime
        try {
            return [DateTime]$Value
        }
        catch {
            Write-Warning "Failed to convert to DateTime: $Value"
            return $null
        }
    }
}

# Get restore points
Write-Host "`nGetting restore points..." -ForegroundColor Yellow
$restorePoints = Get-ComputerRestorePoint | Sort-Object CreationTime -Descending

if ($restorePoints) {
    Write-Host "Found $($restorePoints.Count) restore point(s)" -ForegroundColor Green
    
    foreach ($rp in $restorePoints) {
        Write-Host "`n--- Restore Point ---" -ForegroundColor Cyan
        Write-Host "Description: $($rp.Description)"
        Write-Host "Sequence Number: $($rp.SequenceNumber)"
        Write-Host "Creation Time (Raw): $($rp.CreationTime)"
        Write-Host "Creation Time Type: $($rp.CreationTime.GetType().FullName)"
        
        # Test conversion
        $convertedTime = ConvertTo-DateTime -Value $rp.CreationTime
        
        if ($convertedTime) {
            Write-Host "Converted Time: $convertedTime" -ForegroundColor Green
            
            # Test date arithmetic
            try {
                $timeSince = (Get-Date) - $convertedTime
                Write-Host "Time Since Creation: $([Math]::Round($timeSince.TotalHours, 2)) hours" -ForegroundColor Green
                Write-Host "Date arithmetic: SUCCESS" -ForegroundColor Green
            }
            catch {
                Write-Host "Date arithmetic: FAILED - $_" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Conversion: FAILED" -ForegroundColor Red
        }
    }
}
else {
    Write-Host "No restore points found" -ForegroundColor Yellow
}

Write-Host "`n`nTest complete!" -ForegroundColor Cyan

