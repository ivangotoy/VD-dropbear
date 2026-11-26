
# fork: VDLU feed and key on every flash (appended to customize.sh by .forgejo/module-ci.conf build())
# The shipped vdlu/config.default names the only feed and signing key this zip trusts, and a flash
# installs a whole tree: an existing VDLU config (an earlier install, or another build's feed and
# key) gets source= and key_id= from config.default and profile=hardened, loses tools_source= and
# pubkey_dir=, and keeps its other keys; any pending flashless transaction, a curl adopted by an
# earlier install (tools/) and current.json are dropped, current.json restarting from this zip's
# signed baseline.json when it has one. blobs/ is kept (every blob is hash-checked before use).
VDLU_DIR="${VDDB_ROOT:-}/data/adb/vddropbear/vdlu"
if [ -f "$VDLU_DIR/config" ] && [ -f "$MODPATH/vdlu/config.default" ]; then
    _src=$(sed -n 's/^source=//p' "$MODPATH/vdlu/config.default" | head -n 1)
    _kid=$(sed -n 's/^key_id=//p' "$MODPATH/vdlu/config.default" | head -n 1)
    { grep -v -E '^[[:space:]]*(source|key_id|profile|tools_source|pubkey_dir)[[:space:]]*=' "$VDLU_DIR/config"
      echo "source=$_src"
      [ -z "$_kid" ] || echo "key_id=$_kid"
      echo "profile=hardened"
    } > "$VDLU_DIR/config.new" && mv -f "$VDLU_DIR/config.new" "$VDLU_DIR/config"
    rm -rf "$VDLU_DIR/target.json" "$VDLU_DIR/plan.tsv" "$VDLU_DIR/plan.del" "$VDLU_DIR/journal.json" \
        "$VDLU_DIR/cancel" "$VDLU_DIR/staged" "$VDLU_DIR/.work" "$VDLU_DIR/tools" "$VDLU_DIR/current.json"
    [ ! -f "$MODPATH/vdlu/baseline.json" ] || cp -f "$MODPATH/vdlu/baseline.json" "$VDLU_DIR/current.json"
    ui_print "- VDLU updater: feed $_src"
fi
