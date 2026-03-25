#Requires -Version 7.0
<#
.SYNOPSIS
    ConfigIntegrityRunner - Azure Configuration Drift Detection Module

.DESCRIPTION
    Compares desired-state rules against actual Azure resource configuration,
    flags drift, scores integrity, and produces reporting-friendly output for
    downstream consumption (ServiceNow, dashboards, CI gates).

.NOTES
    Author: Candidate Submission
    Version: 1.0.0
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Data Loading ---

function Import-DesiredState {
    <#
    .SYNOPSIS Loads and validates the desired-state rule file. #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )

    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (-not $raw.rules) {
        throw "Desired state file '$Path' is missing a 'rules' array."
    }
    return $raw
}

function Import-ActualState {
    <#
    .SYNOPSIS Loads and validates the actual-state snapshot file. #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )

    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (-not $raw.resources) {
        throw "Actual state file '$Path' is missing a 'resources' array."
    }
    return $raw
}

#endregion

#region --- Core Comparison Engine ---

function Compare-ResourceChecks {
    <#
    .SYNOPSIS
        Recursively compares a checks object against an actual object.
        Returns a list of drift items.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Desired,
        [Parameter(Mandatory)] [PSCustomObject]$Actual,
        [string]$PathPrefix = ''
    )

    $driftItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($property in $Desired.PSObject.Properties) {
        $key        = $property.Name
        $fullPath   = if ($PathPrefix) { "$PathPrefix.$key" } else { $key }
        $wantedVal  = $property.Value

        # Check if the property even exists on the actual object
        $actualProp = $Actual.PSObject.Properties[$key]
        if ($null -eq $actualProp) {
            $driftItems.Add([PSCustomObject]@{
                CheckPath    = $fullPath
                ExpectedValue = $wantedVal
                ActualValue   = '<MISSING>'
                DriftType     = 'MissingProperty'
            })
            continue
        }

        $actualVal = $actualProp.Value

        # Recurse into nested objects (e.g. tags block)
        if ($wantedVal -is [PSCustomObject] -and $actualVal -is [PSCustomObject]) {
            $nestedDrift = Compare-ResourceChecks -Desired $wantedVal -Actual $actualVal -PathPrefix $fullPath
            if ($nestedDrift) {
                foreach ($item in $nestedDrift) {
                    $driftItems.Add($item)
                }
            }
        }
        else {
            # Normalize booleans coming from JSON (they arrive as bool already, but string compare guard)
            $wantedStr = if ($null -eq $wantedVal) { '<null>' } else { $wantedVal.ToString() }
            $actualStr = if ($null -eq $actualVal) { '<null>' } else { $actualVal.ToString() }

            if ($wantedStr -ne $actualStr) {
                $driftItems.Add([PSCustomObject]@{
                    CheckPath     = $fullPath
                    ExpectedValue = $wantedVal
                    ActualValue   = $actualVal
                    DriftType     = 'ValueMismatch'
                })
            }
        }
    }

    return $driftItems
}

