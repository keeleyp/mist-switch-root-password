<#
.SYNOPSIS
    Set the local root password override on one or more Juniper Mist switches.

.DESCRIPTION
    For each switch MAC address the script:
      1. looks the MAC up in the org inventory to find the site (and the
         Virtual Chassis MAC if the switch is a VC member),
      2. reads the switch config  GET /sites/{site}/devices/00000000-0000-0000-1000-{mac},
      3. takes the existing switch_mgmt block (or a new empty one), sets or
         replaces root_password and leaves every other switch_mgmt field as is,
      4. PUTs only { switch_mgmt = ... } back and re-reads the device to verify.

    Single switch : -Mac and -Password (prompted securely if -Password is left out).
    Many switches : -File pointing at a CSV of mac,password lines; a summary
                    table is printed at the end.

    Use -WhatIf to look everything up and show what would change without writing.

.PARAMETER Mac
    Switch MAC address. Any format: 010203040506, 01:02:03:04:05:06, 01-02-03-04-05-06.

.PARAMETER Password
    New root password. Wrap in single quotes so PowerShell doesn't expand $ or `.
    Leave out to be prompted (input hidden, entered twice).

.PARAMETER File
    CSV file of mac,password pairs, one per line. A header line "mac,password",
    blank lines and lines starting with # are ignored. Everything after the
    first comma is the password, so passwords may contain commas.

.PARAMETER IniPath
    Settings file. Defaults to mist_switch_root_password.ini next to this script.

.PARAMETER OrgId
    Override [mist] org_id from the ini.

.PARAMETER Cloud
    Override [mist] cloud from the ini (gc3, eu, global01, api.ac2.mist.com ...).

.EXAMPLE
    ./Set-MistSwitchRootPassword.ps1 -Mac 01:02:03:04:05:06 -Password 'N3w!Root#2026'

.EXAMPLE
    ./Set-MistSwitchRootPassword.ps1 -Mac 010203040506          # prompts for the password

.EXAMPLE
    ./Set-MistSwitchRootPassword.ps1 -File .\switches.csv -WhatIf
    ./Set-MistSwitchRootPassword.ps1 -File .\switches.csv
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single', Mandatory = $true, Position = 0)]
    [string]$Mac,

    [Parameter(ParameterSetName = 'Single', Position = 1)]
    [string]$Password,

    [Parameter(ParameterSetName = 'Batch', Mandatory = $true)]
    [string]$File,

    [string]$IniPath = (Join-Path $PSScriptRoot 'mist_switch_root_password.ini'),
    [string]$OrgId,
    [string]$Cloud
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DryRun = [bool]$WhatIfPreference

# ---------------------------------------------------------------- helpers ---

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Read-IniFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail "Settings file not found: $Path`n       Copy mist_switch_root_password.ini.example to mist_switch_root_password.ini and fill it in."
    }
    $ini = @{}
    $section = ''
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim().ToLower()
            if (-not $ini.ContainsKey($section)) { $ini[$section] = @{} }
            continue
        }
        if ($line -match '^([^=]+)=(.*)$') {
            if ($section -eq '') { Fail "Key '$($Matches[1].Trim())' in $Path is outside any [section]." }
            $ini[$section][$Matches[1].Trim().ToLower()] = $Matches[2].Trim()
        }
    }
    return $ini
}

function Get-IniValue($Ini, [string]$Section, [string]$Key) {
    if ($Ini.ContainsKey($Section) -and $Ini[$Section].ContainsKey($Key)) { return $Ini[$Section][$Key] }
    return ''
}

function Resolve-ApiHost([string]$CloudName) {
    $c = $CloudName.Trim().ToLower() -replace '^https?://', '' -replace '/.*$', ''
    if ($c -match '\.') { return ($c -replace '^manage\.', 'api.') }
    if ($c -in @('global01', 'us', 'global', 'mist')) { return 'api.mist.com' }
    return "api.$c.mist.com"
}

function Test-Bool([string]$Value, [bool]$Default) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return $Value.Trim().ToLower() -in @('true', 'yes', '1', 'on')
}

function ConvertTo-MistMac([string]$Value) {
    $m = ($Value -replace '[\s:\-\.]', '').ToLower()
    if ($m -notmatch '^[0-9a-f]{12}$') { return $null }
    return $m
}

