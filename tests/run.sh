#!/bin/sh
# VD Dropbear module test suite: POSIX sh, no dependencies beyond a POSIX userland
# (cases that run the WebUI page JS need node; cases that run the fork's build and release code,
# workflow steps or the maintainer scripts need bash, python3, git, zip or unzip, as each case
# states; a case is reported as SKIP when a tool it needs is missing).
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
    # module copy without the VDLU updater (vdlu/, webroot/vdlu.* and, in a built tree, their .sha256
    # companions: own cases below, so service.sh starts no update run here), with its own stub binaries
    (cd "$REPO/module" && tar -cf - --exclude=./bin --exclude=./vdlu --exclude='./webroot/vdlu.*' .) | (cd "$MOD" && tar -xf -)
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
    expect_eq "$a" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2222 -p [::1]:2222 -F -P $DATA/state/vddropbear.pid -e -s -T 3 -j -k "
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
    expect_eq "$a" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2222 -p [::1]:2222 -F -P $DATA/state/vddropbear.pid -T 3 -a -I 60 -K 30 -W 65536 "
}
t_config_normalise() {
    a=$(args_for PORT=abc HOSTKEY_TYPE=dsa "RECEIVE_WINDOW='1;x'" MAX_AUTH_TRIES=x)
    expect_eq "$a" "-r $CE/hostkey_ed25519 -p 127.0.0.1:2222 -p [::1]:2222 -F -P $DATA/state/vddropbear.pid -e -s -j -k "
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
# F2: a key present only as a commented-out line is added again (it does not authenticate as a comment)
t_webui_add_key_commented() {
    k="ssh-ed25519 AAAAexample4 four@example"
    mkdir -p "$CE"; printf '# %s\n' "$k" > "$CE/authorized_keys"
    expect_eq "$(webui_in "$k" add-key)" ok || return 1
    expect_eq "$(grep -cxF "$k" "$CE/authorized_keys")" 1 || return 1
    expect_eq "$(webui list-keys | cut -f2 | base64 -d)" "$k" || return 1
    expect_eq "$(webui_in "$k" add-key)" ok || return 1
    expect_eq "$(grep -cxF "$k" "$CE/authorized_keys")" 1
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
    sed -n '/^const shq = /p; /^function apiErr(/,/r\.stdout; }$/p; /^async function api(/,/^}/p; /^async function apiIn(/,/^}/p' "$MOD/webroot/index.html" >> "$W/run.js"
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
# F37: a START_IN_BFU switch whose secrets cannot be moved answers an error and changes
# nothing: the config keeps the old mode and every secret stays in the old store, none
# half-moved (CE locked, target store not writable, one file not copyable)
t_bfu_move_failure_reported() {
    h='pbkdf2-sha256$600000$00112233$0011223344556677889900112233445566778899001122334455667788990011'
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=0\nPORT=2299')" set-config)" ok || return 1
    expect_eq "$(webui_in "ssh-ed25519 AAAAexample1 one@example" add-key)" ok || return 1
    expect_eq "$(webui_in "$h" set-pw root)" ok || return 1
    printf 'FAKEKEY ed25519\n' > "$CE/hostkey_ed25519"; chmod 600 "$CE/hostkey_ed25519"
    c=$(cat "$DATA/config")
    unchanged() {
        expect_eq "$(cat "$DATA/config")" "$c" || return 1
        for f in authorized_keys passwd hostkey_ed25519; do [ -f "$CE/$f" ] || { fail "$f gone from CE"; return 1; }; done
        [ -z "$(ls -A "$DE" 2>/dev/null)" ] || { fail "DE holds: $(ls -A "$DE")"; return 1; }
        [ -z "$(ls "$DATA" | grep config.new)" ] || fail "config temp left"
    }
    : > "$DE"
    out=$(webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config); rc=$?
    expect_eq "$out" "err: secrets not moved" || return 1
    [ "$rc" != 0 ] || { fail "exit 0 when the target store is not writable"; return 1; }
    rm -f "$DE"; unchanged || return 1
    printf 'ro.product.cpu.abi=x86_64\nsys.user.0.ce_available=false\n' > "$W/props"
    out=$(webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config); rc=$?
    expect_eq "$out" "err: secrets not moved" || return 1
    [ "$rc" != 0 ] || { fail "exit 0 with CE locked"; return 1; }
    unchanged || return 1
    printf 'ro.product.cpu.abi=x86_64\nsys.user.0.ce_available=true\n' > "$W/props"
    [ "$(id -u)" = 0 ] && return 0
    chmod 000 "$CE/passwd"
    out=$(webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config); rc=$?
    chmod 600 "$CE/passwd"
    expect_eq "$out" "err: secrets not moved" || return 1
    [ "$rc" != 0 ] || { fail "exit 0 when passwd cannot be copied"; return 1; }
    rmdir "$DE" 2>/dev/null; unchanged
}
# U3: a START_IN_BFU switch whose rename into the target store fails (the last file), or whose
# config install fails after the renames, answers an error and changes nothing: the config keeps
# its mode, every secret stays in the old store, the target store holds only what it held before.
# The source removal after a completed move is logged when it fails. mv and rm are PATH stubs
# that fail for one destination (FAIL_MV / FAIL_RM) and leave a marker, else run the real tool.
fail_stubs() {
    for _t in mv rm; do
        _r=$(command -v "$_t") || { fail "no $_t"; return 1; }
        _v=$(echo "FAIL_$_t" | tr a-z A-Z)
        printf '#!/bin/sh\nfor a; do l=$a; done\nif [ -n "$%s" ] && [ "$l" = "$%s" ]; then : > "%s/%s-failed"; exit 1; fi\nexec %s "$@"\n' \
            "$_v" "$_v" "$W" "$_t" "$_r" > "$STUB/$_t"
        chmod 755 "$STUB/$_t"
    done
}
t_bfu_rename_failure_reported() {
    h='pbkdf2-sha256$600000$00112233$0011223344556677889900112233445566778899001122334455667788990011'
    fail_stubs || return 1
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=0\nPORT=2299')" set-config)" ok || return 1
    expect_eq "$(webui_in "ssh-ed25519 AAAAexample1 one@example" add-key)" ok || return 1
    expect_eq "$(webui_in "$h" set-pw root)" ok || return 1
    printf 'FAKEKEY ed25519\n' > "$CE/hostkey_ed25519"; chmod 600 "$CE/hostkey_ed25519"
    mkdir -p "$DE"; chmod 700 "$DE"; printf 'KEPT ed25519\n' > "$DE/hostkey_ed25519"
    c=$(cat "$DATA/config")
    unchanged() {
        expect_eq "$(cat "$DATA/config")" "$c" || return 1
        for f in authorized_keys passwd hostkey_ed25519; do [ -f "$CE/$f" ] || { fail "$f gone from CE"; return 1; }; done
        expect_eq "$(ls -A "$DE" | tr '\n' ' ')" "hostkey_ed25519 " || return 1
        expect_eq "$(cat "$DE/hostkey_ed25519")" "KEPT ed25519" || return 1
        [ -z "$(ls "$DATA" | grep config.new)" ] || fail "config temp left"
    }
    out=$(FAIL_MV=$DE/passwd webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config); rc=$?
    [ -e "$W/mv-failed" ] || { fail "mv stub not reached"; return 1; }
    expect_eq "$out" "err: secrets not moved" || return 1
    [ "$rc" != 0 ] || { fail "exit 0 when a secret could not be renamed"; return 1; }
    unchanged || return 1
    rm -f "$W/mv-failed"
    out=$(FAIL_MV=$DATA/config webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config); rc=$?
    [ -e "$W/mv-failed" ] || { fail "mv stub not reached (config)"; return 1; }
    expect_eq "$out" "err: install failed" || return 1
    [ "$rc" != 0 ] || { fail "exit 0 when the config could not be installed"; return 1; }
    unchanged || return 1
    out=$(FAIL_RM=$CE/passwd webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config)
    [ -e "$W/rm-failed" ] || { fail "rm stub not reached"; return 1; }
    expect_eq "$out" ok || return 1
    expect_eq "$(cat "$DE/passwd")" "root:$h" || return 1
    grep -q "could not remove $CE/passwd" "$DATA/state/daemon.log" || fail "failed source removal not logged"
}
# A hostkey_* file whose name holds a space (a hand-made backup) never makes a switch delete
# another secret: the kept target host key survives a failed config install, and the host key
# left in the source store (its target existed) survives a completed switch.
t_bfu_move_odd_names() {
    fail_stubs || return 1
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=0\nPORT=2299')" set-config)" ok || return 1
    mkdir -p "$CE" "$DE"; chmod 700 "$CE" "$DE"
    printf 'FAKEKEY ce\n' > "$CE/hostkey_ed25519"; printf 'OLD ce\n' > "$CE/hostkey_ed25519 old"
    printf 'KEPT de\n' > "$DE/hostkey_ed25519"
    out=$(FAIL_MV=$DATA/config webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config)
    expect_eq "$out" "err: install failed" || return 1
    expect_eq "$(cat "$DE/hostkey_ed25519" 2>/dev/null)" "KEPT de" || { fail "kept target host key deleted"; return 1; }
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config)" ok || return 1
    expect_eq "$(cat "$DE/hostkey_ed25519" 2>/dev/null)" "KEPT de" || return 1
    expect_eq "$(cat "$CE/hostkey_ed25519" 2>/dev/null)" "FAKEKEY ce" || fail "host key left in the source store deleted"
}
# A START_IN_BFU switch with no secret to move yet (fresh install: the source store missing, or
# present and empty) answers ok and saves the new mode
t_bfu_switch_nothing_to_move() {
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=1\nPORT=2299')" set-config)" ok || return 1
    expect_has "$(cat "$DATA/config")" "START_IN_BFU='1'" || return 1
    mkdir -p "$DE"; chmod 700 "$DE"
    expect_eq "$(webui_in "$(printf 'START_IN_BFU=0\nPORT=2299')" set-config)" ok || return 1
    expect_has "$(cat "$DATA/config")" "START_IN_BFU='0'"
}
# R1: a stale temp left in the target store by a killed earlier switch whose pid is reused (here
# the current pid) is never renamed over a kept target file, and that file's source stays put
t_bfu_stale_temp_ignored() {
    mkdir -p "$CE" "$DE"; chmod 700 "$CE" "$DE"
    printf 'FAKEKEY ce\n' > "$CE/hostkey_ed25519"; printf 'ssh-ed25519 AAAAexample1 one@example\n' > "$CE/authorized_keys"
    printf 'KEPT de\n' > "$DE/hostkey_ed25519"
    out=$(MODDIR=$MOD sh -c '. "$MODDIR/common/vddropbear.sh"
        echo STALE > "$2/hostkey_ed25519.tmp.$$"
        vddb_stage_secrets "$1" "$2" && vddb_commit_secrets "$1" "$2" && vddb_drop_sources "$1" "$2" && echo done' _ "$CE" "$DE" 2>&1)
    expect_eq "$out" done || return 1
    expect_eq "$(cat "$DE/hostkey_ed25519")" "KEPT de" || { fail "stale temp renamed over the kept host key"; return 1; }
    expect_eq "$(cat "$CE/hostkey_ed25519" 2>/dev/null)" "FAKEKEY ce" || { fail "source of the kept host key dropped"; return 1; }
    [ -f "$DE/authorized_keys" ] && [ ! -e "$CE/authorized_keys" ] || fail "authorized_keys not moved"
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

# since v1.10 the page (apiErr) turns a non-zero exit into "err: command failed" and drops the
# reply: every data verb exits 0 on success, also when the last file line is a comment or blank
t_webui_verbs_exit_zero() {
    h='pbkdf2-sha256$600000$00112233$0011223344556677889900112233445566778899001122334455667788990011'
    rc_of() { "$@" >/dev/null 2>&1; echo $?; }
    expect_eq "$(rc_of webui_in "$(printf 'PORT=2299\nLISTEN_ALL=0')" set-config)" 0 || return 1
    expect_eq "$(rc_of webui_in "ssh-ed25519 AAAAexample1 one@example" add-key)" 0 || return 1
    expect_eq "$(rc_of webui_in "$h" set-pw root)" 0 || return 1
    printf '# a comment\n\n' >> "$CE/authorized_keys"; printf '# a comment\n' >> "$CE/passwd"
    for v in status get-config list-keys list-pw "del-key 1" "del-pw root"; do
        expect_eq "$(rc_of webui $v)" 0 || { fail "$v"; return 1; }
    done
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
# v1.13: a start from inside an app cgroup (manager Action/WebUI) moves the starting shell to the
# root cgroup before the fork, so the daemon is not frozen with the manager; elsewhere nothing is
# written; a move that fails is logged, prints nothing and still starts the daemon. The cgroup
# files sit under the fake root (VDDB_ROOT); the pid comes from the real /proc/self/stat.
t_freezer_escape() {
    cfg PORT=2299
    mkdir -p "$ROOT/sys/fs/cgroup" "$ROOT/proc/self"
    : > "$ROOT/sys/fs/cgroup/cgroup.procs"
    echo "0::/apps/uid_10001/pid_4242" > "$ROOT/proc/self/cgroup"
    sh "$MOD/action.sh" > "$W/out" 2>"$W/err" & a=$!
    wait "$a"
    expect_eq "$(cat "$ROOT/sys/fs/cgroup/cgroup.procs")" "$a" || return 1
    grep -q "moved pid $a from an app cgroup" "$DATA/state/daemon.log" || { fail "move not logged"; return 1; }
    expect_has "$(cat "$W/out")" "OK, running" || return 1
    : > "$ROOT/sys/fs/cgroup/cgroup.procs"
    echo "0::/" > "$ROOT/proc/self/cgroup"
    sh "$MOD/action.sh" >/dev/null
    expect_eq "$(cat "$ROOT/sys/fs/cgroup/cgroup.procs")" "" || return 1
    rm -f "$ROOT/sys/fs/cgroup/cgroup.procs"; mkdir "$ROOT/sys/fs/cgroup/cgroup.procs"
    echo "0::/apps/uid_10001/pid_4242" > "$ROOT/proc/self/cgroup"
    out=$(sh "$MOD/action.sh" 2>"$W/err")
    expect_has "$out" "OK, running" || return 1
    expect_eq "$(cat "$W/err")" "" || return 1
    grep -q "freezer escape failed: the daemon stays in /apps/uid_10001/pid_4242" "$DATA/state/daemon.log" || fail "failed move not logged"
}
# R2: inside an app cgroup whose cgroup.procs is not writable the escape fails loudly in the log
# (rc 1) and prints nothing
t_freezer_escape_not_writable() {
    [ "$(id -u)" = 0 ] && return 77
    mkdir -p "$ROOT/sys/fs/cgroup" "$ROOT/proc/self" "$DATA/state"
    : > "$ROOT/sys/fs/cgroup/cgroup.procs"; chmod 444 "$ROOT/sys/fs/cgroup/cgroup.procs"
    echo "0::/apps/uid_10001/pid_4242" > "$ROOT/proc/self/cgroup"
    out=$(MODDIR=$MOD sh -c '. "$MODDIR/common/vddropbear.sh"; vddb_escape_freezer; echo "rc=$?"' 2>&1)
    expect_eq "$out" "rc=1" || return 1
    grep -q "freezer escape failed: the daemon stays in /apps/uid_10001/pid_4242" "$DATA/state/daemon.log" || { fail "failed escape not logged"; return 1; }
    echo "0::/" > "$ROOT/proc/self/cgroup"; : > "$DATA/state/daemon.log"
    out=$(MODDIR=$MOD sh -c '. "$MODDIR/common/vddropbear.sh"; vddb_escape_freezer; echo "rc=$?"' 2>&1)
    expect_eq "$out" "rc=0" || return 1
    expect_eq "$(cat "$DATA/state/daemon.log")" ""
}
# U-cgroup: Android 12-14 (and later builds without app/system cgroup isolation) keep an app at
# /uid_<uid>/pid_<pid>, no /apps prefix: a start from there escapes too; the groups of uids below
# 10000 (init services, /system/uid_<n> system apps) are left alone
esc_out() { MODDIR=$MOD sh -c '. "$MODDIR/common/vddropbear.sh"; vddb_escape_freezer; echo "rc=$? pid=$$"' 2>&1; }
t_freezer_escape_uid_layout() {
    mkdir -p "$ROOT/sys/fs/cgroup" "$ROOT/proc/self" "$DATA/state"
    : > "$ROOT/sys/fs/cgroup/cgroup.procs"
    echo "0::/uid_10001/pid_4242" > "$ROOT/proc/self/cgroup"
    out=$(esc_out)
    expect_eq "rc=0 pid=$(cat "$ROOT/sys/fs/cgroup/cgroup.procs")" "$out" || return 1
    expect_has "$out" "rc=0 pid=" || return 1
    grep -q "moved pid ${out#rc=0 pid=} from an app cgroup" "$DATA/state/daemon.log" || { fail "move not logged"; return 1; }
    for _g in /uid_0/pid_77 /uid_1000/pid_77 /system/uid_1000/pid_77 /uid_x/pid_77; do
        : > "$ROOT/sys/fs/cgroup/cgroup.procs"; : > "$DATA/state/daemon.log"
        echo "0::$_g" > "$ROOT/proc/self/cgroup"
        out=$(esc_out)
        expect_has "$out" "rc=0" || return 1
        expect_eq "$(cat "$ROOT/sys/fs/cgroup/cgroup.procs")$(cat "$DATA/state/daemon.log")" "" || { fail "($_g) escaped"; return 1; }
    done
    [ "$(id -u)" = 0 ] && return 0
    : > "$ROOT/sys/fs/cgroup/cgroup.procs"; chmod 444 "$ROOT/sys/fs/cgroup/cgroup.procs"
    echo "0::/uid_10001/pid_4242" > "$ROOT/proc/self/cgroup"
    out=$(esc_out)
    expect_has "$out" "rc=1" || return 1
    grep -q "freezer escape failed: the daemon stays in /uid_10001/pid_4242" "$DATA/state/daemon.log" || fail "failed escape not logged"
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
# the flash-time integrity gate customize.sh sources (.vd/sha256-gate.sh), with companions made by
# upstream's .github/scripts/gen-sha256.sh, under the shell running this suite: a good tree
# passes, a changed file and a companion without its file abort the flash
gate_out() { (MODPATH=$1; . "$1/.vd/sha256-gate.sh") 2>&1; }
t_sha256_gate() {
    sh "$REPO/.github/scripts/gen-sha256.sh" "$MOD" > /dev/null || { fail "gen-sha256 failed"; return 1; }
    out=$(gate_out "$MOD"); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    expect_has "$out" "integrity verified" || return 1
    cp "$MOD/common/vddropbear.sh" "$W/lib.sh"
    echo "# changed" >> "$MOD/common/vddropbear.sh"
    out=$(gate_out "$MOD"); rc=$?
    [ "$rc" != 0 ] || { fail "changed file passed the gate"; return 1; }
    expect_has "$out" "sha256 mismatch: common/vddropbear.sh.sha256" || return 1
    cp "$W/lib.sh" "$MOD/common/vddropbear.sh"; rm "$MOD/action.sh"
    out=$(gate_out "$MOD"); rc=$?
    [ "$rc" != 0 ] || { fail "companion without its file passed the gate"; return 1; }
    expect_has "$out" "sha256 mismatch: action.sh.sha256"
}

# F5: a file sha256sum fails on stops gen-sha256 with a non-zero status (it used to count only
# the last file of each find batch, leaving an empty companion and exit 0). The stub fails on its
# first call only, so the result does not depend on the order find lists the files in.
t_gen_sha256_failure() {
    _real=$(command -v sha256sum) || return 77
    mkdir -p "$W/p"; for _f in a b c d; do echo "$_f" > "$W/p/$_f"; done
    cat > "$STUB/sha256sum" <<EOF
#!/bin/sh
[ -e "$W/failed-once" ] || { : > "$W/failed-once"; echo "sha256sum: read error" >&2; exit 1; }
exec "$_real" "\$@"
EOF
    chmod 755 "$STUB/sha256sum"
    sh "$REPO/.github/scripts/gen-sha256.sh" "$W/p" > "$W/out" 2>&1; rc=$?
    [ -e "$W/failed-once" ] || { fail "stub not called"; return 1; }
    [ "$rc" != 0 ] || fail "a failed hash exited 0: $(tr '\n' ' ' < "$W/out")"
}
# build_zip <outdir> [touch -t stamp]: the real build() from .forgejo/module-ci.conf, run by bash as
# module-ci.sh build-user runs it (forge https://forge.invalid, repo example/VD-dropbear), on a tar
# copy of the files it reads (all given that mtime when a stamp is passed); the zip lands in
# <outdir>/module.zip
build_zip() {
    rm -rf "$W/src"; mkdir -p "$W/src" "$1"
    (cd "$REPO" && tar -cf - module LICENSE NOTICE THIRD-PARTY-NOTICES.md .forgejo/module-ci.conf .forgejo/vdlu \
        .github/scripts/gen-sha256.sh) | (cd "$W/src" && tar -xf -)
    [ -z "${2:-}" ] || find "$W/src" -exec touch -t "$2" {} +
    (cd "$W/src" && OUT=$1 SERVER_URL=https://forge.invalid REPOSITORY=example/VD-dropbear bash -c '. .forgejo/module-ci.conf; build') > "$W/build.log" 2>&1 \
        || { fail "build(): $(tail -n 2 "$W/build.log" | tr '\n' ' ')"; return 1; }
}
# F36: the fork zip carries a .sha256 companion for every file and none without its file, so
# the flash-time gate checks the real payload. Needs bash, python3, zip, unzip (else SKIP).
t_build_zip_sha256() {
    for _t in bash python3 zip unzip; do command -v "$_t" >/dev/null 2>&1 || return 77; done
    build_zip "$W/out" || return 1
    mkdir -p "$W/flash"; (cd "$W/flash" && unzip -q "$W/out/module.zip") || { fail "unzip failed"; return 1; }
    (cd "$W/flash" && find . -type f | sed 's|^\./||') > "$W/files"
    grep -v '\.sha256$' "$W/files" | sed 's/$/.sha256/' | sort > "$W/want"
    grep '\.sha256$' "$W/files" | sort > "$W/have"
    [ -s "$W/want" ] || { fail "empty zip"; return 1; }
    expect_eq "$(cat "$W/have")" "$(cat "$W/want")" || return 1
    out=$(gate_out "$W/flash"); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    expect_has "$out" "integrity verified" || return 1
    echo "# changed" >> "$W/flash/common/vddropbear.sh"
    out=$(gate_out "$W/flash"); rc=$?
    [ "$rc" != 0 ] || fail "changed file passed the gate"
}
# U-zip: two builds of the same files give the same zip bytes, whatever the files' mtimes, the
# time of the build or its time zone. Needs bash, python3, zip, unzip (else SKIP).
t_build_zip_reproducible() {
    for _t in bash python3 zip unzip; do command -v "$_t" >/dev/null 2>&1 || return 77; done
    build_zip "$W/out1" || return 1
    sleep 2
    (TZ=EST5; export TZ; build_zip "$W/out2" 200001020304.05) || return 1
    cmp -s "$W/out1/module.zip" "$W/out2/module.zip" || fail "zip bytes differ between two builds of one tree"
}
# The fork zip ships the VDLU updater fed only from this forge: engine, verifier binaries (as in
# vdlu/verify/PROVENANCE.json), the WebUI panel and its Updates tab, customize.sh's VDLU lines; the
# keyring holds only the owner's key, config.default points at this forge's feed with that key id
# pinned, and every ABI gets the static curl the engine fetches with (no tools download).
# Needs bash, python3, zip, unzip (else SKIP).
t_build_zip_vdlu_shipped() {
    for _t in bash python3 zip unzip; do command -v "$_t" >/dev/null 2>&1 || return 77; done
    build_zip "$W/out" || return 1
    z=$W/out/module.zip; unzip -Z1 "$z" > "$W/list"
    for _f in vdlu/update.sh vdlu/vdlu-verify vdlu/config.default vdlu/verify/PROVENANCE.json webroot/vdlu.js webroot/vdlu.css \
        vdlu/keyring/ivangotoy-2026.pub licenses/curl-NOTICE; do
        grep -qx "$_f" "$W/list" || { fail "zip lacks $_f"; return 1; }
    done
    expect_eq "$(grep '^vdlu/keyring/.*\.pub$' "$W/list")" vdlu/keyring/ivangotoy-2026.pub || return 1
    grep -q 'baseline\.json' "$W/list" && { fail "build() zip holds upstream's baseline.json"; return 1; }
    mkdir -p "$W/x"; (cd "$W/x" && unzip -q "$z") || { fail "unzip"; return 1; }
    cmp -s "$W/x/vdlu/keyring/ivangotoy-2026.pub" "$REPO/.forgejo/vdlu/ivangotoy-2026.pub" || { fail "keyring key differs"; return 1; }
    python3 -I - "$W/x" "$z" "$REPO" > "$W/py" 2>&1 <<'PY' || { fail "$(tr '\n' ' ' < "$W/py")"; return 1; }
import hashlib, json, os, sys, zipfile
x, z, repo = sys.argv[1:]
zi = {i.filename: i for i in zipfile.ZipFile(z).infolist()}
v = json.load(open(os.path.join(x, "vdlu/verify/PROVENANCE.json")))
for abi, m in v["binaries"].items():
    p = f"vdlu/verify/{abi}/ed25519-mini"
    assert hashlib.sha256(open(os.path.join(x, p), "rb").read()).hexdigest() == m["sha256"], p
c = json.load(open(os.path.join(repo, ".forgejo/vdlu/PROVENANCE.json")))["files"]
for abi in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64"):
    p = f"bin/{abi}/curl"
    assert hashlib.sha256(open(os.path.join(x, p), "rb").read()).hexdigest() == c[f"curl/{abi}/curl"]["sha256"], p
    assert (zi[p].external_attr >> 16) & 0o777 == 0o755, p + " mode"
PY
    c=$(cat "$W/x/vdlu/config.default")
    expect_has "$c" "
source=https://forge.invalid/example/VD-dropbear/raw/branch/main/.forgejo/vdlu-feed
" || return 1
    expect_eq "$(grep -c '^source=' "$W/x/vdlu/config.default")" 1 || return 1
    expect_eq "$(grep '^key_id=' "$W/x/vdlu/config.default")" key_id=ivangotoy-2026 || return 1
    expect_eq "$(grep '^profile=' "$W/x/vdlu/config.default")" profile=hardened || return 1
    grep -q -i -E 'github|tools_source' "$W/x/vdlu/config.default" && { fail "config.default names an upstream feed"; return 1; }
    grep -q '^set_perm "\$MODPATH/vdlu/update.sh"' "$W/x/customize.sh" || { fail "customize.sh lost its VDLU lines"; return 1; }
    grep -q 'VDLU flashless updater' "$W/x/customize.sh" || { fail "customize.sh lost its VDLU seed block"; return 1; }
    expect_eq "$(grep -c '^# fork: VDLU feed and key on every flash' "$W/x/customize.sh")" 1 || return 1
    h=$(cat "$W/x/webroot/index.html")
    for _x in 'data-tab="updates"' 'id="tab-updates"' 'src="vdlu.js"' 'href="vdlu.css"' 'data-tab="status"' 'data-tab="pw"'; do
        expect_has "$h" "$_x" || return 1
    done
}
# G4: flashing the fork zip over an install whose VDLU config and state came from another feed
# (upstream's: its source, key id, trusted profile, tools feed) leaves only this forge's feed and key:
# source/key_id from the zip's config.default, profile hardened, tools_source/pubkey_dir gone (also
# written with blanks around '=', which the WebUI still reads), the user's other keys kept; the
# pending transaction, the adopted curl and current.json go, current.json restarts from the zip's
# baseline.json; blobs stay. An install with no VDLU state (fork ci15) is seeded. The module copy
# gets vdlu/ with a config.default as build() writes it and customize.sh with the fork fragment
# build() appends (t_build_zip_vdlu_shipped checks the zip has it). Made-up values.
flash_mod() { (MODPATH=$MOD; ui_print() { echo "$1"; }; grep_prop() { sed -n "s/^$1=//p" "$2"; }
    set_perm() { :; }; set_perm_recursive() { :; }; . "$MOD/customize.sh") 2>&1; }
t_customize_vdlu_migrates() {
    cp -R "$REPO/module/vdlu" "$MOD/vdlu"
    printf '%s\n' profile=hardened source=https://forge.invalid/example/VD-dropbear/raw/branch/main/.forgejo/vdlu-feed \
        channel=stable auto_on_reboot=1 pubkey_dir=keyring key_id=ivangotoy-2026 > "$MOD/vdlu/config.default"
    echo '{"version":10099}' > "$MOD/vdlu/baseline.json"
    grep -q '^# fork: VDLU feed and key on every flash' "$MOD/customize.sh" || cat "$REPO/.forgejo/vdlu/customize-fork.sh" >> "$MOD/customize.sh"
    rm -f "$MOD/customize.sh.sha256"; find "$MOD/vdlu" -name '*.sha256' -exec rm -f {} +   # a built tree's companions
    out=$(flash_mod); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    V=$DATA/vdlu
    expect_eq "$(sort "$V/config" | tr '\n' ' ')" "auto_on_reboot=1 channel=stable key_id=ivangotoy-2026 profile=hardened source=https://forge.invalid/example/VD-dropbear/raw/branch/main/.forgejo/vdlu-feed " || return 1
    expect_eq "$(cat "$V/current.json")" '{"version":10099}' || return 1
    printf '%s\n' profile=trusted source=https://feed.example.invalid/VD-dropbear channel=stable auto_on_reboot=0 \
        auto_on_webui_open=0 pubkey_dir=keyring2 net_policy=wifi key_id=other-2026 \
        ' tools_source = https://feed.example.invalid/vdlu-tools' boot_retry_minutes=7 > "$V/config"
    mkdir -p "$V/staged/bin" "$V/tools/x86_64" "$V/blobs" "$V/.work"
    for _f in target.json plan.tsv plan.del journal.json cancel staged/bin/x tools/x86_64/curl blobs/ab current.json; do echo old > "$V/$_f"; done
    out=$(flash_mod); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    expect_eq "$(sort "$V/config" | tr '\n' ' ')" "auto_on_reboot=0 auto_on_webui_open=0 boot_retry_minutes=7 channel=stable key_id=ivangotoy-2026 net_policy=wifi profile=hardened source=https://forge.invalid/example/VD-dropbear/raw/branch/main/.forgejo/vdlu-feed " || return 1
    for _f in target.json plan.tsv plan.del journal.json cancel staged tools .work; do
        [ -e "$V/$_f" ] && { fail "$_f kept"; return 1; }
    done
    expect_eq "$(cat "$V/blobs/ab")" old || return 1
    expect_eq "$(cat "$V/current.json")" '{"version":10099}' || return 1
    rm "$MOD/vdlu/baseline.json"; echo old > "$V/current.json"
    out=$(flash_mod); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    [ ! -e "$V/current.json" ] || fail "current.json kept without a baseline"
}
# --- VDLU engine (module/vdlu/update.sh, vdlu-verify) on the host ----------------
# vdlu_setup: an installed module in $MD (module/vdlu from the tree, keyring = $W/keys/test-2026.pub)
# with its VDLU state dir $VD (config: hardened, source file://$W/feed, key_id test-2026). The
# bionic-linked vdlu/verify/<abi>/ed25519-mini cannot run here: vdlu-verify takes $MD/vdlu/ed25519-mini
# first, which is either a stub that accepts every signature (VERIFIER=stub, any shell: engine logic)
# or .forgejo/vdlu/ed25519-verify, the same CLI on openssl (VERIFIER=openssl: real signatures).
VSIG=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
vdlu_setup() {
    MD=$W/installed VD=$W/vd
    mkdir -p "$MD" "$VD" "$W/keys" "$W/feed"
    cp -R "$REPO/module/vdlu" "$MD/vdlu"; rm -f "$MD/vdlu/keyring/"* "$MD/vdlu/baseline.json"
    if [ "${VERIFIER:-stub}" = openssl ]; then
        cp "$REPO/.forgejo/vdlu/ed25519-verify" "$MD/vdlu/ed25519-mini"
    else
        printf '#!/bin/sh\n[ -n "$ACCEPT_ONLY" ] && { cmp -s "$2" "$ACCEPT_ONLY" || exit 1; }\n[ -n "$SEEN_MSG" ] && cp "$2" "$SEEN_MSG"\nexit 0\n' > "$MD/vdlu/ed25519-mini"
        [ -f "$W/keys/test-2026.pub" ] || printf '%32s' x > "$W/keys/test-2026.pub"
    fi
    chmod 755 "$MD/vdlu/ed25519-mini"
    cp "$W/keys/test-2026.pub" "$MD/vdlu/keyring/test-2026.pub"
    printf '%s\n' profile=hardened "source=file://$W/feed" channel=stable key_id=test-2026 pubkey_dir=keyring \
        net_policy=any > "$VD/config"
}
veng() { VDLU_DIR=$VD MODULE_DIR=$MD MODID=vddropbear sh "$MD/vdlu/update.sh" "$@"; }
# vfeed <tree> <feed dir> <version> [delete path...]: manifest.json as vdlu-pack writes it (compact,
# sorted keys; key_id test-2026, sig $VSIG) + raw blobs/<sha256> for every file of <tree> (*.sh 0755)
vfeed() {
    _t=$1 _f=$2 _v=$3; shift 3
    mkdir -p "$_f/blobs"; _fl="" _sep=""
    for _p in $(cd "$_t" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); do
        _h=$(sha256sum "$_t/$_p" | cut -d' ' -f1); _z=$(wc -c < "$_t/$_p" | tr -d ' ')
        case "$_p" in *.sh) _m=0755 ;; *) _m=0644 ;; esac
        cp "$_t/$_p" "$_f/blobs/$_h"
        _fl="$_fl$_sep{\"class\":\"live\",\"enc\":\"raw\",\"mode\":\"$_m\",\"path\":\"$_p\",\"sha256\":\"$_h\",\"size\":$_z}"; _sep=,
    done
    _d="" _sep=""; for _p; do _d="$_d$_sep\"$_p\""; _sep=,; done
    printf '{"built":"2026-01-01T00:00:00Z","channel":"stable","delete":[%s],"engine_min":3,"files":[%s],"key_id":"test-2026","module":"vddropbear","schema":1,"sig":"%s","version":%s,"version_name":"v%s"}\n' \
        "$_d" "$_fl" "$VSIG" "$_v" "$_v" > "$_f/manifest.json"
}
# vkey <id>: a throwaway ed25519 key, $W/keys/<id>.pem and its raw 32-byte public half <id>.pub
vkey() { mkdir -p "$W/keys"; openssl genpkey -algorithm ed25519 -out "$W/keys/$1.pem" 2>/dev/null \
    && openssl pkey -in "$W/keys/$1.pem" -pubout -outform DER | tail -c 32 > "$W/keys/$1.pub"; }
# vsign <manifest> <key file id> [key_id]: the vendored producer's vdlu-sign
vsign() { TMPDIR=$W sh "$REPO/.forgejo/vdlu/vdlu-sign" "$1" "$W/keys/$2.pem" "${3:-test-2026}" 2>/dev/null; }
# vdlu_tree <dir> <version>: a small module tree for a feed (a.txt, common/b.sh, gone.txt, module.prop)
vdlu_tree() {
    mkdir -p "$1/common"; echo "a $2" > "$1/a.txt"; printf '#!/bin/sh\necho b\n' > "$1/common/b.sh"
    echo gone > "$1/gone.txt"; printf 'id=vddropbear\nversionCode=%s\n' "$2" > "$1/module.prop"
}
# the engine applies a feed over file:// (stub verifier, any shell): changed file written, unchanged
# file skipped, deleted path removed, module.prop at the feed's version, journal DONE, current.json
t_vdlu_engine_applies_feed() {
    vdlu_setup
    vdlu_tree "$W/v1" 1; (cd "$W/v1" && tar -cf - .) | (cd "$MD" && tar -xf -)
    vdlu_tree "$W/v2" 2; rm "$W/v2/gone.txt"; vfeed "$W/v2" "$W/feed" 2 gone.txt
    out=$(veng run 2>&1); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    expect_eq "$(cat "$MD/a.txt")" "a 2" || return 1
    [ ! -e "$MD/gone.txt" ] || { fail "deleted path kept"; return 1; }
    expect_eq "$(sed -n 's/^versionCode=//p' "$MD/module.prop")" 2 || return 1
    expect_has "$(cat "$VD/journal.json")" '"state":"DONE"' || return 1
    cmp -s "$VD/current.json" "$W/feed/manifest.json" || fail "current.json is not the applied manifest"
}
# the same with real signatures: the vendored vdlu-pack (--prev for delete[]) and vdlu-sign with a
# throwaway key, verified by the shipped vdlu-verify through the openssl verifier. Needs python3, openssl.
t_vdlu_engine_signed_feed() {
    for _t in python3 openssl gzip; do command -v "$_t" >/dev/null 2>&1 || return 77; done
    vkey test-2026 || { fail "openssl ed25519 keygen"; return 1; }
    VERIFIER=openssl vdlu_setup
    vdlu_tree "$W/v1" 1; (cd "$W/v1" && tar -cf - .) | (cd "$MD" && tar -xf -)
    python3 "$REPO/.forgejo/vdlu/vdlu-pack" "$W/v1" "$W/p1" vddropbear 1 2>/dev/null || { fail "pack v1"; return 1; }
    vdlu_tree "$W/v2" 2; rm "$W/v2/gone.txt"; head -c 9000 /dev/zero >> "$W/v2/a.txt"
    python3 "$REPO/.forgejo/vdlu/vdlu-pack" "$W/v2" "$W/feed" vddropbear 2 --prev "$W/p1/manifest.json" 2>/dev/null || { fail "pack v2"; return 1; }
    vsign "$W/feed/manifest.json" test-2026 || { fail "sign"; return 1; }
    out=$(veng run 2>&1); rc=$?
    expect_eq "$rc" 0 || { fail "$out"; return 1; }
    expect_has "$out" "vdlu-verify: OK key_id=test-2026" || return 1
    cmp -s "$MD/a.txt" "$W/v2/a.txt" || { fail "a.txt not updated (gz blob)"; return 1; }
    [ ! -e "$MD/gone.txt" ] || fail "deleted path kept"
}
# V1: text placed next to the signature (between '"sig":"<sig>"' and the next '",') is not covered
# by it but is parsed by the engine: a feed that adds a files[] entry there (blanks before every
# comma) must be refused like any unsigned change, and so must one with a second "sig" field or a NUL
# byte. The stub verifier accepts only the message of the genuine manifest, so the canonical form is
# what is tested, in any shell.
t_vdlu_sig_cut_injection() {
    vdlu_setup
    vdlu_tree "$W/v1" 1; (cd "$W/v1" && tar -cf - .) | (cd "$MD" && tar -xf -)
    vdlu_tree "$W/v2" 2; vfeed "$W/v2" "$W/feed" 2
    SEEN_MSG=$W/genuine.msg sh "$MD/vdlu/vdlu-verify" "$W/feed/manifest.json" "$MD/vdlu/keyring" 2>/dev/null \
        || { fail "genuine manifest refused"; return 1; }
    ACCEPT_ONLY=$W/genuine.msg; export ACCEPT_ONLY
    cp "$W/feed/manifest.json" "$W/genuine.json"
    echo evil > "$W/evil"; _h=$(sha256sum "$W/evil" | cut -d' ' -f1); cp "$W/evil" "$W/feed/blobs/$_h"
    _inj=" ,\"files\":[{\"class\":\"live\" ,\"enc\":\"raw\" ,\"mode\":\"0644\" ,\"path\":\"a.txt\" ,\"sha256\":\"$_h\" ,\"size\":5}] ,\"zz\":\"q"
    sed "s|\"sig\":\"$VSIG\"|\"sig\":\"$VSIG\"$_inj\"|" "$W/genuine.json" > "$W/feed/manifest.json"
    grep -q '"zz":"q",' "$W/feed/manifest.json" || { fail "fixture not built"; return 1; }
    out=$(veng run 2>&1); rc=$?
    [ "$rc" != 0 ] || { fail "manifest with unsigned files[] accepted: $out"; return 1; }
    expect_eq "$(cat "$MD/a.txt")" "a 1" || return 1
    sed "s|\"sig\":\"$VSIG\",|\"sig\":\"$VSIG\",\"sig\":\"$VSIG\",|" "$W/genuine.json" > "$W/feed/manifest.json"
    out=$(sh "$MD/vdlu/vdlu-verify" "$W/feed/manifest.json" "$MD/vdlu/keyring" 2>&1) && { fail "second sig field accepted"; return 1; }
    { cut -c1-9 "$W/genuine.json" | tr -d '\n'; printf '\000'; cut -c10- "$W/genuine.json"; } > "$W/feed/manifest.json"
    out=$(sh "$MD/vdlu/vdlu-verify" "$W/feed/manifest.json" "$MD/vdlu/keyring" 2>&1) && { fail "manifest with a NUL byte accepted"; return 1; }
    cp "$W/genuine.json" "$W/feed/manifest.json"
    out=$(veng run 2>&1); rc=$?
    expect_eq "$rc" 0 || { fail "genuine manifest refused: $out"; return 1; }
    expect_eq "$(cat "$MD/a.txt")" "a 2"
}
# V4: every engine run rebuilds .ca-bundle.pem before taking the lock; rewriting it in place truncated
# the file a concurrent run's curl was reading. The rebuild must replace it by rename: a second link
# to the old bundle keeps its bytes.
t_vdlu_ca_bundle_replaced() {
    vdlu_setup
    echo keep > "$W/cab"; ln "$W/cab" "$VD/.ca-bundle.pem" || { fail "ln"; return 1; }
    veng status >/dev/null 2>&1
    expect_eq "$(cat "$W/cab")" keep
}
# F12: scripts/build-bundles.sh fetch() must not reuse a partial download as a cached tarball
t_build_fetch_partial() {
    sed -n '/^fetch() {/,/^}/p' "$REPO/scripts/build-bundles.sh" > "$W/fetch.sh"
    [ -s "$W/fetch.sh" ] || { fail "fetch() not found"; return 1; }
    printf '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && o=$2; shift; done\nprintf partial > "$o"; exit 18\n' > "$STUB/curl"
    chmod 755 "$STUB/curl"
    _h=$(printf complete | sha256sum | cut -d' ' -f1)
    ( . "$W/fetch.sh"; fetch https://example.invalid/a.tar.gz "$W/a.tar.gz" "$_h" ) && { fail "failed download reported ok"; return 1; }
    printf '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && o=$2; shift; done\nprintf complete > "$o"\n' > "$STUB/curl"
    ( . "$W/fetch.sh"; fetch https://example.invalid/a.tar.gz "$W/a.tar.gz" "$_h" ) || { fail "retry failed"; return 1; }
    expect_eq "$(cat "$W/a.tar.gz")" complete
}
# build-bundles.sh fetch() refuses a tarball whose sha256 is not the pinned one, whether just
# downloaded or already cached, and leaves no file behind; the pinned bytes pass. Made-up bytes.
t_build_fetch_pinned() {
    sed -n '/^fetch() {/,/^}/p' "$REPO/scripts/build-bundles.sh" > "$W/fetch.sh"
    [ -s "$W/fetch.sh" ] || { fail "fetch() not found"; return 1; }
    _h=$(printf 'genuine tarball' | sha256sum | cut -d' ' -f1)
    printf '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && o=$2; shift; done\nprintf "tampered tarball" > "$o"\n' > "$STUB/curl"
    chmod 755 "$STUB/curl"
    ( . "$W/fetch.sh"; fetch https://example.invalid/b.tar.gz "$W/b.tar.gz" "$_h" ) 2>/dev/null && { fail "tampered download accepted"; return 1; }
    [ -e "$W/b.tar.gz" ] || [ -e "$W/b.tar.gz.part" ] && { fail "tampered file left behind"; return 1; }
    printf 'tampered tarball' > "$W/b.tar.gz"
    ( . "$W/fetch.sh"; fetch https://example.invalid/b.tar.gz "$W/b.tar.gz" "$_h" ) 2>/dev/null && { fail "tampered cached copy accepted"; return 1; }
    printf '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && o=$2; shift; done\nprintf "genuine tarball" > "$o"\n' > "$STUB/curl"
    ( . "$W/fetch.sh"; fetch https://example.invalid/b.tar.gz "$W/b.tar.gz" "$_h" ) || { fail "pinned bytes refused"; return 1; }
    expect_eq "$(cat "$W/b.tar.gz")" "genuine tarball" || return 1
    # one cached file, two accepted pins (the OpenSSH release tarball or its fallback archive): a
    # cached copy matching the second pin is reused without a download
    printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"
    _h2=$(printf 'fallback archive' | sha256sum | cut -d' ' -f1); printf 'fallback archive' > "$W/c.tar.gz"
    ( . "$W/fetch.sh"; fetch https://example.invalid/c.tar.gz "$W/c.tar.gz" "$_h" "$_h2" ) || { fail "cached copy with the second pin refused"; return 1; }
    expect_eq "$(cat "$W/c.tar.gz")" "fallback archive" || return 1
    # sha256sum unavailable (fails with no output): the fetch fails and the cached copy is kept
    printf '#!/bin/sh\nexit 1\n' > "$STUB/sha256sum"; chmod 755 "$STUB/sha256sum"
    ( . "$W/fetch.sh"; fetch https://example.invalid/c.tar.gz "$W/c.tar.gz" "$_h" "$_h2" ) 2>/dev/null && { fail "fetch without sha256sum exited 0"; return 1; }
    [ -f "$W/c.tar.gz" ] || fail "cached copy deleted when it could not be hashed"
}

# F32: module-ci.sh release: cleanup() deletes only a release the forge still reports as a
# draft. Real: log/die/jget/api/cleanup and the publish statements (REQ= .. PUBLISHED=1), cut
# from .forgejo/module-ci.sh by sed ranges; stubbed: curl (fake forge at https://forge.invalid).
# Needs bash and python3 like the script itself (else SKIP).
t_release_cleanup_keeps_published() {
    command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 77
    ci="$REPO/.forgejo/module-ci.sh"
    {
        echo 'set -euo pipefail'
        echo 'API=https://forge.invalid/api/v1/repos/example/mod RELEASE_ID=7 PUBLISHED=0 SRC_SHA=0123456789abcdef0123456789abcdef01234567'
        echo 'DRAFT_REQUESTED=0 TAG=v9.9-ci7 REQ={} CHECKED=0 VC=1 UPDATE_URL=https://forge.invalid/u UPDATE_JSON_PATH=u.json REL=/nonexistent'
        echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
        sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$ci"
        echo 'trap cleanup EXIT'
        echo 'if [ "$1" = create ]; then RELEASE_ID=""'
        sed -n '/^DRAFT_REQUESTED=1$/,/^RELEASE_ID="\$(api POST \/releases /p' "$ci"
        echo 'elif [ "$1" = publish ]; then'
        sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$ci"
        echo 'else die "upload failed"; fi'
    } > "$W/rel.sh"
    grep -q '^PUBLISHED=1$' "$W/rel.sh" && grep -q '^cleanup() {' "$W/rel.sh" || { fail "statements not found in module-ci.sh"; return 1; }
    # fake curl: logs "METHOD URL"; POST exits $POST_RC, PATCH $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
    cat > "$STUB/curl" <<EOF
#!/bin/sh
m=GET; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$W/calls"
case "\$m" in
  POST) exit "\${POST_RC:-0}" ;;
  PATCH) exit "\${PATCH_RC:-0}" ;;
  GET) [ "\$DRAFT" = fail ] && exit 22; printf '{"id": 7, "draft": %s}' "\$DRAFT" ;;
esac
EOF
    chmod 755 "$STUB/curl"
    # (a) PATCH fails after the forge applied it (release now published): the run reads the
    # state back and goes on as published, no DELETE
    : > "$W/calls"; PATCH_RC=28 DRAFT=false TMPDIR=$W bash "$W/rel.sh" publish 2>"$W/err"; rc=$?
    expect_eq "$rc" 0 || { fail "(a) $(cat "$W/err")"; return 1; }
    grep -q '^PATCH ' "$W/calls" || { fail "(a) no PATCH sent"; return 1; }
    grep -q '^GET .*/releases/7$' "$W/calls" || { fail "(a) state not read back"; return 1; }
    grep -q '^DELETE ' "$W/calls" && { fail "(a) published release deleted"; return 1; }
    # (b) failure before publish, release still a draft: DELETE issued
    : > "$W/calls"; DRAFT=true TMPDIR=$W bash "$W/rel.sh" upload 2>"$W/err"; rc=$?
    [ "$rc" != 0 ] || { fail "(b) exit 0"; return 1; }
    grep -qx 'DELETE https://forge.invalid/api/v1/repos/example/mod/releases/7' "$W/calls" || { fail "(b) draft not deleted"; return 1; }
    # (c) PATCH fails and the state cannot be read: no DELETE, the id is logged for a manual check
    : > "$W/calls"; PATCH_RC=28 DRAFT=fail TMPDIR=$W bash "$W/rel.sh" publish 2>"$W/err"; rc=$?
    [ "$rc" != 0 ] || { fail "(c) exit 0"; return 1; }
    grep -q '^DELETE ' "$W/calls" && { fail "(c) release deleted with unknown state"; return 1; }
    grep -q 'release 7' "$W/err" || { fail "(c) release id not logged"; return 1; }
    # (d) PATCH succeeds: nothing deleted, exit 0
    : > "$W/calls"; DRAFT=false TMPDIR=$W bash "$W/rel.sh" publish 2>"$W/err"; rc=$?
    expect_eq "$rc" 0 || return 1
    grep -q '^DELETE ' "$W/calls" && { fail "(d) deleted after a good publish"; return 1; }
    # (e) the draft request failed or its reply was lost: no id to delete by, the tag is logged
    : > "$W/calls"; POST_RC=28 DRAFT=true TMPDIR=$W bash "$W/rel.sh" create 2>"$W/err"; rc=$?
    [ "$rc" != 0 ] || { fail "(e) exit 0"; return 1; }
    grep -q '^POST ' "$W/calls" || { fail "(e) no POST sent"; return 1; }
    grep -q '^DELETE ' "$W/calls" && { fail "(e) DELETE without a release id"; return 1; }
    grep -q 'unbound variable' "$W/err" && { fail "(e) unbound variable"; return 1; }
    grep -q 'the draft request for v9.9-ci7 failed or its reply was lost' "$W/err" || { fail "(e) tag not logged"; return 1; }
    return 0
}

# module-ci.sh release, end to end and offline: the real build() zip, a local bare repo as the
# forge's git side (file://) and a curl stub as its API, the asset store, the anonymous download
# and the raw update.json. Nothing is fetched from upstream (the source sha is the base sha).
# release_run <name>: runs the release step in $W/<name>; env knobs for the stub: PATCH_RC (exit
# of the publish PATCH after the forge applied it), ANON_OK_AT / POLL_OK_AT (attempt that first
# succeeds), REJECT_PUSH=1 (the forge refuses pushes once seeded). Sets RR (rc), RD (run dir).
release_setup() {
    for _t in bash python3 git zip unzip; do command -v "$_t" >/dev/null 2>&1 || return 77; done
    build_zip "$W/out" || return 1
    RTOKEN=tok-example-not-a-secret-1234
    # what the release computes from module.prop and the conf (run number 7), as module-ci.sh does
    _c=$REPO/.forgejo/module-ci.conf
    RVC=$(( $(sed -n 's/^versionCode=//p' "$REPO/module/module.prop") + $(sed -n 's/^VERSION_CODE_OFFSET=//p' "$_c") ))
    RTAG=$(sed -n 's/^version=//p' "$REPO/module/module.prop" | sed -E 's/-(fork|ci)[0-9]+$//')-ci7
    case "$RTAG" in v*) ;; *) RTAG=v$RTAG ;; esac
    RZIP=$(sed -n 's/^ZIP_PREFIX=//p' "$_c")-$RTAG.zip
}
release_run() {
    RD=$W/$1; F=$RD/forge-state
    mkdir -p "$RD/forge/owner" "$RD/seed/.forgejo" "$RD/work/.ci-out" "$RD/job" "$RD/bin" "$RD/tmp" "$F"
    git init -q --bare "$RD/forge/owner/repo.git" && git init -q "$RD/seed" || { fail "fixture repos"; return 1; }
    cp "$REPO/.forgejo/module-ci.conf" "$RD/seed/.forgejo/"; echo "# changes" > "$RD/seed/CHANGELOG.md"
    (cd "$RD/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm seed \
        && git push -q "$RD/forge/owner/repo.git" HEAD:refs/heads/main) || { fail "fixture push"; return 1; }
    _base=$(git -C "$RD/seed" rev-parse HEAD)
    [ "${REJECT_PUSH:-0}" = 1 ] && printf '#!/bin/sh\nexit 1\n' > "$RD/forge/owner/repo.git/hooks/pre-receive" \
        && chmod 755 "$RD/forge/owner/repo.git/hooks/pre-receive"
    cp "$W/out/module.zip" "$RD/work/.ci-out/module.zip"
    printf '%s\n\n' "$_base" > "$RD/work/.ci-out/src"; echo "fork main" > "$RD/work/.ci-out/desc"
    echo true > "$F/draft"
    cat > "$RD/bin/curl" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$F/argv"
m=GET o="" att="" w="" mt=0 rt=0; prev=""
for a in "\$@"; do
    case "\$prev" in -X) m=\$a ;; -o) o=\$a ;; -w) w=\$a ;; --max-time) mt=\$a ;; --retry) rt=\$a ;; -F) att=\${a#attachment=@} ;; esac
    prev=\$a; u=\$a
done
echo "\$m \$u \$mt \$rt" >> "$F/calls"
case "\$u" in
  */releases/tags/*|*/tags/*)
    if [ -n "\$w" ]; then printf 404; else printf '{"commit": {"sha": "$_base"}}'; fi ;;
  */releases) printf '{"id": 7}' ;;
  */releases/7/assets\\?name=*) cp "\$att" "$F/asset.zip"; printf '{"id": 9}' ;;
  */releases/7/assets/9) printf '{"browser_download_url": "https://forge.invalid/attachments/9"}' ;;
  https://forge.invalid/attachments/9) cp "$F/asset.zip" "\$o" ;;
  */releases/7)
    case "\$m" in
      PATCH) echo false > "$F/draft"; printf '{}'; exit "\${PATCH_RC:-0}" ;;
      DELETE) echo deleted > "$F/draft" ;;
      *) printf '{"id": 7, "draft": %s}' "\$(cat "$F/draft")" ;;
    esac ;;
  */releases/download/*)
    echo x >> "$F/anon"; [ "\$(wc -l < "$F/anon")" -ge "\${ANON_OK_AT:-1}" ] || exit 22
    cp "$F/asset.zip" "\$o" ;;
  */raw/branch/main/*)
    echo x >> "$F/poll"; [ "\$(wc -l < "$F/poll")" -ge "\${POLL_OK_AT:-1}" ] || { printf '{"versionCode": 1}'; exit 0; }
    git --git-dir="$RD/forge/owner/repo.git" show main:.forgejo/update.json ;;
  *) echo "stub curl: unexpected \$u" >&2; exit 2 ;;
esac
EOF
    printf '#!/bin/sh\necho "sleep $*" >> "%s/sleeps"\n' "$F" > "$RD/bin/sleep"
    chmod 755 "$RD/bin/curl" "$RD/bin/sleep"
    RR=0
    (cd "$RD/job" && env PATH="$RD/bin:$PATH" TMPDIR="$RD/tmp" SERVER_URL="file://$RD/forge" REPOSITORY=owner/repo \
        BASE_SHA="$_base" RUN_NUMBER=7 RELEASE_TOKEN="$RTOKEN" bash "$REPO/.forgejo/module-ci.sh" release "$RD/work") \
        > "$RD/out.log" 2>&1 || RR=$?
    return 0
}
# F34: release mode end to end; its worst-case curl time (every bound x attempts, both
# polling loops at five attempts, plus one more read for a lost publish reply) stays within
# half the job's timeout-minutes, leaving the rest for the clone, the build and git transfers.
# Also: the released zip passes the flash gate, and the token is in no argv and no output.
t_release_end_to_end() {
    release_setup || return $?
    ANON_OK_AT=5 POLL_OK_AT=5 release_run ok || return 1
    expect_eq "$RR" 0 || { fail "$(tail -n 3 "$RD/out.log" | tr '\n' ' ')"; return 1; }
    u=$(git --git-dir="$RD/forge/owner/repo.git" show main:.forgejo/update.json)
    expect_has "$u" "\"versionCode\": $RVC" || return 1
    expect_has "$u" "\"zipUrl\": \"file://$RD/forge/owner/repo/releases/download/$RTAG/$RZIP\"" || return 1
    mkdir -p "$W/flashed"; (cd "$W/flashed" && unzip -q "$F/asset.zip") || { fail "asset unzip"; return 1; }
    expect_eq "$(sed -n 's/^versionCode=//p' "$W/flashed/module.prop")" "$RVC" || return 1
    out=$(gate_out "$W/flashed"); rc=$?
    expect_eq "$rc" 0 || { fail "released zip fails the flash gate: $out"; return 1; }
    grep -qF "$RTOKEN" "$F/argv" "$RD/out.log" && { fail "token in argv or output"; return 1; }
    tm=$(sed -n 's/^ *timeout-minutes: *\([0-9]*\).*/\1/p' "$REPO/.forgejo/workflows/module-release.yml")
    worst=$(awk -v s="$(cat "$F/sleeps" 2>/dev/null | awk '{t+=$2} END {print t+0}')" '
        { b = $3 * ($4 + 1) + ($4 > 0 ? 7 : 0); t += b; if ($1 == "GET" && $4 > 0 && b > g) g = b }
        END { print t + g + s }' "$F/calls")
    [ "$worst" -le $((tm * 60 / 2)) ] || { fail "worst-case curl time ${worst}s > half of timeout-minutes $tm"; return 1; }
}
# C2: the forge publishes the release but the reply to the publish PATCH is lost: the run reads
# the release back, sees it published, and still commits update.json
t_release_publish_reply_lost() {
    release_setup || return $?
    PATCH_RC=28 release_run lost || return 1
    expect_eq "$RR" 0 || { fail "$(tail -n 3 "$RD/out.log" | tr '\n' ' ')"; return 1; }
    grep -q '^DELETE ' "$F/calls" && { fail "published release deleted"; return 1; }
    expect_has "$(git --git-dir="$RD/forge/owner/repo.git" show main:.forgejo/update.json)" "\"versionCode\": $RVC"
}
# F35: a failure after the release is published names the tag and the exact recovery: the
# update.json to commit once the release passed its checks, else delete the release and its tag
t_release_failure_after_publish() {
    release_setup || return $?
    REJECT_PUSH=1 release_run push || return 1
    [ "$RR" != 0 ] || { fail "(push) exit 0"; return 1; }
    o=$(cat "$RD/out.log")
    expect_has "$o" "failure after publishing $RTAG" || return 1
    expect_has "$o" "commit .forgejo/update.json on main with the content below" || return 1
    expect_has "$o" "\"versionCode\": $RVC," || return 1
    expect_has "$o" "\"zipUrl\": \"file://$RD/forge/owner/repo/releases/download/$RTAG/$RZIP\"" || return 1
    ANON_OK_AT=9 release_run anon || return 1
    [ "$RR" != 0 ] || { fail "(anon) exit 0"; return 1; }
    o=$(cat "$RD/out.log")
    expect_has "$o" "the published release failed the check above: delete release $RTAG and tag $RTAG" || return 1
    expect_not "$o" "content below"
}

