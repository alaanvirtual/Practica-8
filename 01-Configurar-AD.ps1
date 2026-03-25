# =============================================================================
# SCRIPT 1: Configuracion de Active Directory - UOs y Usuarios desde CSV
# Archivo: 01-Configurar-AD.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================

#Requires -RunAsAdministrator

param(
    [string]$DomainName    = "practica.local",
    [string]$DomainNetBIOS = "PRACTICA",
    [string]$SafePassword  = "Admin@12345",
    [string]$CSVPath       = "C:\Scripts\usuarios.csv"
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
    Add-Content -Path "C:\Scripts\Logs\01-AD-Setup.log" -Value "[$timestamp][$Level] $Message"
}

function Ensure-LogDirectory {
    if (-not (Test-Path "C:\Scripts\Logs")) {
        New-Item -ItemType Directory -Path "C:\Scripts\Logs" -Force | Out-Null
    }
}

Ensure-LogDirectory
Write-Log "===== INICIO: Configuracion de Active Directory =====" "INFO"

if (-not (Get-WindowsFeature -Name AD-Domain-Services).Installed) {
    Write-Log "Instalando Active Directory Domain Services..." "INFO"
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
    Write-Log "AD DS instalado correctamente." "OK"
}

try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Log "El dominio $($domain.DNSRoot) ya existe. Saltando promocion." "WARN"
}
catch {
    Write-Log "Promoviendo servidor como Controlador de Dominio: $DomainName" "INFO"
    $securePass = ConvertTo-SecureString $SafePassword -AsPlainText -Force
    Install-ADDSForest `
        -DomainName                    $DomainName `
        -DomainNetbiosName             $DomainNetBIOS `
        -SafeModeAdministratorPassword $securePass `
        -InstallDns `
        -Force `
        -NoRebootOnCompletion
    Write-Log "Dominio creado. El servidor se reiniciara." "OK"
    Write-Log "Ejecuta este script nuevamente despues del reinicio." "WARN"
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit
}

Import-Module ActiveDirectory

# ---------------------------------------------------------------------------
# RESOLUCION DE NOMBRES POR SID — funciona en cualquier idioma del SO
# S-1-5-32-544 = Administrators / Administradores
# S-1-5-18     = SYSTEM / SISTEMA
# ---------------------------------------------------------------------------
$sidAdmins   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$sidSystem   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$nombreAdmins = $sidAdmins.Translate([System.Security.Principal.NTAccount]).Value
$nombreSystem = $sidSystem.Translate([System.Security.Principal.NTAccount]).Value

# Domain Users (SID-513 del dominio) para el share SMB
$domainSID      = (Get-ADDomain).DomainSID
$sidDomUsers    = New-Object System.Security.Principal.SecurityIdentifier("$domainSID-513")
$nombreDomUsers = $sidDomUsers.Translate([System.Security.Principal.NTAccount]).Value

Write-Log "Administradores resuelto: $nombreAdmins" "INFO"
Write-Log "SYSTEM resuelto:          $nombreSystem" "INFO"
Write-Log "Domain Users resuelto:    $nombreDomUsers" "INFO"

# ---------------------------------------------------------------------------
# PASO 1 - CREAR ESTRUCTURA DE UOs
# ---------------------------------------------------------------------------
Write-Log "Creando Unidades Organizativas..." "INFO"

$domainDN = (Get-ADDomain).DistinguishedName

$UOs = @(
    @{ Name = "Practica"; Path = $domainDN },
    @{ Name = "Cuates";   Path = "OU=Practica,$domainDN" },
    @{ Name = "NoCuates"; Path = "OU=Practica,$domainDN" },
    @{ Name = "Equipos";  Path = "OU=Practica,$domainDN" }
)

foreach ($ou in $UOs) {
    $ouDN = "OU=$($ou.Name),$($ou.Path)"
    try {
        Get-ADOrganizationalUnit -Identity $ouDN -ErrorAction Stop | Out-Null
        Write-Log "OU ya existe: $($ou.Name)" "WARN"
    }
    catch {
        New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -ProtectedFromAccidentalDeletion $false
        Write-Log "OU creada: $($ou.Name)" "OK"
    }
}

# ---------------------------------------------------------------------------
# PASO 2 - CREAR GRUPOS DE SEGURIDAD
# ---------------------------------------------------------------------------
Write-Log "Creando grupos de seguridad..." "INFO"

$grupos = @(
    @{ Name = "GRP_Cuates";   OU = "OU=Cuates,OU=Practica,$domainDN";   Desc = "Grupo Cuates - Acceso 8AM a 3PM" },
    @{ Name = "GRP_NoCuates"; OU = "OU=NoCuates,OU=Practica,$domainDN"; Desc = "Grupo NoCuates - Acceso 3PM a 2AM" }
)

foreach ($grp in $grupos) {
    try {
        Get-ADGroup -Identity $grp.Name -ErrorAction Stop | Out-Null
        Write-Log "Grupo ya existe: $($grp.Name)" "WARN"
    }
    catch {
        New-ADGroup -Name $grp.Name `
                    -GroupScope Global `
                    -GroupCategory Security `
                    -Path $grp.OU `
                    -Description $grp.Desc
        Write-Log "Grupo creado: $($grp.Name)" "OK"
    }
}

