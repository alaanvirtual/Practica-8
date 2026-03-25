# =============================================================================
# SCRIPT 5b: CORRECCIÓN DE PERMISOS v2 - Usa SIDs para evitar problemas de idioma
# Archivo: 05b-Corregir-Permisos-Fix.ps1
# Ejecutar en: Windows Server 2022 en ESPAÑOL (como Administrador)
# =============================================================================
# CAUSA DEL ERROR ANTERIOR:
#   "Administrators" no existe en Windows en español -> se llama "Administradores"
#   La solución definitiva es usar SIDs (S-1-5-32-544), que funcionan en
#   cualquier idioma sin importar el nombre localizado del grupo.
# =============================================================================

#Requires -RunAsAdministrator

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
    Add-Content -Path "C:\Scripts\Logs\05b-Permisos-Fix.log" -Value "[$timestamp][$Level] $Message"
}

if (-not (Test-Path "C:\Scripts\Logs")) {
    New-Item -ItemType Directory -Path "C:\Scripts\Logs" -Force | Out-Null
}

Write-Log "===== INICIO: Corrección de Permisos v2 (SID-based) =====" "INFO"

# ---------------------------------------------------------------------------
# RESOLUCION DE NOMBRES USANDO SIDs (independiente del idioma del SO)
# ---------------------------------------------------------------------------
# Estos SIDs son iguales en TODOS los Windows, sin importar el idioma:
#   S-1-5-32-544  = Administrators / Administradores
#   S-1-5-18      = SYSTEM / SISTEMA
#   S-1-5-32-545  = Users / Usuarios (del dominio local)
# Para Domain Users del dominio, se resuelve desde AD.
# ---------------------------------------------------------------------------

$sidAdmins  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$sidSystem  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")

# Resolver el nombre real localizado (para usarlo en Grant-SmbShareAccess)
$nombreAdmins = $sidAdmins.Translate([System.Security.Principal.NTAccount]).Value
$nombreSystem = $sidSystem.Translate([System.Security.Principal.NTAccount]).Value

Write-Log "Nombre localizado de Administradores: $nombreAdmins" "INFO"
Write-Log "Nombre localizado de SYSTEM:          $nombreSystem" "INFO"

# Domain Users del dominio (se obtiene desde AD)
Import-Module ActiveDirectory
$domainSID   = (Get-ADDomain).DomainSID
$sidDomUsers = New-Object System.Security.Principal.SecurityIdentifier("$domainSID-513")  # 513 = Domain Users
$nombreDomUsers = $sidDomUsers.Translate([System.Security.Principal.NTAccount]).Value
Write-Log "Nombre localizado de Domain Users:    $nombreDomUsers" "INFO"

# ---------------------------------------------------------------------------
# PASO 1 - CORREGIR EL SHARE SMB
# ---------------------------------------------------------------------------
Write-Log "" "INFO"
Write-Log "Corrigiendo permisos del recurso compartido 'Usuarios'..." "INFO"

$share = Get-SmbShare -Name "Usuarios" -ErrorAction SilentlyContinue

