#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/native-deps"
mkdir -p "$D/prefix" "$D/headers/nlohmann"
fetch() { curl --fail --location --retry 4 "$1" -o "$2"; }
unpack() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }
if [ ! -f "$D/libtorrent/CMakeLists.txt" ]; then
  git clone https://github.com/arvidn/libtorrent.git "$D/libtorrent"
  git -C "$D/libtorrent" checkout 75a08775ba32bdb62157f9e49a786ecdd9f0a0fa
  git -C "$D/libtorrent" submodule update --init --recursive
fi
python3 "$ROOT/ci/patch-ohos-network.py" "$D/libtorrent"
if [ ! -f "$D/boost/boost/version.hpp" ]; then
  fetch https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2 "$D/boost.tar.bz2"
  unpack "$D/boost.tar.bz2" "$D/boost"
fi
# OHOS has pthreads but no pthread cancellation API. Keep nanosleep and skip
# only the cancellation-state wrapper, as Boost already does on Android.
BOOST_SLEEP="$D/boost/boost/core/detail/sp_thread_sleep.hpp"
if ! grep -q BTMOBILE_OHOS "$BOOST_SLEEP"; then
  sed -i 's/!defined(__ANDROID__)/!defined(__ANDROID__) \&\& !defined(BTMOBILE_OHOS)/g' "$BOOST_SLEEP"
fi
fetch https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp "$D/headers/nlohmann/json.hpp"
fetch https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.18.3/httplib.h "$D/headers/httplib.h"
TC="$OHOS_NDK_HOME/build/cmake/ohos.toolchain.cmake"
ARGS=(-DCMAKE_TOOLCHAIN_FILE="$TC" -DOHOS_ARCH=arm64-v8a -DOHOS_PLATFORM=OHOS -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$D/prefix" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF)
if [ ! -f "$D/prefix/lib/libcrypto.a" ]; then
  fetch https://github.com/openssl/openssl/releases/download/openssl-3.0.16/openssl-3.0.16.tar.gz "$D/openssl.tar.gz"
  unpack "$D/openssl.tar.gz" "$D/openssl"
  (
    cd "$D/openssl"
    export CC="$OHOS_NDK_HOME/llvm/bin/clang --target=aarch64-linux-ohos --sysroot=$OHOS_NDK_HOME/sysroot"
    export AR="$OHOS_NDK_HOME/llvm/bin/llvm-ar" RANLIB="$OHOS_NDK_HOME/llvm/bin/llvm-ranlib"
    perl Configure linux-aarch64 no-shared no-tests no-asm -fPIC --prefix="$D/prefix" --libdir=lib
    make -j3
    make install_sw
  )
fi
if [ ! -f "$D/prefix/lib/libz.a" ]; then
  fetch https://zlib.net/fossils/zlib-1.3.1.tar.gz "$D/zlib.tar.gz"
  unpack "$D/zlib.tar.gz" "$D/zlib"
  cmake -S "$D/zlib" -B "$D/zlib-build" "${ARGS[@]}"
  cmake --build "$D/zlib-build" -j3
  cmake --install "$D/zlib-build"
fi
if [ ! -f "$D/prefix/lib/liblzma.a" ]; then
  fetch https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.gz "$D/xz.tar.gz"
  unpack "$D/xz.tar.gz" "$D/xz"
  cmake -S "$D/xz" -B "$D/xz-build" "${ARGS[@]}" -DBUILD_TESTING=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF
  cmake --build "$D/xz-build" -j3
  cmake --install "$D/xz-build"
fi
if [ ! -f "$D/prefix/.archive-crypto-v2" ]; then
  fetch https://github.com/libarchive/libarchive/releases/download/v3.7.7/libarchive-3.7.7.tar.xz "$D/archive.tar.xz"
  unpack "$D/archive.tar.xz" "$D/archive"
  cmake -S "$D/archive" -B "$D/archive-build" "${ARGS[@]}" -DCMAKE_PREFIX_PATH="$D/prefix" -DOPENSSL_ROOT_DIR="$D/prefix" -DOPENSSL_USE_STATIC_LIBS=ON -DOPENSSL_INCLUDE_DIR="$D/prefix/include" -DOPENSSL_SSL_LIBRARY="$D/prefix/lib/libssl.a" -DOPENSSL_CRYPTO_LIBRARY="$D/prefix/lib/libcrypto.a" -DZLIB_INCLUDE_DIR="$D/prefix/include" -DZLIB_LIBRARY="$D/prefix/lib/libz.a" -DLIBLZMA_INCLUDE_DIR="$D/prefix/include" -DLIBLZMA_LIBRARY="$D/prefix/lib/liblzma.a" -DENABLE_TEST=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_BZIP2=OFF -DENABLE_LZ4=OFF -DENABLE_ZSTD=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_ICONV=OFF -DENABLE_ACL=OFF -DENABLE_XATTR=OFF
  cmake --build "$D/archive-build" -j3
  cmake --install "$D/archive-build"
  touch "$D/prefix/.archive-crypto-v2"
fi
find "$D/prefix/lib" -name '*.a' -printf '%f\n'
NOTICES="$ROOT/entry/src/main/resources/rawfile/licenses"
mkdir -p "$NOTICES"
for component in libtorrent boost openssl archive xz zlib; do
  mkdir -p "$NOTICES/$component"
  find "$D/$component" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' \) -exec cp {} "$NOTICES/$component/" \;
done
cp "$D/zlib/zlib.h" "$NOTICES/zlib/zlib-license-header.txt"
cp "$ROOT/LICENSE.txt" "$NOTICES/BTMobile-iTorrent-LICENSE.txt"
fetch https://raw.githubusercontent.com/nlohmann/json/v3.11.3/LICENSE.MIT "$NOTICES/nlohmann-json-LICENSE.txt"
fetch https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.18.3/LICENSE "$NOTICES/cpp-httplib-LICENSE.txt"
