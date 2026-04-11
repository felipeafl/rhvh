# ============================================================
#  DIAGNOSTICO DE CALIDAD DE CONEXION - CLIENTE
#  Uso: .\Diagnostico-ConexionCliente.ps1
#  El script pregunta el pais, IP y puerto del servidor terminal
#  y valida la ruta y conectividad completa.
# ============================================================

#region CONFIGURACION
$PingRepeticiones  = 15
$UmbralJitter_MS   = 30
$UmbralPerdida_Pct = 3
$ReportePath       = "$env:USERPROFILE\Desktop\Diagnostico_Conexion_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"

# Referencias WonderNetwork (https://wondernetwork.com/pings)
# EU_ms  = latencia esperada desde ese pais hacia Alemania/Europa
# US_ms  = latencia esperada desde ese pais hacia EE.UU.
# Margen = porcentaje adicional aceptable sobre la referencia antes de marcar problema
$ReferenciasLatencia = @{
    "1" = @{ Pais = "Chile";    Ciudad = "Santiago";  EU_ms = 210; US_ms = 160; Margen = 0.20 }
    "2" = @{ Pais = "Peru";     Ciudad = "Lima";      EU_ms = 240; US_ms = 180; Margen = 0.20 }
    "3" = @{ Pais = "Bolivia";  Ciudad = "La Paz";    EU_ms = 255; US_ms = 195; Margen = 0.20 }
    "4" = @{ Pais = "Ecuador";  Ciudad = "Quito";     EU_ms = 235; US_ms = 170; Margen = 0.20 }
    "5" = @{ Pais = "Colombia"; Ciudad = "Bogota";    EU_ms = 190; US_ms = 140; Margen = 0.20 }
    "6" = @{ Pais = "Paraguay"; Ciudad = "Asuncion";  EU_ms = 220; US_ms = 165; Margen = 0.20 }
}
#endregion

#region FUNCIONES
function Write-Header {
    param([string]$Titulo)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Titulo" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-SubHeader {
    param([string]$Titulo)
    Write-Host ""
    Write-Host "--- $Titulo ---" -ForegroundColor Yellow
}

function Validate-IP {
    param([string]$Valor)
    $partes = $Valor.Trim().Split('.')
    if ($partes.Count -ne 4) { return $false }
    foreach ($p in $partes) {
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { return $false }
        if ($n -lt 0 -or $n -gt 255)           { return $false }
    }
    return $true
}

function Validate-Port {
    param([string]$Valor)
    $n = 0
    if (-not [int]::TryParse($Valor.Trim(), [ref]$n)) { return $false }
    return ($n -ge 1 -and $n -le 65535)
}

function Test-LatenciaDetallada {
    param([string]$IP, [int]$Count = 15)
    $Resultados = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $Ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $Reply = $Ping.Send($IP, 3000)
            if ($Reply.Status -eq "Success") { $Resultados += $Reply.RoundtripTime }
        } catch { }
        finally { $Ping.Dispose() }
    }
    $Perdidos = $Count - $Resultados.Count
    if ($Resultados.Count -gt 0) {
        $Min = ($Resultados | Measure-Object -Minimum).Minimum
        $Max = ($Resultados | Measure-Object -Maximum).Maximum
        $Avg = [math]::Round(($Resultados | Measure-Object -Average).Average, 1)
        $Diffs = @()
        for ($i = 1; $i -lt $Resultados.Count; $i++) {
            $Diffs += [math]::Abs($Resultados[$i] - $Resultados[$i-1])
        }
        $Jitter  = if ($Diffs.Count -gt 0) { [math]::Round(($Diffs | Measure-Object -Average).Average, 1) } else { 0 }
        $PctLoss = [math]::Round(($Perdidos / $Count) * 100, 0)
        return [PSCustomObject]@{
            Alcanzable  = $true
            Avg_ms      = $Avg; Min_ms = $Min; Max_ms = $Max
            Jitter_ms   = $Jitter; Perdida_Pct = $PctLoss
            Exitosos    = $Resultados.Count; Total = $Count
        }
    } else {
        return [PSCustomObject]@{
            Alcanzable  = $false
            Avg_ms      = 9999; Min_ms = 0; Max_ms = 0
            Jitter_ms   = 0; Perdida_Pct = 100
            Exitosos    = 0; Total = $Count
        }
    }
}