function Format-Mac([string]$m) { return (($m -split '(..)' | Where-Object { $_ }) -join ':') }

function Test-RootPassword([string]$Pw) {
    if ([string]::IsNullOrEmpty($Pw))       { return 'is empty.' }
    if ($Pw -ne $Pw.Trim())                 { return 'has leading or trailing spaces.' }
    if ($Pw -notmatch '^[\x20-\x7E]+$')     { return 'may only contain printable ASCII characters.' }
    if ($Pw.Length -lt 6)                   { return 'must be at least 6 characters (Junos minimum).' }
    if ($Pw.Length -gt 128)                 { return 'must be at most 128 characters.' }
    return $null
}

# Throws (rather than exits) so batch mode can record the failure and carry on.
function Invoke-Mist([string]$Method, [string]$Path, $Body = $null) {
    $params = @{
        Method      = $Method
        Uri         = "$script:BaseUrl$Path"
        Headers     = @{ Authorization = "Token $script:Token"; Accept = 'application/json' }
        ContentType = 'application/json'
    }
    if ($null -ne $Body)           { $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    if ($script:Proxy)             { $params.Proxy = $script:Proxy }
    if ($script:ProxyDefaultCreds) { $params.ProxyUseDefaultCredentials = $true }
    if (-not $script:VerifySsl -and $PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }

        if ($null -eq $status) {
            $msg = "Could not reach $script:BaseUrl : $detail"
            if ($detail -match 'SSL|TLS|certificate|trust') {
                $msg += "`n       Looks like a certificate problem (Zscaler / TLS inspection?)." +
                        "`n       Install the proxy's root CA in the OS certificate store, or as a last resort set [network] verify_ssl = false."
            }
            elseif ($detail -match 'proxy|407') {
                $msg += "`n       Check [network] proxy / proxy_use_default_credentials in the .ini."
            }
            throw $msg
        }
        switch ($status) {
            401 { throw "HTTP 401 Unauthorized - the API token is invalid or for a different cloud ($script:BaseUrl)." }
            403 { throw "HTTP 403 Forbidden on $Method $Path - the token has no (write) access. $detail" }
            404 { throw "HTTP 404 Not Found - $Method $Path" }
            default { throw "HTTP $status on $Method $Path - $detail" }
        }
    }
}

$script:SiteNames = @{}
function Get-SiteName([string]$SiteId) {
    if (-not $script:SiteNames.ContainsKey($SiteId)) {
        try   { $script:SiteNames[$SiteId] = [string](Invoke-Mist 'GET' "/sites/$SiteId").name }
        catch { $script:SiteNames[$SiteId] = $SiteId }
    }
    return $script:SiteNames[$SiteId]
}

function Get-InventoryEntry([string]$m) {
    # PS 7 returns a JSON array as one object; ForEach-Object unrolls it (no-op on 5.1).
    $inv = @(Invoke-Mist 'GET' "/orgs/$script:OrgId/inventory?mac=$m&vc=true" | ForEach-Object { $_ })
    return $inv | Where-Object { $_ -and $_.PSObject.Properties['mac'] -and $_.mac -eq $m } | Select-Object -First 1
}

function Find-Switch([string]$m) {
    # Inventory holds every claimed device, online or not, with its site_id.
    $hit = Get-InventoryEntry $m
    if (-not $hit) { throw "MAC $(Format-Mac $m) not found in the org inventory." }
    if ($hit.type -ne 'switch') { throw "MAC $(Format-Mac $m) is a '$($hit.type)', not a switch." }

    # Virtual Chassis: the physical members show in the inventory as 'unassigned'
    # with vc_mac set; the config lives on the VC device (virtual MAC) at the site.
    $cfgMac = $m
    if ($hit.PSObject.Properties['vc_mac'] -and $hit.vc_mac -and $hit.vc_mac -ne $m) {
        $cfgMac = [string]$hit.vc_mac
        $vc = Get-InventoryEntry $cfgMac
        if (-not $vc) { throw "Switch $(Format-Mac $m) is a member of VC $(Format-Mac $cfgMac), which is not in the inventory." }
        $hit = $vc
    }
    if (-not $hit.PSObject.Properties['site_id'] -or -not $hit.site_id) {
        throw "Switch $(Format-Mac $cfgMac) is in the inventory but not assigned to a site."
    }
    return [pscustomobject]@{ SiteId = [string]$hit.site_id; ConfigMac = $cfgMac }
}

