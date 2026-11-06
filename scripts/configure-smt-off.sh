#!/usr/bin/env bash
# Persistently hide SMT siblings from Linux when BIOS access is unavailable.
# Run from the controller, then reboot the worker when prompted.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/config/lab.env"
# shellcheck source=/dev/null
source "$ROOT/config/nodes.env"
# shellcheck source=lib/remote-admin.sh
source "$ROOT/scripts/lib/remote-admin.sh"
# shellcheck source=lib/inventory.sh
source "$ROOT/scripts/lib/inventory.sh"

lab_resolve_node "${1:-$LAB_DEFAULT_NODE}"

echo "== configuring Linux nosmt on $NODE ($HOST) =="
"${LAB_REMOTE_SSH[@]}" "$TARGET" "$LAB_REMOTE_SUDO sh -c 'cat > /etc/default/grub.d/99-mxl-nosmt.cfg <<\"EOF\"
GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT nosmt\"
EOF
update-grub
test -f /etc/default/grub.d/99-mxl-nosmt.cfg'"

echo
echo "Configured persistent kernel option: nosmt"
echo "Reboot $NODE, then verify from the controller:"
echo "  scripts/check-bios.sh $NODE"
echo "Expected: Hyper-Threading disabled, 1 thread per core."