function Invoke-ConfigIntegrityCheck {
    <#
    .SYNOPSIS
        Main entry point. Evaluates all desired-state rules against the actual snapshot.

    .OUTPUTS
        A PSCustomObject containing:
          - Results     : per-rule evaluation details
          - Summary     : aggregated counts
          - Score       : 0-100 integrity score
          - Grade       : letter grade
          - RunMetadata : timestamps and source files
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$DesiredState,

        [Parameter(Mandatory)]
        [PSCustomObject]$ActualState,

        [string]$DesiredStatePath = '',
        [string]$ActualStatePath  = ''
    )

    $runId    = [System.Guid]::NewGuid().ToString()
    $runStart = Get-Date -Format 'o'
    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Build a lookup map of actual resources by name for O(1) access
    $actualLookup = @{}
    foreach ($resource in $ActualState.resources) {
        $actualLookup[$resource.resource_name] = $resource
    }

    foreach ($rule in $DesiredState.rules) {
        $resourceName  = $rule.resource_name
        $actualResource = $actualLookup[$resourceName]

        if ($null -eq $actualResource) {
            # Resource not found in snapshot at all
            $results.Add([PSCustomObject]@{
                RuleId           = $rule.rule_id
                ResourceName     = $resourceName
                Category         = $rule.category
                Severity         = $rule.severity
                Status           = 'MISSING'
                DriftItems       = @()
                DriftCount       = 0
                CheckCount       = 0
                RemediationHint  = $rule.remediation_hint
                Notes            = "Resource '$resourceName' not found in actual-state snapshot."
            })
            continue
        }

        # Count total checks (flattened)
        $checkCount = Get-FlattenedPropertyCount -Obj $rule.checks

        # Run the comparison
        $driftItems = @(Compare-ResourceChecks -Desired $rule.checks -Actual $actualResource.actual)

        $status = if ($driftItems.Count -eq 0) { 'PASS' } else { 'DRIFT' }

        $results.Add([PSCustomObject]@{
            RuleId          = $rule.rule_id
            ResourceName    = $resourceName
            Category        = $rule.category
            Severity        = $rule.severity
            Status          = $status
            DriftItems      = $driftItems
            DriftCount      = $driftItems.Count
            CheckCount      = $checkCount
            RemediationHint = $rule.remediation_hint
            Notes           = ''
        })
    }

    # Compute integrity score
    $scoreData = Get-IntegrityScore -Results $results

    return [PSCustomObject]@{
        RunId        = $runId
        RunTimestamp = $runStart
        Environment  = $DesiredState.environment
        Results      = $results
        Summary      = $scoreData.Summary
        Score        = $scoreData.Score
        Grade        = $scoreData.Grade
        RunMetadata  = [PSCustomObject]@{
            DesiredStatePath = $DesiredStatePath
            ActualStatePath  = $ActualStatePath
            SchemaVersion    = $DesiredState.schema_version
            SnapshotTime     = $ActualState.snapshot_timestamp
        }
    }
}

#endregion

#region --- Scoring ---

function Get-FlattenedPropertyCount {
    <#
    .SYNOPSIS Counts all leaf properties in a potentially nested object. #>
    [CmdletBinding()]
    [OutputType([int])]
    param([PSCustomObject]$Obj)

    $count = 0
    foreach ($prop in $Obj.PSObject.Properties) {
        if ($prop.Value -is [PSCustomObject]) {
            $count += Get-FlattenedPropertyCount -Obj $prop.Value
        }
        else {
            $count++
        }
    }
    return $count
}

