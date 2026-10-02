#ifndef CHIAKI_SHIM_H
#define CHIAKI_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ChiakiShimSession ChiakiShimSession;
typedef struct ChiakiShimRegist ChiakiShimRegist;

typedef struct
{
	const char *host;
	bool ps5;
	const uint8_t *regist_key;     // 16 bytes
	const uint8_t *morning;        // 16 bytes
	const uint8_t *psn_account_id; // 8 bytes
	int resolution;                // 1 = 360p ... 4 = 1080p
	int fps;
	int bitrate_kbps;              // 0 keeps the preset's bitrate
	int codec;                     // 0 = H.264, 1 = HEVC, 2 = HEVC HDR
	bool dualsense;
} ChiakiShimConnectInfo;

typedef struct
{
	void *user;
	bool (*video)(void *user, const uint8_t *data, size_t size, int32_t frames_lost, bool recovered);
	void (*audio_format)(void *user, uint32_t channels, uint32_t rate);
	void (*audio)(void *user, const int16_t *samples, size_t frame_count);
	void (*connected)(void *user);
	void (*quit)(void *user, bool is_error, const char *reason, const char *detail);
	void (*login_pin)(void *user, bool incorrect);
	void (*rumble)(void *user, uint8_t left, uint8_t right);
	void (*log)(void *user, int level, const char *message);
} ChiakiShimCallbacks;

typedef struct
{
	uint32_t buttons;
	uint8_t l2;
	uint8_t r2;
	int16_t left_x, left_y, right_x, right_y;
	int8_t touch_id[2]; // -1 = finger up
	uint16_t touch_x[2], touch_y[2];
} ChiakiShimControllerState;

typedef struct
{
	int target;
	char ap_ssid[0x30];
	char ap_bssid[0x20];
	char ap_key[0x50];
	char ap_name[0x20];
	uint8_t server_mac[6];
	char server_nickname[0x20];
	char rp_regist_key[0x10];
	uint32_t rp_key_type;
	uint8_t rp_key[0x10];
	uint32_t console_pin;
} ChiakiShimRegisteredHost;

typedef void (*ChiakiShimRegistCallback)(void *user, bool success, const ChiakiShimRegisteredHost *host);

ChiakiShimSession *chiaki_shim_session_start(const ChiakiShimConnectInfo *info, const ChiakiShimCallbacks *callbacks);
void chiaki_shim_session_set_controller(ChiakiShimSession *session, const ChiakiShimControllerState *state);
void chiaki_shim_session_set_login_pin(ChiakiShimSession *session, const char *pin);
/** Stops the session, waits for it to end and frees it. Must not be called from a callback. */
void chiaki_shim_session_stop(ChiakiShimSession *session);

ChiakiShimRegist *chiaki_shim_regist_start(const char *host, bool ps5, const char *system_version,
		const uint8_t *psn_account_id, uint32_t pin, ChiakiShimRegistCallback callback, void *user);
void chiaki_shim_regist_free(ChiakiShimRegist *regist);

#endif
