<#
.SYNOPSIS
    Deploys db/deploy.sql to SQL Server from Windows.

.DESCRIPTION
    The :r paths in deploy.sql are relative to the current directory, so the script changes to the db folder
    first, wherever it is started from. Without -SqlUser it uses Windows authentication (-E). With -SqlUser it
    uses that SQL login; set the environment variable SQLCMDPASSWORD to its password first.

.EXAMPLE
    tools\deploy\deploy.ps1 -Server SQL01

.EXAMPLE
    $env:SQLCMDPASSWORD = '...'; tools\deploy\deploy.ps1 -Server SQL01 -SqlUser deployer
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,

    [string] $SqlUser = '',

    [string] $SqlCmd = 'sqlcmd'
)

$ErrorActionPreference = 'Stop'
$dbDir = Join-Path $PSScriptRoot '..\..\db'

if ($SqlUser -eq '') {
    $auth = @('-E')
} else {
    if (-not $env:SQLCMDPASSWORD) { throw 'Set SQLCMDPASSWORD for the SQL login first.' }
    $auth = @('-U', $SqlUser, '-C')
}

Push-Location $dbDir
try {
    & $SqlCmd -S $Server @auth -I -f 65001 -b -i deploy.sql
    if ($LASTEXITCODE -ne 0) { throw "deploy.sql failed with exit code $LASTEXITCODE" }
    Write-Host 'deployment finished'
} finally {
    Pop-Location
}