function Get-IntegrityScore {
    <#
    .SYNOPSIS
        Calculates a weighted integrity score.

        Scoring model:
          - Each check carries a base weight of 1 point.
          - Severity multipliers: Critical=3x, High=2x, Medium=1.5x, Low=1x
          - A passing resource earns full weighted points.
          - A DRIFT resource loses points proportional to the fraction of checks that drifted.
          - A MISSING resource loses all its weighted points.
          - Final score = (earned / total) * 100, rounded to 1 decimal.

        Grade bands:
          A  >= 95   Environment is healthy; minor drift acceptable
          B  >= 85   Some drift present; review recommended
          C  >= 70   Meaningful drift; remediation warranted
          D  >= 50   Significant drift; escalate
          F   < 50   Critical failures; immediate action required
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[PSCustomObject]]$Results
    )

    $severityMultiplier = @{
        'Critical' = 3.0
        'High'     = 2.0
        'Medium'   = 1.5
        'Low'      = 1.0
    }

    $totalWeightedPoints  = 0.0
    $earnedWeightedPoints = 0.0

    $passCount    = 0
    $driftCount   = 0
    $missingCount = 0
    $criticalDrift = 0

    foreach ($result in $Results) {
        $multiplier = $severityMultiplier[$result.Severity]
        if ($null -eq $multiplier) { $multiplier = 1.0 }

        $ruleWeight = $result.CheckCount * $multiplier
        $totalWeightedPoints += $ruleWeight

        switch ($result.Status) {
            'PASS' {
                $earnedWeightedPoints += $ruleWeight
                $passCount++
            }
            'DRIFT' {
                # Partial credit: earn points for checks that passed
                $passedChecks = $result.CheckCount - $result.DriftCount
                $earnedFraction = if ($result.CheckCount -gt 0) {
                    [double]$passedChecks / $result.CheckCount
                } else { 0.0 }
                $earnedWeightedPoints += ($ruleWeight * $earnedFraction)
                $driftCount++
                if ($result.Severity -eq 'Critical') { $criticalDrift++ }
            }
            'MISSING' {
                # Zero credit
                $missingCount++
                if ($result.Severity -eq 'Critical') { $criticalDrift++ }
            }
        }
    }

    $score = if ($totalWeightedPoints -gt 0) {
        [math]::Round(($earnedWeightedPoints / $totalWeightedPoints) * 100, 1)
    } else { 100.0 }

    $grade = switch ($score) {
        { $_ -ge 95 } { 'A'; break }
        { $_ -ge 85 } { 'B'; break }
        { $_ -ge 70 } { 'C'; break }
        { $_ -ge 50 } { 'D'; break }
        default        { 'F' }
    }

    return [PSCustomObject]@{
        Score   = $score
        Grade   = $grade
        Summary = [PSCustomObject]@{
            TotalRules    = $Results.Count
            Passed        = $passCount
            Drifted       = $driftCount
            Missing       = $missingCount
            CriticalDrift = $criticalDrift
            PassRate      = if ($Results.Count -gt 0) {
                [math]::Round(($passCount / $Results.Count) * 100, 1)
            } else { 100.0 }
        }
    }
}

#endregion

#region --- Output Formatters ---

function Export-IntegrityReport {
    <#
    .SYNOPSIS
        Exports the integrity run result to JSON and optionally a console summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RunResult,

        [string]$OutputPath = '',
        [switch]$ConsoleSummary
    )

    if ($OutputPath) {
        $RunResult | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Verbose "Report written to: $OutputPath"
    }

    if ($ConsoleSummary) {
        Write-IntegrityConsoleSummary -RunResult $RunResult
    }
}