# module-ci.sh build: whatever the build user started is killed after the build, failed or not.
# setpriv and chown are stubs: the stub records a kill and never runs it (here the test user may
# well be the build uid, and `kill -9 -1` would end this session). Needs bash and git (else SKIP).
t_build_kills_build_user() {
    command -v bash >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || return 77
    cat > "$STUB/setpriv" <<'EOF'
#!/bin/sh
case " $* " in *" kill "*) echo "kill-requested $*" >> "$SETPRIV_LOG"; exit 0 ;; esac
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$STUB/chown"
    chmod 755 "$STUB/setpriv" "$STUB/chown"
    [ "$(PATH="$STUB:$PATH" command -v setpriv)" = "$STUB/setpriv" ] || { fail "setpriv stub not first on PATH, not run"; return 1; }
    for _k in ok failed; do
        _b=$W/build-$_k; mkdir -p "$_b/.forgejo"
        cp "$REPO/.forgejo/module-ci.sh" "$_b/.forgejo/"
        if [ "$_k" = ok ]; then
            printf 'build() { echo zip > "$OUT/module.zip"; }\n' > "$_b/.forgejo/module-ci.conf"
        else
            printf 'build() { echo "stub build failed" >&2; return 1; }\n' > "$_b/.forgejo/module-ci.conf"
        fi
        (cd "$_b" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) > /dev/null 2>&1
        : > "$_b/setpriv.log"
        _rc=0
        (cd "$_b" && env PATH="$STUB:$PATH" SETPRIV_LOG="$_b/setpriv.log" SERVER_URL=https://forge.invalid \
            REPOSITORY=owner/repo BASE_SHA="$(git rev-parse HEAD)" bash .forgejo/module-ci.sh build "$_b") > "$_b/out.log" 2>&1 || _rc=$?
        if [ "$_k" = ok ]; then
            [ "$_rc" = 0 ] && [ -f "$_b/.ci-out/module.zip" ] || { fail "($_k) rc=$_rc: $(tail -n 2 "$_b/out.log" | tr '\n' ' ')"; return 1; }
        else
            [ "$_rc" != 0 ] && grep -q "stub build failed" "$_b/out.log" || { fail "($_k) rc=$_rc: $(tail -n 2 "$_b/out.log" | tr '\n' ' ')"; return 1; }
        fi
        grep -q "unbound variable" "$_b/out.log" && { fail "($_k) unbound variable"; return 1; }
        grep -q 'kill-requested .*--reuid=1000 .*kill -9 -1' "$_b/setpriv.log" || { fail "($_k) build user's processes not killed"; return 1; }
    done
    return 0
}

