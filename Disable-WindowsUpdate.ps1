<#
.SYNOPSIS
    Deshabilita descarga e instalación de Windows Updates de forma persistente.

.DESCRIPTION
    Capas aplicadas (defensa en profundidad, porque Windows tiende a "auto-repararse"):
      1. Políticas de registro (equivalente a GPO): NoAutoUpdate, sin acceso a UI, sin drivers vía WU.
      2. Servicios: wuauserv, UsoSvc, WaaSMedicSvc, DoSvc -> Disabled (Start=4). Los inexistentes se omiten.
      3. Scheduled Tasks de WindowsUpdate / UpdateOrchestrator / WaaSMedic -> Disabled.
      4. (Opcional) Enforcer: tarea como SYSTEM (boot + diaria 03:00) que re-aplica todo.

    Modos de ejecución (todos equivalentes):
      A) Archivo local:   .\Disable-WindowsUpdate.ps1 -Action Apply -InstallEnforcer
      B) Directo con iex (iex no admite parámetros -> se pasan por variables de entorno):
           $env:WUBLOCK_ACTION='Apply'; $env:WUBLOCK_ENFORCER='1'
           iex (New-Object Net.WebClient).DownloadString('<URL raw>')
           Remove-Item Env:WUBLOCK_ACTION, Env:WUBLOCK_ENFORCER

.PARAMETER Action
    Status (lectura, default) | Apply (modifica) | Revert (restaura valores por defecto)
    Alternativa: variable de entorno WUBLOCK_ACTION.

.PARAMETER InstallEnforcer
    Con Apply: registra la tarea que reaplica la configuración. Con Revert: la elimina.
    Alternativa: variable de entorno WUBLOCK_ENFORCER=1.

.NOTES
    Windows Server 2016/2019/2022 y Windows 10/11. Ejecutar como Administrador.
    Log: C:\ProgramData\WUBlock\wublock.log
    Todo el código vive dentro de la función Invoke-WUBlock para no contaminar la sesión
    (iex) y para que el enforcer pueda persistirse aunque el script no provenga de un archivo.
#>
param(
    [string]$Action,
    [switch]$InstallEnforcer
)

