# HomeLab - copia "pull" do repositorio restic (criptografado) do servidor para o PC.
# Executado pela tarefa do usuario "\HomeLab\HomeLab Backup Pull" (diaria e no logon).
# Mantem a copia atual e a anterior; uma transferencia incompleta nunca substitui a boa.
param(
    [string]$HostAlias = 'homelab',
    [string]$RemoteRepo = '/var/backups/homelab-restic',
    [string]$Dest = (Join-Path $env:USERPROFILE 'HomeLab-Backups')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$log  = Join-Path $Dest 'pull.log'
$cur  = Join-Path $Dest 'restic'
$prev = Join-Path $Dest 'restic.previous'
$tmp  = Join-Path $Dest 'restic.incoming'
function Write-Log([string]$m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $log -Encoding UTF8 }

try {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    & scp.exe -q -r -o BatchMode=yes -o ConnectTimeout=15 "${HostAlias}:$RemoteRepo" $tmp
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $tmp 'config'))) { throw "scp falhou (codigo $LASTEXITCODE)" }
    $n = (Get-ChildItem $tmp -Recurse -File | Measure-Object -Property Length -Sum)
    if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
    if (Test-Path $cur)  { Rename-Item $cur $prev }
    Rename-Item $tmp $cur
    Write-Log ("ok: {0} arquivos, {1:N1} MB" -f $n.Count, ($n.Sum / 1MB))
} catch {
    Write-Log "FALHA: $($_.Exception.Message)"
    exit 1
}
