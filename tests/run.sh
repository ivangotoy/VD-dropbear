#!/bin/sh
# VD Dropbear module test suite: POSIX sh, no dependencies beyond a POSIX userland.
#   sh tests/run.sh
# Runs the real module scripts (common/vddropbear.sh, common/vddb-webui.sh, service.sh,
# action.sh, customize.sh, uninstall.sh) from a copy of module/ under $TMPDIR, against
# PATH stubs (getprop, pgrep, pkill), stub binaries in bin/x86_64 (vddropbear = a fake
# daemon script that records its argv/env, dropbearkey, toybox) and a fake root
# (VDDB_ROOT) holding data/adb, data/misc_ce/0 and dev. The repository tree is only read.
# Exit status is non-zero if any case fails.

REPO=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(mktemp -d "${TMPDIR:-/tmp}/vddb-tests.XXXXXX") || { echo "mktemp failed"; exit 1; }
PASS=0 FAIL=0 SKIP=0 FAILED=""

# --- fake process helpers ------------------------------------------------------
# pids of live fake daemons of this run (comm vddropbear, cmdline under $BASE)
fake_pids() {
    for _d in /proc/[0-9]*; do
        [ "$(cat "$_d/comm" 2>/dev/null)" = vddropbear ] || continue
        tr '\0' ' ' < "$_d/cmdline" 2>/dev/null | grep -qF "$BASE" || continue
        echo "${_d#/proc/}"
    done | sort -n
}
kill_fakes() { for _p in $(fake_pids); do kill -9 "$_p" 2>/dev/null; done; }
cleanup() { kill_fakes; rm -rf "$BASE"; }
trap cleanup EXIT
trap 'exit 1' INT TERM

# wait_for <shell condition>: poll up to ~5 s
wait_for() {
    _n=0
    while [ "$_n" -lt 50 ]; do
        eval "$1" && return 0
        sleep 0.1; _n=$((_n + 1))
    done
    return 1
}

# --- per-case setup ------------------------------------------------------------
setup() {
    W=$(mktemp -d "$BASE/case.XXXXXX")
    MOD=$W/mod ROOT=$W/root STUB=$W/stub FAKE=$W/fake
    mkdir -p "$MOD" "$ROOT/data/adb" "$ROOT/data/misc_ce/0" "$ROOT/dev" "$STUB" "$FAKE"
    # module copy as shipped by the fork build: no vdlu/, no webroot/vdlu.*, own stub binaries
    (cd "$REPO/module" && tar -cf - --exclude=./bin --exclude=./vdlu --exclude=./webroot/vdlu.js \
        --exclude=./webroot/vdlu.css .) | (cd "$MOD" && tar -xf -)
    mkdir -p "$MOD/bin/x86_64"
    B=$MOD/bin/x86_64
    printf 'ro.product.cpu.abi=x86_64\nsys.user.0.ce_available=true\n' > "$W/props"

    cat > "$STUB/getprop" <<EOF
#!/bin/sh
sed -n "s/^\$1=//p" "$W/props" | head -n1
EOF
    cat > "$STUB/pgrep" <<EOF
#!/bin/sh
[ "\$1" = -x ] && shift
for d in /proc/[0-9]*; do
    [ "\$(cat "\$d/comm" 2>/dev/null)" = "\$1" ] || continue
    tr '\\0' ' ' < "\$d/cmdline" 2>/dev/null | grep -qF "$BASE" || continue
    echo "\${d#/proc/}"
done | sort -n
EOF
    cat > "$STUB/pkill" <<EOF
#!/bin/sh
for p in \$("$STUB/pgrep" "\$@"); do kill "\$p" 2>/dev/null; done
EOF
    # fake daemon: records argv + env, spawns "\$sessions" session children (same comm, ppid = listener)
    cat > "$B/vddropbear" <<EOF
#!/bin/sh
if [ "\$1" = __session ]; then while :; do sleep 1; done; fi
for a in "\$@"; do printf '%s\n' "\$a"; done > "$FAKE/argv.\$\$"
env | grep -E '^(DROPBEAR_[A-Z_]*|HOME|PATH|SHELL|FOO|BAZ)=' > "$FAKE/env.\$\$"
echo "\$\$" >> "$FAKE/started"
n=\$(cat "$FAKE/sessions" 2>/dev/null || echo 0); i=0
while [ "\$i" -lt "\$n" ]; do "\$0" __session & echo "\$!" >> "$FAKE/session-pids"; i=\$((i + 1)); done
while :; do sleep 1; done
EOF
    # dropbearkey: like the real one it refuses to overwrite an existing file
    cat > "$B/dropbearkey" <<EOF
#!/bin/sh
echo "\$*" >> "$FAKE/keygen.log"
case "\$1" in
  -t) [ -e "\$4" ] && { echo "file exists" >&2; exit 1; }
      printf 'FAKEKEY %s\n' "\$2" > "\$4"; chmod 600 "\$4" ;;
  -y) echo "Public key portion is:"; echo "ssh-ed25519 AAAAexample"; echo "Fingerprint: sha256:FAKEFP" ;;
