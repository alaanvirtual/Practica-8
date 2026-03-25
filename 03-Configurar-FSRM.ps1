# =============================================================================
# SCRIPT 3: FSRM - Cuotas de Disco y Apantallamiento de Archivos
# Archivo: 03-Configurar-FSRM.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================
# Cuates:    10 MB de cuota
# NoCuates:   5 MB de cuota
# Bloqueo:   .mp3, .mp4, .exe, .msi en carpetas personales
# =============================================================================

#Requires -RunAsAdministrator

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "Cyan" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
    Add-Content -Path "C:\Scripts\Logs\03-FSRM.log" -Value "[$timestamp][$Level] $Message"
}

Write-Log "===== INICIO: Configuracion FSRM =====" "INFO"

# ---------------------------------------------------------------------------
# PASO 1 - INSTALAR Y VERIFICAR FSRM
# ---------------------------------------------------------------------------
Write-Log "Verificando instalacion de FSRM..." "INFO"

if (-not (Get-WindowsFeature -Name FS-Resource-Manager).Installed) {
    Write-Log "Instalando File Server Resource Manager..." "INFO"
    Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools | Out-Null
    Write-Log "FSRM instalado correctamente." "OK"
} else {
    Write-Log "FSRM ya esta instalado." "WARN"
}

Import-Module FileServerResourceManager

# ---------------------------------------------------------------------------
# PASO 2 - CONFIGURAR NOTIFICACIONES POR EMAIL (opcional, requiere SMTP)
# ---------------------------------------------------------------------------
# Set-FsrmSetting -SmtpServer "localhost" -AdminEmailAddress "admin@practica.local"

# ---------------------------------------------------------------------------
# PASO 3 - CREAR PLANTILLAS DE CUOTA
# ---------------------------------------------------------------------------
Write-Log "Creando plantillas de cuota..." "INFO"

# Accion de notificacion cuando se alcanza el 80% y 100%
$accionEvento80 = New-FsrmAction -Type Event `
    -EventType Warning `
    -Body "El usuario [Source Io Owner] ha alcanzado el 80% de su cuota en [Quota Path]. Uso actual: [Quota Used Bytes] de [Quota Limit Bytes]."

$accionEvento100 = New-FsrmAction -Type Event `
    -EventType Error `
    -Body "LIMITE ALCANZADO: El usuario [Source Io Owner] ha superado la cuota en [Quota Path]. Limite: [Quota Limit Bytes]."

# Umbral de aviso al 80%
$umbral80 = New-FsrmQuotaThreshold -Percentage 80 -Action $accionEvento80

# Umbral de bloqueo al 100%
$umbral100 = New-FsrmQuotaThreshold -Percentage 100 -Action $accionEvento100

# --- Plantilla 10 MB para Cuates ---
$plantilla10MB = "Cuota-10MB-Cuates"
try {
    Get-FsrmQuotaTemplate -Name $plantilla10MB -ErrorAction Stop | Out-Null
    Write-Log "Plantilla '$plantilla10MB' ya existe. Actualizando..." "WARN"
    Set-FsrmQuotaTemplate -Name $plantilla10MB `
        -Size 10MB `
        -SoftLimit $false `
        -Threshold @($umbral80, $umbral100)
} catch {
    New-FsrmQuotaTemplate -Name $plantilla10MB `
        -Size 10MB `
        -SoftLimit $false `
        -Threshold @($umbral80, $umbral100) | Out-Null
    Write-Log "Plantilla creada: $plantilla10MB (10 MB, Hard Limit)" "OK"
}

# --- Plantilla 5 MB para NoCuates ---
$plantilla5MB = "Cuota-5MB-NoCuates"
try {
    Get-FsrmQuotaTemplate -Name $plantilla5MB -ErrorAction Stop | Out-Null
    Write-Log "Plantilla '$plantilla5MB' ya existe. Actualizando..." "WARN"
    Set-FsrmQuotaTemplate -Name $plantilla5MB `
        -Size 5MB `
        -SoftLimit $false `
        -Threshold @($umbral80, $umbral100)
} catch {
    New-FsrmQuotaTemplate -Name $plantilla5MB `
        -Size 5MB `
        -SoftLimit $false `
        -Threshold @($umbral80, $umbral100) | Out-Null
    Write-Log "Plantilla creada: $plantilla5MB (5 MB, Hard Limit)" "OK"
}

# ---------------------------------------------------------------------------
# PASO 4 - ASIGNAR CUOTAS A CARPETAS DE USUARIOS
# ---------------------------------------------------------------------------
Write-Log "Asignando cuotas a carpetas de usuarios..." "INFO"

Import-Module ActiveDirectory
$domainDN = (Get-ADDomain).DistinguishedName

# Usuarios Cuates -> 10 MB
$usuariosCuates = Get-ADGroupMember -Identity "GRP_Cuates" -Recursive |
    Where-Object { $_.objectClass -eq "user" }

foreach ($usr in $usuariosCuates) {
    $carpeta = "C:\Usuarios\$($usr.SamAccountName)"
    if (-not (Test-Path $carpeta)) {
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        Write-Log "  Carpeta creada: $carpeta" "INFO"
    }
    try {
        Get-FsrmQuota -Path $carpeta -ErrorAction Stop | Out-Null
        Set-FsrmQuota -Path $carpeta -Template $plantilla10MB
        Write-Log "  Cuota actualizada (10MB): $($usr.SamAccountName)" "OK"
    } catch {
        New-FsrmQuota -Path $carpeta -Template $plantilla10MB | Out-Null
        Write-Log "  Cuota asignada (10MB): $($usr.SamAccountName)" "OK"
    }
}