# module-release.yml: the job builds the dispatched commit even when main has moved since. The
# steps whose run text clones or calls `module-ci.sh build` run against a local bare repo whose
# main has a commit after BASE_SHA; the fixture's .forgejo/module-ci.sh is a marker script that
# records which commit's copy ran. Run blocks are read without PyYAML. Needs python3 and git.
t_workflow_builds_dispatched_commit() {
    command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || return 77
    _wf=$W/workflow
    mkdir -p "$_wf/job" "$_wf/forge/owner" "$_wf/seed/.forgejo"
    git init -q --bare "$_wf/forge/owner/repo.git" && git init -q "$_wf/seed" || { fail "fixture repos"; return 1; }
    for _c in dispatched later-on-main; do
        printf '#!/bin/sh\necho "%s $*" >> "$MARKER_LOG"\n' "$_c" > "$_wf/seed/.forgejo/module-ci.sh"
        (cd "$_wf/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "$_c") || { fail "fixture commit"; return 1; }
        [ "$_c" = dispatched ] && _base=$(git -C "$_wf/seed" rev-parse HEAD)
    done
    git -C "$_wf/seed" push -q "$_wf/forge/owner/repo.git" HEAD:refs/heads/main || { fail "fixture push"; return 1; }
    python3 -I - "$REPO/.forgejo/workflows/module-release.yml" > "$_wf/steps.sh" <<'PY'
import re, sys
steps, cur = [], None
for l in open(sys.argv[1]).read().split("\n"):
    if re.match(r"^      - name:", l):
        cur = {"run": [], "in": False}; steps.append(cur); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
for st in steps:
    text = "\n".join(st["run"])
    if "git clone" in text or "module-ci.sh build" in text:
        print("(\n" + text + "\n)")
PY
    : > "$_wf/marker.log"
    (cd "$_wf/job" && env SERVER_URL="file://$_wf/forge" REPOSITORY=owner/repo BASE_SHA="$_base" \
        MARKER_LOG="$_wf/marker.log" sh "$_wf/steps.sh") > "$_wf/out.log" 2>&1 || { fail "steps failed: $(tail -n 2 "$_wf/out.log" | tr '\n' ' ')"; return 1; }
    expect_eq "$(git -C "$_wf/job/src" rev-parse HEAD)" "$_base" || return 1
    expect_eq "$(cat "$_wf/marker.log")" "dispatched build src"
}

# gh_step <workflow> <step name>: the run text of that step, read without PyYAML (python3)
gh_step() {
    python3 -I - "$1" "$2" <<'PY'
import re, sys
steps, cur = {}, None
for l in open(sys.argv[1]).read().split("\n"):
    m = re.match(r"^      - name: (.*)$", l)
    if m:
        cur = steps.setdefault(m.group(1).strip(), {"run": [], "in": False}); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
st = steps.get(sys.argv[2])
sys.exit(f"no step {sys.argv[2]!r}") if st is None or not st["run"] else print("\n".join(st["run"]))
PY
}
# T6: ci.yml "Validate JSON" fails on an invalid file that is not the last one checked. The step
# runs under bash -e like a GitHub run: block. Needs bash and python3.
t_ci_validate_json() {
    command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 77
    gh_step "$REPO/.github/workflows/ci.yml" "Validate JSON" > "$W/step.sh" || { fail "step not found"; return 1; }
    mkdir -p "$W/r/module/vdlu"; echo '{"version": ' > "$W/r/module/update.json"; echo '{}' > "$W/r/module/vdlu/baseline.json"
    (cd "$W/r" && bash -e "$W/step.sh") > "$W/out" 2>&1 && { fail "invalid update.json passed: $(tr '\n' ' ' < "$W/out")"; return 1; }
    echo '{}' > "$W/r/module/update.json"
    (cd "$W/r" && bash -e "$W/step.sh") > "$W/out" 2>&1 || fail "valid files failed: $(tr '\n' ' ' < "$W/out")"
}

# T7: ci.yml "Kit + engine parity" fails when a parity script exists and fails, instead of
# reporting it as a skip; absent scripts still skip. Needs bash and python3.
t_ci_parity_failure() {
    command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 77
    gh_step "$REPO/.github/workflows/ci.yml" "Kit + engine parity (skip if references absent)" > "$W/step.sh" || { fail "step not found"; return 1; }
    mkdir -p "$W/g/repo/.github/scripts" "$W/g/VD-ModuleKit/tooling"
    echo 'exit 0' > "$W/g/repo/.github/scripts/release-workflow-lint.sh"
    (cd "$W/g/repo" && bash -e "$W/step.sh") > "$W/out" 2>&1 || { fail "absent references failed: $(tr '\n' ' ' < "$W/out")"; return 1; }
    expect_eq "$(grep -c '(skip)' "$W/out")" 2 || return 1
    echo 'echo "vendor-parity: drift"; exit 1' > "$W/g/VD-ModuleKit/tooling/vendor-parity.sh"
    if (cd "$W/g/repo" && bash -e "$W/step.sh") > "$W/out" 2>&1; then
        fail "failing vendor-parity passed: $(tr '\n' ' ' < "$W/out")"
    fi
}
# pf_run <fixture dir>: scripts/preflight.sh copied into the fixture and run there by bash
pf_run() {
    mkdir -p "$1/scripts"; cp "$REPO/scripts/preflight.sh" "$1/scripts/"
    (cd "$1" && bash scripts/preflight.sh) 2>&1
}
# T3: preflight [6] reports a gen-doc-nav run that updated 10 pages as not idempotent (its match
# was a substring of "10 switcher(s), 0 footer(s)"). Needs bash and python3.
t_preflight_docnav_count() {
    command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 77
    mkdir -p "$W/pf/.github/scripts"
    echo 'import sys; print("gen-doc-nav: 10 switcher(s), 0 footer(s) updated", file=sys.stderr)' > "$W/pf/.github/scripts/gen-doc-nav.py"
    out=$(pf_run "$W/pf")
    expect_has "$out" "nav/footer not idempotent" || return 1
    echo 'import sys; print("gen-doc-nav: 0 switcher(s), 0 footer(s) updated", file=sys.stderr)' > "$W/pf/.github/scripts/gen-doc-nav.py"
    out=$(pf_run "$W/pf")
    expect_has "$out" "nav/footer already canonical"
}
# T5: preflight [8] flags a personal token handed to `gh release create` as GH_TOKEN (it looked at
# `token:` inputs only); the upstream release.yml (GH_TOKEN: github.token) still passes.
t_preflight_release_pat() {
    command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 77
    mkdir -p "$W/pf/.github/workflows"
    printf '%s\n' 'jobs:' '  r:' '    steps:' '      - name: publish' '        env:' \
        '          GH_TOKEN: ${{ secrets.MY_PAT }}' '        run: gh release create v1 x.zip' > "$W/pf/.github/workflows/rel.yml"
    out=$(pf_run "$W/pf")
    expect_has "$out" "custom release token in rel.yml" || return 1
    rm "$W/pf/.github/workflows/rel.yml"; cp "$REPO/.github/workflows/release.yml" "$W/pf/.github/workflows/"
    out=$(pf_run "$W/pf")
    expect_has "$out" "no draft, no PAT"
}
# repack-baseline.sh packs HEAD plus working changes (a temporary index) but took the 0755 modes from
# the real index: an executable not yet staged was packed 0644. The pack/sign tools are stubs; the
# pack stub records the modes it was given. Needs bash, python3 and git.
t_repack_baseline_modes() {
    for _t in bash python3 git; do command -v "$_t" >/dev/null 2>&1 || return 77; done
    _r=$W/rb; mkdir -p "$_r/scripts" "$_r/module" "$_r/p"
    cp "$REPO/scripts/repack-baseline.sh" "$_r/scripts/"
    printf 'version=v1.00\nversionCode=10000\n' > "$_r/module/module.prop"
    for _f in LICENSE NOTICE THIRD-PARTY-NOTICES.md; do echo x > "$_r/$_f"; done
    (cd "$_r" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm seed) || { fail "fixture repo"; return 1; }
    printf '#!/bin/sh\necho new\n' > "$_r/module/new.sh"; chmod 755 "$_r/module/new.sh"
    printf '%s\n' 'import os, stat, sys' 'm = os.path.join(sys.argv[1], "new.sh")' \
        'open(sys.argv[-1], "w").write(oct(stat.S_IMODE(os.stat(m).st_mode)))' 'sys.exit(1)' > "$_r/p/pack"
    echo key > "$_r/p/key"; printf '#!/bin/sh\nexit 0\n' > "$_r/p/sign"; chmod 755 "$_r/p/sign"
    (cd "$_r" && VDLU_PACK="$_r/p/pack" VDLU_SIGN="$_r/p/sign" VDLU_KEY="$_r/p/key" \
        sh scripts/repack-baseline.sh --prev "$_r/p/mode") > "$W/out" 2>&1
    expect_eq "$(cat "$_r/p/mode" 2>/dev/null)" "0o755"
}
# T1: version.sh bump checks module/update.json before it writes anything: a missing update.json
# fails the bump with module.prop untouched (a rerun used to bump twice); a good one bumps both.
t_version_bump_atomic() {
    command -v bash >/dev/null 2>&1 || return 77
    _v=$W/vs; mkdir -p "$_v/.github/scripts" "$_v/module"
    cp "$REPO/.github/scripts/version.sh" "$_v/.github/scripts/"
    printf 'id=x\nversion=v1.13\nversionCode=10013\n' > "$_v/module/module.prop"
    (cd "$_v" && SCHEME=minor bash .github/scripts/version.sh bump) > "$W/out" 2>&1 && { fail "bump without update.json exited 0"; return 1; }
    expect_eq "$(cat "$_v/module/module.prop")" "$(printf 'id=x\nversion=v1.13\nversionCode=10013')" || return 1
    printf '{\n  "zipUrl": "https://example.invalid/v1.13/x-v1.13.zip"\n}\n' > "$_v/module/update.json"
    (cd "$_v" && SCHEME=minor bash .github/scripts/version.sh bump) > "$W/out" 2>&1 || { fail "bump failed: $(tr '\n' ' ' < "$W/out")"; return 1; }
    expect_has "$(cat "$_v/module/module.prop")" "versionCode=10014" || return 1
    expect_has "$(cat "$_v/module/update.json")" "x-v1.14.zip"
}
# T2: tools/gen-update-json.sh refuses a module.prop without a numeric versionCode instead of
# writing an update.json that is not JSON and exiting 0; a good module.prop gives valid JSON.
t_gen_update_json_checks() {
    command -v python3 >/dev/null 2>&1 || return 77
    _g=$W/gu; mkdir -p "$_g/tools" "$_g/module"
    cp "$REPO/tools/gen-update-json.sh" "$_g/tools/"
    printf 'version=v1.13\n' > "$_g/module/module.prop"
    sh "$_g/tools/gen-update-json.sh" > "$W/out" 2>&1 && { fail "no versionCode exited 0"; return 1; }
    [ -e "$_g/module/update.json" ] && { fail "update.json written"; return 1; }
    printf 'versionCode=10013\n' > "$_g/module/module.prop"
    sh "$_g/tools/gen-update-json.sh" > "$W/out" 2>&1 && { fail "no version exited 0"; return 1; }
    [ -e "$_g/module/update.json" ] && { fail "update.json written without a version"; return 1; }
    printf 'version=v1.13\nversionCode=10013\n' > "$_g/module/module.prop"
    sh "$_g/tools/gen-update-json.sh" > "$W/out" 2>&1 || { fail "good module.prop failed"; return 1; }
    expect_eq "$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["versionCode"])' "$_g/module/update.json")" 10013
}
# T9: wiki-sync.yml's push paths cover every file gen_wiki.sh renders from: wiki.conf, the README
# taglines, and each English doc it takes from the repository root (docs/ holds no English copy)
# or adds through WIKI_EXTRA_DOCS. The lists come from wiki.conf and the tree. Needs python3.
t_wiki_sync_paths() {
    command -v python3 >/dev/null 2>&1 || return 77
    python3 -I - "$REPO" > "$W/out" 2>&1 <<'PY' || { fail "$(tr '\n' ' ' < "$W/out")"; return 1; }
import fnmatch, os, re, shlex, sys
root = sys.argv[1]
conf = {}
for l in open(os.path.join(root, ".github/scripts/wiki.conf")):
    m = re.match(r'^([A-Z_]+)=(.*)$', l.strip())
    if m:
        conf[m.group(1)] = " ".join(shlex.split(m.group(2)))
need = [".github/scripts/wiki.conf", ".github/scripts/gen_wiki.sh", "README.md"]
need += sorted(f for f in os.listdir(root) if re.match(r"README\.[a-z]{2}\.md$", f))[:1]
for b in (conf.get("WIKI_DOC_ORDER", "") + " " + conf.get("WIKI_EXTRA_DOCS", "")).split():
    if not os.path.exists(os.path.join(root, "docs", b + ".md")) and os.path.exists(os.path.join(root, b + ".md")):
        need.append(b + ".md")
pats, inp = [], False
for l in open(os.path.join(root, ".github/workflows/wiki-sync.yml")):
    if re.match(r"^    paths:\s*$", l):
        inp = True; continue
    if inp:
        m = re.match(r"^      - '([^']+)'\s*$", l)
        if m:
            pats.append(m.group(1)); continue
        if re.match(r"^      #", l):
            continue
        break
miss = [f for f in need if not any(fnmatch.fnmatchcase(f, p) for p in pats)]
sys.exit("not in wiki-sync paths: " + " ".join(miss)) if miss else print("ok", len(need), pats)
PY
}
CASES="t_args_default t_args_binds t_config_normalise t_config_bfu_store
t_webui_config_roundtrip t_webui_config_rejects_empty t_webui_port_range t_webui_keys t_webui_add_key_commented t_webui_passwords t_webui_unterminated_last_line t_webui_args_quoted t_webui_write_failure t_bfu_toggle_moves_secrets t_bfu_move_failure_reported t_bfu_rename_failure_reported t_bfu_move_odd_names t_bfu_switch_nothing_to_move t_bfu_stale_temp_ignored t_webui_status t_webui_verbs_exit_zero
t_action_start t_empty_hostkey_regenerated t_log_rotated t_start_without_log_quiet t_extra_env_no_glob t_ident_not_inherited t_action_restart_single_instance t_webui_lifecycle_verbs t_restart_keeps_sessions t_orphaned_session_not_listener t_overlapping_starts t_stale_pidfile t_slow_start_reported t_freezer_escape t_freezer_escape_not_writable t_freezer_escape_uid_layout t_disabled_not_started t_disable_stops_running t_log_without_state_dir t_service_afu_bfu
t_service_disabled t_customize t_uninstall t_sha256_gate t_gen_sha256_failure t_build_zip_sha256 t_build_zip_reproducible t_build_zip_vdlu_shipped t_customize_vdlu_migrates t_vdlu_engine_applies_feed t_vdlu_engine_signed_feed t_vdlu_sig_cut_injection t_vdlu_ca_bundle_replaced t_build_fetch_partial t_build_fetch_pinned t_release_cleanup_keeps_published t_release_end_to_end t_release_publish_reply_lost t_release_failure_after_publish t_build_kills_build_user t_workflow_builds_dispatched_commit t_ci_validate_json t_ci_parity_failure t_preflight_docnav_count t_preflight_release_pat t_repack_baseline_modes t_version_bump_atomic t_gen_update_json_checks t_wiki_sync_paths"

for c in $CASES; do run_case "$c"; done
echo "summary: pass=$PASS fail=$FAIL skip=$SKIP${FAILED:+ failed:$FAILED}"
[ "$FAIL" = 0 ]
