#!/bin/sh
# Hot-storage file inventory: prove a deploy moved or lost nothing.
#
#   hot_filelist.sh snapshot <out.tsv.gz>           # path<TAB>size, sorted
#   hot_filelist.sh compare  <before.tsv.gz> [now]  # every file in BEFORE must
#                                                   # still exist, same size
#
# Recording continues during a deploy, so new files are expected and
# ignored. The only file allowed to change size is a camera's
# stream.m3u8 (the rolling live playlist). Exit 1 on any missing or changed file.
set -eu
HOT="${HOT:-/mnt/storage/hot}"

snapshot() {
  (cd "$HOT" && find . -type f -printf '%p\t%s\n' | LC_ALL=C sort) | gzip > "$1"
  echo "$(zcat "$1" | wc -l) files -> $1"
}

compare() {
  before="$1"; now="${2:-}"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  if [ -z "$now" ]; then now="$tmp/now.tsv.gz"; snapshot "$now" >/dev/null; fi
  zcat "$before" | grep -v '/stream\.m3u8	' > "$tmp/b"
  zcat "$now"    | grep -v '/stream\.m3u8	' > "$tmp/n"
  # Lines present before but not now = missing file or changed size.
  LC_ALL=C comm -23 "$tmp/b" "$tmp/n" > "$tmp/gone"
  n=$(wc -l < "$tmp/gone")
  echo "before: $(wc -l < "$tmp/b")  now: $(wc -l < "$tmp/n")  missing/changed: $n"
  if [ "$n" -ne 0 ]; then head -50 "$tmp/gone"; exit 1; fi
  echo "OK: every file from before is still there, unchanged."
}

case "${1:-}" in
  snapshot) snapshot "$2" ;;
  compare)  compare "$2" "${3:-}" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
