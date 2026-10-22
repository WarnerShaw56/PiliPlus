param(
    [string]$Server = 'root@60.204.209.218',
    [string]$IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519"
)
$ErrorActionPreference = 'Stop'
$repository = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot locate repository' }
$archive = Join-Path ([IO.Path]::GetTempPath()) ('piliplus-deploy-' + [guid]::NewGuid().ToString('N') + '.tar.gz')
try {
    git -C $repository archive --format=tar.gz --output=$archive HEAD tools/ai_recommendation_server
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
    scp -i $IdentityFile $archive "${Server}:/tmp/piliplus-service.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw 'Upload failed' }
    ssh -i $IdentityFile $Server 'set -eu; mkdir -p /opt/piliplus-deploy; tar -xzf /tmp/piliplus-service.tar.gz -C /opt/piliplus-deploy; bash /opt/piliplus-deploy/tools/ai_recommendation_server/deploy-instance.sh'
    if ($LASTEXITCODE -ne 0) { throw 'Deployment or health check failed' }
    Write-Host 'Deployment and health check passed.'
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
}
