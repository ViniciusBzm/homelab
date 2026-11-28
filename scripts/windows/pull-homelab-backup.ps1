# HomeLab - copia "pull" do EXPORT restic (criptografado) do servidor para o PC.
# Executado pela tarefa do usuario "\HomeLab\HomeLab Backup Pull" (diaria e no logon).
#
# Consistencia: o servidor so troca o export sob lock exclusivo; aqui a copia e feita
# com "flock -s" (lock compartilhado) + tar numa unica conexao, e so substitui a copia
# boa depois que o MANIFEST.sha256 confere arquivo por arquivo. Mantem atual + anterior.
param(
    [string]$HostAlias = 'homelab',
    [string]$RemoteParent = '/var/backups',
    [string]$RemoteName = 'homelab-restic-export',
    [string]$Dest = (Join-Path $env:USERPROFILE 'HomeLab-Backups')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HomeLabBackup.psm1') -Force
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$log  = Join-Path $Dest 'pull.log'
$cur  = Join-Path $Dest 'restic'
$prev = Join-Path $Dest 'restic.previous'
$tmp  = Join-Path $Dest 'restic.incoming'
function Write-Log([string]$m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $log -Encoding UTF8 }

# Um pull por vez (tarefa agendada + execucao manual, por exemplo).
$lock = Enter-HomeLabPullLock -Path (Join-Path $Dest 'pull.lock')
if (-not $lock) { Write-Log 'ignorado: outro pull em andamento'; exit 2 }
try {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    # Pipe binario pelo cmd.exe (o pipe do PowerShell 5.1 corrompe dados binarios).
    $remote = "flock -s -w 600 $RemoteParent/$RemoteName.lock tar -C $RemoteParent/$RemoteName -cf - ."
    $cmd = "ssh.exe -o BatchMode=yes -o ConnectTimeout=15 $HostAlias `"$remote`" | tar.exe -xf - -C `"$tmp`""
    & cmd.exe /d /c $cmd
    if ($LASTEXITCODE -ne 0) { throw "ssh/tar falhou (codigo $LASTEXITCODE)" }
    $check = Test-HomeLabManifest -Path $tmp
    if (-not $check.Ok) { throw ("copia rejeitada: " + (($check.Problems | Select-Object -First 5) -join '; ')) }
    Invoke-HomeLabRotation -Incoming $tmp -Current $cur -Previous $prev
    $gen = (Get-Content -LiteralPath (Join-Path $cur 'GENERATION') -ErrorAction SilentlyContinue | Select-Object -First 1)
    Write-Log ("ok: {0} arquivos conferidos pelo manifesto; geracao {1}" -f $check.Checked, $gen)
} catch {
    Write-Log "FALHA: $($_.Exception.Message) (copia atual preservada)"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $lock.Dispose(); exit 1
}
$lock.Dispose()
