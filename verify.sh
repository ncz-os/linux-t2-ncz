#!/bin/sh
# verify.sh LINUX_GIT_DIR
# Check that patches/ matches the shipped build record (except the documented
# 9011 description change), apply the series to v7.3-rc7 exactly as build.sh
# does, and print the resulting git tree id.
set -eu
LINUX_GIT_DIR=${1:?usage: verify.sh LINUX_GIT_DIR (a linux.git clone with tag v7.3-rc7)}
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=24a19b953e2a3d0ea5a8c4951a0ab8f32720c907
EXPECT_TREE=451b5dfee3eb77e15dac561766000bc3ec2e4f41
REWORDED=9011-PCI-AER-skip-ANFE-unmask-on-Apple-T2-SEP.patch

got=$(git -C "$LINUX_GIT_DIR" rev-parse 'v7.3-rc7^{commit}')
[ "$got" = "$BASE" ] || { echo "v7.3-rc7 is $got, expected $BASE" >&2; exit 1; }

fail=0
grep '\.patch$' "$HERE/config/PROVENANCE-7.3.0-rc7-t2-ncz.shipped" | while read -r sum name; do
  name=${name#./}
  [ "$name" = "$REWORDED" ] && continue
  echo "$sum  $HERE/patches/$name"
done | sha256sum -c --quiet - || fail=1
n=$(ls "$HERE"/patches/*.patch | wc -l)
[ "$n" -eq 24 ] || { echo "expected 24 patches, found $n" >&2; fail=1; }
[ "$fail" = 0 ] || exit 1
echo "patch hashes match the build record (23 byte-identical, $REWORDED reworded description)"

WORK=$(mktemp -d "${VERIFY_TMPDIR:-$HERE}/.verify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/src"
git -C "$LINUX_GIT_DIR" archive "$BASE" | tar -x -C "$WORK/src"
for p in $(ls "$HERE"/patches/*.patch | sort); do
  (cd "$WORK/src" && patch -p1 -s <"$p")
done
tree=$(cd "$WORK/src" && git init -q && git add -A && git write-tree)
echo "applied tree: $tree"
[ "$tree" = "$EXPECT_TREE" ] && echo "OK: matches the shipped source tree" || { echo "MISMATCH (expected $EXPECT_TREE)" >&2; exit 1; }
