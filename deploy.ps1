# 部署到 GitHub Pages（gh-pages 分支）
#
# 用法（在仓库根目录）：
#   .\deploy.ps1
#   .\deploy.ps1 -PnpmPath 'C:\path\to\pnpm.cjs'     # pnpm 不在 PATH 时手动指定
#
# 做的事：
#   1. 用 DOCS_BASE=/<repo>/ 构建
#   2. 把 .vitepress/dist 推到 gh-pages 分支
#
# 前提：当前仓库的 remote 指向目标仓库，且已能免交互推送（SSH key 或凭据管理器）。

param(
    [string]$Repo     = 'LinStar2006/SSMT4-Tutorial',
    [string]$Branch   = 'gh-pages',
    [string]$PnpmPath = ''
)

$ErrorActionPreference = 'Stop'

# 调用外部程序。Windows PowerShell 在 $ErrorActionPreference='Stop' 下会把子进程写到
# stderr 的普通输出（比如 git、vite 的进度信息）当成终止错误，所以这里临时放开。
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
}

# 找可用的 pnpm：显式参数 > PATH > 常见安装位置。
function Resolve-Pnpm {
    if ($PnpmPath) {
        if (-not (Test-Path $PnpmPath)) { throw "指定的 pnpm 不存在：$PnpmPath" }
        return @('node', $PnpmPath)
    }

    if (Get-Command pnpm -ErrorAction SilentlyContinue) { return @('pnpm') }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'nodejs')
        (Join-Path ${env:ProgramFiles(x86)} 'nodejs')
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
        (Join-Path $env:APPDATA 'npm')
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($dir in $candidates) {
        $cjs = Join-Path $dir 'bin\pnpm.cjs'
        if (-not (Test-Path $cjs)) { $cjs = Join-Path $dir 'pnpm.cjs' }
        if (Test-Path $cjs) { return @('node', $cjs) }
    }

    throw '找不到 pnpm。请先 npm i -g pnpm，或用 -PnpmPath 指定 pnpm.cjs 的完整路径。'
}

$pnpm = Resolve-Pnpm
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$base = "/$($Repo.Split('/')[1])/"

Write-Host "==> 构建（DOCS_BASE=$base）"
$env:DOCS_BASE = $base
$code = Invoke-Native $pnpm[0] ($pnpm[1..($pnpm.Length - 1)] + @('run', 'build'))
Remove-Item Env:\DOCS_BASE -ErrorAction SilentlyContinue
if ($code -ne 0) { throw "构建失败（exit $code）" }

$dist = Join-Path $root '.vitepress\dist'
if (-not (Test-Path $dist)) { throw "找不到构建产物：$dist" }

Write-Host "==> 准备 gh-pages 工作区"
$tmp = Join-Path $env:TEMP ("ssmt-ghpages-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Copy-Item -Path (Join-Path $dist '*') -Destination $tmp -Recurse -Force
New-Item -ItemType File -Path (Join-Path $tmp '.nojekyll') -Force | Out-Null

Push-Location $tmp
try {
    Invoke-Native 'git' @('init', '-b', $Branch, '--quiet') | Out-Null
    Invoke-Native 'git' @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Native 'git' @('add', '-A') | Out-Null
    $msg = "deploy: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $sha = (Invoke-Native 'git' @('-C', $root, 'rev-parse', '--short', 'HEAD'))
    if ($sha) { $msg += " from $sha" }
    Invoke-Native 'git' @('-c', 'user.name=LinStar2006',
                          '-c', 'user.email=LinStar2006@users.noreply.github.com',
                          'commit', '-q', '-m', $msg) | Out-Null

    # 优先用仓库已配置的 remote（凭据已存好）；没有再拼 https 地址
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $remote = git -C $root remote get-url origin 2>$null
    $ErrorActionPreference = $prev
    if (-not $remote) { $remote = "https://github.com/$Repo.git" }

    Write-Host "==> 推送到 $remote ($Branch)"
    $code = Invoke-Native 'git' @('push', '--force', $remote, "${Branch}:${Branch}")
    if ($code -ne 0) { throw "推送失败（exit $code）" }
}
finally {
    Pop-Location
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "==> 完成：https://$($Repo.Split('/')[0]).github.io/$($Repo.Split('/')[1])/"