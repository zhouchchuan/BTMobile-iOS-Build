#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/native-deps/media"
P="$D/prefix"
mkdir -p "$D" "$P"
fetch() { if [ ! -f "$D/$2" ]; then curl -fL --retry 4 "$1" -o "$D/$2"; fi; echo "$3  $D/$2" | sha256sum -c -; }
fetch https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz dav1d-1.5.3.tar.xz 732010aa5ef461fa93355ed2c6c5fedb48ddc4b74e697eaabe8907eaeb943011
fetch https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz ffmpeg-8.0.1.tar.xz 05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
if [ ! -f "$P/.btm-media-v1" ]; then
  tar -xf "$D/dav1d-1.5.3.tar.xz" -C "$D"
  tar -xf "$D/ffmpeg-8.0.1.tar.xz" -C "$D"
  LLVM="$OHOS_NDK_HOME/llvm/bin"
  SYSROOT="$OHOS_NDK_HOME/sysroot"
  # Standalone configuration generated only in the build directory.
  cat > "$D/ohos.ini" <<EOF
[binaries]
c = ['$LLVM/clang', '--target=aarch64-linux-ohos', '--sysroot=$SYSROOT']
ar = '$LLVM/llvm-ar'
strip = '$LLVM/llvm-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
[properties]
needs_exe_wrapper = true
EOF
  meson setup "$D/dav1d-build" "$D/dav1d-1.5.3" --cross-file "$D/ohos.ini" --prefix "$P" --libdir lib --buildtype release --default-library static -Db_staticpic=true -Denable_tools=false -Denable_tests=false
  ninja -C "$D/dav1d-build" -j3 install
  export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"
  ( cd "$D/ffmpeg-8.0.1"
    ./configure --prefix="$P" --target-os=linux --arch=aarch64 --enable-cross-compile \
      --cc="$LLVM/clang" --cxx="$LLVM/clang++" --ar="$LLVM/llvm-ar" --ranlib="$LLVM/llvm-ranlib" --strip="$LLVM/llvm-strip" \
      --extra-cflags="--target=aarch64-linux-ohos --sysroot=$SYSROOT -fPIC -I$P/include" \
      --extra-ldflags="--target=aarch64-linux-ohos --sysroot=$SYSROOT -L$P/lib" \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --disable-autodetect --disable-programs --disable-doc --disable-debug --disable-static --enable-shared --enable-pic \
      --disable-symver --disable-gpl --disable-nonfree --disable-avdevice --disable-avfilter \
      --disable-encoders --disable-muxers --disable-hwaccels --disable-devices --disable-filters --disable-decoders \
      --enable-libdav1d --enable-decoder=libdav1d,aac,aac_fixed,ac3,eac3,flac,mp3,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,alac,subrip,ass,ssa,webvtt,mov_text \
      --disable-demuxers --enable-demuxer=mov,matroska,ogg,ivf \
      --disable-parsers --enable-parser=av1,aac,ac3,flac,mpegaudio,opus,vorbis \
      --disable-protocols --enable-protocol=file,http,tcp --enable-pthreads \
      --extra-libs='-lm'
    # Keep Linux code paths, but use unversioned SONAMEs supported by HAP packing.
    sed -i 's/^SHFLAGS=.*/SHFLAGS=-shared -Wl,-soname,$(SLIBNAME)/;s/^SLIB_INSTALL_NAME=.*/SLIB_INSTALL_NAME=$(SLIBNAME)/;s/^SLIB_INSTALL_LINKS=.*/SLIB_INSTALL_LINKS=/' ffbuild/config.mak
    make -j3
    make install
  )
  touch "$P/.btm-media-v1"
fi
# Harmony packages must contain real .so files, never build-machine symlinks.
mkdir -p "$ROOT/entry/libs/arm64-v8a"
for lib in avformat avcodec avutil swresample swscale; do
  cp -L "$P/lib/lib$lib.so" "$ROOT/entry/libs/arm64-v8a/lib$lib.so"
  SONAME=$("$OHOS_NDK_HOME/llvm/bin/llvm-readelf" -d "$P/lib/lib$lib.so" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')
  test -n "$SONAME"
  test "$SONAME" = "lib$lib.so"
done
NOTICES="$ROOT/entry/src/main/resources/rawfile/licenses/media"
mkdir -p "$NOTICES"
cp "$D/dav1d-1.5.3/COPYING" "$NOTICES/dav1d-BSD-2-Clause.txt"
cp "$D/ffmpeg-8.0.1/COPYING.LGPLv2.1" "$D/ffmpeg-8.0.1/LICENSE.md" "$NOTICES/"
