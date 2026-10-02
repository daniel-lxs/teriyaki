#include <chiaki/latprobe.h>
#include <chiaki/time.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SLOT_COUNT 64
#define BUCKET_US 250
#define BUCKET_COUNT 400 // 100 ms
#define REPORT_INTERVAL_US 5000000ULL

typedef struct
{
	int64_t pts;
	uint64_t first_packet_us;
	bool used;
} Slot;

typedef struct
{
	uint32_t count;
	uint64_t sum_us;
	uint64_t max_us;
	uint32_t buckets[BUCKET_COUNT];
} StageStats;

static pthread_mutex_t probe_mutex = PTHREAD_MUTEX_INITIALIZER;
static int probe_state = -1; // -1 unknown, 0 off, 1 on
static uint64_t first_packet_us;
static Slot slots[SLOT_COUNT];
static unsigned int slot_next;
static StageStats stats[CHIAKI_LAT_STAGE_COUNT];
static uint64_t last_report_us;
static uint32_t frames_begun;

static const char *const stage_names[CHIAKI_LAT_STAGE_COUNT] = {
	"assembled", "decoded", "pulled", "prepared", "gui", "render", "mapped", "swapped"
};

CHIAKI_EXPORT bool chiaki_lat_probe_enabled(void)
{
	if(probe_state < 0)
	{
		const char *v = getenv("CHIAKI_LAT_PROBE");
		probe_state = (v && v[0] == '1') ? 1 : 0;
	}
	return probe_state == 1;
}

static void record(ChiakiLatStage stage, uint64_t delta_us)
{
	StageStats *s = &stats[stage];
	s->count++;
	s->sum_us += delta_us;
	if(delta_us > s->max_us)
		s->max_us = delta_us;
	uint64_t bucket = delta_us / BUCKET_US;
	if(bucket >= BUCKET_COUNT)
		bucket = BUCKET_COUNT - 1;
	s->buckets[bucket]++;
}

static double percentile_ms(const StageStats *s, double p)
{
	uint32_t target = (uint32_t)(s->count * p);
	uint32_t seen = 0;
	for(int i = 0; i < BUCKET_COUNT; i++)
	{
		seen += s->buckets[i];
		if(seen > target)
			return (i + 1) * BUCKET_US / 1000.0;
	}
	return BUCKET_COUNT * BUCKET_US / 1000.0;
}

static void report(ChiakiLog *log)
{
	char line[512];
	size_t off = 0;
	for(int i = 0; i < CHIAKI_LAT_STAGE_COUNT; i++)
	{
		const StageStats *s = &stats[i];
		if(!s->count)
			continue;
		int n = snprintf(line + off, sizeof(line) - off, " %s %.1f/%.1f/%.1f",
				stage_names[i], s->sum_us / 1000.0 / s->count, percentile_ms(s, 0.95), s->max_us / 1000.0);
		if(n < 0 || (size_t)n >= sizeof(line) - off)
			break;
		off += (size_t)n;
	}
	CHIAKI_LOGI(log, "[latprobe] ms since first packet, avg/p95/max:%s | frames %u shown %u",
			line, frames_begun, stats[CHIAKI_LAT_SWAPPED].count);
	memset(stats, 0, sizeof(stats));
	frames_begun = 0;
}

CHIAKI_EXPORT void chiaki_lat_probe_first_packet(void)
{
	if(!chiaki_lat_probe_enabled())
		return;
	uint64_t now = chiaki_time_now_monotonic_us();
	pthread_mutex_lock(&probe_mutex);
	first_packet_us = now;
	pthread_mutex_unlock(&probe_mutex);
}

CHIAKI_EXPORT void chiaki_lat_probe_begin(int64_t pts, ChiakiLog *log)
{
	if(!chiaki_lat_probe_enabled())
		return;
	uint64_t now = chiaki_time_now_monotonic_us();
	pthread_mutex_lock(&probe_mutex);
	if(first_packet_us && now >= first_packet_us)
	{
		Slot *slot = &slots[slot_next++ % SLOT_COUNT];
		slot->pts = pts;
		slot->first_packet_us = first_packet_us;
		slot->used = true;
		frames_begun++;
		record(CHIAKI_LAT_ASSEMBLED, now - first_packet_us);
	}
	if(!last_report_us)
		last_report_us = now;
	else if(now - last_report_us >= REPORT_INTERVAL_US)
	{
		last_report_us = now;
		report(log);
	}
	pthread_mutex_unlock(&probe_mutex);
}

CHIAKI_EXPORT void chiaki_lat_probe_mark(int64_t pts, ChiakiLatStage stage)
{
	if(!chiaki_lat_probe_enabled())
		return;
	uint64_t now = chiaki_time_now_monotonic_us();
	pthread_mutex_lock(&probe_mutex);
	for(int i = 0; i < SLOT_COUNT; i++)
	{
		const Slot *slot = &slots[i];
		if(slot->used && slot->pts == pts)
		{
			if(now >= slot->first_packet_us)
				record(stage, now - slot->first_packet_us);
			break;
		}
	}
	pthread_mutex_unlock(&probe_mutex);
}
