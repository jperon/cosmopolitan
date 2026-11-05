$ErrorActionPreference = 'Stop'
$fail = $false
$servers = @()

function Fail($msg) {
    Write-Host "FAIL: $msg"
    $script:fail = $true
}

function RunT($exe, $a, $to) {
    $p = Start-Process $exe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput o -RedirectStandardError e
    $null = $p.Handle
    if (-not $p.WaitForExit($to)) { try { $p.Kill() } catch {}; return "TIMEOUT" }
    return $p.ExitCode
}

function StartServer($argv, $log) {
    $p = Start-Process .\redbean.exe -ArgumentList $argv -NoNewWindow -PassThru -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
    $script:servers += $p
    return $p
}

function CurlCheck($url, $want, $extra = @()) {
    $argv = @('-s', '-k', '-o', 'body.txt', '-w', '%{http_code}', '--max-time', '10') + $extra + @($url)
    $code = & curl.exe @argv
    if ($LASTEXITCODE -ne 0) { Fail "$url curl exit $LASTEXITCODE"; return }
    if ("$code" -ne '200') { Fail "$url status $code"; return }
    $body = [IO.File]::ReadAllText((Join-Path $PWD 'body.txt'))
    if (-not $body.StartsWith($want)) { Fail "$url body [$body]" }
}

if (-not (Test-Path redbean.exe)) {
    Copy-Item redbean redbean.exe
}

New-Item -ItemType Directory -Force site | Out-Null
Set-Content -NoNewline -LiteralPath site\ip.lua -Value 'Write(FormatIp((GetRemoteAddr())).." host="..tostring(GetHost()).."\n")'

# Never kill these servers: killing one redbean may take down the whole
# process group.  They are left running until this script exits.
StartServer @('-D', 'site', '-p', '18801', '-l', '::1', '-l', '127.0.0.1', '-L', 'l1.txt') 'l1' | Out-Null
StartServer @('-D', 'site', '-p', '18803', '-l', '0.0.0.0', '-l', '::', '-L', 'l3.txt') 'l3' | Out-Null
StartServer @('-D', 'site', '-p', '18804', '-L', 'l4.txt') 'l4' | Out-Null

Start-Sleep -Seconds 2

CurlCheck 'http://[::1]:18801/ip.lua' '::1'
CurlCheck 'http://127.0.0.1:18803/ip.lua' '127.0.0.1'
CurlCheck 'http://[::1]:18803/ip.lua' '::1'
CurlCheck 'http://127.0.0.1:18804/ip.lua' '127.0.0.1'
CurlCheck 'https://[::1]:18801/ip.lua' '::1'
CurlCheck 'https://host.test:18801/ip.lua' '::1' @('--connect-to', 'host.test:18801:[::1]:18801')

$code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 10 'http://[::1]:18804/ip.lua'
if ($LASTEXITCODE -eq 0) { Fail "[::1]:18804 unexpectedly succeeded (status $code)" }

$ll = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq 'fe80::1' -and $_.InterfaceAlias -like 'Loopback*' } |
    Select-Object -First 1
if ($ll) {
    $z = $ll.InterfaceIndex
    StartServer @('-D', 'site', '-p', '18806', '-l', "fe80::1%$z", '-L', 'l5.txt') 'l5' | Out-Null
    Start-Sleep -Seconds 1
    CurlCheck "http://[$($ll.IPAddress)%25$z]:18806/ip.lua" 'fe80::1'
    if (Test-Path l5.txt) {
        if (Select-String -Path l5.txt -Pattern 'listen' -Quiet) {
            Write-Host "ok fe80 listen"
        } else {
            Fail "fe80 did not listen"
        }
    } else {
        Fail "no fe80 log"
    }
} else {
    Write-Host "skip: no fe80::1 loopback address"
}

foreach ($log in @('l1.txt', 'l3.txt', 'l4.txt')) {
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'SIGSEGV' -Quiet)) {
        Fail "SIGSEGV in $log"
    }
}

Get-ChildItem -Path tests -Filter '*_test' -File | ForEach-Object {
    $src = $_.FullName
    $exe = "$src.exe"
    Copy-Item -Force $src $exe
    $rc = RunT -exe $exe -a @(" ") -to 120000
    if ($rc -eq 0) {
        Write-Host "ok $($_.Name)"
    } else {
        Write-Host "ko $($_.Name) ($rc)"
        Get-Content o, e -ErrorAction SilentlyContinue | Select-Object -First 40
        $script:fail = $true
    }
}

Get-ChildItem -Path lua -Filter '*_test.lua' -File | ForEach-Object {
    $rc = RunT -exe .\redbean.exe -a @('-i', $_.FullName) -to 120000
    if ($rc -eq 0) {
        Write-Host "ok $($_.Name)"
    } else {
        Write-Host "ko $($_.Name) ($rc)"
        Get-Content o, e -ErrorAction SilentlyContinue | Select-Object -First 40
        $script:fail = $true
    }
}

foreach ($p in $servers) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
}

if ($fail) {
    Write-Host "FAIL"
    exit 1
}
Write-Host "PASS"
exit 0