function Write-IntegrityConsoleSummary {
    [CmdletBinding()]
    param([PSCustomObject]$RunResult)

    $divider = '=' * 60
    Write-Host $divider -ForegroundColor Cyan
    Write-Host "  CONFIG INTEGRITY RUNNER - RUN SUMMARY" -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor Cyan
    Write-Host "  Run ID     : $($RunResult.RunId)"
    Write-Host "  Timestamp  : $($RunResult.RunTimestamp)"
    Write-Host "  Environment: $($RunResult.Environment)"
    Write-Host ""
    Write-Host "  SCORE: $($RunResult.Score)/100  |  GRADE: $($RunResult.Grade)" -ForegroundColor (Get-GradeColor $RunResult.Grade)
    Write-Host ""
    Write-Host "  Rules Total  : $($RunResult.Summary.TotalRules)"
    Write-Host "  Passed       : $($RunResult.Summary.Passed)" -ForegroundColor Green
    Write-Host "  Drifted      : $($RunResult.Summary.Drifted)" -ForegroundColor Yellow
    Write-Host "  Missing      : $($RunResult.Summary.Missing)" -ForegroundColor Red
    Write-Host "  Critical Hits: $($RunResult.Summary.CriticalDrift)" -ForegroundColor Red
    Write-Host $divider -ForegroundColor Cyan

    foreach ($result in $RunResult.Results) {
        $statusColor = switch ($result.Status) {
            'PASS'    { 'Green' }
            'DRIFT'   { 'Yellow' }
            'MISSING' { 'Red' }
            default   { 'White' }
        }

        Write-Host ""
        Write-Host "  [$($result.Status)] $($result.RuleId) - $($result.ResourceName) [$($result.Severity)]" -ForegroundColor $statusColor

        if ($result.DriftItems.Count -gt 0) {
            foreach ($item in $result.DriftItems) {
                Write-Host "    DRIFT: $($item.CheckPath)" -ForegroundColor Yellow
                Write-Host "      Expected : $($item.ExpectedValue)"
                Write-Host "      Actual   : $($item.ActualValue)"
            }
            Write-Host "    Hint: $($result.RemediationHint)" -ForegroundColor DarkYellow
        }

        if ($result.Status -eq 'MISSING') {
            Write-Host "    $($result.Notes)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $divider -ForegroundColor Cyan
}

function Get-GradeColor {
    param([string]$Grade)
    switch ($Grade) {
        'A'     { return 'Green' }
        'B'     { return 'Cyan' }
        'C'     { return 'Yellow' }
        'D'     { return 'DarkYellow' }
        default { return 'Red' }
    }
}

function ConvertTo-ServiceNowPayload {
    <#
    .SYNOPSIS
        Transforms a run result into a structure ready for ServiceNow REST import.

        Target tables:
          - u_azure_config_integrity_run  : one row per run (score, grade, environment)
          - u_azure_config_drift_item     : one row per drift item, FK to run

        This function returns both sets of records so the caller can POST to the
        ServiceNow Table API in two steps.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RunResult
    )

    $runRecord = [PSCustomObject]@{
        u_run_id          = $RunResult.RunId
        u_run_timestamp   = $RunResult.RunTimestamp
        u_environment     = $RunResult.Environment
        u_score           = $RunResult.Score
        u_grade           = $RunResult.Grade
        u_total_rules     = $RunResult.Summary.TotalRules
        u_passed          = $RunResult.Summary.Passed
        u_drifted         = $RunResult.Summary.Drifted
        u_missing         = $RunResult.Summary.Missing
        u_critical_drift  = $RunResult.Summary.CriticalDrift
        u_pass_rate       = $RunResult.Summary.PassRate
        u_snapshot_time   = $RunResult.RunMetadata.SnapshotTime
    }

    $driftRecords = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($result in $RunResult.Results) {
        if ($result.Status -in @('DRIFT', 'MISSING')) {
            foreach ($item in $result.DriftItems) {
                $driftRecords.Add([PSCustomObject]@{
                    u_run_id           = $RunResult.RunId
                    u_rule_id          = $result.RuleId
                    u_resource_name    = $result.ResourceName
                    u_category         = $result.Category
                    u_severity         = $result.Severity
                    u_status           = $result.Status
                    u_check_path       = $item.CheckPath
                    u_expected_value   = $item.ExpectedValue
                    u_actual_value     = $item.ActualValue
                    u_drift_type       = $item.DriftType
                    u_remediation_hint = $result.RemediationHint
                })
            }

            # MISSING resources get a single synthetic drift record
            if ($result.Status -eq 'MISSING' -and $result.DriftItems.Count -eq 0) {
                $driftRecords.Add([PSCustomObject]@{
                    u_run_id           = $RunResult.RunId
                    u_rule_id          = $result.RuleId
                    u_resource_name    = $result.ResourceName
                    u_category         = $result.Category
                    u_severity         = $result.Severity
                    u_status           = 'MISSING'
                    u_check_path       = 'resource'
                    u_expected_value   = 'present'
                    u_actual_value     = 'not found in snapshot'
                    u_drift_type       = 'MissingResource'
                    u_remediation_hint = $result.RemediationHint
                })
            }
        }
    }

    return [PSCustomObject]@{
        RunRecord    = $runRecord
        DriftRecords = $driftRecords
    }
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Import-DesiredState'
    'Import-ActualState'
    'Invoke-ConfigIntegrityCheck'
    'Export-IntegrityReport'
    'ConvertTo-ServiceNowPayload'
    'Get-IntegrityScore'
    'Compare-ResourceChecks'
    'Get-FlattenedPropertyCount'
)
