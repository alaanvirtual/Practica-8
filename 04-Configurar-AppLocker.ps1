# =============================================================================
# SCRIPT 4: AppLocker - Control de Ejecucion de Aplicaciones
# Archivo: 04-Configurar-AppLocker.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================
# Cuates:    Bloc de Notas (notepad.exe) PERMITIDO
# NoCuates:  Bloc de Notas BLOQUEADO por Hash (resistente a renombrado)
# =============================================================================

#Requires -RunAsAdministrator
Import-Module GroupPolicy
Import-Module ActiveDirectory

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "Cyan" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
    Add-Content -Path "C:\Scripts\Logs\04-AppLocker.log" -Value "[$timestamp][$Level] $Message"
}

Write-Log "===== INICIO: Configuracion AppLocker =====" "INFO"

# ---------------------------------------------------------------------------
# PASO 1 - OBTENER HASH DE NOTEPAD.EXE
# ---------------------------------------------------------------------------
Write-Log "Obteniendo informacion de hash de notepad.exe..." "INFO"

$notepadPath = "$env:SystemRoot\System32\notepad.exe"

if (-not (Test-Path $notepadPath)) {
    Write-Log "ERROR: notepad.exe no encontrado en $notepadPath" "ERROR"
    exit 1
}

# Obtener informacion completa del archivo para AppLocker
$fileInfo = Get-AppLockerFileInformation -Path $notepadPath
Write-Log "Notepad.exe encontrado: $notepadPath" "OK"
Write-Log "Version: $((Get-Item $notepadPath).VersionInfo.FileVersion)" "INFO"

# Calcular hash SHA256 manualmente para verificacion
$hashSHA256 = (Get-FileHash -Path $notepadPath -Algorithm SHA256).Hash
Write-Log "Hash SHA256 de notepad.exe: $hashSHA256" "INFO"

# Guardar hash en archivo para referencia
$hashInfo = @"
Archivo: $notepadPath
Hash SHA256: $hashSHA256
Fecha: $(Get-Date)
Version: $((Get-Item $notepadPath).VersionInfo.FileVersion)
"@
Set-Content -Path "C:\Scripts\notepad-hash.txt" -Value $hashInfo
Write-Log "Hash guardado en C:\Scripts\notepad-hash.txt" "OK"

# ---------------------------------------------------------------------------
# PASO 2 - CREAR GPO PARA CUATES (Notepad PERMITIDO)
# ---------------------------------------------------------------------------
Write-Log "Creando GPO de AppLocker para Cuates (Notepad permitido)..." "INFO"

$domainFQDN = (Get-ADDomain).DNSRoot
$domainDN   = (Get-ADDomain).DistinguishedName
$gpoCuatesName = "GPO-AppLocker-Cuates"

$gpoCuates = Get-GPO -Name $gpoCuatesName -ErrorAction SilentlyContinue
if (-not $gpoCuates) {
    $gpoCuates = New-GPO -Name $gpoCuatesName -Comment "AppLocker: Cuates - Notepad permitido"
    Write-Log "GPO creada: $gpoCuatesName" "OK"
} else {
    Write-Log "GPO ya existe: $gpoCuatesName" "WARN"
}

# Crear XML de politica AppLocker para Cuates
# Regla: Todos los ejecutables de System32 permitidos (incluye notepad)
# Regla de hash que permite notepad ESPECIFICAMENTE
$xmlCuates = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <!-- Regla base: Administradores pueden ejecutar todo -->
    <FilePublisherRule Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
                       Name="Permitir ejecutables firmados por Microsoft (Administradores)"
                       Description="Regla base para administradores"
                       UserOrGroupSid="S-1-5-32-544"
                       Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
                                ProductName="*"
                                BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <!-- Regla: Permitir notepad.exe para GRP_Cuates por HASH -->
    <FileHashRule Id="b5dd97a5-3e2f-4f68-a20a-4a48c41e84e7"
                  Name="Permitir Bloc de Notas - Cuates (por Hash)"
                  Description="Cuates pueden usar notepad.exe - verificado por hash"
                  UserOrGroupSid="S-1-1-0"
                  Action="Allow">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256"
                    Data="0x$hashSHA256"
                    SourceFileName="notepad.exe"
                    SourceFileLength="$($(Get-Item $notepadPath).Length)" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
    <!-- Regla: Permitir todos los programas en Windows y Program Files para usuarios autenticados -->
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20"
                  Name="Permitir Windows System"
                  Description="Permitir ejecutables del sistema"
                  UserOrGroupSid="S-1-1-0"
                  Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51"
                  Name="Permitir Program Files"
                  Description="Permitir ejecutables de Program Files"
                  UserOrGroupSid="S-1-1-0"
                  Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Msi" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