function Get-Traceroute {
    param([string]$IP, [int]$MaxHops = 20)
    $Hops = @()
    # Usar tracert nativo de Windows y parsear su salida real
    $Salida = & tracert -d -h $MaxHops -w 2000 $IP 2>&1
    foreach ($Linea in $Salida) {
        $L = $Linea.ToString().Trim()
        # Linea tipica: "  1     6 ms     3 ms     4 ms  192.168.1.1"
        # o con timeout: "  7     *        *        *     Tiempo de espera agotado"
        if ($L -match '^\s*(\d+)\s+') {
            $NumHop = [int]$Matches[1]
            # Buscar IPs en la linea
            $HopIP = ($L | Select-String -Pattern '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' -AllMatches).Matches |
                     Select-Object -Last 1 | ForEach-Object { $_.Value }
            if (-not $HopIP) { $HopIP = "*" }
            # Buscar tiempos en ms (numeros seguidos de " ms")
            $Tiempos = ($L | Select-String -Pattern '(\d+)\s+ms' -AllMatches).Matches |
                       ForEach-Object { [int]$_.Groups[1].Value }
            $Ms = if ($Tiempos.Count -gt 0) {
                [math]::Round(($Tiempos | Measure-Object -Average).Average, 0)
            } else { $null }
            $Hops += [PSCustomObject]@{ Hop = $NumHop; IP = $HopIP; Ms = $Ms }
        }
    }
    return $Hops
}

function Test-TCPPort {
    param([string]$IP, [int]$Puerto, [int]$TimeoutMs = 3000)
    try {
        $TCP      = New-Object System.Net.Sockets.TcpClient
        $Conexion = $TCP.BeginConnect($IP, $Puerto, $null, $null)
        $Espera   = $Conexion.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $Abierto  = $Espera -and $TCP.Connected
        $TCP.Close()
        return $Abierto
    } catch { return $false }
}

function Get-RegionServidor {
    # Intenta determinar si el servidor esta en Europa o EE.UU. via DNS inverso
    param([string]$IP)
    try {
        $DNS = [System.Net.Dns]::GetHostEntry($IP)
        $Hostname = $DNS.HostName.ToLower()
        if ($Hostname -match 'hetzner|ovh|scaleway|strato|ionos|server\.de|your-server\.de|contabo') {
            return "EU"
        }
        if ($Hostname -match 'amazonaws|azure|google|digitalocean|linode|vultr|cloudflare') {
            return "US"
        }
    } catch { }
    return "DESCONOCIDA"
}
#endregion

$Reporte = [System.Collections.Generic.List[string]]::new()
function Add-R { param([string]$L) $Reporte.Add($L) | Out-Null }

Clear-Host
$FechaInicio = Get-Date

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   DIAGNOSTICO DE CALIDAD DE CONEXION AL SERVIDOR TERMINAL" -ForegroundColor White
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

Add-R "DIAGNOSTICO DE CALIDAD DE CONEXION AL SERVIDOR TERMINAL"
Add-R "Fecha  : $($FechaInicio.ToString('dd/MM/yyyy HH:mm:ss'))"
Add-R "Equipo : $env:COMPUTERNAME"
Add-R ("=" * 70)

# ============================================================
# PASO 1: SELECCION DE PAIS
# ============================================================
Write-Host "  Seleccione el pais desde donde se conecta el cliente:" -ForegroundColor Yellow
Write-Host ""
Write-Host "    [1] Chile     - Santiago"  -ForegroundColor White
Write-Host "    [2] Peru      - Lima"      -ForegroundColor White
Write-Host "    [3] Bolivia   - La Paz"    -ForegroundColor White
Write-Host "    [4] Ecuador   - Quito"     -ForegroundColor White
Write-Host "    [5] Colombia  - Bogota"    -ForegroundColor White
Write-Host "    [6] Paraguay  - Asuncion"  -ForegroundColor White
Write-Host ""

