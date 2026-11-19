#!/bin/sh
# VD Dropbear module test suite: POSIX sh, no dependencies beyond a POSIX userland
# (t_webui_args_quoted also runs the WebUI page JS with node and is skipped without it).
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
# one listener per "port": an atomic lock dir owned by a live listener, like a bind
while ! mkdir "$FAKE/port" 2>/dev/null; do
    o=\$(cat "$FAKE/port/owner" 2>/dev/null)
    if [ -n "\$o" ] && [ "\$(cat /proc/\$o/comm 2>/dev/null)" = vddropbear ]; then
        echo "\$\$" >> "$FAKE/bind-failed"; exit 1
    fi
    [ -n "\$o" ] || { sleep 0.05; [ -n "\$(cat "$FAKE/port/owner" 2>/dev/null)" ] && continue; }
    rm -rf "$FAKE/port"
done
echo "\$\$" > "$FAKE/port/owner"
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
    # toybox: setsid waits "$FAKE/setsid-delay" seconds first when that file exists (a slow launcher)
    cat > "$B/toybox" <<EOF
#!/bin/sh
c=\$1; shift
case "\$c" in
  sleep) exec sleep "\$@" ;;
  setsid) [ -s "$FAKE/setsid-delay" ] && sleep "\$(cat "$FAKE/setsid-delay")"; exec "\$@" ;;
  *) exit 1 ;;