$xmlCuatesPath = "C:\Scripts\AppLocker-Cuates.xml"
Set-Content -Path $xmlCuatesPath -Value $xmlCuates -Encoding UTF8
Write-Log "XML de AppLocker para Cuates generado: $xmlCuatesPath" "OK"

# ---------------------------------------------------------------------------
# PASO 3 - CREAR GPO PARA NOCUATES (Notepad BLOQUEADO por Hash)
# ---------------------------------------------------------------------------
Write-Log "Creando GPO de AppLocker para NoCuates (Notepad bloqueado)..." "INFO"

$gpoNoCuatesName = "GPO-AppLocker-NoCuates"

$gpoNoCuates = Get-GPO -Name $gpoNoCuatesName -ErrorAction SilentlyContinue
if (-not $gpoNoCuates) {
    $gpoNoCuates = New-GPO -Name $gpoNoCuatesName -Comment "AppLocker: NoCuates - Notepad bloqueado por Hash"
    Write-Log "GPO creada: $gpoNoCuatesName" "OK"
} else {
    Write-Log "GPO ya existe: $gpoNoCuatesName" "WARN"
}

$xmlNoCuates = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <!-- Regla base: Administradores pueden ejecutar todo -->
    <FilePublisherRule Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
                       Name="Permitir ejecutables firmados por Microsoft (Administradores)"
                       Description="Regla base para administradores"
                       UserOrGroupSid="S-1-5-32-544"
                       Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
                                ProductName="*"
                                BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <!-- REGLA DE BLOQUEO: Bloquear notepad.exe POR HASH para NoCuates -->
    <!-- Esta regla bloquea el archivo INDEPENDIENTEMENTE DE SU NOMBRE -->
    <FileHashRule Id="c7dd97b6-4e3f-5g79-b31b-5b59d52f95f8"
                  Name="BLOQUEAR Bloc de Notas - NoCuates (por Hash)"
                  Description="NoCuates NO pueden usar notepad.exe - bloqueado por hash incluso si se renombra"
                  UserOrGroupSid="S-1-1-0"
                  Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256"
                    Data="0x$hashSHA256"
                    SourceFileName="notepad.exe"
                    SourceFileLength="$($(Get-Item $notepadPath).Length)" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
    <!-- Permitir el resto de Windows para usuarios autenticados -->
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20"
                  Name="Permitir Windows System"
                  Description="Permitir ejecutables del sistema (excepto los bloqueados)"
                  UserOrGroupSid="S-1-1-0"
                  Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51"
                  Name="Permitir Program Files"
                  Description="Permitir ejecutables de Program Files"
                  UserOrGroupSid="S-1-1-0"
                  Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Msi" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

$xmlNoCuatesPath = "C:\Scripts\AppLocker-NoCuates.xml"
Set-Content -Path $xmlNoCuatesPath -Value $xmlNoCuates -Encoding UTF8
Write-Log "XML de AppLocker para NoCuates generado: $xmlNoCuatesPath" "OK"

# ---------------------------------------------------------------------------
# PASO 4 - APLICAR POLITICAS APPLOCKER A LAS GPOs
# ---------------------------------------------------------------------------
Write-Log "Aplicando politicas AppLocker a las GPOs..." "INFO"