function Set-RootPassword([string]$InputMac, [string]$NewPassword) {
    $r = [ordered]@{ MAC = $InputMac; Switch = ''; Site = ''; Result = ''; Note = '' }

    $m = ConvertTo-MistMac $InputMac
    if (-not $m) { $r.Result = 'FAILED'; $r.Note = 'Not a valid MAC address.'; return [pscustomobject]$r }
    $r.MAC = Format-Mac $m

    $problem = Test-RootPassword $NewPassword
    if ($problem) { $r.Result = 'FAILED'; $r.Note = "Password $problem"; return [pscustomobject]$r }

    try {
        $loc  = Find-Switch $m
        $r.Site = Get-SiteName $loc.SiteId
        if ($loc.ConfigMac -ne $m) { $r.Note = "VC member - set on VC $(Format-Mac $loc.ConfigMac). " }

        $path = "/sites/$($loc.SiteId)/devices/00000000-0000-0000-1000-$($loc.ConfigMac)"
        $dev  = Invoke-Mist 'GET' $path
        $r.Switch = if ($dev.PSObject.Properties['name'] -and $dev.name) { [string]$dev.name } else { '(no name)' }

        if ($dev.PSObject.Properties['disable_auto_config'] -and $dev.disable_auto_config) {
            $r.Note += 'Config management disabled on this switch - Mist will not push it. '
        }
        if ($dev.PSObject.Properties['mist_configured'] -and $dev.mist_configured -eq $false) {
            $r.Note += 'Switch is not Mist-configured (monitor only) - change will not reach it. '
        }

        # Keep every existing switch_mgmt field; only add/replace root_password.
        $hasMgmt = $dev.PSObject.Properties['switch_mgmt'] -and $null -ne $dev.switch_mgmt
        $mgmt = if ($hasMgmt) { $dev.switch_mgmt } else { [pscustomobject]@{} }
        $current = if ($mgmt.PSObject.Properties['root_password']) { [string]$mgmt.root_password } else { $null }

        if ($null -ne $current -and $current -ceq $NewPassword) {
            $r.Result = 'UNCHANGED'; $r.Note += 'Already set to this password.'
            return [pscustomobject]$r
        }

        $action = if ($null -ne $current) { 'replace root_password' }
                  elseif ($hasMgmt) { 'add root_password to switch_mgmt' }
                  else { 'add switch_mgmt with root_password' }

        if (-not $PSCmdlet.ShouldProcess("$($r.Switch) ($($r.MAC)) at $($r.Site)", $action)) {
            $r.Result = 'WOULD CHANGE'; $r.Note += "Would $action."
            return [pscustomobject]$r
        }

        $mgmt | Add-Member -NotePropertyName root_password -NotePropertyValue $NewPassword -Force
        $null = Invoke-Mist 'PUT' $path @{ switch_mgmt = $mgmt }

        $check = Invoke-Mist 'GET' $path
        $after = if ($check.PSObject.Properties['switch_mgmt'] -and $check.switch_mgmt -and
                     $check.switch_mgmt.PSObject.Properties['root_password']) { [string]$check.switch_mgmt.root_password } else { $null }
        if ($after -cne $NewPassword) {
            $r.Result = 'FAILED'; $r.Note += 'PUT returned OK but read-back shows a different root_password.'
        }
        else {
            $r.Result = 'UPDATED'; $r.Note += "Did $action (verified)."
        }
    }
    catch {
        $r.Result = 'FAILED'; $r.Note += $_.Exception.Message
    }
    return [pscustomobject]$r
}

# ----------------------------------------------------------------- config ---

$ini = Read-IniFile $IniPath