# ---------------------------------------------------------------------------
# PASO 3 - CREAR USUARIOS DESDE CSV
# ---------------------------------------------------------------------------
Write-Log "Leyendo CSV: $CSVPath" "INFO"

if (-not (Test-Path $CSVPath)) {
    Write-Log "ERROR: No se encontro el CSV en $CSVPath" "ERROR"
    exit 1
}

$usuarios = Import-Csv -Path $CSVPath

foreach ($u in $usuarios) {
    $dept   = $u.Departamento.Trim()
    $ouPath = if ($dept -eq "Cuates") {
        "OU=Cuates,OU=Practica,$domainDN"
    } else {
        "OU=NoCuates,OU=Practica,$domainDN"
    }

    $secPass = ConvertTo-SecureString $u.Contrasena -AsPlainText -Force
    $upn     = "$($u.Usuario)@$DomainName"

    try {
        Get-ADUser -Identity $u.Usuario -ErrorAction Stop | Out-Null
        Write-Log "Usuario ya existe: $($u.Usuario)" "WARN"
    }
    catch {
        New-ADUser `
            -Name                 "$($u.Nombre) $($u.Apellido)" `
            -GivenName            $u.Nombre `
            -Surname              $u.Apellido `
            -SamAccountName       $u.Usuario `
            -UserPrincipalName    $upn `
            -EmailAddress         $u.Email `
            -Department           $dept `
            -Path                 $ouPath `
            -AccountPassword      $secPass `
            -Enabled              $true `
            -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false
        Write-Log "Usuario creado: $($u.Usuario) -> OU: $dept" "OK"
    }

    $grupo = if ($dept -eq "Cuates") { "GRP_Cuates" } else { "GRP_NoCuates" }
    try {
        Add-ADGroupMember -Identity $grupo -Members $u.Usuario -ErrorAction Stop
        Write-Log "  -> Agregado a $grupo" "OK"
    }
    catch {
        Write-Log "  -> Ya pertenece a $grupo o error: $_" "WARN"
    }

    # Crear carpeta personal
    $homePath = "C:\Usuarios\$($u.Usuario)"
    if (-not (Test-Path $homePath)) {
        New-Item -ItemType Directory -Path $homePath -Force | Out-Null

        $acl = Get-Acl $homePath
        $acl.SetAccessRuleProtection($true, $false)

        # ✅ CORREGIDO: usar SIDs en lugar de nombres hardcodeados
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sidAdmins, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sidSystem, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")

        # El usuario individual se resuelve desde AD (SID propio del usuario)
        $adUserObj  = Get-ADUser -Identity $u.Usuario
        $sidUsuario = New-Object System.Security.Principal.SecurityIdentifier($adUserObj.SID)
        $userRule   = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sidUsuario, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")

        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($systemRule)
        $acl.AddAccessRule($userRule)
        Set-Acl -Path $homePath -AclObject $acl
        Write-Log "  -> Carpeta creada con permisos correctos: $homePath" "OK"
    }

    Set-ADUser -Identity $u.Usuario `
        -HomeDirectory "\\$env:COMPUTERNAME\Usuarios\$($u.Usuario)" `
        -HomeDrive "H:"
}

# ---------------------------------------------------------------------------
# PASO 4 - RECURSO COMPARTIDO SMB
# ---------------------------------------------------------------------------
Write-Log "Configurando recurso compartido SMB..." "INFO"

if (-not (Get-SmbShare -Name "Usuarios" -ErrorAction SilentlyContinue)) {
    # ✅ CORREGIDO: ChangeAccess para Domain Users, no ReadAccess Everyone
    New-SmbShare -Name "Usuarios" `
                 -Path "C:\Usuarios" `
                 -FullAccess   $nombreAdmins `
                 -ChangeAccess $nombreDomUsers | Out-Null
    Write-Log "Share 'Usuarios' creado: $nombreAdmins=Full, $nombreDomUsers=Change" "OK"
} else {
    # Actualizar permisos si el share ya existe
    Get-SmbShareAccess -Name "Usuarios" | ForEach-Object {
        Revoke-SmbShareAccess -Name "Usuarios" -AccountName $_.AccountName -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Grant-SmbShareAccess -Name "Usuarios" -AccountName $nombreAdmins  -AccessRight Full   -Force | Out-Null
    Grant-SmbShareAccess -Name "Usuarios" -AccountName $nombreDomUsers -AccessRight Change -Force | Out-Null
    Write-Log "Share 'Usuarios' actualizado: $nombreAdmins=Full, $nombreDomUsers=Change" "OK"
}

Write-Log "===== FIN: Configuracion de AD completada =====" "OK"
Write-Host ""
Write-Host "SIGUIENTE PASO: Ejecuta 02-Configurar-LogonHours.ps1" -ForegroundColor Yellow
