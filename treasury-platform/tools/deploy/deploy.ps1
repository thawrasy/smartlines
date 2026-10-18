<#
.SYNOPSIS
    Deploys db/deploy.sql to SQL Server from Windows.

.DESCRIPTION
    The :r paths in deploy.sql are relative to the current directory, so the script changes to the db folder
    first, wherever it is started from. Without -SqlUser it uses Windows authentication (-E). With -SqlUser it
    uses that SQL login; set the environment variable SQLCMDPASSWORD to its password first. The server certificate
    is verified: -TrustServerCertificate is refused unless BANKFAS_ALLOW_TRUST_CERT=1, which only a throwaway test
    server may need (DOC-S05 section 5.3, DQ-S05-7). Before deploy.sql it runs db/ops/deploy_preflight.sql with the
    release register, like deploy.sh (gate G4, ADR 0014; self-review E5): not sa or a sysadmin, the SQL Server build
    and Ubuntu release of versions.json, BankFas empty in its collation, RECURSIVE_TRIGGERS OFF. This path has not
    been run (ADR 0001); production deploys with tools/deploy/deploy.sh.

.EXAMPLE
    tools\deploy\deploy.ps1 -Server SQL01

.EXAMPLE
    $env:SQLCMDPASSWORD = '...'; tools\deploy\deploy.ps1 -Server SQL01 -SqlUser deployer
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,

    [string] $SqlUser = '',

    [string] $SqlCmd = 'sqlcmd',

    [switch] $TrustServerCertificate,

    [string] $Versions = ''
)

$ErrorActionPreference = 'Stop'
$dbDir = Join-Path $PSScriptRoot '..\..\db'
if ($Versions -eq '') { $Versions = Join-Path $PSScriptRoot '..\..\versions.json' }
if ($TrustServerCertificate -and $env:BANKFAS_ALLOW_TRUST_CERT -ne '1') {
    throw '-TrustServerCertificate trusts any server certificate; only a throwaway test server may use it (BANKFAS_ALLOW_TRUST_CERT=1, DOC-S05 section 5.3)'
}

if ($SqlUser -eq '') {
    $auth = @('-E')
} else {
    if (-not $env:SQLCMDPASSWORD) { throw 'Set SQLCMDPASSWORD for the SQL login first.' }
    $auth = @('-U', $SqlUser)
}
if ($TrustServerCertificate) { $auth += '-C' }

# The release register: the SQL Server build and the Ubuntu release of the database host (gate G4).
$dbHost = (Get-Content -Raw -Encoding UTF8 $Versions | ConvertFrom-Json).database_host
$expectVersion = [string] $dbHost.sqlserver.product_version
$expectOs = [string] $dbHost.os_release
if ($expectVersion -notmatch '^\d+(\.\d+){3}$' -or $expectOs -notmatch '^\d+\.\d+$') {
    throw "$Versions must give database_host.sqlserver.product_version and database_host.os_release"
}
$preflight = New-TemporaryFile
$run = New-TemporaryFile
Push-Location $dbDir
try {
    $sql = Get-Content -Raw -Encoding UTF8 (Join-Path $dbDir 'ops\deploy_preflight.sql')
    $sql = $sql.Replace('$(BANKFAS_EXPECT_VERSION)', $expectVersion).Replace('$(BANKFAS_EXPECT_OS)', $expectOs)
    Set-Content -Path $preflight -Value $sql -Encoding UTF8
    # One session: deploy.sql starts only after the mark the preflight sets in it (50146).
    Set-Content -Path $run -Value (":r `"$preflight`"`nGO`n:r `"" + (Join-Path $dbDir 'deploy.sql') + "`"") -Encoding UTF8
    & $SqlCmd -S $Server @auth -I -f 65001 -b -i $run
    if ($LASTEXITCODE -ne 0) { throw "the preflight or deploy.sql failed with exit code $LASTEXITCODE" }
    Write-Host 'deployment finished'
} finally {
    Pop-Location
    Remove-Item -Force $preflight, $run
}
