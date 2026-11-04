#!/bin/bash
# Лента подключений и отключений томов за последние N минут (по умолчанию 10):
# что делала наша программа (MountTrace), что видел diskarbitrationd и что писало ядро
# про SMB. Finder тоже ходит через diskarbitrationd, поэтому его отключение видно рядом
# с нашим — и видно, у кого между «просьбой» и «готово» прошли секунды.
#
#   bash scripts/mount_trace.sh        # последние 10 минут
#   bash scripts/mount_trace.sh 30     # последние 30 минут

MINUTES="${1:-10}"

/usr/bin/log show --last "${MINUTES}m" --style compact --info --predicate '
  (category == "MountTrace")
  OR (process == "diskarbitrationd" AND NOT eventMessage CONTAINS "registered callback" AND (
        eventMessage CONTAINS "solicitation"
     OR eventMessage CONTAINS "unmounted disk"
     OR eventMessage CONTAINS "mounted disk"
     OR eventMessage CONTAINS "approv"
     OR eventMessage CONTAINS "dissent"))
  OR (process == "kernel" AND (eventMessage CONTAINS[c] "smbfs" OR eventMessage CONTAINS[c] "smb_"))
  OR (process == "NetAuthSysAgent" OR process == "NetAuthAgent")
' 2>/dev/null \
| /usr/bin/grep -v '^Timestamp' \
| sed -E 's/\[com\.apple\.DiskArbitration\.diskarbitrationd:default\] *//; s/ +queued solicitation, id = [0-9A-Fa-f:]+, kind = /  просьба: /' \
| cut -c1-220