$SelPais = ""
while (-not $ReferenciasLatencia.ContainsKey($SelPais)) {
    $SelPais = (Read-Host "  Ingrese el numero del pais [1-6]").Trim()
    if (-not $ReferenciasLatencia.ContainsKey($SelPais)) {
        Write-Host "  Opcion no valida. Intente nuevamente." -ForegroundColor Red
    }
}
$InfoPais = $ReferenciasLatencia[$SelPais]
Write-Host "  Pais: $($InfoPais.Pais) ($($InfoPais.Ciudad))" -ForegroundColor Green

# ============================================================
# PASO 2: IP DEL SERVIDOR TERMINAL
# ============================================================
Write-Host ""
$IPServidor = ""
while (-not (Validate-IP $IPServidor)) {
    $IPServidor = (Read-Host "  IP publica del servidor terminal (ej: 168.119.24.106)").Trim()
    if (-not (Validate-IP $IPServidor)) {
        Write-Host "  IP no valida. Formato esperado: 4 numeros separados por puntos (0-255)" -ForegroundColor Red
    }
}
Write-Host "  IP servidor: $IPServidor" -ForegroundColor Green

# ============================================================
# PASO 3: PUERTO RDP
# ============================================================
Write-Host ""
Write-Host "  Puerto RDP del servidor terminal" -ForegroundColor Yellow
Write-Host "  (Presione Enter para usar el puerto por defecto 3389)" -ForegroundColor Gray
$PuertoInput = (Read-Host "  Puerto").Trim()

if ($PuertoInput -eq "") {
    $PuertoRDP = 3389
} elseif (Validate-Port $PuertoInput) {
    $PuertoRDP = [int]$PuertoInput
} else {
    Write-Host "  Puerto no valido. Se usara 3389 por defecto." -ForegroundColor Yellow
    $PuertoRDP = 3389
}
Write-Host "  Puerto RDP: $PuertoRDP" -ForegroundColor Green
Write-Host ""

# Detectar region del servidor
$RegionServidor = Get-RegionServidor -IP $IPServidor
$RefMs = switch ($RegionServidor) {
    "EU"   { $InfoPais.EU_ms }
    "US"   { $InfoPais.US_ms }
    default { [math]::Min($InfoPais.EU_ms, $InfoPais.US_ms) }
}
$UmbralLatencia_MS = [math]::Round($RefMs * (1 + $InfoPais.Margen), 0)

Add-R ""
Add-R "Pais del cliente    : $($InfoPais.Pais) - $($InfoPais.Ciudad)"
Add-R "IP servidor         : $IPServidor"
Add-R "Puerto RDP          : $PuertoRDP"
Add-R "Region detectada    : $RegionServidor"
Add-R "Latencia ref. EU    : $($InfoPais.EU_ms) ms (WonderNetwork)"
Add-R "Latencia ref. US    : $($InfoPais.US_ms) ms (WonderNetwork)"
Add-R "Umbral alerta (+20%): $UmbralLatencia_MS ms"

# ============================================================
# SECCION 1: INFORMACION DEL EQUIPO CLIENTE
# ============================================================
Write-Header "1. INFORMACION DEL EQUIPO CLIENTE"
Add-R ""
Add-R "[1. INFORMACION DEL CLIENTE]"

try {
    $OS = Get-WmiObject Win32_OperatingSystem
    $CS = Get-WmiObject Win32_ComputerSystem
    Write-Host "  Equipo  : $($CS.Name)" -ForegroundColor White
    Write-Host "  Sistema : $($OS.Caption) ($($OS.OSArchitecture))" -ForegroundColor White
    Write-Host "  Usuario : $env:USERNAME" -ForegroundColor White
    Add-R "  Equipo: $($CS.Name) | OS: $($OS.Caption) | Usuario: $env:USERNAME"
} catch { }

Write-SubHeader "Adaptador de red activo"
$Adaptadores = Get-WmiObject Win32_NetworkAdapterConfiguration |
               Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }
$GatewayIP = $null
if ($Adaptadores) {
    foreach ($A in $Adaptadores) {
        $IPs = $A.IPAddress -join ", "
        $GW  = ($A.DefaultIPGateway -join ", ")
        $GatewayIP = $A.DefaultIPGateway | Select-Object -First 1
        Write-Host "  Adaptador : $($A.Description)" -ForegroundColor White
        Write-Host "  IP local  : $IPs" -ForegroundColor White
        Write-Host "  Gateway   : $GW" -ForegroundColor White
        Write-Host "  DNS       : $($A.DNSServerSearchOrder -join ', ')" -ForegroundColor Gray
        Add-R "  Adaptador: $($A.Description) | IP: $IPs | GW: $GW"
    }
} else {
    Write-Host "  [!] No se detecto adaptador con gateway." -ForegroundColor Yellow
}


# ============================================================
# SECCION 2: RED LOCAL - GATEWAY
# ============================================================
Write-Header "2. RED LOCAL - GATEWAY"
Add-R ""
Add-R "[2. RED LOCAL - GATEWAY]"

$TestGW = $null
if ($GatewayIP) {
    Write-Host "  Probando gateway: $GatewayIP ($PingRepeticiones pings)..." -ForegroundColor Gray
    $TestGW = Test-LatenciaDetallada -IP $GatewayIP -Count $PingRepeticiones

    if ($TestGW.Alcanzable) {
        $ColorGW = if ($TestGW.Avg_ms -gt 20) { "Red" } elseif ($TestGW.Avg_ms -gt 5) { "Yellow" } else { "Green" }
        $EstGW   = if ($TestGW.Avg_ms -gt 20) { "ALTO" } elseif ($TestGW.Avg_ms -gt 5) { "ELEVADO" } else { "OK" }
        Write-Host "  Gateway IP        : $GatewayIP"                                                              -ForegroundColor White
        Write-Host "  Latencia promedio : $($TestGW.Avg_ms) ms  (min=$($TestGW.Min_ms) / max=$($TestGW.Max_ms))"  -ForegroundColor $ColorGW
        Write-Host "  Jitter            : $($TestGW.Jitter_ms) ms"                                                 -ForegroundColor $ColorGW
        Write-Host "  Perdida           : $($TestGW.Perdida_Pct) %"                                                -ForegroundColor $ColorGW
        Write-Host "  Estado            : $EstGW"                                                                  -ForegroundColor $ColorGW
        Add-R "  Gateway $GatewayIP - avg=$($TestGW.Avg_ms)ms jitter=$($TestGW.Jitter_ms)ms perdida=$($TestGW.Perdida_Pct)% - $EstGW"
    } else {
        Write-Host "  Estado : SIN RESPUESTA" -ForegroundColor Red
        Add-R "  Gateway $GatewayIP - SIN RESPUESTA"
    }
} else {
    Write-Host "  Estado : SIN GATEWAY DETECTADO" -ForegroundColor Yellow
    Add-R "  Gateway: no detectado"
}

# ============================================================
# SECCION 3: CONECTIVIDAD AL SERVIDOR TERMINAL
# ============================================================
Write-Header "3. CONECTIVIDAD AL SERVIDOR TERMINAL"
Add-R ""
Add-R "[3. CONECTIVIDAD AL SERVIDOR]"

Write-Host "  Servidor          : $IPServidor" -ForegroundColor White
Write-Host "  Puerto RDP        : $PuertoRDP"  -ForegroundColor White
Write-Host "  Region detectada  : $RegionServidor" -ForegroundColor White

$RefLabel = if ($RegionServidor -eq "EU") { "Europa - $($InfoPais.EU_ms) ms" } `
            elseif ($RegionServidor -eq "US") { "EE.UU. - $($InfoPais.US_ms) ms" } `
            else { "EU=$($InfoPais.EU_ms) ms / US=$($InfoPais.US_ms) ms" }
Write-Host "  Ref. WonderNetwork: $RefLabel (desde $($InfoPais.Pais))" -ForegroundColor White
Write-Host "  Umbral alerta     : $UmbralLatencia_MS ms (ref. +20%)"   -ForegroundColor White
Write-Host ""
Write-Host "  Realizando $PingRepeticiones pings al servidor..." -ForegroundColor Gray

$TestSrv = Test-LatenciaDetallada -IP $IPServidor -Count $PingRepeticiones