# Usuarios NoCuates -> 5 MB
$usuariosNoCuates = Get-ADGroupMember -Identity "GRP_NoCuates" -Recursive |
    Where-Object { $_.objectClass -eq "user" }

foreach ($usr in $usuariosNoCuates) {
    $carpeta = "C:\Usuarios\$($usr.SamAccountName)"
    if (-not (Test-Path $carpeta)) {
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        Write-Log "  Carpeta creada: $carpeta" "INFO"
    }
    try {
        Get-FsrmQuota -Path $carpeta -ErrorAction Stop | Out-Null
        Set-FsrmQuota -Path $carpeta -Template $plantilla5MB
        Write-Log "  Cuota actualizada (5MB): $($usr.SamAccountName)" "OK"
    } catch {
        New-FsrmQuota -Path $carpeta -Template $plantilla5MB | Out-Null
        Write-Log "  Cuota asignada (5MB): $($usr.SamAccountName)" "OK"
    }
}

# ---------------------------------------------------------------------------
# PASO 5 - CREAR GRUPO DE ARCHIVOS BLOQUEADOS
# ---------------------------------------------------------------------------
Write-Log "Creando grupo de archivos bloqueados (multimedia + ejecutables)..." "INFO"

$fileGroupName = "Archivos-Bloqueados-Practica"

$extensionesBloqueadas = @(
    "*.mp3", "*.mp4", "*.avi", "*.mkv", "*.mov", "*.wmv", "*.flac", "*.wav",
    "*.exe", "*.msi", "*.bat", "*.cmd", "*.com", "*.scr", "*.pif"
)

try {
    Get-FsrmFileGroup -Name $fileGroupName -ErrorAction Stop | Out-Null
    Set-FsrmFileGroup -Name $fileGroupName -IncludePattern $extensionesBloqueadas
    Write-Log "Grupo de archivos actualizado: $fileGroupName" "WARN"
} catch {
    New-FsrmFileGroup -Name $fileGroupName -IncludePattern $extensionesBloqueadas | Out-Null
    Write-Log "Grupo de archivos creado: $fileGroupName" "OK"
}

Write-Log "Extensiones bloqueadas: $($extensionesBloqueadas -join ', ')" "INFO"

# ---------------------------------------------------------------------------
# PASO 6 - CREAR PLANTILLA DE APANTALLAMIENTO (FILE SCREEN TEMPLATE)
# ---------------------------------------------------------------------------
Write-Log "Creando plantilla de apantallamiento de archivos..." "INFO"

$screenTemplateName = "Pantalla-Multimedia-Ejecutables"

# Accion de evento cuando se intenta guardar archivo bloqueado
$accionBloqueo = New-FsrmAction -Type Event `
    -EventType Warning `
    -Body "ARCHIVO BLOQUEADO: El usuario [Source Io Owner] intento guardar '[Source File Path]' en [File Screen Path]. Tipo bloqueado: [File Group]."

try {
    Get-FsrmFileScreenTemplate -Name $screenTemplateName -ErrorAction Stop | Out-Null
    Set-FsrmFileScreenTemplate -Name $screenTemplateName `
        -Active `
        -IncludeGroup @($fileGroupName) `
        -Notification @($accionBloqueo)
    Write-Log "Plantilla de apantallamiento actualizada: $screenTemplateName" "WARN"
} catch {
    New-FsrmFileScreenTemplate -Name $screenTemplateName `
        -Active `
        -IncludeGroup @($fileGroupName) `
        -Notification @($accionBloqueo) | Out-Null
    Write-Log "Plantilla de apantallamiento creada: $screenTemplateName" "OK"
}

# ---------------------------------------------------------------------------
# PASO 7 - APLICAR APANTALLAMIENTO A TODAS LAS CARPETAS
# ---------------------------------------------------------------------------
Write-Log "Aplicando apantallamiento a carpetas de todos los usuarios..." "INFO"

$todosUsuarios = @() + $usuariosCuates + $usuariosNoCuates

foreach ($usr in $todosUsuarios) {
    $carpeta = "C:\Usuarios\$($usr.SamAccountName)"
    if (Test-Path $carpeta) {
        try {
            Get-FsrmFileScreen -Path $carpeta -ErrorAction Stop | Out-Null
            Set-FsrmFileScreen -Path $carpeta -Template $screenTemplateName -Active
            Write-Log "  Apantallamiento actualizado: $($usr.SamAccountName)" "OK"
        } catch {
            New-FsrmFileScreen -Path $carpeta -Template $screenTemplateName -Active | Out-Null
            Write-Log "  Apantallamiento aplicado: $($usr.SamAccountName)" "OK"
        }
    }
}

# ---------------------------------------------------------------------------
# PASO 8 - VERIFICACION FINAL
# ---------------------------------------------------------------------------
Write-Log "" "INFO"
Write-Log "===== VERIFICACION FINAL FSRM =====" "INFO"
Write-Log "Cuotas configuradas:" "INFO"
Get-FsrmQuota | ForEach-Object {
    Write-Log "  $($_.Path) -> Limite: $([math]::Round($_.Size/1MB,0)) MB | Uso: $([math]::Round($_.Usage/1KB,0)) KB" "INFO"
}
Write-Log "Apantallamientos configurados:" "INFO"
Get-FsrmFileScreen | ForEach-Object {
    Write-Log "  $($_.Path) -> Activo: $($_.Active)" "INFO"
}

Write-Log "===== FIN: FSRM configurado correctamente =====" "OK"
Write-Host ""
Write-Host "SIGUIENTE PASO: Ejecuta 04-Configurar-AppLocker.ps1" -ForegroundColor Yellow
