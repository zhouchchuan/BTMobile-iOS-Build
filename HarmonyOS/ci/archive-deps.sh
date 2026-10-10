#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/native-deps"
mkdir -p "$D"
get_source() {
  local url=$1 name=$2 hash=$3
  if [ ! -f "$D/$name/.verified-source" ]; then
    curl -fL --retry 4 "$url" -o "$D/$name.tar.gz"
    echo "$hash  $D/$name.tar.gz" | sha256sum -c -
    mkdir -p "$D/$name"
    tar -xf "$D/$name.tar.gz" -C "$D/$name" --strip-components=1
    touch "$D/$name/.verified-source"
  fi
}
get_source https://codeload.github.com/ip7z/7zip/tar.gz/refs/tags/26.04 sevenzip-26.04 48fdc6dfe879ee2db867bb07f19c4a9406bfea01d51f48785b6c7a137881e25c
get_source https://codeload.github.com/rikyoz/bit7z/tar.gz/refs/tags/v4.1.0 bit7z 82393783f81d5e4eef8d6657c9cf7fa8b66c3e0e7a58328a7c101eafbf84f308
python3 "$ROOT/ci/patch-archive.py" "$D/bit7z"
if [ "${1:-ohos}" = host ]; then
  OUT="$D/host-archive"
  CC=cc CXX=c++
else
  OUT="$D/prefix/lib"
  CC="$OHOS_NDK_HOME/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/sysroot"
  CXX="$OHOS_NDK_HOME/llvm/bin/clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/sysroot"
fi
mkdir -p "$OUT"
if [ ! -f "$OUT/.7zip-26.04-v1" ]; then
  make -C "$D/sevenzip-26.04/CPP/7zip/Bundles/Format7zF" -f makefile.gcc -j3 \
    O="$OUT/obj-7zip" CC="$CC" CXX="$CXX" CFLAGS_WARN_WALL='-Wall -Wextra' \
    LDFLAGS_STATIC_3='-Wl,-soname,lib7zip.so'
  cp "$OUT/obj-7zip/7z.so" "$OUT/lib7zip.so"
  touch "$OUT/.7zip-26.04-v1"
fi
if [ "${1:-ohos}" != host ]; then
  mkdir -p "$ROOT/entry/libs/arm64-v8a"
  cp "$OUT/lib7zip.so" "$ROOT/entry/libs/arm64-v8a/"
fi
NOTICES="$ROOT/entry/src/main/resources/rawfile/licenses"
mkdir -p "$NOTICES/7zip" "$NOTICES/bit7z"
cp "$D/sevenzip-26.04/DOC/License.txt" "$NOTICES/7zip/"
cp "$D/sevenzip-26.04/DOC/unRarLicense.txt" "$NOTICES/7zip/"
cp "$D/bit7z/LICENSE" "$NOTICES/bit7z/"
# Ship patched MPL file and patch recipe, plus the exact corresponding LGPL
# library source with the cloud artifact. Private signing material is excluded.
cp "$D/bit7z/src/internal/opencallback.cpp" "$NOTICES/bit7z/"
cp "$ROOT/ci/patch-archive.py" "$NOTICES/bit7z/"
