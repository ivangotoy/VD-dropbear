#!/usr/bin/env bash
# Generic KernelSU module release pipeline (this repo's own copy; it started from the copy other module repos share).
#
#   module-ci.sh build <workdir>    no forge token: merge upstream, build the zip
#                                   (the build runs as an unprivileged user)
#   module-ci.sh release <workdir>  forge token: version + updateJson into the zip,
#                                   [signed VDLU feed + baseline] -> draft -> upload ->
#                                   download back and verify -> push merge -> publish ->
#                                   commit update.json [+ the VDLU feed]
# The release step runs this script and the config as fetched from the dispatched
# commit, never the copies in the build workspace. A failure before publish
# deletes the draft once the forge confirms it is still one (a lost reply to the
# draft request is logged instead). The merge with upstream is pushed to main right before the
# publish call, so a failure before that push pushes nothing, and a failed
# publish leaves the merge on main (without a release). A failure after the
# publish logs the recovery: the update.json to commit, or the release to delete.
#
# Per-repo settings: .forgejo/module-ci.conf (sourced shell)
#   UPSTREAM_URL, UPSTREAM_BRANCH   upstream merged into main ("" = none)
#   ZIP_PREFIX                      release zip name prefix
#   VERSION_CODE_FLOOR              lowest versionCode allowed to release
#   VERSION_CODE_OFFSET             added to the built versionCode (default 0)
#   UPDATE_JSON_PATH                update.json path in main (default .forgejo/update.json)
#   SYNC_ROOT_PROP                  fork-owned module.prop in main kept at the released version
#   CHANGELOG_PATH                  changelog file in the tree ("" = none)
#   build()                         runs in the tree, leaves the module zip at "$OUT/module.zip"
#   prebuilt()                      instead of merge + build: puts an upstream release zip at
#                                   "$OUT/module.zip" and a one-line source note in "$OUT/upstream-desc"
#   VDLU_FEED_PATH, VDLU_KEY_ID     VDLU feed dir in main ("" = none) and the key id that signs it:
#                                   the release packs the released zip's tree into a signed
#                                   manifest.json + blobs/ (key: env VDLU_SIGN_KEY, PEM), ships the
#                                   manifest as vdlu/baseline.json and commits the feed with update.json
#   release_files()                 optional, release step: writes extra fork-only files for the
#                                   update.json commit (in-app update feeds) and lists them in
#                                   RELEASE_FILES; sees VERSION VC TAG ZIP_NAME ZIP_URL ZIP_SHA ZIP_SIZE
#                                   BUILT_VERSION SRC_SHA BODY CHANGELOG_URL UPDATE_URL
set -euo pipefail
# git has no timeout of its own: a fetch/clone/push whose server stops sending fails after
# 60 s below 1 KiB/s instead of holding the runner until the job timeout (values set by the
# caller are kept)
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1024}" GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-60}"