if ($TestSrv.Alcanzable) {
    $ColorSrv  = if ($TestSrv.Avg_ms -ge $UmbralLatencia_MS)   { "Red" } `
                 elseif ($TestSrv.Avg_ms -ge ($RefMs * 1.10))  { "Yellow" } `
                 else { "Green" }
    $EstSrv    = if ($TestSrv.Avg_ms -ge $UmbralLatencia_MS)   { "SOBRE UMBRAL" } `
                 elseif ($TestSrv.Avg_ms -ge ($RefMs * 1.10))  { "ELEVADO" } `
                 else { "OK" }
    $ColorJit  = if ($TestSrv.Jitter_ms -ge $UmbralJitter_MS)  { "Red" } `
                 elseif ($TestSrv.Jitter_ms -ge 15)             { "Yellow" } else { "Green" }
    $EstJit    = if ($TestSrv.Jitter_ms -ge $UmbralJitter_MS)  { "ALTO" } `
                 elseif ($TestSrv.Jitter_ms -ge 15)             { "ELEVADO" } else { "OK" }
    $ColorPerd = if ($TestSrv.Perdida_Pct -ge $UmbralPerdida_Pct) { "Red" } `
                 elseif ($TestSrv.Perdida_Pct -ge 1)               { "Yellow" } else { "Green" }
    $EstPerd   = if ($TestSrv.Perdida_Pct -ge $UmbralPerdida_Pct) { "ALTA" } `
                 elseif ($TestSrv.Perdida_Pct -ge 1)               { "LEVE" } else { "OK" }

    Write-Host "  Latencia promedio : $($TestSrv.Avg_ms) ms  (min=$($TestSrv.Min_ms) / max=$($TestSrv.Max_ms))  [$EstSrv]"         -ForegroundColor $ColorSrv
    Write-Host "  Jitter            : $($TestSrv.Jitter_ms) ms  [$EstJit]"                                                          -ForegroundColor $ColorJit
    Write-Host "  Perdida paquetes  : $($TestSrv.Perdida_Pct) % ($($TestSrv.Exitosos)/$($TestSrv.Total) exitosos)  [$EstPerd]"      -ForegroundColor $ColorPerd
    Add-R "  Servidor $IPServidor - avg=$($TestSrv.Avg_ms)ms [$EstSrv] jitter=$($TestSrv.Jitter_ms)ms [$EstJit] perdida=$($TestSrv.Perdida_Pct)% [$EstPerd]"
} else {
    Write-Host "  Latencia          : SIN RESPUESTA ICMP" -ForegroundColor Red
    Add-R "  Servidor $IPServidor - SIN RESPUESTA ICMP"
}

# ============================================================
# SECCION 4: TRACEROUTE
# ============================================================
Write-Header "4. TRAZADO DE RUTA (traceroute)"
Add-R ""
Add-R "[4. TRACEROUTE A $IPServidor]"

Write-Host "  Ejecutando tracert hacia $IPServidor (max 20 saltos)..." -ForegroundColor Gray
Write-Host "  Puede tomar hasta 60 segundos..." -ForegroundColor Gray
Write-Host ""

$Hops = Get-Traceroute -IP $IPServidor -MaxHops 20

