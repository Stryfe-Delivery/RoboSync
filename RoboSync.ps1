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

# Validate paths exist
if (-Not (Test-Path $config.SourceDir)) {
    Write-Error "Source directory does not exist: $($config.SourceDir)"
    exit 1
}

foreach ($dir in $config.DestDirs) {
    if (-Not (Test-Path $dir)) {
        Write-Warning "Destination directory does not exist and will be created: $dir"
    }
}

# Define paths for the log files
$errorLogPath = Join-Path $scriptDir "error.log"
$runLogPath = Join-Path $scriptDir "run.log"
$testLogPath = Join-Path $scriptDir "test.log"

# Function to run robocopy in test mode (/L)
function Test-Robocopy {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_})]
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
            # Build the robocopy arguments array
            $arguments = @(
                "`"$SourceDir`"",
                "`"$DestDir`""
            )
            
            # Add options
            $arguments += $Options.Split(" ") | Where-Object { $_ }
            
            # Add test mode
            $arguments += "/L"
            
            # Add exclusions
            foreach ($exclusion in $Exclusions) {
                $arguments += "/XD"
                $arguments += "`"$exclusion`""
            }

            $cmd = "robocopy $arguments"
            Add-Content -Path $testLogPath -Value "`nTEST COMMAND: $cmd"
            
            # Run robocopy and capture exit code
            $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
            
            # Log output
            Add-Content -Path $testLogPath -Value "Exit Code: $($process.ExitCode)"
            
            # Check for serious errors (exit code >= 8 indicates failure)
            if ($process.ExitCode -ge 8) {
                Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - TEST MODE ERRORS for destination '$DestDir': Exit code $($process.ExitCode)"
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
        [ValidateScript({Test-Path $_})]
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
            # Build the robocopy arguments array
            $arguments = @(
                "`"$SourceDir`"",
                "`"$DestDir`""
            )
            
            # Add options
            $arguments += $Options.Split(" ") | Where-Object { $_ }
            
            # Add exclusions
            foreach ($exclusion in $Exclusions) {
                $arguments += "/XD"
                $arguments += "`"$exclusion`""
            }

            $cmd = "robocopy $arguments"
            Add-Content -Path $runLogPath -Value "COMMAND: $cmd"
            
            # Run robocopy and capture exit code
            $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
            
            # Check exit code
            if ($process.ExitCode -ge 8) {
                Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - Errors encountered for destination '$DestDir': Exit code $($process.ExitCode)"
                Write-Error "Robocopy failed for $DestDir with exit code $($process.ExitCode)"
            } else {
                Write-Host "Robocopy completed successfully for $DestDir (Exit code: $($process.ExitCode))"
                Add-Content -Path $runLogPath -Value "Robocopy completed for destination '$DestDir' with exit code $($process.ExitCode)"
            }

            $stopTime = Get-Date
            $duration = $stopTime - $startTime
            Add-Content -Path $runLogPath -Value "[$stopTime] - Robocopy operation completed for destination '$DestDir'. Duration: $duration."
            
            # Send notification if BurntToast is available
            if (Get-Module -ListAvailable -Name BurntToast) {
                Import-Module BurntToast
                New-BurntToastNotification -Text "RoboCopy Task Completed", "Robocopy completed for $DestDir with exit code $($process.ExitCode)"
            }
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
$testOptions = "/MIR /Z /R:5 /W:10 /MT:32"
$testPassed = Test-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options $testOptions -Exclusions $config.Exclusions

if ($testPassed) {
    Write-Host "Test mode completed successfully. Proceeding with actual copy operation..."
    # Now run the actual copy
    Start-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options "/MIR /Z /R:5 /W:10 /MT:32" -Exclusions $config.Exclusions
} else {
    Write-Host "Test mode encountered errors. Check $testLogPath and $errorLogPath for details."
    Write-Error "Robocopy test failed. Aborting actual copy operation."
    
    # Send notification if BurntToast is available
    if (Get-Module -ListAvailable -Name BurntToast) {
        Import-Module BurntToast
        New-BurntToastNotification -Text "RoboCopy Test Failed", "Robocopy test mode encountered errors. Check logs."
    }
    exit 1
}