MODE="${1:?mode}"; WORK="$(cd "${2:?workdir}" && pwd)"
: "${SERVER_URL:?}" "${REPOSITORY:?}" "${BASE_SHA:?}"
BUILD_UID=1000
OUT="$WORK/.ci-out"
export GIT_AUTHOR_NAME="Ivan Angelov" GIT_AUTHOR_EMAIL="ivangotoy@gmail.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
prop_get() { sed -n "s/^$1=//p" "$2" | head -n1 | tr -d '\r'; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
sedq() { printf '%s' "$1" | sed 's/[\\|&]/\\&/g'; }  # text for the replacement of a s|...|...| command
jget() { python3 -I -c 'import json,sys;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[int(k)] if k.isdigit() else d[k]
print(d)' "$1"; }
load_conf() {
    UPSTREAM_URL="" UPSTREAM_BRANCH="" ZIP_PREFIX="${REPOSITORY#*/}" VERSION_CODE_FLOOR=0 VERSION_CODE_OFFSET=0
    UPDATE_JSON_PATH=".forgejo/update.json" SYNC_ROOT_PROP="" CHANGELOG_PATH="" VDLU_FEED_PATH="" VDLU_KEY_ID=""
    . "$1"
}

if [ "$MODE" = build-user ]; then
    # unprivileged part of the build step
    cd "$WORK"; load_conf .forgejo/module-ci.conf
    if declare -F prebuilt >/dev/null; then prebuilt; else build; fi
    exit 0
fi

if [ "$MODE" = build ]; then
    cd "$WORK"; load_conf .forgejo/module-ci.conf
    rm -rf "$OUT"; mkdir -p "$OUT"
    git checkout -q -B main "$BASE_SHA"
    printf '.ci-out/\n.ci-home/\n' >> .git/info/exclude
    SRC_SHA="$BASE_SHA" UP_SHA="" DESC=""
    if ! declare -F prebuilt >/dev/null && [ -n "$UPSTREAM_URL" ]; then
        log "merging $UPSTREAM_URL $UPSTREAM_BRANCH"
        git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
        UP_SHA="$(git rev-parse FETCH_HEAD)"
        UP_NAME="${UPSTREAM_URL#https://github.com/}"; UP_NAME="${UP_NAME%.git}"
        if git merge-base --is-ancestor "$UP_SHA" HEAD; then
            log "upstream $UP_SHA already merged"
        else
            git merge -q --no-ff --no-edit -m "Merge $UP_NAME $UPSTREAM_BRANCH ${UP_SHA:0:12}" "$UP_SHA" \
                || die "merge conflict with upstream $UP_SHA: resolve by hand"
        fi
        SRC_SHA="$(git rev-parse HEAD)"
        DESC="$UP_NAME@$UPSTREAM_BRANCH ${UP_SHA:0:12}"
        [ "$SRC_SHA" = "$BASE_SHA" ] || git bundle create -q "$OUT/merge.bundle" "$BASE_SHA..main"
    fi
    printf '%s\n%s\n' "$SRC_SHA" "$UP_SHA" > "$OUT/src"
    mkdir -p "$WORK/.ci-home"
    chown -R "$BUILD_UID:$BUILD_UID" "$WORK" "$OUT"
    log "building $SRC_SHA as uid $BUILD_UID"
    # The build user gets exactly the variables below. The signing secrets go by environment only,
    # never as argv (an `env -i NAME=value` argv is readable in /proc by other local users): take
    # the export off every other variable (not unset: the caller may export a name this script uses,
    # such as WORK, OUT or BUILD_UID), export these with the builtin, and let env(1) drop by name
    # whatever bash cannot un-export (names that are not identifiers, exported functions).
    (   keep=" PATH JAVA_HOME JAVA_HOME_21 JAVA_HOME_26 SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_STORE_PASSWORD SIGN_KEY_PASSWORD SERVER_URL REPOSITORY BASE_SHA GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME "
        drop=()
        for v in $(compgen -e); do
            case "$keep" in *" $v "*) ;; *) export -n "$v" 2>/dev/null || drop+=(-u "$v") ;; esac
        done
        while IFS= read -r -d '' e; do
            [[ "${e%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || drop+=(-u "${e%%=*}")
        done < "/proc/$BASHPID/environ"
        export PATH GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME HOME="$WORK/.ci-home" LANG=C.UTF-8 GRADLE_USER_HOME=/ci/gradle \
            JAVA_HOME="${JAVA_HOME:-}" JAVA_HOME_21="${JAVA_HOME_21:-}" JAVA_HOME_26="${JAVA_HOME_26:-}" \
            ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk \
            SIGN_KEYSTORE_B64="${SIGN_KEYSTORE_B64:-}" SIGN_KEY_ALIAS="${SIGN_KEY_ALIAS:-}" \
            SIGN_STORE_PASSWORD="${SIGN_STORE_PASSWORD:-}" SIGN_KEY_PASSWORD="${SIGN_KEY_PASSWORD:-}" \
            SERVER_URL="$SERVER_URL" REPOSITORY="$REPOSITORY" BASE_SHA="$BASE_SHA" OUT="$OUT"
        exec env ${drop[@]+"${drop[@]}"} setpriv --reuid="$BUILD_UID" --regid="$BUILD_UID" --clear-groups \
            bash "$WORK/.forgejo/module-ci.sh" build-user "$WORK"
    ) || build_rc=$?
    # nothing the build user started outlives the build, whether it failed or not
    setpriv --reuid="$BUILD_UID" --regid="$BUILD_UID" --clear-groups kill -9 -1 2>/dev/null || true
    [ "${build_rc:-0}" = 0 ] || die "build failed"
    [ -f "$OUT/module.zip" ] || die "build left no $OUT/module.zip"
    [ -f "$OUT/upstream-desc" ] && DESC="$(head -n1 "$OUT/upstream-desc")"
    printf '%s\n' "$DESC" > "$OUT/desc"
    log "build done"
    exit 0
fi

[ "$MODE" = release ] || die "unknown mode $MODE"
: "${RELEASE_TOKEN:?}" "${RUN_NUMBER:?}"
API="$SERVER_URL/api/v1/repos/$REPOSITORY"
# The token never goes into argv: curl reads the header from a 0600 file that is removed
# on exit, git gets it through GIT_CONFIG_* environment variables
AUTH_DIR="$(mktemp -d)"
trap 'rm -rf "$AUTH_DIR"' EXIT
AUTH_H="$AUTH_DIR/header"
(umask 077; printf 'Authorization: token %s\n' "$RELEASE_TOKEN" > "$AUTH_H")
auth() { printf 'Authorization: token %s' "$RELEASE_TOKEN"; }
# The VDLU signing key (env VDLU_SIGN_KEY, PEM) the same way: the builtin printf writes it to a 0600
# file in AUTH_DIR, then the variable is dropped, so no process started from here sees it
VDLU_KEY="$AUTH_DIR/vdlu.pem"
(umask 077; printf '%s\n' "${VDLU_SIGN_KEY:-}" > "$VDLU_KEY")
unset VDLU_SIGN_KEY
# Only reads are retried: a retried POST/PATCH/DELETE can repeat a change the forge made.
# Time bounds: the release step must end (and run cleanup) well inside the job's
# timeout-minutes, so the small JSON reads, which are retried or looped, get 60 s per
# attempt; writes (a lost reply is worse than a slow one) and zip transfers keep 600 s.
api() {
    local m="$1" p="$2" r="" t=600; shift 2
    case "$m" in GET|HEAD) r="--retry 3" t=60 ;; esac
    curl -sS --connect-timeout 30 --max-time "$t" --fail-with-body $r -X "$m" -H "@$AUTH_H" "$@" "$API$p"
}
http_code() { curl -sS --connect-timeout 30 --max-time 60 -o /dev/null -w '%{http_code}' -H "@$AUTH_H" "$API$1"; }
git_auth() {
    (n="${GIT_CONFIG_COUNT:-0}"
     export GIT_CONFIG_COUNT=$((n + 1)) "GIT_CONFIG_KEY_$n=http.extraHeader" "GIT_CONFIG_VALUE_$n=$(auth)"
     git "$@")
}

REL="$(pwd)/rel"
rm -rf "$REL"; mkdir -p "$REL"
git_auth clone -q --branch main "$SERVER_URL/$REPOSITORY.git" "$REL/repo"
cd "$REL/repo"
git cat-file -e "$BASE_SHA^{commit}" && git merge-base --is-ancestor "$BASE_SHA" HEAD || die "base $BASE_SHA not in main"
git show "$BASE_SHA:.forgejo/module-ci.conf" > "$REL/module-ci.conf"
# main's tip in this clone (BASE_SHA or later): what was last published there, update.json and the
# VDLU feed, is read from it, since main may have moved on since the dispatched commit
MAIN_SHA="$(git rev-parse HEAD)"
load_conf "$REL/module-ci.conf"
if [ -n "$VDLU_FEED_PATH" ]; then
    [[ "$VDLU_KEY_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "VDLU_FEED_PATH needs VDLU_KEY_ID in module-ci.conf"
    grep -q -- '-----BEGIN PRIVATE KEY-----' "$VDLU_KEY" || die "secret VDLU_SIGN_KEY is not set (or not a PEM private key): nothing published"
fi

# build results are data owned by the build user: regular files only, checked before use
regular() { [ -f "$1" ] && [ ! -L "$1" ] || die "$1 is not a regular file"; }
regular "$OUT/src"; regular "$OUT/desc"; regular "$OUT/module.zip"
{ read -r SRC_SHA; read -r UP_SHA; } < "$OUT/src"
DESC="$(head -c 200 "$OUT/desc" | head -n1 | tr -cd '[:print:]')"
[[ "$SRC_SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad source sha"
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    [[ "$UP_SHA" =~ ^[0-9a-f]{40}$ ]] || die "bad upstream sha"
    git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
    git merge-base --is-ancestor "$UP_SHA" FETCH_HEAD || die "$UP_SHA is not on upstream $UPSTREAM_BRANCH"
    regular "$OUT/merge.bundle"
    git fetch -q "$OUT/merge.bundle" "main:refs/ci/merge"
    [ "$(git rev-parse refs/ci/merge)" = "$SRC_SHA" ] || die "bundle tip differs from the built sha"
    [ "$(git rev-parse "$SRC_SHA^1") $(git rev-parse "$SRC_SHA^2")" = "$BASE_SHA $UP_SHA" ] || die "merge parents differ"
    [ "$(git merge-tree --write-tree "$BASE_SHA" "$UP_SHA")" = "$(git rev-parse "$SRC_SHA^{tree}")" ] || die "merge tree differs"
    [ -z "$(git log --format=%B -1 "$SRC_SHA" | grep -iE 'co-authored|generated')" ] || die "trailer in merge message"
fi
cp "$OUT/module.zip" "$REL/module.zip"

# version and updateJson inside the zip
unzip -p "$REL/module.zip" module.prop > "$REL/built.prop" || die "zip has no module.prop at its root"
BUILT_VERSION="$(prop_get version "$REL/built.prop")"
BUILT_VC="$(prop_get versionCode "$REL/built.prop")"
case "$BUILT_VC" in ''|*[!0-9]*) die "built versionCode '$BUILT_VC' is not a number" ;; esac
VERSION="$(printf '%s' "$BUILT_VERSION" | sed -E 's/-(fork|ci)[0-9]+$//')-ci$RUN_NUMBER"
VC=$((BUILT_VC + VERSION_CODE_OFFSET))
# a release never reuses or lowers the published versionCode (managers and VDLU's hardened profile
# refuse a lower one): the update.json on main's tip names the last release committed there
LAST_VC=0
if git cat-file -e "$MAIN_SHA:$UPDATE_JSON_PATH" 2>/dev/null; then
    LAST_VC="$(git show "$MAIN_SHA:$UPDATE_JSON_PATH" | python3 -I -c 'import json, sys
v = json.load(sys.stdin)["versionCode"]
sys.exit(1) if type(v) is not int or v < 0 else print(v)')" \
        || die "$UPDATE_JSON_PATH at $MAIN_SHA has no integer versionCode"
fi
# a release published by a run that failed before its update.json commit is not on main: the newest
# published release on the forge counts too (its body records "versionCode N"; unreadable = stop)
PUB_VC="$(api GET "/releases?draft=false&pre-release=false&limit=1" | python3 -I -c 'import json, re, sys
rs = json.load(sys.stdin)
if not rs:
    print(0); sys.exit(0)
m = re.search(r"^versionCode ([0-9]+)$", rs[0].get("body") or "", re.M)
sys.exit(1) if not m else print(m.group(1))')" \
    || die "the newest published release on the forge records no versionCode (or the release list is unreadable): nothing published"
[ "$PUB_VC" -le "$LAST_VC" ] || LAST_VC=$PUB_VC
[ "$VC" -gt "$LAST_VC" ] || VC=$((LAST_VC + 1))
[ "$VC" -ge "$VERSION_CODE_FLOOR" ] || die "versionCode $VC is below the floor $VERSION_CODE_FLOOR"
TAG="$(printf '%s' "$VERSION" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
case "$TAG" in v*) ;; *) TAG="v$TAG" ;; esac
ZIP_NAME="$ZIP_PREFIX-$TAG.zip"
UPDATE_URL="$SERVER_URL/$REPOSITORY/raw/branch/main/$UPDATE_JSON_PATH"
ZIP_URL="$SERVER_URL/$REPOSITORY/releases/download/$TAG/$ZIP_NAME"
CHANGELOG_URL=""
if [ -n "$CHANGELOG_PATH" ] && git cat-file -e "$SRC_SHA:$CHANGELOG_PATH" 2>/dev/null; then
    CHANGELOG_URL="$SERVER_URL/$REPOSITORY/raw/commit/$SRC_SHA/$CHANGELOG_PATH"
fi
log "version $VERSION versionCode $VC tag $TAG"
# the update.json main gets once the release is published (cleanup() prints it for a manual fix)
python3 -I - "$REL/update.json" "$VERSION" "$VC" "$ZIP_URL" "$CHANGELOG_URL" <<'PY'
import json, sys
path, version, vc, zip_url, changelog = sys.argv[1:]
with open(path, "w") as f:
    f.write(json.dumps({"version": version, "versionCode": int(vc), "zipUrl": zip_url, "changelog": changelog}, indent=2) + "\n")
PY

python3 -I - "$REL/module.zip" "$REL/$ZIP_NAME" "$VERSION" "$VC" "$UPDATE_URL" <<'PY'
import hashlib, sys, zipfile
src, dst, version, vc, url = sys.argv[1:]
zin = zipfile.ZipFile(src)
lines, seen = [], set()
for line in zin.read("module.prop").decode().splitlines():
    k = line.split("=", 1)[0]
    if k in ("version", "versionCode", "updateJson"):
        if k in seen:
            continue
        seen.add(k)
        line = f"{k}=" + {"version": version, "versionCode": vc, "updateJson": url}[k]
    lines.append(line)
for k, v in (("version", version), ("versionCode", vc), ("updateJson", url)):
    if k not in seen:
        lines.append(f"{k}={v}")
prop = ("\n".join(lines) + "\n").encode()
# install-time checks that pin module.prop (module.prop.sha256, verify scripts listing
# its sha256) are updated by replacing the old hash wherever an entry holds it
old_h = hashlib.sha256(zin.read("module.prop")).hexdigest().encode()
new_h = hashlib.sha256(prop).hexdigest().encode()
with zipfile.ZipFile(dst, "w") as zout:
    for info in zin.infolist():
        data = zin.read(info)
        if info.filename == "module.prop":
            data = prop
        elif old_h in data:
            data = data.replace(old_h, new_h)
            print(f"==> module.prop hash updated in {info.filename}", file=sys.stderr)
        zi = zipfile.ZipInfo(info.filename, info.date_time)
        zi.compress_type, zi.external_attr, zi.create_system = info.compress_type, info.external_attr, info.create_system
        zout.writestr(zi, data, compresslevel=9 if info.compress_type == zipfile.ZIP_DEFLATED else None)
# every <file>.sha256 entry must hold the hash of <file>
z = zipfile.ZipFile(dst)
names = set(z.namelist())
for n in names:
    if n != "module.prop" and old_h != new_h and old_h in z.read(n):
        sys.exit(f"{n} still holds the old module.prop hash")
for n in names:
    if n.endswith(".sha256") and n[:-7] in names:
        want = z.read(n).decode().split()[0].strip()
        got = hashlib.sha256(z.read(n[:-7])).hexdigest()
        if want != got:
            sys.exit(f"sidecar {n} does not match {n[:-7]}")
PY
# VDLU (conf VDLU_FEED_PATH): the feed for exactly this zip, signed, and its manifest in the zip
vdlu_feed() {
    local d="$REL/vdlu" f
    rm -rf "$d"; mkdir -p "$d/bin" "$d/tree" "$d/final"
    # the producer and the verifier from the dispatched commit (never from the build workspace); the
    # zip is build-user data and nothing in it runs here
    for f in vdlu-pack vdlu-sign ed25519-verify; do git show "$BASE_SHA:.forgejo/vdlu/$f" > "$d/bin/$f"; done
    git show "$BASE_SHA:module/vdlu/vdlu-verify" > "$d/bin/vdlu-verify"
    cp "$d/bin/ed25519-verify" "$d/bin/ed25519-mini"; chmod 0755 "$d/bin/"*
    vdlu_tree "$REL/$ZIP_NAME" "$d/tree"
    local kr="$d/tree/vdlu/keyring"
    [ "$(find "$kr" -name '*.pub' | wc -l)" = 1 ] && [ -f "$kr/$VDLU_KEY_ID.pub" ] \
        || die "the zip's vdlu/keyring must hold exactly $VDLU_KEY_ID.pub"
    openssl pkey -in "$VDLU_KEY" -pubout -outform DER 2>/dev/null | tail -c 32 > "$d/key.pub" || die "VDLU_SIGN_KEY is not a usable key"
    cmp -s "$d/key.pub" "$kr/$VDLU_KEY_ID.pub" || die "VDLU_SIGN_KEY is not the private half of vdlu/keyring/$VDLU_KEY_ID.pub"
    local modid prev=()
    modid="$(prop_get id "$d/tree/module.prop")"
    if git cat-file -e "$MAIN_SHA:$VDLU_FEED_PATH/manifest.json" 2>/dev/null; then
        git show "$MAIN_SHA:$VDLU_FEED_PATH/manifest.json" > "$d/prev.json"; prev=(--prev "$d/prev.json")
    fi
    env -u RELEASE_TOKEN python3 -I "$d/bin/vdlu-pack" "$d/tree" "$d/feed" "$modid" "$VC" \
        --version-name "$VERSION" --channel stable "${prev[@]}" >&2 || die "vdlu-pack failed"
    # delete[] of earlier releases stays, so a device that skipped a release still removes its deletions
    if [ -f "$d/prev.json" ]; then
        python3 -I - "$d/feed/manifest.json" "$d/prev.json" <<'PY' || die "delete[] carry-over failed"
import json, sys
m, prev = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
now = {f["path"] for f in m["files"]}
m["delete"] = sorted(set(m["delete"]) | {p for p in prev.get("delete", []) if isinstance(p, str) and p not in now})
open(sys.argv[1], "w").write(json.dumps(m, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
PY
    fi
    env -u RELEASE_TOKEN TMPDIR="$AUTH_DIR" sh "$d/bin/vdlu-sign" "$d/feed/manifest.json" "$VDLU_KEY" "$VDLU_KEY_ID" >&2 \
        || die "vdlu-sign failed"
    # the device's check: the dispatched commit's vdlu-verify, the zip's keyring, only this key id
    env -u RELEASE_TOKEN TMPDIR="$AUTH_DIR" VDLU_KEYID_ALLOW="$VDLU_KEY_ID" sh "$d/bin/vdlu-verify" "$d/feed/manifest.json" "$kr" >&2 \
        || die "the signed manifest fails vdlu-verify with the shipped key"
    python3 -I - "$d/feed/manifest.json" "$VC" "$modid" <<'PY' || die "signed manifest: wrong version or module"
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if m["version"] == int(sys.argv[2]) and m["module"] == sys.argv[3] else 1)
PY
    # vdlu-pack leaves vdlu/baseline.json and *.sha256 out of the manifest, so adding them changes no
    # file it covers
    python3 -I - "$REL/$ZIP_NAME" "$d/feed/manifest.json" <<'PY' || die "baseline.json not added to the zip"
import hashlib, os, sys, zipfile
zp, mp = sys.argv[1:]
data = open(mp, "rb").read()
add = {"vdlu/baseline.json": data,
       "vdlu/baseline.json.sha256": (hashlib.sha256(data).hexdigest() + "  baseline.json\n").encode()}
zin = zipfile.ZipFile(zp)
when = zin.getinfo("module.prop").date_time
with zipfile.ZipFile(zp + ".new", "w") as zout:
    for info in zin.infolist():
        if info.filename not in add:
            zout.writestr(info, zin.read(info), compresslevel=9 if info.compress_type == zipfile.ZIP_DEFLATED else None)
    for name, b in add.items():
        zi = zipfile.ZipInfo(name, when)
        zi.compress_type, zi.external_attr, zi.create_system = zipfile.ZIP_DEFLATED, 0o100644 << 16, 3
        zout.writestr(zi, b, compresslevel=9)
os.replace(zp + ".new", zp)
PY
    # the signed files[] is what a pack of the final zip gives: the baseline matches the shipped bytes
    vdlu_tree "$REL/$ZIP_NAME" "$d/final"
    env -u RELEASE_TOKEN python3 -I "$d/bin/vdlu-pack" "$d/final" "$d/check" "$modid" "$VC" >/dev/null 2>&1 || die "re-pack failed"
    python3 -I - "$d/feed/manifest.json" "$d/check/manifest.json" "$d/final/vdlu/baseline.json" <<'PY' || die "the signed manifest does not match the final zip"
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
sys.exit(0 if a["files"] == b["files"] and open(sys.argv[1], "rb").read() == open(sys.argv[3], "rb").read() else 1)
PY
    log "VDLU feed: version $VC, $(find "$d/feed/blobs" -type f | wc -l) blobs, signed by $VDLU_KEY_ID"
}
# vdlu_tree <zip> <dir>: the zip's files with their zip modes; build-user data, so only relative
# names without '..', regular files and directories
vdlu_tree() {
    python3 -I - "$1" "$2" <<'PY' || die "unsafe or unreadable zip entries"
import os, stat, sys, zipfile
z, out = zipfile.ZipFile(sys.argv[1]), sys.argv[2]
for i in z.infolist():
    n, mode = i.filename, i.external_attr >> 16
    parts = n.rstrip("/").split("/")
    if n.startswith("/") or "\\" in n or any(p in ("", ".", "..") for p in parts):
        sys.exit("unsafe entry name: " + n)
    dst = os.path.join(out, *parts)
    if i.is_dir():
        os.makedirs(dst, exist_ok=True); continue
    if mode and not stat.S_ISREG(mode):
        sys.exit("not a regular file: " + n)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(z.read(i))
    os.chmod(dst, 0o755 if mode & 0o111 else 0o644)
PY
}
[ -z "$VDLU_FEED_PATH" ] || vdlu_feed
ZIP="$REL/$ZIP_NAME"
unzip -tq "$ZIP" >/dev/null || die "zip test failed"
[ "$(unzip -p "$ZIP" module.prop | prop_get updateJson /dev/stdin)" = "$UPDATE_URL" ] || die "updateJson not set"
ZIP_SHA="$(sha "$ZIP")"
log "zip $ZIP_NAME sha256 $ZIP_SHA"

RELEASE_ID="" PUBLISHED=0 DRAFT_REQUESTED=0 CHECKED=0
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$RELEASE_ID" ] && [ "$DRAFT_REQUESTED" = 1 ]; then
        # a rejected request, or one the forge applied with its reply lost: no id to delete by
        log "failure: the draft request for $TAG failed or its reply was lost; the forge may hold that draft: check it by hand"
    fi
    if [ "$rc" -ne 0 ] && [ -n "$RELEASE_ID" ] && [ "$PUBLISHED" != 1 ]; then
        # a publish PATCH whose reply was lost may still have been applied: delete only a confirmed draft
        draft="$(api GET "/releases/$RELEASE_ID" | jget draft || true)"
        if [ "$draft" = True ]; then
            log "failure before publish: deleting draft release $RELEASE_ID"
            api DELETE "/releases/$RELEASE_ID" >/dev/null || true
        else
            log "failure: release $RELEASE_ID not deleted (draft state '${draft:-unreadable}'): check it by hand"
        fi
    fi
    if [ "$rc" -ne 0 ] && [ "$PUBLISHED" = 1 ]; then
        # the release is public: say how to bring the update feed in line with it
        if [ "$CHECKED" = 1 ]; then
            log "failure after publishing $TAG: $UPDATE_URL did not confirm versionCode $VC"
            log "recovery: unless it answers $VC by now, commit $UPDATE_JSON_PATH on main with the content below, or dispatch the workflow again (it releases under a new tag)"
            [ -z "${VDLU_FEED_PATH:-}" ] || log "the VDLU feed $VDLU_FEED_PATH on main still serves the previous release (its files were in this runner's workspace): the next dispatch publishes a new one"
            cat "$REL/update.json" >&2
        else
            log "failure after publishing $TAG: the published release failed the check above: delete release $TAG and tag $TAG by hand ($UPDATE_JSON_PATH on main still names the previous release)"
        fi
    fi
    rm -rf "$AUTH_DIR"
    exit "$rc"
}
trap cleanup EXIT

# draft release, upload, download back, verify
[ "$(http_code "/releases/tags/$TAG")" = 404 ] || die "release $TAG exists (or the check failed)"
[ "$(http_code "/tags/$TAG")" = 404 ] || die "tag $TAG exists (or the check failed)"
BODY="$(printf 'Built by module-release #%s from %s (%s).\nversionCode %s\nsha256 %s  %s\nupdateJson %s' \
    "$RUN_NUMBER" "${SRC_SHA:0:12}" "${DESC:-fork main}" "$VC" "$ZIP_SHA" "$ZIP_NAME" "$UPDATE_URL")"
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"target_commitish":"main","name":sys.argv[2],"body":sys.argv[3],"draft":True}))' "$TAG" "$ZIP_PREFIX $VERSION" "$BODY")"
DRAFT_REQUESTED=1
RELEASE_ID="$(api POST /releases -H 'Content-Type: application/json' -d "$REQ" | jget id)"
log "draft release $RELEASE_ID, uploading $ZIP_NAME"
ASSET_ID="$(api POST "/releases/$RELEASE_ID/assets?name=$ZIP_NAME" -F "attachment=@$ZIP" | jget id)"
ASSET_URL="$(api GET "/releases/$RELEASE_ID/assets/$ASSET_ID" | jget browser_download_url)"
log "downloading back $ASSET_URL"
curl -sSL --connect-timeout 30 --max-time 600 --fail-with-body -H "@$AUTH_H" -o "$REL/back.zip" "$ASSET_URL"
[ "$(sha "$REL/back.zip")" = "$ZIP_SHA" ] || die "downloaded asset sha256 differs"
unzip -tq "$REL/back.zip" >/dev/null || die "downloaded asset fails zip test"

