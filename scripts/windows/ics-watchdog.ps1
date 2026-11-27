# HomeLab ICS watchdog
# Executado como SYSTEM pelo Agendador de Tarefas (no boot e a cada 5 min).
# Garante que o Compartilhamento de Conexao com a Internet (ICS) esteja
# Wi-Fi (publica) -> Ethernet (privada) e funcional; reaplica se quebrar.

$ErrorActionPreference = 'Stop'
$PublicName  = 'Wi-Fi'
$PrivateName = 'Ethernet'
$IcsAddress  = '192.168.137.1'
$Dir = 'C:\ProgramData\HomeLab'
$Log = Join-Path $Dir 'ics-watchdog.log'

function Write-Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Add-Content -Path $Log -Encoding UTF8
}

# Mantem o log pequeno (~ ultimas 500 linhas)
if ((Test-Path $Log) -and ((Get-Item $Log).Length -gt 200KB)) {
    Get-Content $Log -Tail 500 | Set-Content $Log -Encoding UTF8
}

function Get-SharingConfig([object]$mgr, [string]$name) {
    foreach ($c in $mgr.EnumEveryConnection) {
        $p = $mgr.NetConnectionProps.Invoke($c)
        if ($p.Name -eq $name) { return $mgr.INetSharingConfigurationForINetConnection.Invoke($c) }
    }
    return $null
}

function Test-IcsDns {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Resolve-DnsName -Name 'deb.debian.org' -Server $IcsAddress -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 5 }
    }
    return $false
}

try {
    $pub  = Get-NetAdapter -Name $PublicName  -ErrorAction SilentlyContinue
    $priv = Get-NetAdapter -Name $PrivateName -ErrorAction SilentlyContinue
    if (-not $pub -or -not $priv) { Write-Log "Adaptador ausente (Wi-Fi=$([bool]$pub) Ethernet=$([bool]$priv)); nada a fazer."; exit 0 }
    if ($pub.Status -ne 'Up') { exit 0 }  # sem Wi-Fi nao ha o que compartilhar

    # So age se o proprio PC tem internet (evita "consertar" quando o problema e o Wi-Fi)
    $pcOnline = (Test-NetConnection -ComputerName 1.1.1.1 -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet)
    if (-not $pcOnline) { Write-Log 'PC sem internet; ICS nao reavaliado.'; exit 0 }

    $mgr  = New-Object -ComObject HNetCfg.HNetShare
    $cPub = Get-SharingConfig $mgr $PublicName
    $cPrv = Get-SharingConfig $mgr $PrivateName

    $flagsOk = $cPub.SharingEnabled -and $cPub.SharingConnectionType -eq 0 -and
               $cPrv.SharingEnabled -and $cPrv.SharingConnectionType -eq 1

    $reason = $null
    if (-not $flagsOk) { $reason = 'configuracao ICS ausente/incorreta' }
    elseif ($priv.Status -eq 'Up' -and -not (Test-IcsDns)) { $reason = "ICS configurado mas DNS em $IcsAddress nao responde" }

    if ($reason) {
        Write-Log "Reaplicando ICS: $reason"
        foreach ($c in $mgr.EnumEveryConnection) {
            $cfg = $mgr.INetSharingConfigurationForINetConnection.Invoke($c)
            if ($cfg.SharingEnabled) { $cfg.DisableSharing() }
        }
        Start-Sleep -Seconds 2
        $cPub = Get-SharingConfig $mgr $PublicName
        $cPrv = Get-SharingConfig $mgr $PrivateName
        $cPub.EnableSharing(0)
        $cPrv.EnableSharing(1)
        Start-Sleep -Seconds 5
        if ($priv.Status -eq 'Up') { Write-Log "ICS reaplicado. DNS ICS ok: $(Test-IcsDns)" } else { Write-Log 'ICS reaplicado (Ethernet desconectada).' }
    }
} catch {
    Write-Log "ERRO: $($_.Exception.Message)"
    exit 1
}
