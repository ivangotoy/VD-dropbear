#!/system/bin/sh
# ======================================================================
#  VD Dropbear  ::  standalone, configurable rooted SSH daemon
#  A private SSH server for KernelSU/APatch/Magisk. No invasive ADB exposure.
#  Manager "Action" button: (re)launch the single daemon.
#
#  Copyright (C) 2026  VD171
#  SPDX-License-Identifier: Apache-2.0
#
#  Licensed under the Apache License, Version 2.0; you may obtain a copy at
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Site           : https://vd171.ru
#  Site           : https://vd.priv8.ru
#  Source         : https://github.com/VD171/VD-dropbear
#  GitHub         : @VD171 https://github.com/VD171
#  XDA-Developers : @VD171 https://xdaforums.com/m/vd171.4699873/
#  XDA thread     : https://xdaforums.com/t/VD-Dropbear.4808524/
#  Telegram       : @VD_Priv8 https://t.me/VD_Priv8
#  Channel        : @Priv8_VD https://t.me/Priv8_VD
#  Discord        : @VD.Priv8 https://discord.com/users/1296831918989639721
#  E-mail         : vd.priv8@pm.me
# ======================================================================
# Never reads stdin (the KSU manager keeps it open and would hang here), and
# the daemon is spawned in its own session so the manager's action tree drains.

exec 0</dev/null
MODDIR=${0%/*}
. "$MODDIR/common/vddropbear.sh"

echo "VD Dropbear: (re)launching the daemon..."
vddb_restart

vddb_load_config
# the launcher runs in the background: wait (max ~3 s) until the recorded pid is the
# daemon itself or has exited, so the report below is not taken mid-launch
if [ "$ENABLED" = "1" ]; then
    _i=0
    while [ "$_i" -lt 15 ]; do
        _p="$(cat "$VDDB_PIDFILE" 2>/dev/null)"
        case "$_p" in ''|*[!0-9]*) ;; *)
            [ "$(cat "/proc/$_p/comm" 2>/dev/null)" = "$VDDB_PROC" ] && break
            vddb_pid_alive "$_p" || break ;;
        esac
        _i=$((_i+1)); "$VDDB_TOYBOX" sleep 0.2 2>/dev/null
    done
fi
if vddb_is_running; then
    echo "OK, running"
    echo "  pid    : $(vddb_pid)"
    echo "  port   : $PORT"
    echo "  listen : $(vddb_listen_summary)"
    echo "  mode   : $([ "$START_IN_BFU" = 1 ] && echo 'BFU (secrets on DE storage)' || echo 'AFU (secrets on CE storage)')"
else
    echo "FAILED: the daemon is not running."
    echo "  see the log: $VDDB_LOG"
fi