if ($share) {
    # Revocar todos los permisos actuales
    Get-SmbShareAccess -Name "Usuarios" | ForEach-Object {
        Revoke-SmbShareAccess -Name "Usuarios" -AccountName $_.AccountName -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Asignar permisos correctos usando nombres resueltos por SID
    Grant-SmbShareAccess -Name "Usuarios" -AccountName $nombreAdmins  -AccessRight Full   -Force | Out-Null
    Grant-SmbShareAccess -Name "Usuarios" -AccountName $nombreDomUsers -AccessRight Change -Force | Out-Null

    Write-Log "Share corregido:" "OK"
    Write-Log "  $nombreAdmins  -> Full" "OK"
    Write-Log "  $nombreDomUsers -> Change" "OK"
} else {
    Write-Log "Share 'Usuarios' no encontrado. Creándolo..." "WARN"
    New-SmbShare -Name "Usuarios" `
                 -Path "C:\Usuarios" `
                 -FullAccess $nombreAdmins `
                 -ChangeAccess $nombreDomUsers | Out-Null
    Write-Log "Share 'Usuarios' creado con permisos correctos." "OK"
}

# ---------------------------------------------------------------------------
# PASO 2 - REPARAR PERMISOS NTFS (usando SIDs directamente)
# ---------------------------------------------------------------------------
Write-Log "" "INFO"
Write-Log "Reparando permisos NTFS..." "INFO"

$raiz = "C:\Usuarios"

# --- Carpeta raíz: solo Admins y SYSTEM ---
Write-Log "Asegurando permisos de la raíz C:\Usuarios..." "INFO"
$aclRaiz = Get-Acl $raiz
$aclRaiz.SetAccessRuleProtection($true, $false)

$ruleRaizAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sidAdmins, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$ruleRaizSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sidSystem, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")

$aclRaiz.AddAccessRule($ruleRaizAdmins)
$aclRaiz.AddAccessRule($ruleRaizSystem)
Set-Acl -Path $raiz -AclObject $aclRaiz
Write-Log "Raíz C:\Usuarios asegurada (solo Administradores y SYSTEM)." "OK"

# --- Subcarpetas de cada usuario ---
$subcarpetas = Get-ChildItem -Path $raiz -Directory

foreach ($carpeta in $subcarpetas) {
    $usuario = $carpeta.Name
    $ruta    = $carpeta.FullName

    # Verificar que el usuario existe en AD
    try {
        $adUser = Get-ADUser -Identity $usuario -ErrorAction Stop
    } catch {
        Write-Log "  [$usuario] No encontrado en AD, omitiendo..." "WARN"
        continue
    }

    # Obtener el SID del usuario desde AD (evita problemas de nombre/idioma)
    $sidUsuario = New-Object System.Security.Principal.SecurityIdentifier($adUser.SID)

    $acl = Get-Acl $ruta
    $acl.SetAccessRuleProtection($true, $false)

    $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmins,  "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem,  "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $ruleUser   = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidUsuario, "Modify",      "ContainerInherit,ObjectInherit", "None", "Allow")

    $acl.AddAccessRule($ruleAdmins)
    $acl.AddAccessRule($ruleSystem)
    $acl.AddAccessRule($ruleUser)
    Set-Acl -Path $ruta -AclObject $acl

    Write-Log "  [$usuario] NTFS OK -> Modify para $($sidUsuario.Translate([System.Security.Principal.NTAccount]).Value)" "OK"
}

# ---------------------------------------------------------------------------
# PASO 3 - VERIFICACIÓN FINAL
# ---------------------------------------------------------------------------
Write-Log "" "INFO"
Write-Log "===== VERIFICACIÓN FINAL =====" "INFO"

Write-Log "Permisos del Share 'Usuarios':" "INFO"
Get-SmbShareAccess -Name "Usuarios" | ForEach-Object {
    Write-Log "  $($_.AccountName) -> $($_.AccessRight)" "INFO"
}

Write-Log "" "INFO"
Write-Log "Permisos NTFS de C:\Usuarios (raíz):" "INFO"
(Get-Acl "C:\Usuarios").Access | ForEach-Object {
    Write-Log "  $($_.IdentityReference) -> $($_.FileSystemRights)" "INFO"
}

Write-Log "" "INFO"
Write-Log "Muestra de permisos NTFS (primera carpeta de usuario):" "INFO"
$primera = Get-ChildItem "C:\Usuarios" -Directory | Select-Object -First 1
if ($primera) {
    (Get-Acl $primera.FullName).Access | ForEach-Object {
        Write-Log "  [$($primera.Name)] $($_.IdentityReference) -> $($_.FileSystemRights)" "INFO"
    }
}

Write-Log "" "INFO"
Write-Log "===== FIN: Permisos corregidos correctamente =====" "OK"

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  PRUEBA DESDE EL CLIENTE WINDOWS 10" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Inicia sesión como un usuario del dominio (ej: jgarcia)" -ForegroundColor White
Write-Host "2. H:\ debe abrirse automáticamente con permisos de escritura" -ForegroundColor White
Write-Host "3. Prueba crear un .txt en H:\   -> DEBE FUNCIONAR" -ForegroundColor Green
Write-Host "4. Prueba copiar un .mp3 a H:\   -> FSRM debe BLOQUEARLO" -ForegroundColor Red
Write-Host "5. Prueba un archivo > cuota      -> FSRM debe BLOQUEARLO" -ForegroundColor Red
Write-Host ""
Write-Host "Si H:\ no aparece, ejecuta en el cliente (cmd como usuario):" -ForegroundColor Yellow
Write-Host "  net use H: \\$($env:COMPUTERNAME)\Usuarios\%USERNAME% /persistent:yes" -ForegroundColor White
Write-Host ""
Write-Host "Para verificar el share desde el servidor:" -ForegroundColor Yellow
Write-Host "  Get-SmbShareAccess -Name 'Usuarios'" -ForegroundColor White