# Funcion para aplicar AppLocker XML a una GPO via registro
function Set-AppLockerGPO {
    param([string]$GPOName, [string]$XMLPath, [string]$DomainFQDN)

    $gpo = Get-GPO -Name $GPOName
    $gpoGuid = $gpo.Id.ToString()
    $sysvol = "\\$DomainFQDN\SYSVOL\$DomainFQDN\Policies\{$gpoGuid}"

    # Crear estructura de directorios para AppLocker en GPO
    $applockerPath = "$sysvol\Machine\Microsoft\Windows NT\AppLocker"
    if (-not (Test-Path $applockerPath)) {
        New-Item -ItemType Directory -Path $applockerPath -Force | Out-Null
    }

    # Copiar XML de AppLocker
    Copy-Item -Path $XMLPath -Destination "$applockerPath\AppLocker.xml" -Force
    Write-Log "  XML copiado a SYSVOL: $applockerPath" "OK"

    # Habilitar el servicio Application Identity en la GPO (necesario para AppLocker)
    # Configurar via Set-GPRegistryValue
    Set-GPRegistryValue -Name $GPOName `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" `
        -ValueName "Start" `
        -Type DWord `
        -Value 2 | Out-Null

    Write-Log "  Servicio AppIDSvc configurado para inicio automatico en GPO: $GPOName" "OK"
}

Set-AppLockerGPO -GPOName $gpoCuatesName   -XMLPath $xmlCuatesPath   -DomainFQDN $domainFQDN
Set-AppLockerGPO -GPOName $gpoNoCuatesName -XMLPath $xmlNoCuatesPath -DomainFQDN $domainFQDN

# ---------------------------------------------------------------------------
# PASO 5 - VINCULAR GPOs A LAS UOs
# ---------------------------------------------------------------------------
Write-Log "Vinculando GPOs de AppLocker a UOs..." "INFO"

$ouCuates   = "OU=Cuates,OU=Practica,$domainDN"
$ouNoCuates = "OU=NoCuates,OU=Practica,$domainDN"

foreach ($link in @(
    @{ GPO = $gpoCuatesName;   OU = $ouCuates },
    @{ GPO = $gpoNoCuatesName; OU = $ouNoCuates }
)) {
    try {
        New-GPLink -Name $link.GPO -Target $link.OU -ErrorAction Stop | Out-Null
        Write-Log "GPO '$($link.GPO)' vinculada a '$($link.OU)'" "OK"
    } catch {
        if ($_ -match "already linked") {
            Write-Log "GPO '$($link.GPO)' ya vinculada a '$($link.OU)'" "WARN"
        } else {
            Write-Log "Error: $_" "ERROR"
        }
    }
}

# ---------------------------------------------------------------------------
# PASO 6 - HABILITAR SERVICIO APPLICATION IDENTITY EN EL SERVIDOR
# ---------------------------------------------------------------------------
Write-Log "Habilitando servicio Application Identity (AppIDSvc) en el servidor..." "INFO"

Set-Service -Name AppIDSvc -StartupType Automatic
Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
$svc = Get-Service -Name AppIDSvc
Write-Log "Servicio AppIDSvc: Estado=$($svc.Status), Inicio=$($svc.StartType)" "OK"

# Forzar actualizacion de politicas
Invoke-GPUpdate -Force -RandomDelayInMinutes 0 | Out-Null
Write-Log "Politicas actualizadas (gpupdate /force)" "OK"

Write-Log "===== FIN: AppLocker configurado correctamente =====" "OK"
Write-Host ""
Write-Host "IMPORTANTE - Para que AppLocker funcione en clientes:" -ForegroundColor Magenta
Write-Host "  1. El servicio 'Application Identity' debe estar INICIADO en el cliente" -ForegroundColor White
Write-Host "  2. Ejecutar 'gpupdate /force' en el cliente despues de unirse al dominio" -ForegroundColor White
Write-Host "  3. Cerrar e iniciar sesion para que las politicas surtan efecto" -ForegroundColor White
Write-Host ""
Write-Host "Hash de notepad.exe guardado en: C:\Scripts\notepad-hash.txt" -ForegroundColor Yellow
Write-Host "SIGUIENTE PASO: Ejecuta 05-Union-Windows.ps1 en el cliente Windows" -ForegroundColor Yellow