if ($Hops.Count -gt 0) {
    Write-Host ("  {0,4}  {1,-18}  {2,10}  {3}" -f "Hop", "IP", "Latencia", "Nota") -ForegroundColor Gray
    Write-Host "  $('-' * 60)" -ForegroundColor Gray

    $HopAnteriorMs = $null
    $LlegoDestino  = $false

    foreach ($H in $Hops) {
        $MsStr = if ($null -ne $H.Ms) { "$($H.Ms) ms" } else { "timeout" }
        $Obs   = ""
        $Color = "White"

        if ($H.IP -eq "*") {
            $Color = "Gray"
            $Obs   = "sin respuesta"
        } elseif ($null -ne $H.Ms) {
            if ($H.IP -eq $IPServidor) {
                $Color = "Green"
                $Obs   = "DESTINO"
                $LlegoDestino = $true
            } elseif ($null -ne $HopAnteriorMs -and ($H.Ms - $HopAnteriorMs) -gt 80) {
                $Color = "Yellow"
                $Obs   = "+$([math]::Round($H.Ms - $HopAnteriorMs)) ms vs hop anterior"
            } elseif ($H.Ms -gt 300) {
                $Color = "Red"
                $Obs   = "latencia alta"
            }
            $HopAnteriorMs = $H.Ms
        }

        $Linea = "  {0,4}  {1,-18}  {2,10}  {3}" -f $H.Hop, $H.IP, $MsStr, $Obs
        Write-Host $Linea -ForegroundColor $Color
        Add-R $Linea
    }

    Write-Host ""
    $TotalSaltos   = $Hops.Count
    $SaltosTimeout = ($Hops | Where-Object { $_.IP -eq "*" }).Count
    $EstRuta = if ($LlegoDestino) { "COMPLETA" } else { "INCOMPLETA" }
    $ColorRuta = if ($LlegoDestino) { "Green" } else { "Yellow" }
    Write-Host "  Saltos totales    : $TotalSaltos" -ForegroundColor White
    Write-Host "  Sin respuesta     : $SaltosTimeout" -ForegroundColor White
    Write-Host "  Estado ruta       : $EstRuta" -ForegroundColor $ColorRuta
    Add-R "  Ruta: $TotalSaltos saltos / $SaltosTimeout timeout / $EstRuta"
} else {
    Write-Host "  Estado : SIN RESULTADOS" -ForegroundColor Red
    Add-R "  Traceroute: sin resultados"
}

# ============================================================
# SECCION 5: PUERTOS TCP
# ============================================================
Write-Header "5. PUERTOS TCP"
Add-R ""
Add-R "[5. PUERTOS TCP]"

Write-Host "  Probando puerto $PuertoRDP (RDP)..." -ForegroundColor Gray
$RDPAbierto = Test-TCPPort -IP $IPServidor -Puerto $PuertoRDP
$EstRDP     = if ($RDPAbierto) { "ABIERTO" } else { "CERRADO/FILTRADO" }
$ColorRDP   = if ($RDPAbierto) { "Green" }   else { "Red" }
Write-Host "  Puerto $PuertoRDP (RDP)  : $EstRDP" -ForegroundColor $ColorRDP
Add-R "  Puerto $PuertoRDP (RDP): $EstRDP"

Write-Host "  Probando puerto 443 (HTTPS/RDG)..." -ForegroundColor Gray
$P443Abierto = Test-TCPPort -IP $IPServidor -Puerto 443
$Est443      = if ($P443Abierto) { "ABIERTO" } else { "CERRADO/FILTRADO" }
$Color443    = if ($P443Abierto) { "Green" }   else { "Gray" }
Write-Host "  Puerto 443 (HTTPS) : $Est443" -ForegroundColor $Color443
Add-R "  Puerto 443 (HTTPS): $Est443"

if ($PuertoRDP -ne 3389) {
    Write-Host "  Probando puerto 3389 (RDP default)..." -ForegroundColor Gray
    $P3389Abierto = Test-TCPPort -IP $IPServidor -Puerto 3389
    $Est3389      = if ($P3389Abierto) { "ABIERTO" } else { "CERRADO/FILTRADO" }
    $Color3389    = if ($P3389Abierto) { "Green" }   else { "Gray" }
    Write-Host "  Puerto 3389 (RDP)  : $Est3389" -ForegroundColor $Color3389
    Add-R "  Puerto 3389 (RDP default): $Est3389"
}

# ============================================================
# SECCION 6: RESUMEN
# ============================================================
Write-Header "6. RESUMEN"
Add-R ""
Add-R "[6. RESUMEN]"

Write-Host ""
Write-Host "  ---- EQUIPO CLIENTE ----" -ForegroundColor Gray
Write-Host "  Pais              : $($InfoPais.Pais) - $($InfoPais.Ciudad)" -ForegroundColor White

