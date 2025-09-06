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

# Log rotation function
function Rotate-Logs {
    param([string]$LogPath, [int]$MaxFiles = 10)
    
    if (Test-Path $LogPath) {
        $logFile = Get-Item $LogPath
        if ($logFile.Length -gt 10MB) {
            $archivePath = $LogPath -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $LogPath $archivePath -Force
        }
        
        # Limit number of archived logs
        $logFiles = Get-ChildItem (Split-Path $LogPath) -Filter "*$(Split-Path $LogPath -Leaf)*" | 
                    Sort-Object CreationTime -Descending
        if ($logFiles.Count -gt $MaxFiles) {
            $logFiles | Select-Object -Skip $MaxFiles | Remove-Item -Force
        }
    }
}

# Rotate logs before starting
Rotate-Logs $errorLogPath
Rotate-Logs $runLogPath
Rotate-Logs $testLogPath

# Function to run robocopy in test mode (/L)
function Test-Robocopy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType Container})]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [ValidateCount(1, [int]::MaxValue)]
        [array]$DestDirs,
        
        [Parameter(Mandatory=$true)]
        [string]$Options,
        
        [Parameter(Mandatory=$true)]
        [array]$Exclusions
    )

    try {
        $startTime = Get-Date
        Add-Content -Path $testLogPath -Value "`n[$startTime] - Robocopy TEST operation started (list-only mode)."

        $testResults = @{}
        
        # Process destinations sequentially for test mode (more predictable)
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

            # Add long path support if available
            if ($Options -notmatch "/256") {
                $arguments += "/256"
            }

            $cmd = "robocopy $arguments"
            Add-Content -Path $testLogPath -Value "`nTEST COMMAND: $cmd"
            
            # Run robocopy and capture exit code
            $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
            
            # Log output
            Add-Content -Path $testLogPath -Value "Exit Code: $($process.ExitCode)"
            
            # Store result
            $testResults[$DestDir] = $process.ExitCode -lt 8
            
            # Check for serious errors (exit code >= 8 indicates failure)
            if ($process.ExitCode -ge 8) {
                Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - TEST MODE ERRORS for destination '$DestDir': Exit code $($process.ExitCode)"
            }
        }

        $stopTime = Get-Date
        $duration = $stopTime - $startTime
        Add-Content -Path $testLogPath -Value "[$stopTime] - Robocopy TEST operation completed. Duration: $duration."
        
        # Return true only if all tests passed
        return ($testResults.Values -notcontains $false)
    } catch {
        $errorMsg = $_.Exception.Message
        Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - TEST MODE UNEXPECTED ERROR: $errorMsg"
        return $false
    }
}

# Function to run robocopy with retry logic
function Invoke-RobocopyWithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [array]$Arguments,
        [int]$MaxRetries = 3,
        [int]$RetryDelay = 30
    )
    
    $attempt = 1
    while ($attempt -le $MaxRetries) {
        $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -lt 8) {
            return $process
        }
        
        Write-Warning "Attempt $attempt failed with exit code $($process.ExitCode). Retrying in $RetryDelay seconds..."
        Add-Content -Path $runLogPath -Value "Attempt $attempt failed with exit code $($process.ExitCode). Retrying in $RetryDelay seconds..."
        Start-Sleep -Seconds $RetryDelay
        $attempt++
        $RetryDelay *= 2  # Exponential backoff
    }
    
    return $process
}

