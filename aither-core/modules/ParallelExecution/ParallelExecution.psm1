#Requires -Version 7.0

<#
.SYNOPSIS
Parallel execution utilities for OpenTofu Lab Automation

.DESCRIPTION
This module provides cross-platform parallel processing capabilities for PowerShell scripts,
including parallel test execution, job management, and result aggregation.

.NOTES
- Compatible with PowerShell 7.0+ on Windows, Linux, and macOS
- Optimized for CPU-intensive and I/O-intensive workloads
- Integrated with Pester for parallel test execution
- Follows PowerShell 7.0+ cross-platform standards
#>

# Import the centralized Logging module
$loggingImported = $false

# Check if Logging module is already available
if (Get-Module -Name 'Logging' -ErrorAction SilentlyContinue) {
    $loggingImported = $true
    Write-Verbose "Logging module already available"
} else {
    $loggingPaths = @()
    
    # Add paths that don't require environment variables
    $loggingPaths += 'Logging'  # Try module name first (if in PSModulePath)
    $loggingPaths += (Join-Path (Split-Path $PSScriptRoot -Parent) "Logging")  # Relative to modules directory
    
    # Add paths that require environment variables (with null checks)
    if ($env:PWSH_MODULES_PATH) { 
        $loggingPaths += (Join-Path $env:PWSH_MODULES_PATH "Logging")
    }
    if ($env:PROJECT_ROOT) { 
        $loggingPaths += (Join-Path $env:PROJECT_ROOT "aither-core/modules/Logging")
    }
    
    # Add fallback path
    $loggingPaths += '/workspaces/AitherLabs/aither-core/modules/Logging'

    foreach ($loggingPath in $loggingPaths) {
        if ($loggingImported) { break }

        try {
            if ($loggingPath -eq 'Logging') {
                Import-Module 'Logging' -Global -ErrorAction Stop
            } elseif (Test-Path $loggingPath) {
                Import-Module $loggingPath -Global -ErrorAction Stop
            } else {
                continue
            }
            Write-Verbose "Successfully imported Logging module from: $loggingPath"
            $loggingImported = $true
        } catch {
            Write-Verbose "Failed to import Logging from $loggingPath : $_"
        }
    }
}

if (-not $loggingImported) {
    Write-Warning "Could not import Logging module from any of the attempted paths"
    # Fallback logging function
    function Write-CustomLog {
        param([string]$Message, [string]$Level = "INFO")
        Write-Host "[$Level] $Message"
    }
}

function Invoke-ParallelForEach {
    <#
    .SYNOPSIS
    Executes a script block in parallel across multiple items

    .DESCRIPTION
    Provides a cross-platform parallel foreach implementation using PowerShell 7.0+ ForEach-Object -Parallel

    .PARAMETER InputObject
    The collection of items to process in parallel

    .PARAMETER ScriptBlock
    The script block to execute for each item

    .PARAMETER ThrottleLimit
    Maximum number of parallel threads (default: processor count)

    .PARAMETER TimeoutSeconds
    Timeout for the entire operation in seconds (default: 300)

    .EXAMPLE
    $files = Get-ChildItem *.ps1
    $results = Invoke-ParallelForEach -InputObject $files -ScriptBlock {
        param($file)
        Invoke-ScriptAnalyzer -Path $file.FullName
    }

    .NOTES
    Uses PowerShell 7.0+ native parallel processing
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject = @(),

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [int]$ThrottleLimit = [Environment]::ProcessorCount,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300
    )

    begin {
        Write-CustomLog "Starting parallel execution with throttle limit: $ThrottleLimit" -Level "INFO"
        $items = @()
    }

    process {
        if ($InputObject) {
            $items += $InputObject
        }
    }

    end {
        if ($items.Count -eq 0) {
            Write-CustomLog "No items to process" -Level "INFO"
            return @()
        }

        try {
            $startTime = Get-Date
            $results = $items | ForEach-Object -Parallel $ScriptBlock -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds

            $duration = (Get-Date) - $startTime
            Write-CustomLog "Parallel execution completed in $($duration.TotalSeconds) seconds" -Level "SUCCESS"

            return $results
        }
        catch {
            Write-CustomLog "Parallel execution failed: $($_.Exception.Message)" -Level "ERROR"
            throw
        }
    }
}