esac
EOF
    cat > "$B/toybox" <<'EOF'
#!/bin/sh
c=$1; shift
case "$c" in setsid|sleep) [ "$c" = sleep ] && exec sleep "$@"; exec "$@" ;; *) exit 1 ;; esac
EOF
    for t in scp rsync sftp-server; do printf '#!/bin/sh\n' > "$B/$t"; done
    chmod 755 "$STUB"/* "$B"/*
    mkdir -p "$ROOT/data/adb/vddropbear/state"   # as customize.sh leaves it
    PATH="$STUB:$PATH" VDDB_ROOT=$ROOT
    export PATH VDDB_ROOT
    DATA=$ROOT/data/adb/vddropbear CE=$ROOT/data/misc_ce/0/vddropbear/secret DE=$DATA/secret
    WEBUI="$MOD/common/vddb-webui.sh"
}
teardown() { kill_fakes; }

# helpers on the fake root
cfg() { mkdir -p "$DATA"; printf '%s\n' "$@" > "$DATA/config"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
webui() { sh "$WEBUI" "$@"; }
webui_in() { _v=$1; shift; b64 "$_v" | sh "$WEBUI" "$@"; }
listener() { cat "$FAKE/started" 2>/dev/null | tail -n1; }
last_argv() { cat "$FAKE/argv.$(listener)" 2>/dev/null; }
alive() { [ -n "$1" ] && fake_pids | grep -qx "$1"; }
mode_of() { ls -ld "$1" | cut -c1-10; }
# build_args in a subshell with the library sourced and the given config
args_for() { cfg "$@"; (MODDIR=$MOD; . "$MOD/common/vddropbear.sh"; vddb_load_config; vddb_build_args | tr '\n' ' '); }

fail() { echo "    $*"; return 1; }
expect_eq() { [ "$1" = "$2" ] || fail "expected [$2] got [$1]"; }
expect_has() { case "$1" in *"$2"*) return 0 ;; esac; fail "missing [$2]"; }
expect_not() { case "$1" in *"$2"*) fail "unexpected [$2] in [$1]" ;; esac; return 0; }

run_case() {
    _name=$1
    if ( setup; set +e; "$_name"; _rc=$?; teardown; exit $_rc ); then
        PASS=$((PASS + 1)); echo "PASS $_name"
    else
        _rc=$?
        if [ "$_rc" = 77 ]; then SKIP=$((SKIP + 1)); echo "SKIP $_name"
        else FAIL=$((FAIL + 1)); FAILED="$FAILED $_name"; echo "FAIL $_name"; fi
    fi
}

# --- cases: argv / config ------------------------------------------------------
t_args_default() {
    mkdir -p "$DATA"; cp "$MOD/common/config.default" "$DATA/config"
    a=$(MODDIR=$MOD; . "$MOD/common/vddropbear.sh"; vddb_load_config; vddb_build_args | tr '\n' ' ')
    expect_eq "$a" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2222 -p [::1]:2222 -F -P /dev/null -e -s -T 3 -j -k "
}
t_args_binds() {
    a=$(args_for LISTEN_ALL=1)
    expect_has "$a" "-p 0.0.0.0:2222 -p [::]:2222 " || return 1
    a=$(args_for LISTEN_LOOPBACK=1 LISTEN_IPV6=0 PORT=2299)
    expect_has "$a" "-p 127.0.0.1:2299 -F" || return 1
    a=$(args_for LISTEN_LOOPBACK=0 'LISTEN_ADDRESSES=192.0.2.5,192.0.2.6:2200,fe80::1,[2001:db8::1],[2001:db8::2]:22')
    expect_has "$a" "-p 192.0.2.5:2222 -p 192.0.2.6:2200 -p [fe80::1]:2222 -p [2001:db8::1]:2222 -p [2001:db8::2]:22 -F" || return 1
    a=$(args_for LISTEN_LOOPBACK=0 LISTEN_ALL=0)
    expect_has "$a" "-p 127.0.0.1:2222 -F" || return 1
    a=$(args_for PASSWORD_AUTH=1 ALLOW_LOCAL_FORWARD=1 ALLOW_REMOTE_FORWARD=1 GATEWAY_PORTS=1 IDLE_TIMEOUT=60 KEEPALIVE=30 RECEIVE_WINDOW=65536 PASS_ENV=0)
    expect_eq "$a" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2222 -p [::1]:2222 -F -P /dev/null -T 3 -a -I 60 -K 30 -W 65536 "
}
t_config_normalise() {
    a=$(args_for PORT=abc HOSTKEY_TYPE=dsa "RECEIVE_WINDOW='1;x'" MAX_AUTH_TRIES=x)
    expect_eq "$a" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2222 -p [::1]:2222 -F -P /dev/null -e -s -j -k "
}
t_config_bfu_store() {
    a=$(args_for START_IN_BFU=1 HOSTKEY_TYPE=ecdsa)
    expect_has "$a" "-r $DE/hostkey_ecdsa "
}

# --- cases: WebUI backend --------------------------------------------------------
t_webui_config_roundtrip() {
    evil="x'; touch $W/pwned; echo '"
    out=$(webui_in "$(printf 'PORT=2299\nIDENT_STRING=%s\nNOT_A_KEY=1\nLISTEN_ADDRESSES=192.0.2.5' "$evil")" set-config)
    expect_eq "$out" ok || return 1
    [ ! -e "$W/pwned" ] || fail "config value executed" || return 1
    grep -q NOT_A_KEY "$DATA/config" && { fail "non-whitelisted key written"; return 1; }
    expect_eq "$(mode_of "$DATA/config")" "-rw-------" || return 1
    got=$(webui get-config | grep '^IDENT_STRING' | cut -f2 | base64 -d)
    [ ! -e "$W/pwned" ] || fail "config value executed on load" || return 1
    expect_eq "$got" "$evil" || return 1
    got=$(webui get-config | grep '^PORT' | cut -f2 | base64 -d)
    expect_eq "$got" 2299
}
t_webui_config_rejects_empty() {
    cfg PORT=2299
    out=$(webui_in "garbage" set-config); rc=$?
    expect_eq "$out" "err: no valid keys" || return 1
    [ "$rc" != 0 ] || fail "exit 0 on error" || return 1
    expect_eq "$(cat "$DATA/config")" PORT=2299
}
t_webui_keys() {
    k1="ssh-ed25519 AAAAexample1 one@example"
    k2="ssh-rsa AAAAexample2 two@example"
    expect_eq "$(webui_in "$k1" add-key)" ok || return 1
    expect_eq "$(webui_in "$k2" add-key)" ok || return 1
    expect_eq "$(webui_in "$k1" add-key)" ok || return 1
    expect_eq "$(grep -c . "$CE/authorized_keys")" 2 || return 1
    out=$(webui_in "not a key" add-key); rc=$?
    expect_eq "$out" "err: not a public key" || return 1
    [ "$rc" != 0 ] || fail "exit 0 on error" || return 1
    expect_eq "$(webui_in "$(printf '%s\nssh-ed25519 AAAAinjected x' "ssh-ed25519 AAAAexample3 three@example")" add-key)" ok || return 1
    grep -q AAAAinjected "$CE/authorized_keys" && { fail "second line accepted"; return 1; }
    expect_eq "$(mode_of "$CE/authorized_keys")" "-rw-------" || return 1
    expect_eq "$(mode_of "$CE")" "drwx------" || return 1
    l=$(webui list-keys)
    expect_eq "$(printf '%s\n' "$l" | sed -n 2p | cut -f2 | base64 -d)" "$k2" || return 1
    expect_eq "$(webui del-key 1)" ok || return 1
    expect_eq "$(head -n1 "$CE/authorized_keys")" "$k2" || return 1
    out=$(webui del-key 'x;y'); expect_eq "$out" "err: bad index"
}
t_webui_passwords() {
    spec='pbkdf2-sha256$600000$00112233445566778899aabbccddeeff$0011223344556677889900112233445566778899001122334455667788990011'
    expect_eq "$(webui_in "$spec" set-pw root)" ok || return 1
    expect_eq "$(webui_in "$spec" set-pw shell)" ok || return 1
    expect_eq "$(webui_in "$spec" set-pw root)" ok || return 1
    expect_eq "$(grep -c '^root:' "$CE/passwd")" 1 || return 1
    expect_eq "$(mode_of "$CE/passwd")" "-rw-------" || return 1
    out=$(webui_in "$(printf 'pbkdf2-sha256$1$aa$bb\nevil:pbkdf2-sha256$1$aa$bb')" set-pw root)
    expect_eq "$out" "err: bad hash spec" || return 1
    expect_eq "$(webui_in "$spec" set-pw 'a;b')" "err: bad user" || return 1
    l=$(webui list-pw | while read -r u; do printf '%s' "$u" | base64 -d; echo; done | tr '\n' ' ')
    expect_eq "$l" "shell root " || return 1
    expect_eq "$(webui del-pw shell)" ok || return 1
    expect_eq "$(cut -d: -f1 "$CE/passwd")" root
}
t_webui_status() {
    cfg PORT=2299
    s=$(webui status)
    expect_has "$s" "running=0" || return 1
    expect_has "$s" "port=2299" || return 1
    expect_has "$s" "mode=AFU" || return 1
    expect_has "$s" "abi=x86_64" || return 1
    expect_has "$s" "secret_dir=$CE" || return 1
    printf '%s\n' "$s" | grep -qx 'hostkey_fp=' || fail "hostkey_fp not empty" || return 1
    out=$(webui bogus); rc=$?
    expect_eq "$out" "err: unknown verb: bogus" || return 1
    [ "$rc" != 0 ] || fail "exit 0 on unknown verb"
}

# --- cases: lifecycle ----------------------------------------------------------
t_action_start() {
    cfg PORT=2299 "EXTRA_ENV='FOO=bar;BAZ=q x'" HIDE_IDENT=1
    out=$(sh "$MOD/action.sh")
    expect_has "$out" "OK, running" || return 1
    wait_for '[ -s "$FAKE/started" ]' || { fail "daemon never started"; return 1; }
    p=$(listener)
    expect_has "$out" "pid    : $p" || return 1
    expect_has "$(last_argv | tr '\n' ' ')" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2299" || return 1
    expect_eq "$(mode_of "$CE/hostkey_ed25519")" "-rw-------" || return 1
    expect_eq "$(mode_of "$CE")" "drwx------" || return 1
    wait_for '[ -s "$FAKE/env.$p" ]' || return 1
    e=$(cat "$FAKE/env.$p")
    expect_has "$e" "DROPBEAR_AUTHKEYS=$ROOT/dev/vddropbear/authorized_keys" || return 1
    expect_has "$e" "DROPBEAR_PASSWD_FILE=$CE/passwd" || return 1
    expect_has "$e" "DROPBEAR_IDENT=SSH-2.0-" || return 1
    expect_has "$e" "FOO=bar" || return 1
    expect_has "$e" "BAZ=q x" || return 1
    expect_eq "$(readlink "$ROOT/dev/vddropbear/authorized_keys")" "$CE/authorized_keys" || return 1
    expect_eq "$(mode_of "$ROOT/dev/vddropbear")" "drwx------" || return 1
    [ -L "$DATA/bin/scp" ] || fail "tools not linked"
}
t_action_restart_single_instance() {
    cfg PORT=2299
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ -n "$(listener)" ]' || return 1
    p1=$(listener)
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ "$(listener)" != "$p1" ]' || { fail "no new daemon"; return 1; }
    wait_for '! alive "$p1"' || { fail "old daemon still alive"; return 1; }
    expect_eq "$(fake_pids | wc -l | tr -d ' ')" 1
}
# F2: start/stop/restart re-run the backend for status; the shipped file is not executable (0644)
t_webui_lifecycle_verbs() {
    cfg PORT=2299
    expect_eq "$(mode_of "$WEBUI")" "-rw-r--r--" || return 1
    s=$(webui start); rc=$?
    expect_eq "$rc" 0 || return 1
    expect_has "$s" "port=2299" || return 1
    wait_for '[ -n "$(listener)" ]' || { fail "start did not spawn"; return 1; }
    s=$(webui restart); expect_has "$s" "port=2299" || return 1
    s=$(webui stop); rc=$?
    expect_eq "$rc" 0 || return 1
    expect_has "$s" "running=0"
}
# F1: a restart replaces the listener only; open sessions (children with the same
# process name) survive it, status reports the listener, and WebUI Stop ends both.
t_restart_keeps_sessions() {
    cfg PORT=2299
    echo 1 > "$FAKE/sessions"
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ -s "$FAKE/session-pids" ]' || { fail "no session spawned"; return 1; }
    l1=$(listener); s1=$(cat "$FAKE/session-pids")
    echo 0 > "$FAKE/sessions"
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ "$(listener)" != "$l1" ]' || { fail "no new listener"; return 1; }
    l2=$(listener)
    wait_for '! alive "$l1"' || { fail "old listener alive"; return 1; }
    alive "$s1" || { fail "restart killed the open session"; return 1; }
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ "$(listener)" != "$l2" ]' || { fail "no third listener"; return 1; }
    l3=$(listener)
    wait_for '! alive "$l2"' || { fail "second restart missed the listener"; return 1; }
    alive "$s1" || { fail "second restart killed the open session"; return 1; }
    expect_has "$(webui status)" "pid=$l3
" || return 1
    s=$(webui stop)
    expect_has "$s" "running=0" || return 1
    wait_for '[ -z "$(fake_pids)" ]' || fail "stop left processes"
}
# F1: a stale pid record (daemon died at bind, pid reused by another process) is ignored
t_stale_pidfile() {
    cfg PORT=2299
    sleep 30 & other=$!
    echo "$other" > "$DATA/state/daemon.pid"
    expect_has "$(webui status)" "running=0" || { kill "$other"; return 1; }
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ -n "$(listener)" ]' || { kill "$other"; fail "no start"; return 1; }
    kill -0 "$other" 2>/dev/null || { fail "stop killed an unrelated process"; return 1; }
    kill "$other"
    expect_eq "$(cat "$DATA/state/daemon.pid")" "$(listener)"
}
t_disabled_not_started() {
    cfg ENABLED=0
    out=$(sh "$MOD/action.sh")
    expect_has "$out" "FAILED" || return 1
    [ ! -s "$FAKE/started" ] || fail "started while disabled"
}
t_service_afu_bfu() {
    sh "$MOD/service.sh"
    expect_eq "$(sed -n 's/^PORT=//p' "$DATA/config")" 2222 || return 1
    wait_for '[ -n "$(listener)" ]' || { fail "AFU start missing"; return 1; }
    expect_has "$(last_argv | tr '\n' ' ')" "-r $CE/hostkey_ed25519" || return 1
    kill_fakes; rm -f "$FAKE/started"
    cfg START_IN_BFU=1
    printf 'ro.product.cpu.abi=x86_64\nsys.user.0.ce_available=false\n' > "$W/props"
    sh "$MOD/service.sh"
    wait_for '[ -n "$(listener)" ]' || { fail "BFU start missing"; return 1; }
    expect_has "$(last_argv | tr '\n' ' ')" "-r $DE/hostkey_ed25519"
}
t_service_disabled() {
    cfg ENABLED=0
    sh "$MOD/service.sh"
    sleep 0.3
    [ ! -s "$FAKE/started" ] || fail "started while disabled"
}
t_customize() {
    out=$(MODPATH=$MOD; ui_print() { echo "$1"; }; grep_prop() { sed -n "s/^$1=//p" "$2"; }
          set_perm() { :; }; set_perm_recursive() { :; }; . "$MOD/customize.sh")
    expect_has "$out" "Default config written" || return 1
    cmp -s "$DATA/config" "$MOD/common/config.default" || fail "config not seeded" || return 1
    expect_eq "$(mode_of "$DATA")" "drwx------" || return 1
    cfg PORT=2299
    out=$(MODPATH=$MOD; ui_print() { echo "$1"; }; grep_prop() { sed -n "s/^$1=//p" "$2"; }
          set_perm() { :; }; set_perm_recursive() { :; }; . "$MOD/customize.sh")
    expect_has "$out" "Existing config kept" || return 1
    expect_eq "$(cat "$DATA/config")" PORT=2299
}
t_uninstall() {
    cfg PORT=2299
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ -n "$(listener)" ]' || return 1
    sh "$MOD/uninstall.sh"; rc=$?
    expect_eq "$rc" 0 || return 1
    wait_for '[ -z "$(fake_pids)" ]' || { fail "daemon survived uninstall"; return 1; }
    [ ! -e "$ROOT/dev/vddropbear" ] || fail "shim left behind" || return 1
    [ -f "$DATA/config" ] || fail "config removed"
}

CASES="t_args_default t_args_binds t_config_normalise t_config_bfu_store
t_webui_config_roundtrip t_webui_config_rejects_empty t_webui_keys t_webui_passwords t_webui_status
t_action_start t_action_restart_single_instance t_webui_lifecycle_verbs t_restart_keeps_sessions t_stale_pidfile t_disabled_not_started t_service_afu_bfu
t_service_disabled t_customize t_uninstall"

for c in $CASES; do run_case "$c"; done
echo "summary: pass=$PASS fail=$FAIL skip=$SKIP${FAILED:+ failed:$FAILED}"
[ "$FAIL" = 0 ]
