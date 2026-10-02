// Per-frame latency probe, measured from the frame's first packet. Enable with CHIAKI_LAT_PROBE=1.

#ifndef CHIAKI_LATPROBE_H
#define CHIAKI_LATPROBE_H

#include "common.h"
#include "log.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	CHIAKI_LAT_ASSEMBLED = 0,
	CHIAKI_LAT_DECODED,
	CHIAKI_LAT_PULLED,
	CHIAKI_LAT_PREPARED,
	CHIAKI_LAT_GUI,
	CHIAKI_LAT_RENDER,
	CHIAKI_LAT_MAPPED,
	CHIAKI_LAT_SWAPPED,
	CHIAKI_LAT_STAGE_COUNT
} ChiakiLatStage;

CHIAKI_EXPORT bool chiaki_lat_probe_enabled(void);
CHIAKI_EXPORT void chiaki_lat_probe_first_packet(void);
CHIAKI_EXPORT void chiaki_lat_probe_begin(int64_t pts, ChiakiLog *log);
CHIAKI_EXPORT void chiaki_lat_probe_mark(int64_t pts, ChiakiLatStage stage);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_LATPROBE_H