function Invoke-WUBlock {
    param(
        [string]$Action = 'Status',
        [bool]$InstallEnforcer = $false
    )

    $ErrorActionPreference = 'Continue'

    # Cuerpo de esta función: se usa para persistir el enforcer sin depender de un archivo de origen
    $SelfBody = $MyInvocation.MyCommand.ScriptBlock.ToString()

    # Chequeo de admin en runtime (#Requires no aplica con iex)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Ejecutar en una consola elevada (Administrador).' }

    # ------------------------------------------------------------ Config
    $WorkDir      = 'C:\ProgramData\WUBlock'
    $LogFile      = Join-Path $WorkDir 'wublock.log'
    $EnforcerName = 'WUBlock-Enforcer'
    $WUPolicy     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $AUPolicy     = "$WUPolicy\AU"

    # Servicio = valor de inicio por defecto (para Revert)
    $Services = [ordered]@{
        'wuauserv'     = 'Manual'
        'UsoSvc'       = 'Manual'
        'WaaSMedicSvc' = 'Manual'
        'DoSvc'        = 'Manual'
    }

    $TaskPaths = @(
        '\Microsoft\Windows\WindowsUpdate\',
        '\Microsoft\Windows\UpdateOrchestrator\',
        '\Microsoft\Windows\WaaSMedic\'
    )

    # Valores de política: Path, Name, Value
    $Policies = @(
        @{ Path = $AUPolicy; Name = 'NoAutoUpdate';                    Value = 1 }  # sin actualizaciones automáticas
        @{ Path = $AUPolicy; Name = 'AUOptions';                       Value = 1 }  # 1 = nunca buscar/descargar/instalar
        @{ Path = $AUPolicy; Name = 'NoAutoRebootWithLoggedOnUsers';   Value = 1 }
        @{ Path = $WUPolicy; Name = 'SetDisableUXWUAccess';            Value = 1 }  # inhabilita "Buscar actualizaciones"
        @{ Path = $WUPolicy; Name = 'ExcludeWUDriversInQualityUpdate'; Value = 1 }
    )

    # ------------------------------------------------------------ Helpers
    function Write-Log {
        param([string]$Msg, [string]$Level = 'INFO')
        if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        Add-Content -Path $LogFile -Value $line
        Write-Host $line
    }

    function Set-Policy {
        param($Path, $Name, $Value)
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
        Write-Log "Policy $Name=$Value"
    }

    function Set-ServiceState {
        param([string]$Name, [ValidateSet('Disabled', 'Manual', 'Automatic')][string]$StartType)
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log "Servicio $Name no existe en este SO, se omite" 'WARN'; return }

        if ($StartType -eq 'Disabled' -and $svc.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }

        try {
            Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
        }
        catch {
            # Fallback directo a registro (WaaSMedicSvc suele rechazar Set-Service)
            $startVal = @{ Disabled = 4; Manual = 3; Automatic = 2 }[$StartType]
            try {
                Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $startVal -ErrorAction Stop
            }
            catch {
                Write-Log "No se pudo cambiar $Name a $StartType (acceso denegado, servicio protegido por TrustedInstaller)" 'WARN'
                return
            }
        }
        Write-Log "Servicio $Name -> $StartType"
    }

    function Set-UpdateTasks {
        param([ValidateSet('Disable', 'Enable')][string]$Mode)
        foreach ($tp in $TaskPaths) {
            Get-ScheduledTask -TaskPath "$tp*" -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    if ($Mode -eq 'Disable') { $_ | Disable-ScheduledTask -ErrorAction Stop | Out-Null }
                    else                     { $_ | Enable-ScheduledTask  -ErrorAction Stop | Out-Null }
                    Write-Log "Task $($_.TaskPath)$($_.TaskName) -> $Mode"
                }
                catch {
                    Write-Log "Task $($_.TaskPath)$($_.TaskName) no modificable: $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }

    function Install-Enforcer {
        if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
        $dest = Join-Path $WorkDir 'Invoke-WUBlock.ps1'

        # El enforcer persiste el cuerpo de esta función + una llamada fija a Apply (sin reinstalarse)
        $content = "function Invoke-WUBlock {`r`n$SelfBody`r`n}`r`nInvoke-WUBlock -Action Apply -InstallEnforcer `$false`r`n"
        Set-Content -Path $dest -Value $content -Encoding UTF8 -Force
        Write-Log "Script del enforcer persistido en $dest"

        $act  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest`""
        $trg  = @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -Daily -At '03:00')
        )
        $prin = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $EnforcerName -Action $act -Trigger $trg -Principal $prin `
            -Description 'Reaplica el bloqueo de Windows Update' -Force | Out-Null
        Write-Log "Enforcer '$EnforcerName' registrado (boot + diario 03:00, SYSTEM)"
    }

    function Remove-Enforcer {
        if (Get-ScheduledTask -TaskName $EnforcerName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $EnforcerName -Confirm:$false
            Write-Log "Enforcer '$EnforcerName' eliminado"
        }
        $dest = Join-Path $WorkDir 'Invoke-WUBlock.ps1'
        if (Test-Path $dest) { Remove-Item $dest -Force }
    }

    # ------------------------------------------------------------ Acciones
    function Invoke-Status {
        Write-Host "`n== Políticas ==" -ForegroundColor Cyan
        foreach ($p in $Policies) {
            $v = (Get-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
            '{0,-35} = {1}' -f $p.Name, $(if ($null -eq $v) { '<no definido>' } else { $v })
        }

        Write-Host "`n== Servicios ==" -ForegroundColor Cyan
        @($Services.Keys) | ForEach-Object {
            Get-Service -Name $_ -ErrorAction SilentlyContinue
        } | Select-Object Name, Status, StartType | Format-Table -AutoSize

        Write-Host "== Scheduled Tasks (no deshabilitadas) ==" -ForegroundColor Cyan
        foreach ($tp in $TaskPaths) {
            Get-ScheduledTask -TaskPath "$tp*" -ErrorAction SilentlyContinue |
                Where-Object State -ne 'Disabled' |
                Select-Object TaskPath, TaskName, State | Format-Table -AutoSize
        }

        Write-Host "== Enforcer ==" -ForegroundColor Cyan
        Get-ScheduledTask -TaskName $EnforcerName -ErrorAction SilentlyContinue |
            Select-Object TaskName, State | Format-Table -AutoSize
    }

    function Invoke-Apply {
        Write-Log '=== APPLY: bloqueo de Windows Update ==='
        foreach ($p in $Policies) { Set-Policy @p }
        foreach ($s in @($Services.Keys)) { Set-ServiceState -Name $s -StartType Disabled }
        Set-UpdateTasks -Mode Disable
        if ($InstallEnforcer) { Install-Enforcer }
        Write-Log '=== APPLY completado ==='
    }

    function Invoke-Revert {
        Write-Log '=== REVERT: restaurando Windows Update ==='
        foreach ($p in $Policies) {
            Remove-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue
            Write-Log "Policy $($p.Name) eliminada"
        }
        foreach ($s in @($Services.Keys)) { Set-ServiceState -Name $s -StartType $Services[$s] }
        Set-UpdateTasks -Mode Enable
        if ($InstallEnforcer) { Remove-Enforcer }
        Write-Log '=== REVERT completado ==='
    }

    switch ($Action) {
        'Status' { Invoke-Status }
        'Apply'  { Invoke-Apply;  Invoke-Status }
        'Revert' { Invoke-Revert; Invoke-Status }
        default  { throw "Action inválida: '$Action' (usar Status | Apply | Revert)" }
    }
}

# ---------------------------------------------------------------- Entrada
# Prioridad: parámetro del script > variable de entorno > default (Status)
$wuAction = if ($Action) { $Action } elseif ($env:WUBLOCK_ACTION) { $env:WUBLOCK_ACTION } else { 'Status' }
$wuEnf    = [bool]$InstallEnforcer -or ($env:WUBLOCK_ENFORCER -eq '1')

Invoke-WUBlock -Action $wuAction -InstallEnforcer $wuEnf
