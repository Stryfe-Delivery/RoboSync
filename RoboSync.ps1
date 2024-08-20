# Get the directory where the script is running
$scriptDir = Split-Path (Convert-Path -LiteralPath ([Environment]::GetCommandLineArgs()[0]))

# Load configuration from a JSON file in the script's directory
$configPath = Join-Path $scriptDir "config.json"
if (-Not (Test-Path $configPath)) {
    Write-Error "Configuration file not found at $configPath"
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# Validate configuration - make sure notes section is not considered
if (-Not $config.SourceDir -or -Not $config.DestDirs -or -Not $config.Exclusions) {
    Write-Error "Invalid configuration file. Please ensure it contains 'SourceDir', 'DestDirs', and 'Exclusions'."
    exit 1
}

# Define paths for the log files
$errorLogPath = Join-Path $scriptDir "error.log"
$runLogPath = Join-Path $scriptDir "run.log"

# Function to start robocopy
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
        # Record the start time
        $startTime = Get-Date
        Add-Content -Path $runLogPath -Value "`n[$startTime] - Robocopy operation started."

        foreach ($DestDir in $DestDirs) {
            # Build the robocopy command with exclusions
            $exclusionParams = ""
            if ($Exclusions) {
                foreach ($exclusion in $Exclusions) {
                    $exclusionParams += " /XD $exclusion"
                }
            }

            $cmd = "robocopy $SourceDir $DestDir $Options $exclusionParams"
            $output = & cmd.exe /c $cmd 2>&1 | Where-Object { $_ -match "ERROR" }

            if ($output) {
                # Log errors to the error log file
                Add-Content -Path $errorLogPath -Value "`n[$startTime] - Errors encountered:"
                Add-Content -Path $errorLogPath -Value $output
            } else {
                Write-Host "Robocopy completed successfully for $DestDir"
            }

            # Record the stop time and calculate the duration
            $stopTime = Get-Date
            $duration = $stopTime - $startTime
            Add-Content -Path $runLogPath -Value "[$stopTime] - Robocopy operation completed for destination '$DestDir'. Duration: $duration."

            # Send notification
            New-BurntToastNotification -Text "RoboCopy Task Completed", "Robocopy completed successfully for $DestDir"
        }

        # Log completion
        Add-Content -Path $runLogPath -Value "Robocopy operation completed."
    } catch {
        # Log unexpected errors
        $errorMsg = $_.Exception.Message
        Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - Unexpected error: $errorMsg"
        Write-Error "An unexpected error occurred: $errorMsg"
    }
}

# Execute the copy with options and exclusions loaded from the configuration file
Start-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options "/MIR /Z /R:5 /W:10 /MT:32" -Exclusions $config.Exclusions
