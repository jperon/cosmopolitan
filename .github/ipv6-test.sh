#!/bin/sh
# IPv6 smoke tests for redbean and the net unit tests.
# Run from the directory that holds redbean, ape.elf, tests/ and lua/.
set -u

UNAME=$(uname -s)
RC=0

fail() {
    echo "FAIL: $*" >&2
    RC=1
}

# On BSD a new file inherits the group of the directory it is created in,
# and the directory synced into the VM may carry a different group.  Give
# the tree and the tests' temporary directory the caller's group so that
# lunix_test's st:gid() check matches unix.getgid().
chgrp "$(id -g)" . 2>/dev/null || true
case "$UNAME" in
    FreeBSD|NetBSD|OpenBSD)
        BSD_TMP=${TMPDIR:-/tmp}/ipv6-test-tmp.$$
        mkdir -p "$BSD_TMP/o/tmp"
        chgrp "$(id -g)" "$BSD_TMP" "$BSD_TMP/o" "$BSD_TMP/o/tmp" 2>/dev/null || true
        chmod g+s "$BSD_TMP" "$BSD_TMP/o" "$BSD_TMP/o/tmp" 2>/dev/null || true
        TMPDIR=$BSD_TMP
        export TMPDIR
        ;;
esac

# Pick the launcher.  macOS runs the APE polyglot directly.  NetBSD and
# OpenBSD shells refuse the embedded NUL, so they always need ape.elf.
# Elsewhere, keep direct execution if it works, otherwise fall back to
# the APE loader (as described in tool/cosmocc/README.md).
RUN=
case "$UNAME" in
    Darwin)
        RUN=
        ;;
    NetBSD|OpenBSD)
        RUN=./ape.elf
        ;;
    *)
        if ! ./redbean --version >/dev/null 2>&1 &&
           ! ./redbean -h >/dev/null 2>&1; then
            if ./ape.elf ./redbean --version >/dev/null 2>&1 ||
               ./ape.elf ./redbean -h >/dev/null 2>&1; then
                RUN=./ape.elf
            fi
        fi
        ;;
esac
echo "launcher: ${RUN:-direct}"

run_ape() {
    if [ -n "$RUN" ]; then
        "$RUN" "$@"
    else
        "$@"
    fi
}

# Like run_ape, but bounded by timeout(1) when it is available.
run_limited() {
    seconds=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        if [ -n "$RUN" ]; then
            timeout "$seconds" "$RUN" "$@"
        else
            timeout "$seconds" "$@"
        fi
    else
        if [ -n "$RUN" ]; then
            "$RUN" "$@"
        else
            "$@"
        fi
    fi
}

mkdir -p site
cat >site/ip.lua <<'LUA'
Write(FormatIp((GetRemoteAddr())).." host="..tostring(GetHost()).."\n")
LUA

# Never kill these servers: killing one redbean may take down the whole
# process group.  They are left running until this script exits.
run_ape ./redbean -D site -p 18801 -l ::1 -l 127.0.0.1 -L l1 </dev/null >l1.out 2>&1 &
run_ape ./redbean -D site -p 18803 -l 0.0.0.0 -l :: -L l3 </dev/null >l3.out 2>&1 &
run_ape ./redbean -D site -p 18804 -L l4 </dev/null >l4.out 2>&1 &

if [ "$UNAME" = "Linux" ] || [ "$UNAME" = "OpenBSD" ]; then
    run_ape ./redbean -D site -p 18805 -l ::1 -S -L l6 </dev/null >l6.out 2>&1 &
fi

sleep 2

cat >c.lua <<'LUA'
ProgramSslFetchVerify(false)