if ($TestGW -and $TestGW.Alcanzable) {
    $EstGWR   = if ($TestGW.Avg_ms -gt 20) { "ALTO" } elseif ($TestGW.Avg_ms -gt 5) { "ELEVADO" } else { "OK" }
    $ColorGWR = if ($TestGW.Avg_ms -gt 20) { "Red" }  elseif ($TestGW.Avg_ms -gt 5) { "Yellow" }  else { "Green" }
    Write-Host "  Gateway           : $GatewayIP" -ForegroundColor White
    Write-Host "  Latencia gateway  : $($TestGW.Avg_ms) ms  [$EstGWR]"       -ForegroundColor $ColorGWR
    Write-Host "  Jitter gateway    : $($TestGW.Jitter_ms) ms"               -ForegroundColor $ColorGWR
    Write-Host "  Perdida gateway   : $($TestGW.Perdida_Pct) %"              -ForegroundColor $ColorGWR
    Add-R "  Gateway: avg=$($TestGW.Avg_ms)ms jitter=$($TestGW.Jitter_ms)ms perdida=$($TestGW.Perdida_Pct)% [$EstGWR]"
}

Write-Host ""
Write-Host "  ---- SERVIDOR TERMINAL ----" -ForegroundColor Gray
Write-Host "  IP                : $IPServidor (Puerto $PuertoRDP)" -ForegroundColor White
Write-Host "  Region            : $RegionServidor"                 -ForegroundColor White
Write-Host "  Referencia        : $RefLabel"                       -ForegroundColor White
Write-Host "  Umbral (+20%)     : $UmbralLatencia_MS ms"          -ForegroundColor White

if ($TestSrv.Alcanzable) {
    $ColorR = if ($TestSrv.Avg_ms -ge $UmbralLatencia_MS) { "Red" } elseif ($TestSrv.Avg_ms -ge ($RefMs * 1.10)) { "Yellow" } else { "Green" }
    $EstR   = if ($TestSrv.Avg_ms -ge $UmbralLatencia_MS) { "SOBRE UMBRAL" } elseif ($TestSrv.Avg_ms -ge ($RefMs * 1.10)) { "ELEVADO" } else { "OK" }
    $EstJR  = if ($TestSrv.Jitter_ms -ge $UmbralJitter_MS) { "ALTO" } elseif ($TestSrv.Jitter_ms -ge 15) { "ELEVADO" } else { "OK" }
    $EstPR  = if ($TestSrv.Perdida_Pct -ge $UmbralPerdida_Pct) { "ALTA" } elseif ($TestSrv.Perdida_Pct -ge 1) { "LEVE" } else { "OK" }
    Write-Host "  Latencia          : $($TestSrv.Avg_ms) ms  [$EstR]"         -ForegroundColor $ColorR
    Write-Host "  Jitter            : $($TestSrv.Jitter_ms) ms  [$EstJR]"     -ForegroundColor $(if ($EstJR -eq "OK") { "Green" } elseif ($EstJR -eq "ELEVADO") { "Yellow" } else { "Red" })
    Write-Host "  Perdida           : $($TestSrv.Perdida_Pct) %  [$EstPR]"   -ForegroundColor $(if ($EstPR -eq "OK") { "Green" } elseif ($EstPR -eq "LEVE") { "Yellow" } else { "Red" })
    Add-R "  Servidor: latencia=$($TestSrv.Avg_ms)ms [$EstR] jitter=$($TestSrv.Jitter_ms)ms [$EstJR] perdida=$($TestSrv.Perdida_Pct)% [$EstPR]"
} else {
    Write-Host "  Latencia ICMP     : SIN RESPUESTA" -ForegroundColor Red
    Add-R "  Servidor: SIN RESPUESTA ICMP"
}

Write-Host "  Puerto $PuertoRDP (RDP)   : $EstRDP" -ForegroundColor $ColorRDP
Write-Host "  Puerto 443 (HTTPS) : $Est443"         -ForegroundColor $Color443
Add-R "  Puerto ${PuertoRDP}: $EstRDP | Puerto 443: $Est443"

try {
    $Reporte | Out-File -FilePath $ReportePath -Encoding UTF8
    Write-Host ""
    Write-Host "  Reporte guardado en: $ReportePath" -ForegroundColor Cyan
} catch {
    Write-Host "  No se pudo guardar el reporte: $_" -ForegroundColor Red
}

$Dur = [math]::Round(((Get-Date) - $FechaInicio).TotalSeconds, 0)
Write-Host ""
Write-Host "  Diagnostico completado en $Dur segundos." -ForegroundColor Gray
Write-Host ""
