<#
.SYNOPSIS
    Locates the 32-bit MSVC environment (vcvars32.bat) on this machine or CI runner.
#>
function Join-BasePath([string]$Base, [string]$Child) {
    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    return (Join-Path $Base $Child)
}

function Find-VcVars32 {
    $vswhereCandidates = @(
        (Join-BasePath $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-BasePath ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-BasePath $env:LOCALAPPDATA 'Microsoft\VisualStudio\Installer\vswhere.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $installRoots = @()
    foreach ($vswhere in $vswhereCandidates) {
        $found = & $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($found)) { $installRoots += $found.Trim() }
    }

    $installRoots += @(
        (Join-BasePath $env:ProgramFiles 'Microsoft Visual Studio\2022'),
        (Join-BasePath ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022')
    )

    foreach ($root in $installRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }

        $direct = Join-Path $root 'VC\Auxiliary\Build\vcvars32.bat'
        if (Test-Path -LiteralPath $direct) { return $direct }

        foreach ($edition in @('Enterprise', 'Professional', 'Community', 'BuildTools')) {
            $candidate = Join-BasePath $root "$edition\VC\Auxiliary\Build\vcvars32.bat"
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        }

        $nested = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'VC\Auxiliary\Build\vcvars32.bat' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($nested) { return $nested }
    }

    return $null
}