function Start-ParallelJob {
    <#
    .SYNOPSIS
    Starts a background job for parallel execution

    .DESCRIPTION
    Creates and starts a PowerShell background job with proper error handling and logging

    .PARAMETER Name
    Name of the job for identification

    .PARAMETER ScriptBlock
    Script block to execute in the background job

    .PARAMETER ArgumentList
    Arguments to pass to the script block

    .EXAMPLE
    $job = Start-ParallelJob -Name "TestValidation" -ScriptBlock {
        param($path)
        Invoke-Pester -Path $path
    } -ArgumentList @("./tests")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [object[]]$ArgumentList = @()
    )

    try {
        Write-CustomLog "Starting background job: $Name" -Level "INFO"

        $job = Start-Job -Name $Name -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList

        Write-CustomLog "Job started successfully: $Name (ID: $($job.Id))" -Level "SUCCESS"
        return $job
    }
    catch {
        Write-CustomLog "Failed to start job $Name : $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Wait-ParallelJobs {
    <#
    .SYNOPSIS
    Waits for multiple parallel jobs to complete

    .DESCRIPTION
    Monitors and waits for background jobs with timeout and progress reporting

    .PARAMETER Jobs
    Array of job objects to wait for

    .PARAMETER TimeoutSeconds
    Maximum time to wait for all jobs to complete

    .PARAMETER ShowProgress
    Whether to show progress while waiting

    .EXAMPLE
    $jobs = @($job1, $job2, $job3)
    $results = Wait-ParallelJobs -Jobs $jobs -TimeoutSeconds 600 -ShowProgress
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Job[]]$Jobs,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 600,

        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress
    )

    try {
        $startTime = Get-Date
        $results = @{}

        Write-CustomLog "Waiting for $($Jobs.Count) jobs to complete (timeout: $TimeoutSeconds seconds)" -Level "INFO"
          do {
            $runningJobs = $Jobs | Where-Object { $_.State -eq 'Running' }
            $completedJobs = $Jobs | Where-Object { $_.State -in @('Completed', 'Failed', 'Stopped') }

            if ($ShowProgress) {
                $percentComplete = [math]::Round(($completedJobs.Count / $Jobs.Count) * 100, 1)
                Write-Progress -Activity "Waiting for parallel jobs" -Status "$($completedJobs.Count)/$($Jobs.Count) completed" -PercentComplete $percentComplete
            }

            # Check for completed jobs and collect results
            foreach ($job in ($Jobs | Where-Object { $_.State -in @('Completed', 'Failed', 'Stopped') })) {
                if (-not $results.ContainsKey($job.Id)) {
                    $jobResult = Receive-Job -Job $job -Keep
                    $results[$job.Id] = @{
                        Name = $job.Name
                        State = $job.State
                        Result = $jobResult
                        HasErrors = $job.ChildJobs[0].Error.Count -gt 0
                        Errors = $job.ChildJobs[0].Error
                    }

                    if ($job.State -eq 'Failed') {
                        Write-CustomLog "Job failed: $($job.Name)" -Level "ERROR"
                    } else {
                        Write-CustomLog "Job completed: $($job.Name)" -Level "SUCCESS"
                    }
                }
            }

            # Check timeout
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalSeconds -gt $TimeoutSeconds) {
                Write-CustomLog "Timeout reached after $($elapsed.TotalSeconds) seconds" -Level "WARN"
                # For timeout, still add running jobs to results
                foreach ($job in $runningJobs) {
                    if (-not $results.ContainsKey($job.Id)) {
                        $results[$job.Id] = @{
                            Name = $job.Name
                            State = 'Timeout'
                            Result = $null
                            HasErrors = $false
                            Errors = @()
                        }
                    }
                }
                break
            }

            if ($runningJobs.Count -gt 0) {
                Start-Sleep -Seconds 1
            }

        } while ($runningJobs.Count -gt 0)

        if ($ShowProgress) {
            Write-Progress -Activity "Waiting for parallel jobs" -Completed
        }

        # Clean up jobs
        $Jobs | Remove-Job -Force -ErrorAction SilentlyContinue

        $duration = (Get-Date) - $startTime
        Write-CustomLog "All jobs completed in $($duration.TotalSeconds) seconds" -Level "SUCCESS"

        return $results.Values
    }
    catch {
        Write-CustomLog "Error waiting for parallel jobs: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Invoke-ParallelPesterTests {
    <#
    .SYNOPSIS
    Executes Pester tests in parallel across multiple test files

    .DESCRIPTION
    Provides parallel execution of Pester tests using PowerShell 7.0+ parallel capabilities

    .PARAMETER TestFiles
    Array of test file paths to execute in parallel

    .PARAMETER ThrottleLimit
    Maximum number of parallel test executions (default: processor count)

    .PARAMETER PesterConfiguration
    Custom Pester configuration object to use for tests

    .PARAMETER TimeoutSeconds
    Timeout for individual test file execution in seconds (default: 300)

    .EXAMPLE
    $testFiles = Get-ChildItem "tests" -Filter "*.Tests.ps1" -Recurse
    $results = Invoke-ParallelPesterTests -TestFiles $testFiles.FullName

    .NOTES
    Uses PowerShell 7.0+ native parallel processing with Pester
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$TestFiles,
        
        [Parameter()]
        [int]$ThrottleLimit = [Environment]::ProcessorCount,
        
        [Parameter()]
        [object]$PesterConfiguration = $null,
        
        [Parameter()]
        [int]$TimeoutSeconds = 300
    )

    begin {
        Write-CustomLog "Starting parallel Pester test execution" -Level "INFO"
        Write-CustomLog "Processing $($TestFiles.Count) test files with throttle limit $ThrottleLimit" -Level "INFO"
        
        # Validate test files exist
        $validTestFiles = @()
        foreach ($testFile in $TestFiles) {
            if (Test-Path $testFile) {
                $validTestFiles += $testFile
            } else {
                Write-CustomLog "Test file not found: $testFile" -Level "WARN"
            }
        }
        
        if ($validTestFiles.Count -eq 0) {
            throw "No valid test files found"
        }
        
        Write-CustomLog "Found $($validTestFiles.Count) valid test files" -Level "INFO"
    }

    process {
        try {
            # Execute tests in parallel
            $results = $validTestFiles | ForEach-Object -Parallel {
                $testFile = $_
                $pesterConfig = $using:PesterConfiguration
                
                try {
                    # Import Pester in each parallel runspace
                    Import-Module Pester -Force -ErrorAction Stop
                    
                    # Create basic Pester configuration if none provided
                    if ($null -eq $pesterConfig) {
                        $pesterConfig = New-PesterConfiguration
                        $pesterConfig.Run.Path = $testFile
                        $pesterConfig.Output.Verbosity = 'Minimal'
                        $pesterConfig.TestResult.Enabled = $true
                    }
                    
                    # Execute the test
                    $testResult = Invoke-Pester -Configuration $pesterConfig
                    
                    return @{
                        TestFile = $testFile
                        Result = $testResult
                        Success = ($testResult.Failed.Count -eq 0)
                        Duration = $testResult.Duration
                        PassedCount = $testResult.Passed.Count
                        FailedCount = $testResult.Failed.Count
                        SkippedCount = $testResult.Skipped.Count
                        Timestamp = Get-Date
                    }
                }
                catch {
                    return @{
                        TestFile = $testFile
                        Result = $null
                        Success = $false
                        Error = $_.Exception.Message
                        Duration = [TimeSpan]::Zero
                        PassedCount = 0
                        FailedCount = 1
                        SkippedCount = 0
                        Timestamp = Get-Date
                    }
                }
            } -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds
            
            # Calculate summary statistics
            $totalPassed = ($results | Measure-Object -Property PassedCount -Sum).Sum
            $totalFailed = ($results | Measure-Object -Property FailedCount -Sum).Sum
            $totalSkipped = ($results | Measure-Object -Property SkippedCount -Sum).Sum
            $totalDuration = [TimeSpan]::Zero
            
            foreach ($result in $results) {
                $totalDuration = $totalDuration.Add($result.Duration)
            }
            
            $summary = @{
                TestFiles = $validTestFiles
                Results = $results
                TotalPassed = $totalPassed
                TotalFailed = $totalFailed
                TotalSkipped = $totalSkipped
                TotalDuration = $totalDuration
                Success = ($totalFailed -eq 0)
                ExecutionTime = Get-Date
            }
            
            Write-CustomLog "Parallel Pester execution completed: $totalPassed passed, $totalFailed failed, $totalSkipped skipped" -Level "INFO"
            
            return $summary
        }
        catch {
            Write-CustomLog "Error in parallel Pester execution: $($_.Exception.Message)" -Level "ERROR"
            throw
        }
    }
}

