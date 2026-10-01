#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/.build/ios-ffmpeg"
source_dir="$output/source"
sdk="$THEOS/sdks/iPhoneOS16.5.sdk"
compiler="$(xcrun --find clang)"
mkdir -p "$output"
if [ ! -d "$source_dir/.git" ]; then
  git clone --depth 1 --branch n6.1.2 https://github.com/FFmpeg/FFmpeg.git "$source_dir"
fi
test "$(git -C "$source_dir" describe --tags --exact-match)" = n6.1.2
test "$(git -C "$source_dir" rev-parse HEAD)" = b1a4534186ca51b0457579fc05a5739eb2cc45cd
for architecture in arm64 arm64e host; do
  minimum=14.0
  if [ "$architecture" = arm64e ]; then minimum=15.0; fi
  prefix="$output/$architecture"
  if [ -f "$prefix/lib/libavformat.a" ]; then continue; fi
  mkdir -p "$output/build-$architecture"
  cd "$output/build-$architecture"
  configure_arch=aarch64
  flags="-arch $architecture -miphoneos-version-min=$minimum"
  extra_options=(--disable-x86asm)
  selected_sdk="$sdk"
  if [ "$architecture" = host ]; then
    configure_arch="$(uname -m)"
    flags="-arch $configure_arch"
    selected_sdk="$(xcrun --sdk macosx --show-sdk-path)"
  fi
  "$source_dir/configure" \
    --prefix="$prefix" --target-os=darwin --arch="$configure_arch" --enable-cross-compile \
    --cc="$compiler" --sysroot="$selected_sdk" "${extra_options[@]}" \
    --extra-cflags="$flags -fPIC -fvisibility=hidden" \
    --extra-ldflags="$flags" \
    --disable-programs --disable-doc --disable-debug --disable-shared --enable-static \
    --disable-gpl --disable-nonfree --disable-autodetect --disable-everything \
    --disable-avdevice --disable-avfilter --disable-postproc --enable-network \
    --enable-avformat --enable-avcodec --enable-avutil --enable-swscale --enable-swresample \
    --enable-videotoolbox --enable-securetransport --enable-zlib \
    --enable-protocol=file,http,https,tcp,tls,udp,rtp,rtmp,rtmpt,rtmps,rtmpts,crypto,data \
    --enable-demuxer=mov,matroska,flv,hls,mpegts,rtsp,aac,mp3,wav,ogg,flac,image2,image2pipe,h264,hevc \
    --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,vorbis,opus,flac,alac,mjpeg,png,bmp,gif \
    --enable-parser=h264,hevc,aac,mpegaudio,opus,vorbis,flac \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox
  make -j "$(sysctl -n hw.ncpu)"
  make install
done
mkdir -p "$output/universal/lib" "$output/universal/include"
cp -R "$output/arm64/include/." "$output/universal/include/"
for library in avformat avcodec swresample swscale avutil; do
  xcrun lipo -create "$output/arm64/lib/lib$library.a" "$output/arm64e/lib/lib$library.a" \
    -output "$output/universal/lib/lib$library.a"
done
cp "$source_dir/COPYING.LGPLv2.1" "$output/universal/FFmpeg-LICENSE.txt"
printf '%s\n' 'https://github.com/FFmpeg/FFmpeg/tree/n6.1.2' > "$output/universal/FFmpeg-SOURCE.txt"