# Function to start actual robocopy with parallel execution
function Start-Robocopy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType Container})]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [ValidateCount(1, [int]::MaxValue)]
        [array]$DestDirs,
        
        [Parameter(Mandatory=$true)]
        [string]$Options,
        
        [Parameter(Mandatory=$true)]
        [array]$Exclusions,
        
        [int]$MaxParallelJobs = 2
    )

    try {
        $startTime = Get-Date
        Add-Content -Path $runLogPath -Value "`n[$startTime] - Robocopy operation started."
        
        # Script block for parallel execution
        $scriptBlock = {
            param($SourceDir, $DestDir, $Options, $Exclusions, $RunLogPath, $ErrorLogPath)
            
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
            
            # Add long path support if available
            if ($Options -notmatch "/256") {
                $arguments += "/256"
            }

            $cmd = "robocopy $arguments"
            Add-Content -Path $RunLogPath -Value "COMMAND: $cmd"
            
            # Run robocopy with retry logic
            $process = Invoke-RobocopyWithRetry -Arguments $arguments -MaxRetries 3 -RetryDelay 30
            
            # Check exit code
            if ($process.ExitCode -ge 8) {
                Add-Content -Path $ErrorLogPath -Value "`n[$(Get-Date)] - Errors encountered for destination '$DestDir': Exit code $($process.ExitCode)"
                return @{
                    Destination = $DestDir
                    Success = $false
                    ExitCode = $process.ExitCode
                    Error = "Robocopy failed with exit code $($process.ExitCode)"
                }
            } else {
                Add-Content -Path $RunLogPath -Value "Robocopy completed for destination '$DestDir' with exit code $($process.ExitCode)"
                return @{
                    Destination = $DestDir
                    Success = $true
                    ExitCode = $process.ExitCode
                    Error = $null
                }
            }
        }
        
        # Run jobs in parallel with throttling
        $jobs = @()
        $totalDestinations = $DestDirs.Count
        $completed = 0
        
        foreach ($DestDir in $DestDirs) {
            # Throttle parallel jobs
            while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxParallelJobs) {
                Start-Sleep -Milliseconds 500
                
                # Check completed jobs
                $completedJobs = $jobs | Where-Object { $_.State -ne 'Running' }
                foreach ($job in $completedJobs) {
                    $result = Receive-Job -Job $job
                    $completed++
                    
                    # Update progress
                    Write-Progress -Activity "Copying files" -Status "Processing $completed of $totalDestinations destinations" -PercentComplete (($completed / $totalDestinations) * 100)
                    
                    if (-not $result.Success) {
                        Write-Error "Failed to copy to $($result.Destination): $($result.Error)"
                    }
                }
                
                # Remove completed jobs
                $completedJobs | Remove-Job
                $jobs = $jobs | Where-Object { $_.State -eq 'Running' }
            }
            
            # Start new job
            $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $SourceDir, $DestDir, $Options, $Exclusions, $runLogPath, $errorLogPath
            $jobs += $job
        }
        
        # Wait for remaining jobs
        while ($jobs | Where-Object { $_.State -eq 'Running' }) {
            Start-Sleep -Seconds 2
            
            $completedJobs = $jobs | Where-Object { $_.State -ne 'Running' }
            foreach ($job in $completedJobs) {
                $result = Receive-Job -Job $job
                $completed++
                
                Write-Progress -Activity "Copying files" -Status "Processing $completed of $totalDestinations destinations" -PercentComplete (($completed / $totalDestinations) * 100)
                
                if (-not $result.Success) {
                    Write-Error "Failed to copy to $($result.Destination): $($result.Error)"
                }
            }
            
            $completedJobs | Remove-Job
            $jobs = $jobs | Where-Object { $_.State -eq 'Running' }
        }
        
        Write-Progress -Activity "Copying files" -Completed
        
        $stopTime = Get-Date
        $duration = $stopTime - $startTime
        Add-Content -Path $runLogPath -Value "[$stopTime] - Robocopy operation completed. Duration: $duration."
        
        # Send notification if BurntToast is available
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast
            New-BurntToastNotification -Text "RoboCopy Task Completed", "Robocopy completed for all destinations in $([math]::Round($duration.TotalMinutes, 1)) minutes"
        } else {
            Write-Host "Robocopy completed for all destinations in $([math]::Round($duration.TotalMinutes, 1)) minutes" -ForegroundColor Green
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Add-Content -Path $errorLogPath -Value "`n[$(Get-Date)] - Unexpected error: $errorMsg"
        Write-Error "An unexpected error occurred: $errorMsg"
    } finally {
        # Clean up any remaining jobs
        $jobs | Remove-Job -Force
    }
}

# Notification function with fallbacks
function Send-Notification {
    param([string]$Title, [string]$Message, [string]$Type = "Info")
    
    # Try BurntToast first
    if (Get-Module -ListAvailable -Name BurntToast) {
        Import-Module BurntToast
        New-BurntToastNotification -Text $Title, $Message
        return
    }
    
    # Fallback to system sounds
    if ($Type -eq "Error") {
        [System.Media.SystemSounds]::Hand.Play()
    } else {
        [System.Media.SystemSounds]::Exclamation.Play()
    }
    
    # Fallback to writing to event log
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("RobocopyScript")) {
            [System.Diagnostics.EventLog]::CreateEventSource("RobocopyScript", "Application")
        }
        
        $eventType = if ($Type -eq "Error") { [System.Diagnostics.EventLogEntryType]::Error } else { [System.Diagnostics.EventLogEntryType]::Information }
        Write-EventLog -LogName "Application" -Source "RobocopyScript" -EntryType $eventType -EventId 1000 -Message "$Title : $Message"
    } catch {
        # Source might not be registered, just write to host
        Write-Host "$Title : $Message" -ForegroundColor $(if ($Type -eq "Error") { "Red" } else { "Yellow" })
    }
}

# Main execution flow

# First run in test mode
$testOptions = if ($config.Options) { $config.Options } else { "/MIR /Z /R:5 /W:10 /MT:32" }
$testPassed = Test-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options $testOptions -Exclusions $config.Exclusions

if ($testPassed) {
    Write-Host "Test mode completed successfully. Proceeding with actual copy operation..."
    
    # Now run the actual copy with parallel execution
    $maxParallel = if ($config.MaxParallelJobs -and $config.MaxParallelJobs -gt 0) { $config.MaxParallelJobs } else { 2 }
    Start-Robocopy -SourceDir $config.SourceDir -DestDirs $config.DestDirs -Options $testOptions -Exclusions $config.Exclusions -MaxParallelJobs $maxParallel
} else {
    Write-Host "Test mode encountered errors. Check $testLogPath and $errorLogPath for details."
    Write-Error "Robocopy test failed. Aborting actual copy operation."
    Send-Notification -Title "RoboCopy Test Failed" -Message "Robocopy test mode encountered errors. Check logs." -Type "Error"
    exit 1
}
