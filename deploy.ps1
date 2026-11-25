# 部署到 GitHub Pages（gh-pages 分支）
#
# 用法（在仓库根目录）：
#   .\deploy.ps1
#
# 做的事：
#   1. 用 DOCS_BASE=/SSMT4-Tutorial/ 构建
#   2. 把 .vitepress/dist 推到 gh-pages 分支
#
# 前提：当前仓库的 origin 指向目标仓库，且已能免交互推送（SSH key 或凭据管理器）。

param(
    [string]$Repo   = 'LinStar2006/SSMT4-Tutorial',
    [string]$Branch = 'gh-pages'
)

$ErrorActionPreference = 'Stop'

# 本机 pnpm 不在 PATH，需要显式走完整路径
$nodeDir = 'C:\Users\North\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin'
$pnpmCjs = 'C:\Users\North\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.cjs'
if (Test-Path $nodeDir) { $env:PATH = "$nodeDir;$env:PATH" }
$pnpm = if (Test-Path $pnpmCjs) { @('node', $pnpmCjs) } else { @('pnpm') }

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$base = "/$($Repo.Split('/')[1])/"

Write-Host "==> 构建（DOCS_BASE=$base）"
$env:DOCS_BASE = $base
& $pnpm[0] $pnpm[1..($pnpm.Length - 1)] run build
if ($LASTEXITCODE -ne 0) { throw "构建失败（exit $LASTEXITCODE）" }
Remove-Item Env:\DOCS_BASE -ErrorAction SilentlyContinue

$dist = Join-Path $root '.vitepress\dist'
if (-not (Test-Path $dist)) { throw "找不到构建产物：$dist" }

Write-Host "==> 准备 gh-pages 工作区"
$tmp = Join-Path $env:TEMP "ssmt-ghpages-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Copy-Item -Path (Join-Path $dist '*') -Destination $tmp -Recurse -Force
New-Item -ItemType File -Path (Join-Path $tmp '.nojekyll') -Force | Out-Null

Push-Location $tmp
try {
    git init -b $Branch --quiet
    git config core.autocrlf false
    git add -A
    git -c user.name='LinStar2006' -c user.email='LinStar2006@users.noreply.github.com' `
        commit -q -m "deploy: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') from $(git -C $root rev-parse --short HEAD)"

    Write-Host "==> 推送到 $Repo ($Branch)"
    git push --force "https://github.com/$Repo.git" "${Branch}:${Branch}"
    if ($LASTEXITCODE -ne 0) { throw "推送失败（exit $LASTEXITCODE）" }
}
finally {
    Pop-Location
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "==> 完成：https://$($Repo.Split('/')[0]).github.io/$($Repo.Split('/')[1])/"