# push the merge (fast-forward only), publish at the built commit
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    log "pushing merge $SRC_SHA"
    git_auth push -q origin "$SRC_SHA:refs/heads/main" || die "push of the merge failed (main moved?)"
fi
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"draft":False,"target_commitish":sys.argv[1]}))' "$SRC_SHA")"
if ! api PATCH "/releases/$RELEASE_ID" -H 'Content-Type: application/json' -d "$REQ" >/dev/null; then
    # the forge may have applied the publish and lost the reply: go on once it reports the release published
    [ "$(api GET "/releases/$RELEASE_ID" | jget draft || true)" = False ] || die "publish of release $RELEASE_ID failed"
    log "the publish reply was lost, but release $RELEASE_ID is published: continuing"
fi
PUBLISHED=1
TAG_SHA="$(api GET "/tags/$TAG" | jget commit.sha)"
[ "$TAG_SHA" = "$SRC_SHA" ] || die "published tag $TAG points at $TAG_SHA, expected $SRC_SHA"
for i in 1 2 3 4 5; do curl -fsSL --connect-timeout 30 --max-time 180 -o "$REL/anon.zip" "$ZIP_URL" && break; sleep 5; done
[ "$(sha "$REL/anon.zip")" = "$ZIP_SHA" ] || die "anonymous download of $ZIP_URL differs"
CHECKED=1
log "published $TAG"

