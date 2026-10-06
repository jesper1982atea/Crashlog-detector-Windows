Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NativePowerShell {
    if ($env:OS -ne 'Windows_NT') { throw 'Installation stöds endast på Windows.' }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Använd 64-bitars Windows PowerShell via Sysnative från Intunes 32-bitars installationsprocess.'
    }
}

function Assert-NoReparsePoints {
    param([Parameter(Mandatory)][string]$Root)
    $item = Get-Item -LiteralPath $Root -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse point tillåts inte: $Root"
    }
    if (-not $item.PSIsContainer) { throw "Installationssökvägen är inte en katalog: $Root" }
    # Traverse one level at a time; never follow a junction during validation.
    foreach ($child in Get-ChildItem -LiteralPath $Root -Force) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point tillåts inte: $($child.FullName)"
        }
        if ($child.PSIsContainer) { Assert-NoReparsePoints $child.FullName }
    }
}

function Protect-InstallationDirectory {
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path -LiteralPath $Root) { Assert-NoReparsePoints $Root }
    else { [void][IO.Directory]::CreateDirectory($Root) }
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($identity in @($system, $admins)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Root -AclObject $acl
    # Remove explicit permissions left by older/user-created files and directories.
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        $childAcl = Get-Acl -LiteralPath $item.FullName
        $childAcl.SetAccessRuleProtection($false, $false)
        foreach ($rule in @($childAcl.Access | Where-Object { -not $_.IsInherited })) {
            [void]$childAcl.RemoveAccessRuleSpecific($rule)
        }
        $childAcl.SetOwner($admins)
        Set-Acl -LiteralPath $item.FullName -AclObject $childAcl
    }
}

Export-ModuleMember -Function Assert-NativePowerShell, Assert-NoReparsePoints, Protect-InstallationDirectory
