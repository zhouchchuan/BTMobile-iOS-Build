#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST=$(mktemp -d)
g++ -std=c++17 -O1 -g -Wall -Wextra -pthread "$ROOT/tests/media_engine_test.cpp" -I"$ROOT/native-deps/headers" $(pkg-config --cflags --libs libavformat libavcodec libavutil libswresample libswscale) -o "$TEST/media-test"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 4 -c:v libaom-av1 -cpu-used 8 -crf 38 -c:a aac "$TEST/av1.mp4"
timeout 25 "$TEST/media-test" "$TEST/av1.mp4" audio
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=24 -t 4 -pix_fmt yuv420p10le -c:v libaom-av1 -cpu-used 8 -crf 38 "$TEST/av1-10bit.mkv"
timeout 25 "$TEST/media-test" "$TEST/av1-10bit.mkv" silent
printf '1\n00:00:00,000 --> 00:00:04,000\nAV1 subtitle sample\n' > "$TEST/subtitle.srt"
ffmpeg -hide_banner -loglevel error -i "$TEST/av1.mp4" -i "$TEST/subtitle.srt" -map 0:v -map 0:a -map 0:a -map 1:s -c copy "$TEST/tracks.mkv"
timeout 25 "$TEST/media-test" "$TEST/tracks.mkv" tracks
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=10 -t 1 -c:v mpeg4 "$TEST/non-av1.mp4"
timeout 10 "$TEST/media-test" "$TEST/non-av1.mp4" reject
