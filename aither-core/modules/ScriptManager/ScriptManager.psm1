<#
.SYNOPSIS
Centralized management for one-off scripts in OpenTofu Lab Automation.

.DESCRIPTION
This module provides functions to register, validate, and execute one-off scripts.
It ensures scripts are integrated into the project framework without breaking dependencies.

#>

function Register-OneOffScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,
        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        
        [Parameter()]
        [string]$Description = "",
        
        [Parameter()]
        [string]$Purpose = "",
        
        [Parameter()]
        [string]$Author = $env:USERNAME,
        
        [Parameter()]
        [hashtable]$Parameters = @{},
        
        [Parameter()]
        [switch]$Force
    )

    begin {
        $ErrorActionPreference = "Stop"
        
        # Validate script path exists
        if (-not (Test-Path $ScriptPath)) {
            throw "Script file not found: $ScriptPath"
        }
        
        # Validate Name parameter
        if ([string]::IsNullOrWhiteSpace($Name)) {
            throw "Name parameter cannot be null or empty"
        }
    }
    
    process {
        try {
            $MetadataFile = (Join-Path (Get-Location) "scripts/one-off-scripts.json")
            $MetadataDir = Split-Path $MetadataFile -Parent
            
            # Ensure metadata directory exists
            if (-not (Test-Path $MetadataDir)) {
                New-Item -ItemType Directory -Path $MetadataDir -Force | Out-Null
            }

            $scriptMetadata = @{
                ScriptPath = $ScriptPath
                Name = $Name
                Description = $Description
                Purpose = $Purpose
                Author = $Author
                Parameters = $Parameters
                RegisteredDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Executed = $false
                ExecutionDate = $null
                ExecutionResult = $null
            }

            if (-not (Test-Path $MetadataFile)) {
                $allScripts = @()
            } else {
                $allScripts = Get-Content $MetadataFile | ConvertFrom-Json
            }

            $existingScript = $allScripts | Where-Object { $_.ScriptPath -eq $ScriptPath }

            if ($existingScript -and -not $Force) {
                Write-Warning "Script already registered: $ScriptPath"
                return $false
            }

            if ($existingScript -and $Force) {
                $allScripts = $allScripts | Where-Object { $_.ScriptPath -ne $ScriptPath }
                Write-Verbose "Re-registering script: $ScriptPath"
            }

            $allScripts += $scriptMetadata
            $allScripts | ConvertTo-Json -Depth 10 | Set-Content $MetadataFile

            Write-Verbose "Script registered successfully: $ScriptPath"
            return $true
        }
        catch {
            Write-Error "Failed to register script: $($_.Exception.Message)"
            throw
        }
    }
}

function Test-OneOffScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,
        
        [Parameter()]
        [string]$Name
    )

    begin {
        $ErrorActionPreference = "Stop"
    }
    
    process {
        try {
            $MetadataFile = (Join-Path (Get-Location) "scripts/one-off-scripts.json")

            if (-not (Test-Path $MetadataFile)) {
                Write-Warning "Metadata file not found: $MetadataFile"
                return $false
            }

            $allScripts = Get-Content $MetadataFile | ConvertFrom-Json
            
            # Search by ScriptPath or Name
            if ($Name) {
                $scriptMetadata = $allScripts | Where-Object { $_.Name -eq $Name }
            } else {
                $scriptMetadata = $allScripts | Where-Object { $_.ScriptPath -eq $ScriptPath }
            }

            if (-not $scriptMetadata) {
                Write-Warning "Script '$ScriptPath' not found in metadata."
                return $false
            }

            if (-not (Test-Path $ScriptPath)) {
                Write-Warning "Script file not found: $ScriptPath"
                return $false
            }

            # Basic syntax validation
            try {
                $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $ScriptPath -Raw), [ref]$null)
                Write-Verbose "Script syntax validation passed: $ScriptPath"
                return $true
            }
            catch {
                Write-Warning "Script syntax validation failed: $ScriptPath - $($_.Exception.Message)"
                return $false
            }
        }
        catch {
            Write-Error "Failed to test script: $($_.Exception.Message)"
            return $false
        }
    }
}

function Invoke-OneOffScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,
        
        [Parameter()]
        [string]$Name,
        
        [Parameter()]
        [hashtable]$Parameters = @{},
        
        [Parameter()]
        [switch]$Force
    )

    begin {
        $ErrorActionPreference = "Stop"
    }
    
    process {
        try {
            $MetadataFile = (Join-Path (Get-Location) "scripts/one-off-scripts.json")

            if (-not (Test-Path $MetadataFile)) {
                Write-Warning "Metadata file not found: $MetadataFile. Register the script first."
                return $false
            }

            $allScripts = Get-Content $MetadataFile | ConvertFrom-Json
            
            # Find script by ScriptPath or Name
            if ($Name) {
                $script = $allScripts | Where-Object { $_.Name -eq $Name }
            } else {
                $script = $allScripts | Where-Object { $_.ScriptPath -eq $ScriptPath }
            }

            if (-not $script) {
                Write-Error "Script '$ScriptPath' not found in metadata."
                return $false
            }

            if ($script.Executed -and -not $Force) {
                Write-Warning "Script '$($script.Name)' already executed. Use -Force to re-run."
                return $false
            }

            if (-not (Test-Path $ScriptPath)) {
                Write-Error "Script file not found: $ScriptPath"
                return $false
            }

            Write-Verbose "Executing script: $ScriptPath"
            
            # Execute script with parameters if provided
            if ($Parameters.Count -gt 0) {
                $result = & $ScriptPath @Parameters
            } else {
                $result = & $ScriptPath
            }
            
            # Update metadata
            $script.Executed = $true
            $script.ExecutionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $script.ExecutionResult = "Success"
            
            # Save updated metadata
            $allScripts | ConvertTo-Json -Depth 10 | Set-Content $MetadataFile
            
            Write-Verbose "Script executed successfully: $ScriptPath"
            return $true
        }
        catch {
            # Update metadata with failure info
            if ($script) {
                $script.ExecutionResult = "Failed: $($_.Exception.Message)"
                $script.ExecutionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $allScripts | ConvertTo-Json -Depth 10 | Set-Content $MetadataFile -ErrorAction SilentlyContinue
            }
            
            Write-Error "Script execution failed: $($_.Exception.Message)"
            return $false
        }
    }
}
