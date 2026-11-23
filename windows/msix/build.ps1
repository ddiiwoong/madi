# 마디 Windows판의 MSIX 꾸러미를 만든다 — Microsoft Store에 올릴 것(서명하지 않음 — Store가 서명한다).
#
#   pwsh windows/msix/build.ps1 -Source out\Madi -Output out\msix `
#        -IdentityName <꾸러미 이름> -Publisher "CN=<게시자 ID>" -PublisherDisplayName <게시자 표시 이름>
#
# -Source는 `dotnet publish … -r win-x64 --self-contained true`의 출력(Madi.exe와 editor\). 꾸러미 이름 · 게시자 · 게시자 표시 이름은
# Partner Center ▸ 앱 ▸ 제품 ID에 나온다(README.md). 주지 않으면 시험용 값(Madi.Test · CN=Madi Test)이다 — 그 꾸러미는 Store가 받지 않는다.
# 필요한 것: Windows SDK(makeappx · makepri — GitHub의 windows-latest에는 들어 있다), PowerShell 7.

param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Output,
    [string] $IdentityName = "Madi.Test",
    [string] $Publisher = "CN=Madi Test",
    [string] $PublisherDisplayName = "ddiiwoong",
    [string] $DisplayName = "마디",
    # 비우면 Madi.Windows.csproj의 Version. 세 마디면 네 번째에 0을 붙인다 — Store는 네 번째 마디를 0으로만 받는다.
    [string] $Version = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string] $message) { throw "MSIX: $message" }

# MARK: 값 확인 — 꾸러미 이름 · 판은 Windows가 꼴을 정해 둔 값이다. 틀리면 makeappx가 알아보기 어려운 말로 멈춘다.

if ($Version -eq "") {
    $project = Join-Path $PSScriptRoot "..\Madi.Windows\Madi.Windows.csproj"
    $Version = (Select-Xml -Path $project -XPath "//Version").Node.InnerText
}
if ($Version -match '^\d+\.\d+\.\d+$') { $Version = "$Version.0" }
if ($Version -notmatch '^\d+\.\d+\.\d+\.0$') { Fail "판은 0.1.2 · 0.1.2.0 꼴입니다(네 번째 마디는 0): $Version" }
if ($IdentityName -notmatch '^[A-Za-z0-9.-]{3,50}$') { Fail "꾸러미 이름은 영문 · 숫자 · '.' · '-'로 3~50자입니다: $IdentityName" }
if ($Publisher -notmatch '^CN=') { Fail "게시자는 CN=으로 시작합니다: $Publisher" }
if (-not (Test-Path (Join-Path $Source "Madi.exe"))) { Fail "Madi.exe가 없습니다: $Source" }
if (-not (Test-Path (Join-Path $Source "editor\index.html"))) { Fail "편집기 묶음(editor\index.html)이 없습니다: $Source" }

# MARK: SDK 도구 — 가장 새 판의 x64

$kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$bin = Get-ChildItem $kits -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName "x64" } |
    Where-Object { Test-Path (Join-Path $_ "makeappx.exe") } |
    Select-Object -First 1
if (-not $bin) { Fail "Windows SDK의 makeappx.exe를 찾지 못했습니다: $kits" }
$makeappx = Join-Path $bin "makeappx.exe"
$makepri = Join-Path $bin "makepri.exe"

function Run([string] $tool, [string[]] $arguments) {
    & $tool @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "$(Split-Path $tool -Leaf) 실패 — $LASTEXITCODE" }
}

# MARK: 꾸러미에 넣을 것 — publish 출력 + 로고 + 매니페스트 + resources.pri

$Output = [System.IO.Path]::GetFullPath($Output)
$stage = Join-Path $Output "stage"
$priRoot = Join-Path $Output "pri"
foreach ($folder in @($stage, $priRoot)) {
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory -Path $folder | Out-Null
}
Copy-Item -Path (Join-Path $Source "*") -Destination $stage -Recurse
Copy-Item -Path (Join-Path $PSScriptRoot "Assets") -Destination (Join-Path $stage "Assets") -Recurse

$escape = { param($value) [System.Security.SecurityElement]::Escape($value) }
$manifest = Get-Content (Join-Path $PSScriptRoot "AppxManifest.xml") -Raw -Encoding utf8
$values = [ordered]@{
    "{{IdentityName}}" = $IdentityName
    "{{Publisher}}" = $Publisher
    "{{PublisherDisplayName}}" = $PublisherDisplayName
    "{{DisplayName}}" = $DisplayName
    "{{Version}}" = $Version
}
foreach ($token in $values.Keys) { $manifest = $manifest.Replace($token, (& $escape $values[$token])) }
if ($manifest -match '\{\{') { Fail "채우지 못한 자리가 남았습니다" }
[System.IO.File]::WriteAllText((Join-Path $stage "AppxManifest.xml"), $manifest, [System.Text.UTF8Encoding]::new($false))

# 로고의 배율 · 크기 한정자(scale-200 · targetsize-24 …)는 resources.pri가 푼다. 로고만 따로 둔 폴더에서 만든다 — publish 출력
# (수백 개의 dll)까지 자원으로 훑지 않게.
Copy-Item -Path (Join-Path $PSScriptRoot "Assets") -Destination (Join-Path $priRoot "Assets") -Recurse
$priConfig = Join-Path $Output "priconfig.xml"
Run $makepri @("createconfig", "/cf", $priConfig, "/dq", "ko-KR", "/pv", "10.0.0", "/o")
Run $makepri @("new", "/pr", $priRoot, "/cf", $priConfig, "/mn", (Join-Path $stage "AppxManifest.xml"),
    "/of", (Join-Path $stage "resources.pri"), "/o")

# MARK: 묶기 — makeappx가 매니페스트를 스키마로 확인한다

$name = "Madi-$($Version -replace '\.0$', '')-windows-x64.msix"
$msix = Join-Path $Output $name
Run $makeappx @("pack", "/d", $stage, "/p", $msix, "/o")
Remove-Item $priRoot -Recurse -Force
Write-Host "MSIX: $msix ($([math]::Round((Get-Item $msix).Length / 1MB, 1)) MB) — $IdentityName $Version, $Publisher"