local function check(url, want)
    local status, headers, body = Fetch(url)
    assert(status == 200, url .. " status " .. tostring(status))
    assert(type(body) == "string", url .. " body " .. tostring(body))
    assert(body:sub(1, #want) == want, url .. " body " .. tostring(body))
end

check("http://[::1]:18801/ip.lua", "::1")
check("http://127.0.0.1:18803/ip.lua", "127.0.0.1")
check("http://[::1]:18803/ip.lua", "::1")
check("http://127.0.0.1:18804/ip.lua", "127.0.0.1")
check("https://[::1]:18801/ip.lua", "::1")
assert(Fetch("http://[::1]:18804/") == nil, "[::1]:18804 unexpectedly succeeded")
LUA

if [ "$UNAME" = "Linux" ] || [ "$UNAME" = "OpenBSD" ]; then
    cat >>c.lua <<'LUA'
check("http://[::1]:18805/ip.lua", "::1")
LUA
fi

if run_limited 120 ./redbean -i c.lua; then
    echo "ok fetch checks"
else
    fail "fetch checks"
fi

# Exercise a link-local address when lo0 has one.  The zone index is the
# hexadecimal scopeid reported by ifconfig, translated to decimal.
FE80_INDEX=
if ifconfig lo0 >ifconfig-lo0.txt 2>/dev/null; then
    if grep -q "fe80::1" ifconfig-lo0.txt; then
        FE80_HEX=$(sed -n 's/.*scopeid 0x\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' \
            ifconfig-lo0.txt | head -n 1)
        if [ -n "$FE80_HEX" ]; then
            FE80_INDEX=$((0x$FE80_HEX))
        fi
    fi
fi
if [ -n "$FE80_INDEX" ]; then
    run_ape ./redbean -D site -p 18806 -l "fe80::1%$FE80_INDEX" -L l5 \
        </dev/null >l5.out 2>&1 &
    sleep 1
    if grep -q "listen" l5 2>/dev/null; then
        echo "ok fe80::1%$FE80_INDEX listen"
    else
        fail "fe80::1%$FE80_INDEX did not listen"
    fi
else
    echo "skip: no fe80::1 with scopeid on lo0"
fi

for f in l1 l3 l4; do
    if [ -f "$f" ] && grep -q "SIGSEGV" "$f"; then
        fail "SIGSEGV in $f"
    fi
done

for t in tests/*_test; do
    [ -f "$t" ] || continue
    name=$(basename "$t")
    if run_limited 120 "$t" >"$name.log" 2>&1; then
        echo "ok $name"
    else
        status=$?
        # NetBSD and OpenBSD shells cannot re-exec an APE directly;
        # redbean_test does exactly that, so a failure caused by the shell
        # refusing the NUL byte is an expected failure on those platforms.
        if [ "$name" = "redbean_test" ] &&
           { [ "$UNAME" = "NetBSD" ] || [ "$UNAME" = "OpenBSD" ]; } &&
           grep -qF -e "nul ('\\0') in shell input" -e "NUL byte unexpected" "$name.log"; then
            echo "ok $name (expected failure on $UNAME: APE re-exec via /bin/sh)"
        else
            echo "ko $name ($status)"
            sed 's/^/  /' "$name.log"
            RC=1
        fi
    fi
done

for t in lua/*_test.lua; do
    [ -f "$t" ] || continue
    name=$(basename "$t")
    if run_limited 120 ./redbean -i "$t" >"$name.log" 2>&1; then
        echo "ok $name"
    else
        status=$?
        # NetBSD 9.5 st_blocks depends on the filesystem, not on our code.
        # Ipv6Test runs before UnixTest in this file, so its checks did run.
        if [ "$name" = "lunix_test.lua" ] && [ "$UNAME" = "NetBSD" ] &&
           grep -qF 'lunix_test.lua:123: assertion failed' "$name.log"; then
            echo "ok $name (expected failure on $UNAME: st_blocks filesystem dependent)"
        else
            echo "ko $name ($status)"
            sed 's/^/  /' "$name.log"
            RC=1
        fi
    fi
done

if [ "$RC" -eq 0 ]; then
    echo "PASS"
else
    echo "FAIL"
fi
exit "$RC"
