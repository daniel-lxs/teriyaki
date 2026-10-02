#include "chiaki_shim.h"

#include <chiaki/discovery.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define LOG_MASK (CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR)

struct ChiakiShimSession
{
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	ChiakiLog log;
	ChiakiShimCallbacks cb;
};

struct ChiakiShimRegist
{
	ChiakiRegist regist;
	ChiakiLog log;
	ChiakiShimRegistCallback cb;
	void *user;
};

static pthread_once_t lib_once = PTHREAD_ONCE_INIT;

static void lib_init(void)
{
	chiaki_lib_init();
}

static void session_log(ChiakiLogLevel level, const char *msg, void *user)
{
	ChiakiShimSession *s = user;
	s->cb.log(s->cb.user, (int)level, msg);
}

static bool session_video(uint8_t *buf, size_t size, int32_t frames_lost, bool recovered, void *user)
{
	ChiakiShimSession *s = user;
	return s->cb.video(s->cb.user, buf, size, frames_lost, recovered);
}

static void session_audio_settings(uint32_t channels, uint32_t rate, void *user)
{
	ChiakiShimSession *s = user;
	s->cb.audio_format(s->cb.user, channels, rate);
}

static void session_audio_frame(int16_t *buf, size_t samples_count, void *user)
{
	ChiakiShimSession *s = user;
	s->cb.audio(s->cb.user, buf, samples_count);
}

static void session_event(ChiakiEvent *event, void *user)
{
	ChiakiShimSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			s->cb.connected(s->cb.user);
			break;
		case CHIAKI_EVENT_QUIT:
			s->cb.quit(s->cb.user, chiaki_quit_reason_is_error(event->quit.reason),
					chiaki_quit_reason_string(event->quit.reason), event->quit.reason_str);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			s->cb.login_pin(s->cb.user, event->login_pin_request.pin_incorrect);
			break;
		case CHIAKI_EVENT_RUMBLE:
			s->cb.rumble(s->cb.user, event->rumble.left, event->rumble.right);
			break;
		default:
			break;
	}
}

ChiakiShimSession *chiaki_shim_session_start(const ChiakiShimConnectInfo *info, const ChiakiShimCallbacks *callbacks)
{
	pthread_once(&lib_once, lib_init);

	ChiakiShimSession *s = calloc(1, sizeof(*s));
	if(!s)
		return NULL;
	s->cb = *callbacks;
	chiaki_log_init(&s->log, LOG_MASK, session_log, s);

	ChiakiConnectInfo connect = { 0 };
	connect.ps5 = info->ps5;
	connect.host = info->host;
	memcpy(connect.regist_key, info->regist_key, sizeof(connect.regist_key));
	memcpy(connect.morning, info->morning, sizeof(connect.morning));
	memcpy(connect.psn_account_id, info->psn_account_id, sizeof(connect.psn_account_id));
	chiaki_connect_video_profile_preset(&connect.video_profile,
			(ChiakiVideoResolutionPreset)info->resolution, (ChiakiVideoFPSPreset)info->fps);
	if(info->bitrate_kbps > 0)
		connect.video_profile.bitrate = (unsigned int)info->bitrate_kbps;
	connect.video_profile.codec = (ChiakiCodec)info->codec;
	connect.video_profile_auto_downgrade = true;
	connect.enable_dualsense = info->dualsense;
	connect.audio_video_disabled = CHIAKI_NONE_DISABLED;
	connect.packet_loss_max = 0.05;

	chiaki_opus_decoder_init(&s->opus, &s->log);
	if(chiaki_session_init(&s->session, &connect, &s->log) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_opus_decoder_fini(&s->opus);
		free(s);
		return NULL;
	}

	chiaki_opus_decoder_set_cb(&s->opus, session_audio_settings, session_audio_frame, s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&s->opus, &sink);
	chiaki_session_set_audio_sink(&s->session, &sink);
	chiaki_session_set_video_sample_cb(&s->session, session_video, s);
	chiaki_session_set_event_cb(&s->session, session_event, s);

	if(chiaki_session_start(&s->session) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_session_fini(&s->session);
		chiaki_opus_decoder_fini(&s->opus);
		free(s);
		return NULL;
	}
	return s;
}

