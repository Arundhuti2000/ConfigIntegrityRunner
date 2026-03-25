@{
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Platform Engineering'
    Description       = 'Azure configuration drift detection and integrity scoring'
    PowerShellVersion = '7.0'
    RootModule        = 'ConfigIntegrityRunner.psm1'
    FunctionsToExport = @(
        'Import-DesiredState'
        'Import-ActualState'
        'Invoke-ConfigIntegrityCheck'
        'Export-IntegrityReport'
        'ConvertTo-ServiceNowPayload'
        'Get-IntegrityScore'
        'Compare-ResourceChecks'
        'Get-FlattenedPropertyCount'
    )
}
