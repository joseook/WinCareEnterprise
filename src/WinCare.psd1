@{
    # WinCare Enterprise - module manifest. Version is the single source of truth
    # for the app version (read by Start-WinCare.ps1 and the packaging scripts).
    ModuleVersion        = '0.2.1'
    GUID                 = '6f0f8f8e-4a37-4c1e-9a55-2b8d0f3c7a11'
    Author               = 'WinCare Enterprise contributors'
    CompanyName          = 'WinCare Enterprise'
    Copyright            = '(c) 2026 WinCare Enterprise contributors. MIT License.'
    Description          = 'Read-first Windows diagnostics and maintenance for technicians and corporate environments.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    NestedModules        = @(
        'Core/WinCare.Core.psm1',
        'Modules/WinCare.System.psm1',
        'Modules/WinCare.Storage.psm1',
        'Modules/WinCare.Startup.psm1',
        'Modules/WinCare.Security.psm1',
        'Modules/WinCare.Diagnostics.psm1',
        'Modules/WinCare.Reporting.psm1',
        'Modules/WinCare.Cleanup.psm1',
        'Modules/WinCare.Integrity.psm1',
        'Modules/WinCare.Office.psm1',
        'Modules/WinCare.Elevation.psm1',
        'Modules/WinCare.Baseline.psm1',
        'Modules/WinCare.Health.psm1'
    )
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Windows', 'Diagnostics', 'Maintenance', 'WPF', 'Enterprise')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
