#!/bin/sh
# Runs the development build. Straight into a stream: run-macos.sh --fullscreen stream <nickname> <host>
# CHIAKI_LAT_PROBE=1 logs per-stage frame timing; CHIAKI_PACE=1 restores upstream frame pacing.
cd "$(dirname "$0")/.." || exit 1
exec open -n --env QT_VULKAN_LIB=/opt/homebrew/lib/libvulkan.1.dylib \
	${CHIAKI_LAT_PROBE:+--env CHIAKI_LAT_PROBE=$CHIAKI_LAT_PROBE} ${CHIAKI_PACE:+--env CHIAKI_PACE=$CHIAKI_PACE} \
	build/gui/chiaki.app --args "$@"
