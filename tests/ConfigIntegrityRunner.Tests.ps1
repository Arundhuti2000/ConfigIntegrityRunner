#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '3.4.0' }

$modulePath = Join-Path $PSScriptRoot '../src/ConfigIntegrityRunner.psm1'
Import-Module $modulePath -Force

# Helper: build a minimal PSCustomObject from a hashtable
function New-PSObj {
    param([hashtable]$h)
    $obj = [PSCustomObject]@{}
    foreach ($kv in $h.GetEnumerator()) {
        $obj | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value
    }
    return $obj
}

Describe 'Compare-ResourceChecks' {
    Context 'Identical desired and actual state' {
        It 'Returns empty drift list when everything matches' {
            $desired = New-PSObj @{ vm_size = 'Standard_D2s_v3'; https_only = $true }
            $actual  = New-PSObj @{ vm_size = 'Standard_D2s_v3'; https_only = $true }

            $result = Compare-ResourceChecks -Desired $desired -Actual $actual
            $result.Count | Should Be 0
        }
    }

    Context 'Simple value mismatch' {
        It 'Detects a single scalar drift' {
            $desired = New-PSObj @{ vm_size = 'Standard_D2s_v3' }
            $actual  = New-PSObj @{ vm_size = 'Standard_B2s' }

            $result = Compare-ResourceChecks -Desired $desired -Actual $actual
            $result.Count | Should Be 1
            $result[0].DriftType | Should Be 'ValueMismatch'
            $result[0].ExpectedValue | Should Be 'Standard_D2s_v3'
            $result[0].ActualValue | Should Be 'Standard_B2s'
        }
    }

    Context 'Nested property drift' {
        It 'Detects drift inside a nested object (tags)' {
            $desired = New-PSObj @{
                tags = New-PSObj @{ Env = 'Prod'; Owner = 'TeamA' }
            }
            $actual = New-PSObj @{
                tags = New-PSObj @{ Env = 'Dev'; Owner = 'TeamA' }
            }

            $result = Compare-ResourceChecks -Desired $desired -Actual $actual
            $result.Count | Should Be 1
            $result[0].CheckPath | Should Be 'tags.Env'
        }
    }

    Context 'Missing property' {
        It 'Detects when a property is missing on actual resource' {
            $desired = New-PSObj @{ key1 = 'val1' }
            $actual  = New-PSObj @{ other = 'val2' }

            $result = Compare-ResourceChecks -Desired $desired -Actual $actual
            $result.Count | Should Be 1
            $result[0].DriftType | Should Be 'MissingProperty'
        }
    }
}

Describe 'Get-IntegrityScore' {
    Context 'Scoring logic' {
        It 'Calculates 100% score for a perfect run' {
            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            $results.Add([PSCustomObject]@{
                Status     = 'PASS'
                Severity   = 'High'
                CheckCount = 5
                DriftCount = 0
            })

            $score = Get-IntegrityScore -Results $results
            $score.Score | Should Be 100.0
            $score.Grade | Should Be 'A'
        }

        It 'Calculates 0% score for a total failure' {
            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            $results.Add([PSCustomObject]@{
                Status     = 'MISSING'
                Severity   = 'Medium'
                CheckCount = 10
                DriftCount = 0
            })

            $score = Get-IntegrityScore -Results $results
            $score.Score | Should Be 0.0
            $score.Grade | Should Be 'F'
        }

        It 'Calculates partial credit for partial drift' {
            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            $results.Add([PSCustomObject]@{
                Status     = 'DRIFT'
                Severity   = 'Low'
                CheckCount = 10
                DriftCount = 2
            })
            # Pass fraction = 8/10 = 0.8
            # Weight = 1.0 (Low). Earned = 0.8. Total = 1.0. 
            # Score = 80.0

            $score = Get-IntegrityScore -Results $results
            $score.Score | Should Be 80.0
            $score.Grade | Should Be 'C' 
        }
        
        It 'Applies severity multipliers correctly' {
            # Critical (3x) Pass vs Low (1x) Fail
            # Critical: 1 check, Pass. Points = 1 * 3 = 3. Earned = 3.
            # Low: 1 check, Fail. Points = 1 * 1 = 1. Earned = 0.
            # Total Points = 4. Earned = 3. Score = 75%.
            
            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            $results.Add([PSCustomObject]@{
                Status     = 'PASS'
                Severity   = 'Critical'
                CheckCount = 1
                DriftCount = 0
            })
            $results.Add([PSCustomObject]@{
                Status     = 'MISSING' # 0 credit
                Severity   = 'Low'
                CheckCount = 1
                DriftCount = 0
            })

            $score = Get-IntegrityScore -Results $results
            $score.Score | Should Be 75.0
        }
    }
}
