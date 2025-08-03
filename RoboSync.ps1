# Get the directory where the script is running
$scriptDir = Split-Path (Convert-Path -LiteralPath ([Environment]::GetCommandLineArgs()[0]))

# Load configuration from a JSON file in the script's directory
$configPath = Join-Path $scriptDir "config.json"
if (-Not (Test-Path $configPath)) {
    Write-Error "Configuration file not found at $configPath"
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# Validate configuration 
if (-Not $config.SourceDir -or -Not $config.DestDirs -or -Not $config.Exclusions) {
    Write-Error "Invalid configuration file. Please ensure it contains 'SourceDir', 'DestDirs', and 'Exclusions'."
    exit 1
}

# Define paths for the log files
$errorLogPath = Join-Path $scriptDir "error.log"
$runLogPath = Join-Path $scriptDir "run.log"
$testLogPath = Join-Path $scriptDir "test.log"

# Function to run robocopy in test mode (/L)
function Test-Robocopy {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [array]$DestDirs,
        
        [Parameter(Mandatory=$true)]
        [string]$Options,
        
        [Parameter(Mandatory=$true)]
        [array]$Exclusions
    )

    try {
        $startTime = Get-Date
        Add-Content -Path $testLogPath -Value "`n[$startTime] - Robocopy TEST operation started (list-only mode)."

        foreach ($DestDir in $DestDirs) {
            # Build the robocopy command with exclusions and /L (list-only) parameter
            $exclusionParams = ""
            if ($Exclusions) {
                foreach ($exclusion in $Exclusions) {
                    $exclusionParams += " /XD $exclusion"
                }
            }

            $cmd = "robocopy $SourceDir $DestDir $Options /L $exclusionParams"
            Add-Content -Path $testLogPath -Value "`nTEST COMMAND: $cmd"
            
            # Run the test and capture output
            $output = & cmd.exe /c $cmd 2>&1
            Add-Content -Path $testLogPath -Value $output

            # Check for serious errors (not just informational messages)
            if ($output -match "ERROR") {
                Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - TEST MODE ERRORS for destination '$DestDir':"
                Add-Content -Path $errorLogPath -Value ($output -match "ERROR")
                return $false
            }
        }

        $stopTime = Get-Date
        $duration = $stopTime - $startTime
        Add-Content -Path $testLogPath -Value "[$stopTime] - Robocopy TEST operation completed. Duration: $duration."
        return $true
    } catch {
        $errorMsg = $_.Exception.Message
        Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - TEST MODE UNEXPECTED ERROR: $errorMsg"
        return $false
    }
}

# Function to start actual robocopy
function Start-Robocopy {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [array]$DestDirs,
        
        [Parameter(Mandatory=$true)]
        [string]$Options,
        
        [Parameter(Mandatory=$true)]
        [array]$Exclusions
    )

    try {
        $startTime = Get-Date
        Add-Content -Path $runLogPath -Value "`n[$startTime] - Robocopy operation started."

        foreach ($DestDir in $DestDirs) {
            $exclusionParams = ""
            if ($Exclusions) {
                foreach ($exclusion in $Exclusions) {
                    $exclusionParams += " /XD $exclusion"
                }
            }

            $cmd = "robocopy $SourceDir $DestDir $Options $exclusionParams"
            $output = & cmd.exe /c $cmd 2>&1 | Where-Object { $_ -match "ERROR" }

            if ($output) {
                Add-Content -Path $errorLogPath -Value "`n[$startTime] - Errors encountered:"
                Add-Content -Path $errorLogPath -Value $output
            } else {
                Write-Host "Robocopy completed successfully for $DestDir"
            }

            $stopTime = Get-Date
            $duration = $stopTime - $startTime
            Add-Content -Path $runLogPath -Value "[$stopTime] - Robocopy operation completed for destination '$DestDir'. Duration: $duration."
            New-BurntToastNotification -Text "RoboCopy Task Completed", "Robocopy completed successfully for $DestDir"
        }

        Add-Content -Path $runLogPath -Value "Robocopy operation completed."
    } catch {
        $errorMsg = $_.Exception.Message
        Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - Unexpected error: $errorMsg"
        Write-Error "An unexpected error occurred: $errorMsg"
    }
}

# Main execution flow

# First run in test mode
$testOptions = "/MIR /Z /R:5 /W:10 /MT:32"  # Same options but will add /L
$testPassed = Test-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options $testOptions -Exclusions $config.Exclusions

if ($testPassed) {
    Write-Host "Test mode completed successfully. Proceeding with actual copy operation..."
    # Now run the actual copy
    Start-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options "/MIR /Z /R:5 /W:10 /MT:32" -Exclusions $config.Exclusions
} else {
    Write-Host "Test mode encountered errors. Check $testLogPath and $errorLogPath for details."
    Write-Error "Robocopy test failed. Aborting actual copy operation."
    New-BurntToastNotification -Text "RoboCopy Test Failed", "Robocopy test mode encountered errors. Check logs."
    exit 1
}