void chiaki_shim_session_set_controller(ChiakiShimSession *s, const ChiakiShimControllerState *state)
{
	ChiakiControllerState out;
	chiaki_controller_state_set_idle(&out);
	out.buttons = state->buttons;
	out.l2_state = state->l2;
	out.r2_state = state->r2;
	out.left_x = state->left_x;
	out.left_y = state->left_y;
	out.right_x = state->right_x;
	out.right_y = state->right_y;
	for(int i = 0; i < CHIAKI_CONTROLLER_TOUCHES_MAX; i++)
	{
		out.touches[i].id = state->touch_id[i];
		out.touches[i].x = state->touch_x[i];
		out.touches[i].y = state->touch_y[i];
	}
	chiaki_session_set_controller_state(&s->session, &out);
}

void chiaki_shim_session_set_login_pin(ChiakiShimSession *s, const char *pin)
{
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void chiaki_shim_session_stop(ChiakiShimSession *s)
{
	chiaki_session_stop(&s->session);
	chiaki_session_join(&s->session);
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	free(s);
}

static void regist_event(ChiakiRegistEvent *event, void *user)
{
	ChiakiShimRegist *r = user;
	if(event->type != CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS || !event->registered_host)
	{
		r->cb(r->user, false, NULL);
		return;
	}
	const ChiakiRegisteredHost *in = event->registered_host;
	ChiakiShimRegisteredHost out = { 0 };
	out.target = (int)in->target;
	memcpy(out.ap_ssid, in->ap_ssid, sizeof(out.ap_ssid));
	memcpy(out.ap_bssid, in->ap_bssid, sizeof(out.ap_bssid));
	memcpy(out.ap_key, in->ap_key, sizeof(out.ap_key));
	memcpy(out.ap_name, in->ap_name, sizeof(out.ap_name));
	memcpy(out.server_mac, in->server_mac, sizeof(out.server_mac));
	memcpy(out.server_nickname, in->server_nickname, sizeof(out.server_nickname));
	memcpy(out.rp_regist_key, in->rp_regist_key, sizeof(out.rp_regist_key));
	out.rp_key_type = in->rp_key_type;
	memcpy(out.rp_key, in->rp_key, sizeof(out.rp_key));
	out.console_pin = in->console_pin;
	r->cb(r->user, true, &out);
}

static void regist_log(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)level;
	(void)msg;
	(void)user;
}

ChiakiShimRegist *chiaki_shim_regist_start(const char *host, bool ps5, const char *system_version,
		const uint8_t *psn_account_id, uint32_t pin, ChiakiShimRegistCallback callback, void *user)
{
	pthread_once(&lib_once, lib_init);

	ChiakiShimRegist *r = calloc(1, sizeof(*r));
	if(!r)
		return NULL;
	r->cb = callback;
	r->user = user;
	chiaki_log_init(&r->log, LOG_MASK, regist_log, r);

	ChiakiDiscoveryHost discovered = { 0 };
	discovered.system_version = system_version;
	discovered.device_discovery_protocol_version =
		ps5 ? CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5 : CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;

	ChiakiRegistInfo info = { 0 };
	info.target = chiaki_discovery_host_system_version_target(&discovered);
	if(ps5 && !chiaki_target_is_ps5(info.target))
		info.target = CHIAKI_TARGET_PS5_1;
	info.host = host;
	info.broadcast = false;
	memcpy(info.psn_account_id, psn_account_id, sizeof(info.psn_account_id));
	info.pin = pin;

	if(chiaki_regist_start(&r->regist, &r->log, &info, regist_event, r) != CHIAKI_ERR_SUCCESS)
	{
		free(r);
		return NULL;
	}
	return r;
}

void chiaki_shim_regist_free(ChiakiShimRegist *r)
{
	chiaki_regist_stop(&r->regist);
	chiaki_regist_fini(&r->regist);
	free(r);
}