$script:Token = Get-IniValue $ini 'mist' 'api_token'
$cloudName    = if ($Cloud) { $Cloud } else { Get-IniValue $ini 'mist' 'cloud' }
$script:OrgId = if ($OrgId) { $OrgId } else { Get-IniValue $ini 'mist' 'org_id' }
if (-not $script:Token) { Fail '[mist] api_token is missing or empty in the .ini file.' }
if (-not $cloudName)    { Fail '[mist] cloud is missing in the .ini file (or pass -Cloud).' }
if (-not $script:OrgId) { Fail '[mist] org_id is missing in the .ini file (or pass -OrgId).' }

$script:VerifySsl         = Test-Bool (Get-IniValue $ini 'network' 'verify_ssl') $true
$script:Proxy             = Get-IniValue $ini 'network' 'proxy'
$script:ProxyDefaultCreds = Test-Bool (Get-IniValue $ini 'network' 'proxy_use_default_credentials') $false

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not $script:VerifySsl) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
}
if (-not $script:VerifySsl) {
    Write-Host 'WARNING: verify_ssl = false - TLS certificate checks are disabled.' -ForegroundColor Yellow
}

$script:BaseUrl = "https://$(Resolve-ApiHost $cloudName)/api/v1"

# ------------------------------------------------------------ work list -----

$jobs = @()
if ($PSCmdlet.ParameterSetName -eq 'Batch') {
    if (-not (Test-Path -LiteralPath $File)) { Fail "File not found: $File" }
    $n = 0
    foreach ($raw in Get-Content -LiteralPath $File) {
        $n++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $i = $line.IndexOf(',')
        if ($i -lt 0) { Fail "$File line ${n}: expected mac,password" }
        $mac = $line.Substring(0, $i).Trim().Trim('"')
        $pw  = $line.Substring($i + 1)
        if ($pw.Length -ge 2 -and $pw.StartsWith('"') -and $pw.EndsWith('"')) { $pw = $pw.Substring(1, $pw.Length - 2) }
        if ($mac -match '^mac$') { continue }   # header row
        $jobs += [pscustomobject]@{ Mac = $mac; Password = $pw }
    }
    if ($jobs.Count -eq 0) { Fail "No mac,password lines found in $File" }

    $dupes = $jobs | ForEach-Object { ConvertTo-MistMac $_.Mac } | Where-Object { $_ } |
             Group-Object | Where-Object Count -gt 1 | ForEach-Object { Format-Mac $_.Name }
    if ($dupes) { Fail "These MACs appear more than once in ${File}: $($dupes -join ', ')" }
}
else {
    if (-not $PSBoundParameters.ContainsKey('Password')) {
        $p1 = Read-Host 'New root password' -AsSecureString
        $p2 = Read-Host 'Re-enter new root password' -AsSecureString
        $plain = { param($s) [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }
        $Password = & $plain $p1
        if ((& $plain $p2) -cne $Password) { Fail 'The two entries do not match - nothing changed.' }
    }
    $jobs += [pscustomobject]@{ Mac = $Mac; Password = $Password }
}

# ---------------------------------------------------------------- run -------

# One up-front call so a bad token / cloud / proxy fails once, not per switch.
try   { $org = Invoke-Mist 'GET' "/orgs/$script:OrgId" }
catch { Fail $_.Exception.Message }

Write-Host ''
Write-Host "Mist API : $script:BaseUrl"
Write-Host "Org      : $($org.name)"
if ($DryRun) { Write-Host 'Mode     : WhatIf - nothing will be written' -ForegroundColor Yellow }
Write-Host ''

$results = @()
$k = 0
foreach ($j in $jobs) {
    $k++
    if ($jobs.Count -gt 1) { Write-Progress -Activity 'Setting switch root passwords' -Status $j.Mac -PercentComplete (100 * $k / $jobs.Count) }
    $results += Set-RootPassword $j.Mac $j.Password
}
if ($jobs.Count -gt 1) { Write-Progress -Activity 'Setting switch root passwords' -Completed }

$results | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

$failed = @($results | Where-Object Result -eq 'FAILED').Count
$counts = $results | Group-Object Result | ForEach-Object { "$($_.Name) $($_.Count)" }
$colour = if ($failed) { 'Red' } else { 'Green' }
Write-Host "Summary: $($results.Count) switch(es) - $($counts -join ', ')" -ForegroundColor $colour

if ($failed) { exit 1 }