# update.json (and the fork-owned module.prop) in main
git_auth fetch -q origin main
git checkout -q -B main FETCH_HEAD
mkdir -p "$(dirname "$UPDATE_JSON_PATH")"
cp "$REL/update.json" "$UPDATE_JSON_PATH"
git add -- "$UPDATE_JSON_PATH"
if [ -n "$VDLU_FEED_PATH" ]; then
    # the feed is this release's pack whole: blobs no longer referenced by its manifest go
    rm -rf "$VDLU_FEED_PATH"; mkdir -p "$(dirname "$VDLU_FEED_PATH")"
    cp -R "$REL/vdlu/feed" "$VDLU_FEED_PATH"
    git add -A -- "$VDLU_FEED_PATH"
fi
if declare -F release_files >/dev/null; then
    RELEASE_FILES="" ZIP_SIZE="$(stat -c %s "$ZIP")"
    release_files
    for f in $RELEASE_FILES; do git add -- "$f"; done
fi
if [ -n "$SYNC_ROOT_PROP" ]; then
    sed -i -E "s|^version=.*|version=$(sedq "$VERSION")|; s|^versionCode=.*|versionCode=$VC|; s|^updateJson=.*|updateJson=$(sedq "$UPDATE_URL")|" "$SYNC_ROOT_PROP"
    git add -- "$SYNC_ROOT_PROP"
fi
git commit -q -m "update.json: $VERSION (versionCode $VC)"
git_auth push -q origin HEAD:refs/heads/main || die "push of update.json failed"
got=""
for i in 1 2 3 4 5; do
    got="$(curl -fsS --connect-timeout 30 --max-time 60 "$UPDATE_URL" | jget versionCode || true)"
    [ "$got" = "$VC" ] && break; sleep 5
done
[ "$got" = "$VC" ] || die "$UPDATE_URL answers versionCode '$got', expected $VC"
log "done: $UPDATE_URL -> $TAG"