function Merge-ParallelTestResults {
    <#
    .SYNOPSIS
    Merges results from parallel Pester test execution

    .DESCRIPTION
    Aggregates test results from multiple parallel test runs into a single summary

    .PARAMETER TestResults
    Array of test result objects from parallel execution

    .EXAMPLE
    $mergedResults = Merge-ParallelTestResults -TestResults $parallelResults
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$TestResults = @()
    )

    try {
        Write-CustomLog "Merging results from $($TestResults.Count) parallel test runs" -Level "INFO"

        if ($TestResults.Count -eq 0) {
            return [PSCustomObject]@{
                TotalTests = 0
                Passed = 0
                Failed = 0
                Skipped = 0
                TotalTime = [timespan]::Zero
                Failures = @()
                Success = $true
            }
        }

        $totalPassed = 0
        $totalFailed = 0
        $totalSkipped = 0
        $totalTime = [timespan]::Zero
        $allFailures = @()

        foreach ($result in $TestResults) {
            if ($result.Result -and $result.Result.PSObject.Properties['Passed']) {
                $totalPassed += $result.Result.Passed.Count
                $totalFailed += $result.Result.Failed.Count
                $totalSkipped += $result.Result.Skipped.Count

                if ($result.Result.PSObject.Properties['TotalTime']) {
                    $totalTime += $result.Result.TotalTime
                }

                if ($result.Result.Failed.Count -gt 0) {
                    $allFailures += $result.Result.Failed
                }
            }

            if ($result.HasErrors) {
                Write-CustomLog "Test job $($result.Name) had errors: $($result.Errors -join '; ')" -Level "WARN"
            }
        }

        $summary = [PSCustomObject]@{
            TotalTests = $totalPassed + $totalFailed + $totalSkipped
            Passed = $totalPassed
            Failed = $totalFailed
            Skipped = $totalSkipped
            TotalTime = $totalTime
            Failures = $allFailures
            Success = $totalFailed -eq 0
        }

        Write-CustomLog "Test summary: $($summary.Passed) passed, $($summary.Failed) failed, $($summary.Skipped) skipped in $($summary.TotalTime)" -Level "INFO"

        return $summary
    }
    catch {
        Write-CustomLog "Error merging test results: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Invoke-ParallelForEach',
    'Start-ParallelJob',
    'Wait-ParallelJobs',
    'Invoke-ParallelPesterTests',
    'Merge-ParallelTestResults'
)