esac
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
expect_not() { case "$1" in *"$2"*) fail "unexpected [$2]"; return 1 ;; esac; return 0; }

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
# F9: an out-of-range PORT is refused at save time instead of failing at bind
t_webui_port_range() {
    cfg PORT=2299
    for v in 0 65536 70000 99999999999999999999 22x; do
        out=$(webui_in "$(printf 'PORT=%s\nLISTEN_ALL=0' "$v")" set-config 2>/dev/null); rc=$?
        expect_eq "$out" "err: bad PORT" || { fail "PORT=$v accepted"; return 1; }
        [ "$rc" != 0 ] || { fail "exit 0 for PORT=$v"; return 1; }
    done
    expect_eq "$(cat "$DATA/config")" PORT=2299 || return 1
    expect_eq "$(webui_in "$(printf 'PORT=65535\nLISTEN_ALL=0')" set-config)" ok || return 1
    expect_eq "$(webui_in "$(printf 'PORT=\nLISTEN_ALL=0')" set-config)" ok
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
# F3: a hand-edited file whose last line has no trailing newline
t_webui_unterminated_last_line() {
    mkdir -p "$CE"; chmod 700 "$CE"
    printf 'ssh-ed25519 AAAAexample1 one@example\nssh-ed25519 AAAAexample2 two@example' > "$CE/authorized_keys"
    expect_eq "$(webui list-keys | wc -l | tr -d ' ')" 2 || return 1
    expect_eq "$(webui_in "ssh-rsa AAAAexample3 three@example" add-key)" ok || return 1
    expect_eq "$(sed -n 2p "$CE/authorized_keys")" "ssh-ed25519 AAAAexample2 two@example" || return 1
    expect_eq "$(sed -n 3p "$CE/authorized_keys")" "ssh-rsa AAAAexample3 three@example" || return 1
    printf 'ssh-ed25519 AAAAexample1 one@example\nssh-ed25519 AAAAexample2 two@example' > "$CE/authorized_keys"
    expect_eq "$(webui del-key 1)" ok || return 1
    expect_eq "$(cat "$CE/authorized_keys")" "ssh-ed25519 AAAAexample2 two@example" || return 1
    h='pbkdf2-sha256$600000$00112233$0011223344556677889900112233445566778899001122334455667788990011'
    printf 'root:%s\nshell:%s' "$h" "$h" > "$CE/passwd"
    expect_eq "$(webui list-pw | wc -l | tr -d ' ')" 2 || return 1
    expect_eq "$(webui_in "$h" set-pw system)" ok || return 1
    expect_eq "$(cut -d: -f1 "$CE/passwd" | tr '\n' ' ')" "root shell system " || return 1
    printf 'root:%s\nshell:%s' "$h" "$h" > "$CE/passwd"
    expect_eq "$(webui del-pw root)" ok || return 1
    expect_eq "$(cut -d: -f1 "$CE/passwd" | tr '\n' ' ')" "shell "
}
# F27: a WebUI argument reaches the backend as one literal word: a user name read back
# from a hand-edited passwd file is not run by the shell (page JS, needs node: else SKIP)
t_webui_args_quoted() {
    node -e "" >/dev/null 2>&1 || return 77
    printf 'const SH = process.argv[2]; let CMD = "";\nfunction exec(c) { CMD = c; return Promise.resolve({ errno: 0, stdout: "", stderr: "" }); }\n' > "$W/run.js"
    sed -n '/^function shq(/p; /^async function api(/,/^}/p; /^async function apiIn(/,/^}/p' "$MOD/webroot/index.html" >> "$W/run.js"
    printf 'const [verb, arg, inp] = process.argv.slice(3);\n(inp ? apiIn(verb, inp, arg) : api(verb, arg)).then(() => process.stdout.write(CMD));\n' >> "$W/run.js"
    printf '#!/bin/sh\ncat > "%s/stdin"; for a in "$@"; do printf "[%%s]" "$a"; done > "%s/args"\n' "$W" "$W" > "$W/backend"
    evil="x\$(touch $W/pwned)';touch $W/pwned2;'y"
    cmd=$(node "$W/run.js" "$W/backend" del-pw "$evil" </dev/null) || { fail "node run failed"; return 1; }
    sh -c "$cmd" </dev/null 2>/dev/null
    [ ! -e "$W/pwned" ] && [ ! -e "$W/pwned2" ] || { fail "argument run by the shell: $cmd"; return 1; }
    expect_eq "$(cat "$W/args" 2>/dev/null)" "[del-pw][$evil]" || return 1
    cmd=$(node "$W/run.js" "$W/backend" set-pw "$evil" QUJD </dev/null) || { fail "node run failed"; return 1; }
    sh -c "$cmd" 2>/dev/null
    [ ! -e "$W/pwned" ] && [ ! -e "$W/pwned2" ] || { fail "argument run by the shell: $cmd"; return 1; }
    expect_eq "$(cat "$W/args" 2>/dev/null)" "[set-pw][$evil]" || return 1
    expect_eq "$(cat "$W/stdin")" QUJD
}
# F4: a failed rewrite reports an error, keeps the old file and leaves no temp file
t_webui_write_failure() {
    [ "$(id -u)" = 0 ] && return 77
    h='pbkdf2-sha256$600000$00112233$0011223344556677889900112233445566778899001122334455667788990011'
    expect_eq "$(webui_in "ssh-ed25519 AAAAexample1 one@example" add-key)" ok || return 1
    expect_eq "$(webui_in "$h" set-pw root)" ok || return 1
    k=$(cat "$CE/authorized_keys"); p=$(cat "$CE/passwd")
    chmod 500 "$CE"
    for v in "del-key 1" "del-pw root"; do
        out=$(webui_in "$h" $v 2>/dev/null); rc=$?
        expect_has "$out" "err: " || { chmod 700 "$CE"; return 1; }
        [ "$rc" != 0 ] || { chmod 700 "$CE"; fail "$v: exit 0 on error"; return 1; }
    done
    chmod 700 "$CE"
    # set-pw re-asserts the dir mode itself; make the current file unreadable instead
    chmod 000 "$CE/passwd"
    out=$(webui_in "$h" set-pw shell 2>/dev/null); rc=$?
    chmod 600 "$CE/passwd"
    expect_has "$out" "err: " || return 1
    [ "$rc" != 0 ] || { fail "set-pw: exit 0 on error"; return 1; }
    expect_eq "$(cat "$CE/authorized_keys")" "$k" || return 1
    expect_eq "$(cat "$CE/passwd")" "$p" || return 1
    expect_eq "$(ls "$CE" | grep -c tmp)" 0 || return 1
    chmod 500 "$DATA"
    out=$(webui_in "PORT=2299" set-config 2>"$W/err"); rc=$?
    chmod 700 "$DATA"
    expect_has "$out" "err: " || return 1
    [ "$rc" != 0 ] || { fail "set-config: exit 0 on error"; return 1; }
    expect_eq "$(cat "$W/err")" ""
}
# F5: switching START_IN_BFU in the WebUI moves the secrets to the other store,
# never overwrites a secret already there, and a plain start moves nothing
t_bfu_toggle_moves_secrets() {
    h='pbkdf2-sha256$600000$00112233$0011223344556677889900112233445566778899001122334455667788990011'
    expect_eq "$(webui_in "ssh-ed25519 AAAAexample1 one@example" add-key)" ok || return 1
    expect_eq "$(webui_in "$h" set-pw root)" ok || return 1
    printf 'FAKEKEY ed25519\n' > "$CE/hostkey_ed25519"; chmod 600 "$CE/hostkey_ed25519"
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config)" ok || return 1
    for f in authorized_keys passwd hostkey_ed25519; do
        [ -f "$DE/$f" ] || { fail "$f not moved to DE"; return 1; }
        [ ! -e "$CE/$f" ] || { fail "$f left in CE"; return 1; }
        expect_eq "$(mode_of "$DE/$f")" "-rw-------" || return 1
    done
    expect_eq "$(mode_of "$DE")" "drwx------" || return 1
    expect_eq "$(webui list-keys | cut -f2 | base64 -d)" "ssh-ed25519 AAAAexample1 one@example" || return 1
    # a key already in the target store wins; the other copy stays where it was
    mkdir -p "$CE"; printf 'ssh-rsa AAAAexample2 two@example\n' > "$CE/authorized_keys"
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=0\nPORT=2299')" set-config)" ok || return 1
    expect_eq "$(cat "$CE/authorized_keys")" "ssh-rsa AAAAexample2 two@example" || return 1
    expect_eq "$(cat "$DE/authorized_keys")" "ssh-ed25519 AAAAexample1 one@example" || return 1
    [ -f "$CE/passwd" ] && [ ! -e "$DE/passwd" ] || { fail "passwd not moved back"; return 1; }
    # same mode saved again, and a start: nothing moves
    printf 'ssh-ed25519 AAAAdormant x@example\n' > "$DE/authorized_keys"
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=0\nPORT=2299')" set-config)" ok || return 1
    sh "$MOD/action.sh" >/dev/null
    expect_eq "$(cat "$CE/authorized_keys")" "ssh-rsa AAAAexample2 two@example" || return 1
    [ -f "$DE/authorized_keys" ] || fail "dormant DE key touched"
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
# F7: an empty host key file (crash between create and write) is regenerated;
# dropbearkey (and the stub) refuse to overwrite an existing file
t_empty_hostkey_regenerated() {
    cfg PORT=2299
    mkdir -p "$CE"; : > "$CE/hostkey_ed25519"
    out=$(sh "$MOD/action.sh")
    expect_has "$out" "OK, running" || return 1
    [ -s "$CE/hostkey_ed25519" ] || fail "host key still empty"
}
# F8: the daemon log is rotated at start once it is over 1 MiB (one old copy kept)
t_log_rotated() {
    cfg PORT=2299
    dd if=/dev/zero of="$DATA/state/daemon.log" bs=1024 count=1100 2>/dev/null
    sh "$MOD/action.sh" >/dev/null
    [ -f "$DATA/state/daemon.log.1" ] || { fail "no rotated copy"; return 1; }
    n=$(wc -c < "$DATA/state/daemon.log")
    [ "$n" -lt 1048576 ] || { fail "log not rotated ($n bytes)"; return 1; }
    sh "$MOD/action.sh" >/dev/null
    [ "$(wc -c < "$DATA/state/daemon.log.1")" -ge 1126400 ] || fail "small log rotated over the old copy"
}
# F8b: the first start with no daemon.log yet must not print errors
t_start_without_log_quiet() {
    cfg PORT=2299
    mkdir -p "$CE"; printf 'FAKEKEY ed25519\n' > "$CE/hostkey_ed25519"
    rm -f "$DATA/state/daemon.log"
    err=$(sh "$MOD/action.sh" 2>&1 >/dev/null)
    expect_eq "$err" ""
}
# F10: EXTRA_ENV values are taken literally, not glob-expanded against the cwd
t_extra_env_no_glob() {
    cfg "EXTRA_ENV='FOO=*'"
    mkdir -p "$W/cwd"; : > "$W/cwd/FOO=expanded"
    (cd "$W/cwd" && sh "$MOD/action.sh" >/dev/null)
    wait_for '[ -s "$FAKE/env.$(listener)" ]' || { fail "no start"; return 1; }
    expect_has "$(cat "$FAKE/env.$(listener)")" "FOO=*"
}
# A restart run from an SSH session (daemon env passed on with -e) must not keep
# the old banner once HIDE_IDENT is off
t_ident_not_inherited() {
    cfg HIDE_IDENT=0
    DROPBEAR_IDENT=SSH-2.0-oldbanner sh "$MOD/action.sh" >/dev/null
    wait_for '[ -s "$FAKE/env.$(listener)" ]' || { fail "no start"; return 1; }
    expect_not "$(cat "$FAKE/env.$(listener)")" "DROPBEAR_IDENT"
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
# F1b: listener gone (killed, or a new daemon died at bind), its session orphaned:
# the orphan is not reported as the daemon and the next start does not signal it
t_orphaned_session_not_listener() {
    cfg PORT=2299
    echo 1 > "$FAKE/sessions"
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ -s "$FAKE/session-pids" ]' || { fail "no session spawned"; return 1; }
    l1=$(listener); s1=$(cat "$FAKE/session-pids")
    echo 0 > "$FAKE/sessions"
    kill -9 "$l1"
    wait_for '! alive "$l1"' || return 1
    expect_has "$(webui status)" "running=0" || return 1
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ "$(listener)" != "$l1" ]' || { fail "no new listener"; return 1; }
    sleep 0.5
    alive "$s1" || fail "start signalled the orphaned session"
}
# F1c: overlapping starts (double tap on Restart, boot start meeting Action)
# converge on one listener, and status names it
t_overlapping_starts() {
    cfg PORT=2299
    for r in 1 2 3 4 5; do
        sh "$MOD/action.sh" >/dev/null & a=$!
        sh "$MOD/action.sh" >/dev/null & b=$!
        wait "$a" "$b"
        sleep 0.3
        n=$(fake_pids | wc -l | tr -d ' ')
        [ "$n" = 1 ] || { fail "round $r: $n listeners"; return 1; }
        p=$(fake_pids)
        expect_has "$(webui status)" "pid=$p
" || { fail "round $r: status does not name the listener"; return 1; }
    done
    sh "$MOD/action.sh" >/dev/null
    sleep 0.3
    expect_eq "$(fake_pids | wc -l | tr -d ' ')" 1
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
# F29: Action and WebUI start report the daemon once the launcher has exec'd it, not
# the state right after the background spawn (slow launcher: record not written yet)
t_slow_start_reported() {
    cfg PORT=2299
    echo 0.5 > "$FAKE/setsid-delay"
    out=$(sh "$MOD/action.sh")
    expect_has "$out" "OK, running" || return 1
    wait_for '[ -n "$(listener)" ]' || { fail "daemon never started"; return 1; }
    p1=$(listener)
    expect_has "$out" "pid    : $p1
" || return 1
    s=$(webui start)
    expect_has "$s" "running=1" || return 1
    wait_for '[ "$(listener)" != "$p1" ]' || { fail "start did not replace the daemon"; return 1; }
    expect_has "$s" "pid=$(listener)
"
}
t_disabled_not_started() {
    cfg ENABLED=0
    out=$(sh "$MOD/action.sh")
    expect_has "$out" "FAILED" || return 1
    [ ! -s "$FAKE/started" ] || fail "started while disabled"
}
# Saving with Enabled off (WebUI Save & restart) stops the running daemon
t_disable_stops_running() {
    cfg PORT=2299
    sh "$MOD/action.sh" >/dev/null
    wait_for '[ -n "$(listener)" ]' || return 1
    l1=$(listener)
    expect_eq "$(webui_in "$(printf 'ENABLED=0\nPORT=2299')" set-config)" ok || return 1
    s=$(webui restart)
    expect_has "$s" "running=0" || return 1
    wait_for '! alive "$l1"' || fail "disabled daemon still running"
}
# F6: logging without a state dir (install not run yet) must not print errors
t_log_without_state_dir() {
    cfg ENABLED=0
    rm -rf "$DATA/state"
    err=$(sh "$MOD/action.sh" 2>&1 >/dev/null)
    expect_eq "$err" ""
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

# --- cases: build tooling (logic taken from the script text, nothing fetched) ---
# F12: scripts/build-bundles.sh fetch() must not reuse a partial download as a cached tarball
t_build_fetch_partial() {
    sed -n '/^fetch() {/,/^}/p' "$REPO/scripts/build-bundles.sh" > "$W/fetch.sh"
    [ -s "$W/fetch.sh" ] || { fail "fetch() not found"; return 1; }
    printf '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && o=$2; shift; done\nprintf partial > "$o"; exit 18\n' > "$STUB/curl"
    chmod 755 "$STUB/curl"
    ( . "$W/fetch.sh"; fetch https://example.invalid/a.tar.gz "$W/a.tar.gz" ) && { fail "failed download reported ok"; return 1; }
    printf '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && o=$2; shift; done\nprintf complete > "$o"\n' > "$STUB/curl"
    ( . "$W/fetch.sh"; fetch https://example.invalid/a.tar.gz "$W/a.tar.gz" ) || { fail "retry failed"; return 1; }
    expect_eq "$(cat "$W/a.tar.gz")" complete
}

CASES="t_args_default t_args_binds t_config_normalise t_config_bfu_store
t_webui_config_roundtrip t_webui_config_rejects_empty t_webui_port_range t_webui_keys t_webui_passwords t_webui_unterminated_last_line t_webui_args_quoted t_webui_write_failure t_bfu_toggle_moves_secrets t_webui_status
t_action_start t_empty_hostkey_regenerated t_log_rotated t_start_without_log_quiet t_extra_env_no_glob t_ident_not_inherited t_action_restart_single_instance t_webui_lifecycle_verbs t_restart_keeps_sessions t_orphaned_session_not_listener t_overlapping_starts t_stale_pidfile t_slow_start_reported t_disabled_not_started t_disable_stops_running t_log_without_state_dir t_service_afu_bfu
t_service_disabled t_customize t_uninstall t_build_fetch_partial"

for c in $CASES; do run_case "$c"; done
echo "summary: pass=$PASS fail=$FAIL skip=$SKIP${FAILED:+ failed:$FAILED}"
[ "$FAIL" = 0 ]
