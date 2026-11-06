#!/usr/bin/env bash
# Copy the source clips a run decodes into LAB_MEDIA_HOSTPATH on a worker.
#
# The clips are not in this repo (they are large, and not ours to redistribute).
# Any 1080p60 and 2160p60 source works, but the published density numbers were
# measured with the two clips named in config/lab.env - a different source
# changes decoder cost and shifts the achievable stream count.
#
# Run FROM THE CONTROLLER, with the clips available locally:
#   scripts/stage-media.sh /path/to/clip.mp4 [more clips...] [-- NODE]
#
# With no clips given, it only lists what the worker already has.
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

NODE="$LAB_DEFAULT_NODE"
CLIPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) NODE="$2"; shift 2 ;;
    *)  CLIPS+=("$1"); shift ;;
  esac
done

lab_resolve_node "$NODE"
DEST="${LAB_MEDIA_HOSTPATH:-/opt/mxl-media}"

if [[ ${#CLIPS[@]} -gt 0 ]]; then
  for clip in "${CLIPS[@]}"; do
    [[ -f "$clip" ]] || { echo "FATAL: no such file: $clip" >&2; exit 2; }
  done
  echo "== copying ${#CLIPS[@]} clip(s) to $NODE:$DEST =="
  "${LAB_REMOTE_SSH[@]}" "$TARGET" "$LAB_REMOTE_SUDO mkdir -p '$DEST'"
  # Land in the user's home first, then move as root: $DEST is root-owned.
  for clip in "${CLIPS[@]}"; do
    base="$(basename "$clip")"
    scp -q "$clip" "$TARGET:/tmp/$base"
    "${LAB_REMOTE_SSH[@]}" "$TARGET" "$LAB_REMOTE_SUDO install -m 0644 -o root -g root '/tmp/$base' '$DEST/$base' && rm -f '/tmp/$base'"
    echo "  staged $base"
  done
fi

echo "== clips on $NODE:$DEST =="
ssh -o BatchMode=yes "$TARGET" "ls -la '$DEST' 2>/dev/null || echo '  (directory absent)'"
echo
echo "config/lab.env expects:"
echo "  LAB_INPUT_1080P=${LAB_INPUT_1080P:-unset}"
echo "  LAB_INPUT_4K=${LAB_INPUT_4K:-unset}"

# A filename and MP4 header are not enough: the workload image is deliberately
# minimal and may lack a demuxer or decoder required by an otherwise-valid clip.
# Probe the configured 1080p input with the exact image before a campaign spends
# four minutes waiting for Pods that can never become Ready.
IMAGE="${LAB_IMAGE:-localhost/mxl-ffmpeg-full:v1}"
INPUT="${LAB_INPUT_1080P:-}"
if [[ -n "$INPUT" ]] && ssh -o BatchMode=yes "$TARGET" "test -f '$DEST/$INPUT'"; then
  echo "== validating $INPUT with $IMAGE =="
  "${LAB_REMOTE_SSH[@]}" "$TARGET" \
    "$LAB_REMOTE_SUDO nerdctl --namespace k8s.io run --rm --net host -v '$DEST:/media:ro' --entrypoint /opt/bin/ffprobe '$IMAGE' -v error -show_entries stream=codec_name,width,height,r_frame_rate -of default=noprint_wrappers=1 '/media/$INPUT'"
fi
