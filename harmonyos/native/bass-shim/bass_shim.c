/*
 * bass_shim.c —— BASS / BASSmix / BASS_FX 兼容垫片（OpenHarmony / musl）
 * ---------------------------------------------------------------------------
 * 为什么需要它
 *   osu.Framework 的音频层与 BASS 深度耦合（AudioManager / TrackBass / SampleBass /
 *   BassAudioMixer / BassAmplitudeProcessor），NuGet 里的 libbass*.so 全部是 Bionic
 *   (Android) 或 glibc (linux-x64) 产物，DT_NEEDED 里有 ld-linux-*.so / libc.so.6，
 *   OHOS 的 musl 动态链接器无法加载。BASS 又是闭源的，没法从源码重编。
 *
 *   因此这里按「同一个 C ABI」重写一份最小实现：
 *     · libbass.so      —— BASS 2.4 主库（设备 / 通道 / 采样 / 配置）
 *     · libbassmix.so   —— BASSmix（混音器）
 *     · libbass_fx.so   —— BASS_FX（tempo / reverse / BPM）
 *   托管侧一行代码都不用改，ManagedBass 的 DllImport 直接落到这里。
 *
 * 当前语义：**静音但时钟真实**
 *   · 设备初始化永远成功（设备 1 = Default，已初始化），所以
 *     AudioManager.IsLoaded == true，不会卡在「无音频设备」的降级路径里。
 *   · 通道真的会播放、暂停、seek，位置按 CLOCK_MONOTONIC 前进；
 *     只是不产生任何 PCM（BASS_ChannelGetData 返回 0，GetLevel 返回 0）。
 *   · 也就是说：菜单 / 谱面 / 判定逻辑的时间轴是准的，只是听不见。
 *   M3 要把 BASS_ChannelGetData / 播放真正接到 OH_AudioRenderer + 解码器上，
 *   本文件就是那个接入点。
 *
 * 编译：见同目录 build-bass-shim.py（OHOS clang，x86_64 / arm64-v8a）。
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

#ifndef SHIM_MODULE
#define SHIM_MODULE 0 /* 0 = bass, 1 = bassmix, 2 = bass_fx */
#endif

#if SHIM_MODULE == 0
/* 只有 libbass.so 需要解码器与音频输出；mix / fx 只是转发到 libbass。 */
#include "ohosdec.h"
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

static int oh_audio_start(int rate);
static void oh_audio_stop(void);
#endif

/* ------------------------------------------------------------------ */
/* 公共常量                                                            */
/* ------------------------------------------------------------------ */

#define BASS_ACTIVE_STOPPED 0
#define BASS_ACTIVE_PLAYING 1
#define BASS_ACTIVE_STALLED 2
#define BASS_ACTIVE_PAUSED  3

#define BASS_DEVICE_ENABLED 0x1
#define BASS_DEVICE_DEFAULT 0x2
#define BASS_DEVICE_INIT    0x4

#define BASS_ATTRIB_FREQ  1
#define BASS_ATTRIB_VOL   2
#define BASS_ATTRIB_PAN   3
#define BASS_ATTRIB_BITRATE 5
#define BASS_ATTRIB_TEMPO 0x10000

#define BASS_POS_BYTE 0

#define MAX_CHANNELS 512

/* BASS 的 BASS_FILEPROCS（流式读回调）。
   字段顺序必须与 un4seen 官方头文件 / ManagedBass.FileProcedures 完全一致，
   否则会把 length 当 read 调，读到的是野指针。 */
typedef struct BASS_FILEPROCS
{
    void (*close)(void *user);
    uint64_t (*length)(void *user);
    uint32_t (*read)(void *buffer, uint32_t length, void *user);
    int (*seek)(uint64_t offset, void *user);
} BASS_FILEPROCS;

/* ------------------------------------------------------------------ */
/* 核心状态（只有 libbass.so 里存在一份；mix / fx 通过 ohshim_* 访问）   */
/* ------------------------------------------------------------------ */

#if SHIM_MODULE == 0

typedef struct
{
    int used;
    int state;          /* BASS_ACTIVE_* */
    int freq;
    int chans;
    uint64_t len;       /* 总长度（字节），0 表示未知 */
    uint64_t base;      /* 当前播放段之前已走过的字节数 */
    uint64_t start_ns;  /* 当前播放段开始时刻 */
    float volume;
    float pan;

    /* ---- 解码 / 混音 ---- */
    void *dec;          /* ohosdec 句柄（解码器），0 = 静音通道 */
    float bitrate;      /* kbps，BASS_ATTRIB_BITRATE 用 */
    const void *procs;  /* BASS_FILEPROCS*，释放时要回调 close 把源流关掉 */
    void *procs_user;
    void *src_data;     /* 从 FileProcedures 读进来的整份压缩数据 */

    int base_freq;      /* 源采样率：位置换算基准，不随 BASS_ATTRIB_FREQ 变 */
    float tempo;        /* BASS_FX Tempo 属性，单位百分点 */
    int is_mixer;       /* 由 BASS_Mixer_StreamCreate 建立 */
    int parent;         /* 所属 mixer 句柄；0 = 未挂载 */
    uint64_t dec_frame; /* 解码器当前所在帧，避免每次回调都 seek */
} shim_channel;

static shim_channel g_ch[MAX_CHANNELS];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_next_sync = 0x1000;

static int g_dev_current = -1; /* BASS_DEFAULT_DEVICE */
static int g_dev_inited;

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t bytes_per_sec(const shim_channel *c)
{
    /* 16-bit 采样。freq 是 BASS_ATTRIB_FREQ（变速），tempo 是 BASS_FX 的变速；
       两者都让「源字节位置」推进得更快/更慢，与音频回调读取的帧号保持一致。 */
    double rate = 1.0 + (double)c->tempo / 100.0;
    if (rate < 0.05)
        rate = 0.05;
    return (uint64_t)((double)(c->freq > 0 ? c->freq : 44100)
                      * (double)(c->chans > 0 ? c->chans : 2) * 2.0 * rate);
}

/* 以下 ohshim_* 同时被 libbassmix.so / libbass_fx.so 调用 */
uint64_t ohshim_now_ns(void) { return now_ns(); }

int ohshim_channel_create(int freq, int chans, uint64_t len)
{
    int h = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 1; i < MAX_CHANNELS; i++)
    {
        if (!g_ch[i].used)
        {
            memset(&g_ch[i], 0, sizeof(g_ch[i]));
            g_ch[i].used = 1;
            g_ch[i].state = BASS_ACTIVE_STOPPED;
            g_ch[i].freq = freq > 0 ? freq : 44100;
            g_ch[i].base_freq = freq > 0 ? freq : 44100;
            g_ch[i].chans = chans > 0 ? chans : 2;
            g_ch[i].len = len;
            g_ch[i].volume = 1.0f;
            h = i;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return h;
}

int ohshim_channel_free(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;

    /* 先把要释放的资源取出来，解锁后再释放 —— 解码器析构 + 回调托管侧
       的 close 都可能花时间，不能占着全局锁。 */
    void *dec = 0;
    const BASS_FILEPROCS *procs = 0;
    void *procs_user = 0;
    void *src_data = 0;

    pthread_mutex_lock(&g_lock);
    dec = g_ch[handle].dec;
    procs = (const BASS_FILEPROCS *)g_ch[handle].procs;
    procs_user = g_ch[handle].procs_user;
    src_data = g_ch[handle].src_data;
    g_ch[handle].dec = 0;
    g_ch[handle].procs = 0;
    g_ch[handle].procs_user = 0;
    g_ch[handle].src_data = 0;
    g_ch[handle].used = 0;
    pthread_mutex_unlock(&g_lock);

    if (dec)
        ohosdec_close(dec);
    if (src_data)
        free(src_data);
    /* BASS 的约定：流被释放时替调用方关闭源。托管侧 TrackBass 依赖这个行为
       来 Dispose 底层 Stream，不回调会泄漏文件句柄。 */
    if (procs && procs->close)
        procs->close(procs_user);

    return 1;
}

int ohshim_channel_play(int handle, int restart)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    shim_channel *c = &g_ch[handle];
    if (!c->used)
    {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    if (restart || c->state != BASS_ACTIVE_PAUSED)
        c->base = 0;
    c->start_ns = now_ns();
    c->state = BASS_ACTIVE_PLAYING;
    int need_audio = c->is_mixer;
    int rate = c->freq;
    pthread_mutex_unlock(&g_lock);

    /* 不能在持锁时 Start：回调线程会立刻进来抢同一把锁。 */
    if (need_audio)
        oh_audio_start(rate);
    return 1;
}

int ohshim_channel_pause(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    shim_channel *c = &g_ch[handle];
    if (!c->used)
    {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    if (c->state == BASS_ACTIVE_PLAYING)
    {
        uint64_t elapsed = now_ns() - c->start_ns;
        c->base += elapsed * bytes_per_sec(c) / 1000000000ull;
        c->state = BASS_ACTIVE_PAUSED;
    }
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int ohshim_channel_stop(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    shim_channel *c = &g_ch[handle];
    if (c->used)
    {
        c->state = BASS_ACTIVE_STOPPED;
        c->base = 0;
    }
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int ohshim_channel_active(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return BASS_ACTIVE_STOPPED;
    pthread_mutex_lock(&g_lock);
    int state = g_ch[handle].used ? g_ch[handle].state : BASS_ACTIVE_STOPPED;
    pthread_mutex_unlock(&g_lock);
    return state;
}

/* mode 目前只支持 BASS_POS_BYTE(0)；其余模式按字节返回，够 osu! 用 */
uint64_t ohshim_channel_pos(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    uint64_t pos = 0;
    pthread_mutex_lock(&g_lock);
    shim_channel *c = &g_ch[handle];
    if (c->used)
    {
        pos = c->base;
        if (c->state == BASS_ACTIVE_PLAYING)
            pos += (now_ns() - c->start_ns) * bytes_per_sec(c) / 1000000000ull;
        if (c->len > 0 && pos > c->len)
            pos = c->len;
    }
    pthread_mutex_unlock(&g_lock);
    return pos;
}

int ohshim_channel_set_pos(int handle, uint64_t pos)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    shim_channel *c = &g_ch[handle];
    if (c->used)
    {
        c->base = pos;
        c->start_ns = now_ns();
    }
    pthread_mutex_unlock(&g_lock);
    return 1;
}

uint64_t ohshim_channel_len(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    uint64_t len;
    pthread_mutex_lock(&g_lock);
    len = g_ch[handle].used ? g_ch[handle].len : 0;
    pthread_mutex_unlock(&g_lock);
    return len;
}

void ohshim_channel_set_len(int handle, uint64_t len)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return;
    pthread_mutex_lock(&g_lock);
    if (g_ch[handle].used)
        g_ch[handle].len = len;
    pthread_mutex_unlock(&g_lock);
}

int ohshim_channel_freq(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 44100;
    int f = g_ch[handle].used ? g_ch[handle].freq : 44100;
    return f > 0 ? f : 44100;
}

int ohshim_channel_chans(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 2;
    int c = g_ch[handle].used ? g_ch[handle].chans : 2;
    return c > 0 ? c : 2;
}

int ohshim_new_sync(void) { return __sync_add_and_fetch(&g_next_sync, 1); }

/* BASSmix 通过这几个入口把「谁混到谁」登记到 libbass 的全局通道表里。
   放在 libbass 而不是 libbassmix：音频回调需要同一把锁读到一致的通道状态。 */
int ohshim_mixer_mark(int handle, int is_mixer)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    if (g_ch[handle].used)
        g_ch[handle].is_mixer = is_mixer;
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int ohshim_mixer_add(int mixer, int channel)
{
    if (mixer <= 0 || mixer >= MAX_CHANNELS || channel <= 0 || channel >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    if (!g_ch[mixer].used || !g_ch[channel].used)
    {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    g_ch[channel].parent = mixer;
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int ohshim_mixer_remove(int channel)
{
    if (channel <= 0 || channel >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    if (g_ch[channel].used)
        g_ch[channel].parent = 0;
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int ohshim_channel_get_parent(int handle)
{
    if (handle <= 0 || handle >= MAX_CHANNELS)
        return 0;
    pthread_mutex_lock(&g_lock);
    int parent = g_ch[handle].used ? g_ch[handle].parent : 0;
    pthread_mutex_unlock(&g_lock);
    return parent;
}

/* ------------------------------------------------------------------ */
/* OH_AudioRenderer 输出（唯一的音频设备）                              */
/* ------------------------------------------------------------------
   osu.Framework 的结构是：子通道（Decode）-> BASSmix 混音器（播放型）-> 设备。
   因此这里不逐个通道播放，而是在渲染器回调里把挂到「正在播放的混音器」上的
   子通道混合成 s16 立体声。

   位置以墙钟为准（ohshim_channel_pos 用同一套公式），回调每次按当前源字节位置
   定位解码器，所以「听到的帧」和「游戏读到的时间」天然一致——这对节奏游戏的
   判定比音质更重要。变速（BASS_ATTRIB_FREQ / BASS_FX Tempo）也走同一条公式。
------------------------------------------------------------------ */

#define AUDIO_MAX_FRAMES 1024
#define AUDIO_PCM_CAP    2048

static OH_AudioRenderer *g_renderer;
static int g_audio_rate = 44100;
static int g_audio_active;

static int32_t oh_audio_write(OH_AudioRenderer *renderer, void *user, void *buffer, int32_t length)
{
    (void)renderer; (void)user;

    int16_t *out = (int16_t *)buffer;
    if (out == 0 || length <= 0)
        return 0;

    memset(out, 0, (size_t)length);
    int frames = length / 4; /* s16 立体声 */
    if (frames > AUDIO_MAX_FRAMES)
        frames = AUDIO_MAX_FRAMES;

    if (!g_audio_active || frames <= 0)
        return length;

    int32_t acc_l[AUDIO_MAX_FRAMES];
    int32_t acc_r[AUDIO_MAX_FRAMES];
    memset(acc_l, 0, sizeof(acc_l));
    memset(acc_r, 0, sizeof(acc_r));

    pthread_mutex_lock(&g_lock);

    for (int m = 1; m < MAX_CHANNELS; m++)
    {
        shim_channel *mix = &g_ch[m];
        if (!mix->used || !mix->is_mixer || mix->state != BASS_ACTIVE_PLAYING)
            continue;

        int32_t mix_l = (int32_t)(mix->volume * 256.0f);
        int32_t mix_r = mix_l;

        for (int c = 1; c < MAX_CHANNELS; c++)
        {
            shim_channel *src = &g_ch[c];
            if (!src->used || src->parent != m || src->dec == 0)
                continue;

            /* 任何状态都读取：暂停/停止的通道位置不再前进，会自然变成静音重复，
               所以这里只需要区分「位置是否有效」。 */
            uint64_t pos = src->base;
            if (src->state == BASS_ACTIVE_PLAYING)
                pos += (now_ns() - src->start_ns) * bytes_per_sec(src) / 1000000000ull;
            if (src->len > 0 && pos > src->len)
                pos = src->len;

            int chans = src->chans > 0 && src->chans <= 2 ? src->chans : 2;
            uint64_t src_frame = pos / (uint64_t)(chans * 2);

            int64_t drift = (int64_t)src_frame - (int64_t)src->dec_frame;
            if (drift < 0 || drift > 8192)
            {
                ohosdec_seek(src->dec, src_frame);
                src->dec_frame = src_frame;
            }
            else if (drift > 0)
            {
                int16_t skip[256 * 2];
                while (drift > 0)
                {
                    uint64_t want = (uint64_t)drift > 256 ? 256 : (uint64_t)drift;
                    uint64_t got = ohosdec_read(src->dec, skip, want);
                    if (got == 0)
                    {
                        ohosdec_seek(src->dec, src_frame);
                        src->dec_frame = src_frame;
                        break;
                    }
                    src->dec_frame += got;
                    drift -= (int64_t)got;
                }
            }

            uint64_t need64 = (uint64_t)((double)frames * (double)src->base_freq / (double)g_audio_rate) + 2;
            if (need64 > AUDIO_PCM_CAP)
                need64 = AUDIO_PCM_CAP;

            int16_t pcm[AUDIO_PCM_CAP * 2];
            memset(pcm, 0, sizeof(pcm));
            uint64_t got = ohosdec_read(src->dec, pcm, need64);
            src->dec_frame += got;

            int32_t vol = (int32_t)(src->volume * 256.0f);
            int32_t pan_l = 256;
            int32_t pan_r = 256;
            if (src->pan < 0.0f)
                pan_r = (int32_t)((1.0f + src->pan) * 256.0f);
            else if (src->pan > 0.0f)
                pan_l = (int32_t)((1.0f - src->pan) * 256.0f);

            double step = (double)src->base_freq / (double)g_audio_rate;

            for (int i = 0; i < frames; i++)
            {
                double p = (double)i * step;
                uint64_t idx = (uint64_t)p;
                if (idx + 1 >= got)
                    break;
                uint64_t next = idx + 1;
                int frac = (int)((p - (double)idx) * 256.0);

                int l0 = chans == 1 ? pcm[idx * 2] : pcm[idx * chans];
                int l1 = chans == 1 ? pcm[next * 2] : pcm[next * chans];
                int r0 = chans == 1 ? l0 : pcm[idx * chans + 1];
                int r1 = chans == 1 ? l1 : pcm[next * chans + 1];

                int l = l0 + ((l1 - l0) * frac >> 8);
                int r = r0 + ((r1 - r0) * frac >> 8);

                acc_l[i] += ((l * vol * pan_l) >> 16) * mix_l;
                acc_r[i] += ((r * vol * pan_r) >> 16) * mix_r;
            }
        }
    }

    pthread_mutex_unlock(&g_lock);

    for (int i = 0; i < frames; i++)
    {
        int l = (acc_l[i] >> 8);
        int r = (acc_r[i] >> 8);
        out[i * 2] = (int16_t)(l < -32768 ? -32768 : (l > 32767 ? 32767 : l));
        out[i * 2 + 1] = (int16_t)(r < -32768 ? -32768 : (r > 32767 ? 32767 : r));
    }

    return length;
}

static int oh_audio_start_impl(int rate)
{
    OH_AudioStreamBuilder *builder = 0;
    if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS || builder == 0)
        return 0;

    OH_AudioStreamBuilder_SetSamplingRate(builder, rate);
    OH_AudioStreamBuilder_SetChannelCount(builder, 2);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_GAME);

    OH_AudioRenderer_Callbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.OH_AudioRenderer_OnWriteData = oh_audio_write;
    OH_AudioStreamBuilder_SetRendererCallback(builder, callbacks, 0);

    OH_AudioRenderer *renderer = 0;
    OH_AudioStream_Result result = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer);
    OH_AudioStreamBuilder_Destroy(builder);

    if (result != AUDIOSTREAM_SUCCESS || renderer == 0)
        return 0;

    g_renderer = renderer;
    g_audio_rate = rate > 0 ? rate : 44100;
    g_audio_active = 1;

    if (OH_AudioRenderer_Start(renderer) != AUDIOSTREAM_SUCCESS)
    {
        OH_AudioRenderer_Release(renderer);
        g_renderer = 0;
        g_audio_active = 0;
        return 0;
    }
    return 1;
}

static int oh_audio_start(int rate)
{
    if (g_renderer != 0)
        return OH_AudioRenderer_Start(g_renderer) == AUDIOSTREAM_SUCCESS;

    /* 44.1k 是 osu.Framework 混音器的固定频率；设备不支持时退到 48k，
       oh_audio_write 里已按 g_audio_rate 做线性重采样。 */
    if (oh_audio_start_impl(rate))
        return 1;
    if (rate != 48000 && oh_audio_start_impl(48000))
        return 1;
    return 0;
}

static void oh_audio_stop(void)
{
    g_audio_active = 0;
    if (g_renderer == 0)
        return;
    OH_AudioRenderer_Stop(g_renderer);
    OH_AudioRenderer_Release(g_renderer);
    g_renderer = 0;
}

int ohshim_dev_init(int device)
{
    g_dev_current = device < 0 ? 1 : device;
    g_dev_inited = 1;
    return 1;
}

int ohshim_dev_free(void)
{
    oh_audio_stop();
    g_dev_inited = 0;
    g_dev_current = -1;
    return 1;
}

int ohshim_dev_current(void) { return g_dev_current; }
int ohshim_dev_set(int device) { g_dev_current = device; return 1; }

#endif /* SHIM_MODULE == 0 */

#if SHIM_MODULE == 1 || SHIM_MODULE == 2
/* 由 libbass.so 导出，mix / fx 只是转发 */
extern uint64_t ohshim_channel_pos(int handle);
extern int ohshim_channel_set_pos(int handle, uint64_t pos);
extern int ohshim_channel_freq(int handle);
extern int ohshim_new_sync(void);
extern int ohshim_channel_play(int handle, int restart);
extern int ohshim_channel_active(int handle);
extern int ohshim_mixer_mark(int handle, int is_mixer);
extern int ohshim_mixer_add(int mixer, int channel);
extern int ohshim_mixer_remove(int channel);
#endif

/* ------------------------------------------------------------------ */
/* libbass.so                                                          */
/* ------------------------------------------------------------------ */

#if SHIM_MODULE == 0

typedef struct
{
    const char *name;
    const char *driver;
    uint32_t flags;
} BASS_DEVICEINFO;

typedef struct
{
    uint32_t flags;
    uint32_t hwsize;
    uint32_t hwfree;
    uint32_t freesam;
    uint32_t free3d;
    uint32_t minrate;
    uint32_t maxrate;
    int eax;
    uint32_t minbuf;
    uint32_t dsver;
    uint32_t latency;
    uint32_t initflags;
    uint32_t speakers;
    uint32_t freq;
} BASS_INFO;

typedef struct
{
    uint32_t freq;
    uint32_t chans;
    uint32_t flags;
    uint32_t ctype;
    uint32_t origres;
    uint32_t plugin;
    uint32_t sample;
    const char *filename;
} BASS_CHANNELINFO;

int BASS_GetVersion(void) { return 0x02041500; } /* 2.4.21 */
int BASS_ErrorGetCode(void) { return 0; }

int BASS_Init(int device, uint32_t freq, uint32_t flags, void *win, void *clsid)
{
    (void)freq; (void)flags; (void)win; (void)clsid;
    return ohshim_dev_init(device);
}

int BASS_Free(void) { return ohshim_dev_free(); }
int BASS_GetDevice(void) { return ohshim_dev_current(); }
int BASS_SetDevice(int device) { return ohshim_dev_set(device); }
int BASS_GetDeviceCount(void) { return 2; } /* NoSound + Default */

int BASS_GetDeviceInfo(int device, BASS_DEVICEINFO *info)
{
    if (!info || device < 0 || device > 1)
        return 0;

    if (device == 0)
    {
        info->name = "No sound";
        info->driver = "";
        info->flags = BASS_DEVICE_ENABLED;
    }
    else
    {
        info->name = "OpenHarmony Audio";
        info->driver = "ohaudio";
        info->flags = BASS_DEVICE_ENABLED | BASS_DEVICE_DEFAULT | BASS_DEVICE_INIT;
    }

    return 1;
}

int BASS_GetInfo(BASS_INFO *info)
{
    if (!info)
        return 0;
    memset(info, 0, sizeof(*info));
    info->minrate = 44100;
    info->maxrate = 44100;
    info->minbuf = 10;
    info->latency = 10;
    info->speakers = 2;
    info->freq = 44100;
    info->initflags = 0;
    return 1;
}

int BASS_Start(void) { return 1; }
int BASS_Stop(void) { return 1; }
int BASS_Pause(void) { return 1; }
int BASS_Update(uint32_t length) { (void)length; return 1; }
float BASS_GetCPU(void) { return 0.0f; }
int BASS_SetConfig(uint32_t option, uint32_t value) { (void)option; (void)value; return 1; }
uint32_t BASS_GetConfig(uint32_t option) { (void)option; return 0; }
int BASS_SetConfigPtr(uint32_t option, void *value) { (void)option; (void)value; return 1; }
void *BASS_GetConfigPtr(uint32_t option) { (void)option; return 0; }
int BASS_SetVolume(float volume) { (void)volume; return 1; }
float BASS_GetVolume(void) { return 1.0f; }

int BASS_PluginLoad(const char *file, uint32_t flags) { (void)file; (void)flags; return 0; }
int BASS_PluginFree(int handle) { (void)handle; return 1; }
const void *BASS_PluginGetInfo(int handle) { (void)handle; return 0; }

/* ---- 流 / 采样创建 ---- */

int BASS_StreamCreate(uint32_t freq, uint32_t chans, uint32_t flags, void *proc, void *user)
{
    (void)flags; (void)proc; (void)user;
    return ohshim_channel_create((int)freq, (int)chans, 0);
}

int BASS_StreamCreateFile(int mem, const void *file, uint64_t offset, uint64_t length, uint32_t flags)
{
    (void)mem; (void)file; (void)offset; (void)length; (void)flags;
    return ohshim_channel_create(44100, 2, 0);
}

int BASS_StreamCreateURL(const char *url, uint32_t offset, uint32_t flags, void *proc, void *user)
{
    (void)url; (void)offset; (void)flags; (void)proc; (void)user;
    return ohshim_channel_create(44100, 2, 0);
}

/*
 * BASS_StreamCreateFileUser —— osu 加载**所有音轨**的唯一入口。
 *
 * TrackBass.prepareStream() 会把自己的 Stream 包成 BASS_FILEPROCS 传进来：
 *     Bass.CreateStream(StreamSystem.NoBuffer, Decode | Prescan | AsyncFile,
 *                       callbacks, handle)
 * 所以这个函数不在的话，任何音轨都会抛 EntryPointNotFoundException，
 * 谱面和菜单音乐全部加载失败（M2 实测）。
 *
 * 这里做三件 BASS 内部本来会做的事：
 *   1. 通过 FileProcedures 把整条流读进内存（谱面音频通常 1~10 MB，
 *      比在 musl 上折腾一边读一边解码稳得多，也让 seek 变成内存内定位）；
 *   2. 用解码器探测**真实**的采样率 / 声道数 / 总帧数 —— 这三个值不能估算：
 *      VBR mp3 与 ogg 的位速都不是常数，估错会让进度条和 seek 全偏
 *      （osu 用它们算 Track.Length 与 BASS_ChannelBytes2Seconds）；
 *   3. 按源格式建立通道。位置仍然由墙钟推进（本阶段不产生 PCM），
 *      但换算基准与真实文件一致，播放/暂停/seek 的行为就是对的。
 *
 * 解码器句柄挂在通道上，BASS_StreamFree 时释放，并回调 procs->close
 * 把托管侧的 Stream 关掉（TrackBass 依赖这个行为来 Dispose）。
 */
int BASS_StreamCreateFileUser(uint32_t system, uint32_t flags, const BASS_FILEPROCS *procs, void *user)
{
    (void)system;
    (void)flags;

    if (procs == 0 || procs->read == 0)
        return 0;

    const uint64_t max_size = 512ull * 1024 * 1024;

    uint64_t cap = procs->length ? procs->length(user) : 0;
    if (cap == 0 || cap > max_size)
        cap = 1ull << 20; /* 长度未知或离谱：从 1 MB 开始按需翻倍 */

    uint8_t *data = (uint8_t *)malloc((size_t)cap);
    if (data == 0)
        return 0;

    uint64_t total = 0;
    uint64_t alloc = cap;

    for (;;)
    {
        if (total == alloc)
        {
            if (alloc >= max_size)
                break;

            uint64_t next = alloc * 2;
            uint8_t *grown = (uint8_t *)realloc(data, (size_t)next);
            if (grown == 0)
                break;

            data = grown;
            alloc = next;
        }

        uint32_t want = (alloc - total) > (1u << 20) ? (1u << 20) : (uint32_t)(alloc - total);
        uint32_t got = procs->read(data + total, want, user);

        if (got == 0)
            break; /* EOF */

        total += got;
    }

    int handle = ohshim_channel_create(44100, 2, 0);

    if (handle == 0)
    {
        free(data);
        if (procs->close)
            procs->close(user);
        return 0;
    }

    void *dec = ohosdec_open(data, (size_t)total);

    int freq = 44100;
    int chans = 2;
    uint64_t frames = 0;

    if (dec != 0)
    {
        int f = (int)ohosdec_freq(dec);
        int c = (int)ohosdec_chans(dec);

        if (f > 0)
            freq = f;
        if (c > 0)
            chans = c;

        frames = ohosdec_frames(dec);
    }

    uint64_t len = frames * (uint64_t)chans * 2ull;

    float bitrate = 0.0f;
    if (frames > 0 && freq > 0)
    {
        double seconds = (double)frames / (double)freq;
        if (seconds > 0.0)
            bitrate = (float)((double)total * 8.0 / 1000.0 / seconds);
    }

    pthread_mutex_lock(&g_lock);
    g_ch[handle].freq = freq;
    g_ch[handle].base_freq = freq;
    g_ch[handle].chans = chans;
    g_ch[handle].len = len;
    g_ch[handle].bitrate = bitrate;
    g_ch[handle].dec = dec;
    g_ch[handle].procs = procs;
    g_ch[handle].procs_user = user;
    /* 解码器直接引用这份内存，所以必须一直持有到 StreamFree。 */
    g_ch[handle].src_data = (dec != 0) ? data : 0;
    pthread_mutex_unlock(&g_lock);

    if (dec == 0)
    {
        /* 解不开（少见编码 / 文件损坏）：不抛错，退化成静音通道，
           让游戏继续跑，而不是整条音轨加载失败把谱面卡死。 */
        free(data);
    }

    return handle;
}

int BASS_StreamFree(int handle) { return ohshim_channel_free(handle); }
uint64_t BASS_StreamGetFilePosition(int handle, uint32_t mode) { (void)handle; (void)mode; return 0; }
uint32_t BASS_StreamPutData(int handle, const void *buffer, uint32_t length) { (void)handle; (void)buffer; (void)length; return 0; }
uint32_t BASS_StreamPutFileData(int handle, const void *buffer, uint32_t length) { (void)handle; (void)buffer; (void)length; return 0; }

int BASS_MusicLoad(int mem, const void *file, uint64_t offset, uint32_t length, uint32_t flags, uint32_t freq)
{
    (void)mem; (void)file; (void)offset; (void)length; (void)flags; (void)freq;
    return 0;
}

int BASS_MusicFree(int handle) { (void)handle; return 1; }

int BASS_SampleLoad(int mem, const void *file, uint64_t offset, uint32_t length, uint32_t max, uint32_t flags)
{
    (void)mem; (void)file; (void)offset; (void)length; (void)max; (void)flags;
    return ohshim_channel_create(44100, 2, 0);
}

int BASS_SampleCreate(uint32_t length, uint32_t freq, uint32_t chans, uint32_t max, uint32_t flags)
{
    (void)length; (void)freq; (void)chans; (void)max; (void)flags;
    return 0;
}

int BASS_SampleFree(int handle) { (void)handle; return 1; }
int BASS_SampleGetChannel(int handle, int createNew)
{
    /* 采样句柄本身就是通道句柄；复用即可（静音垫片无需多通道） */
    (void)createNew;
    return handle;
}
int BASS_SampleGetChannels(int handle, int *channels) { (void)handle; (void)channels; return 0; }
int BASS_SampleGetInfo(int handle, void *info) { (void)handle; (void)info; return 0; }
int BASS_SampleSetInfo(int handle, const void *info) { (void)handle; (void)info; return 1; }
int BASS_SampleGetData(int handle, void *buffer) { (void)handle; (void)buffer; return 0; }
int BASS_SampleSetData(int handle, const void *buffer) { (void)handle; (void)buffer; return 1; }
int BASS_SampleStop(int handle) { return ohshim_channel_stop(handle); }

/* ---- 通道 ---- */

int BASS_ChannelPlay(int handle, int restart) { return ohshim_channel_play(handle, restart); }
int BASS_ChannelPause(int handle) { return ohshim_channel_pause(handle); }
int BASS_ChannelStop(int handle) { return ohshim_channel_stop(handle); }
int BASS_ChannelIsActive(int handle) { return ohshim_channel_active(handle); }
int BASS_ChannelSetDevice(int handle, int device) { (void)handle; (void)device; return 1; }
int BASS_ChannelGetDevice(int handle) { (void)handle; return ohshim_dev_current(); }

uint64_t BASS_ChannelGetPosition(int handle, uint32_t mode) { (void)mode; return ohshim_channel_pos(handle); }
int BASS_ChannelSetPosition(int handle, uint64_t pos, uint32_t mode)
{
    (void)mode;
    return ohshim_channel_set_pos(handle, pos);
}

uint64_t BASS_ChannelGetLength(int handle, uint32_t mode) { (void)mode; return ohshim_channel_len(handle); }

double BASS_ChannelBytes2Seconds(int handle, uint64_t pos)
{
    double rate = (double)ohshim_channel_freq(handle) * (double)ohshim_channel_chans(handle) * 2.0;
    return rate > 0.0 ? (double)pos / rate : 0.0;
}

uint64_t BASS_ChannelSeconds2Bytes(int handle, double pos)
{
    double rate = (double)ohshim_channel_freq(handle) * (double)ohshim_channel_chans(handle) * 2.0;
    return (uint64_t)(pos * rate);
}

int BASS_ChannelSetAttribute(int handle, uint32_t attrib, float value)
{
    if (handle <= 0 || handle >= MAX_CHANNELS || !g_ch[handle].used)
        return 1;
    pthread_mutex_lock(&g_lock);
    if (attrib == BASS_ATTRIB_VOL)
        g_ch[handle].volume = value;
    else if (attrib == BASS_ATTRIB_PAN)
        g_ch[handle].pan = value;
    else if (attrib == BASS_ATTRIB_FREQ && value > 0.0f)
        g_ch[handle].freq = (int)value;
    else if (attrib == BASS_ATTRIB_TEMPO)
        g_ch[handle].tempo = value;
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int BASS_ChannelGetAttribute(int handle, uint32_t attrib, float *value)
{
    if (!value)
        return 0;
    switch (attrib)
    {
        case BASS_ATTRIB_FREQ:
            *value = (float)ohshim_channel_freq(handle);
            return 1;

        case BASS_ATTRIB_VOL:
            *value = (handle > 0 && handle < MAX_CHANNELS) ? g_ch[handle].volume : 1.0f;
            return 1;

        case BASS_ATTRIB_PAN:
            *value = (handle > 0 && handle < MAX_CHANNELS) ? g_ch[handle].pan : 0.0f;
            return 1;

        case BASS_ATTRIB_BITRATE:
            /* TrackBass 在建流后立刻读它（Bass.ChannelGetAttribute(stream, Bitrate)），
               读不到会退化到 0，进而影响 osu 的加载时间估算与频谱显示。 */
            *value = 0.0f;
            if (handle > 0 && handle < MAX_CHANNELS)
            {
                pthread_mutex_lock(&g_lock);
                *value = g_ch[handle].bitrate;
                pthread_mutex_unlock(&g_lock);
            }
            return 1;

        default:
            *value = 0.0f;
            return 1;
    }
}

int BASS_ChannelSlideAttribute(int handle, uint32_t attrib, float value, uint32_t time)
{
    (void)time;
    return BASS_ChannelSetAttribute(handle, attrib, value);
}

int BASS_ChannelIsSliding(int handle, uint32_t attrib) { (void)handle; (void)attrib; return 0; }
uint32_t BASS_ChannelFlags(int handle, uint32_t flags, uint32_t mask) { (void)handle; (void)flags; (void)mask; return 0; }
int BASS_ChannelUpdate(int handle, uint32_t length) { (void)handle; (void)length; return 1; }
int BASS_ChannelLock(int handle, int lock) { (void)handle; (void)lock; return 1; }

int BASS_ChannelGetInfo(int handle, BASS_CHANNELINFO *info)
{
    if (!info)
        return 0;
    memset(info, 0, sizeof(*info));
    info->freq = (uint32_t)ohshim_channel_freq(handle);
    info->chans = (uint32_t)ohshim_channel_chans(handle);
    info->ctype = 0x10000; /* BASS_CTYPE_STREAM */
    return 1;
}

/* 静音：没有 PCM 可读。返回 0 表示「本帧没有数据」，调用方会稍后重试，
   TrackBass 只在真正播歌时读数据，M1b 自检不涉及。 */
uint32_t BASS_ChannelGetData(int handle, void *buffer, uint32_t length)
{
    (void)handle;
    if (buffer && length)
        memset(buffer, 0, length);
    return 0;
}

uint32_t BASS_ChannelGetLevel(int handle)
{
    (void)handle;
    return 0; /* 左右声道都是 0 */
}

int BASS_ChannelGetLevelEx(int handle, float *levels, float length, uint32_t flags)
{
    (void)handle; (void)length; (void)flags;
    if (levels)
    {
        levels[0] = 0.0f;
        levels[1] = 0.0f;
    }
    return 1;
}

int BASS_ChannelSetSync(int handle, uint32_t type, uint64_t param, void *proc, void *user)
{
    (void)handle; (void)type; (void)param; (void)proc; (void)user;
    return ohshim_new_sync();
}

int BASS_ChannelRemoveSync(int handle, int sync) { (void)handle; (void)sync; return 1; }
int BASS_ChannelSetDSP(int handle, void *proc, void *user, int priority) { (void)handle; (void)proc; (void)user; (void)priority; return 0; }
int BASS_ChannelRemoveDSP(int handle, int dsp) { (void)handle; (void)dsp; return 1; }
int BASS_ChannelSetLink(int handle, int channel) { (void)handle; (void)channel; return 1; }
int BASS_ChannelRemoveLink(int handle, int channel) { (void)handle; (void)channel; return 1; }
const char *BASS_ChannelGetTags(int handle, uint32_t tags) { (void)handle; (void)tags; return 0; }

int BASS_ChannelSetFX(int handle, uint32_t type, int priority) { (void)handle; (void)type; (void)priority; return ohshim_new_sync(); }
int BASS_ChannelRemoveFX(int handle, int fx) { (void)handle; (void)fx; return 1; }
int BASS_FXSetParameters(int handle, const void *params) { (void)handle; (void)params; return 1; }
int BASS_FXGetParameters(int handle, void *params) { (void)handle; (void)params; return 1; }
int BASS_FXSetPriority(int handle, int priority) { (void)handle; (void)priority; return 1; }
int BASS_FXReset(int handle) { (void)handle; return 1; }

/* ---- 3D（osu! 不用，保持可链接） ---- */
int BASS_Apply3D(void) { return 1; }
int BASS_Set3DFactors(float distf, float rollf, float doppf) { (void)distf; (void)rollf; (void)doppf; return 1; }
int BASS_Get3DFactors(float *distf, float *rollf, float *doppf) { (void)distf; (void)rollf; (void)doppf; return 1; }
int BASS_Set3DPosition(const void *pos, const void *vel, const void *front, const void *top) { (void)pos; (void)vel; (void)front; (void)top; return 1; }
int BASS_Get3DPosition(void *pos, void *vel, void *front, void *top) { (void)pos; (void)vel; (void)front; (void)top; return 1; }
int BASS_ChannelSet3DAttributes(int handle, int mode, float min, float max, int iangle, int oangle, float outvol) { (void)handle; (void)mode; (void)min; (void)max; (void)iangle; (void)oangle; (void)outvol; return 1; }
int BASS_ChannelGet3DAttributes(int handle, uint32_t *mode, float *min, float *max, uint32_t *iangle, uint32_t *oangle, float *outvol) { (void)handle; (void)mode; (void)min; (void)max; (void)iangle; (void)oangle; (void)outvol; return 1; }
int BASS_ChannelSet3DPosition(int handle, const void *pos, const void *orient, const void *vel) { (void)handle; (void)pos; (void)orient; (void)vel; return 1; }
int BASS_ChannelGet3DPosition(int handle, void *pos, void *orient, void *vel) { (void)handle; (void)pos; (void)orient; (void)vel; return 1; }

/* ---- 录音（osu! 不用，返回失败） ---- */
int BASS_RecordInit(int device) { (void)device; return 0; }
int BASS_RecordFree(void) { return 1; }
int BASS_RecordGetDevice(void) { return -1; }
int BASS_RecordSetDevice(int device) { (void)device; return 1; }
int BASS_RecordGetDeviceCount(void) { return 0; }
int BASS_RecordGetDeviceInfo(int device, void *info) { (void)device; (void)info; return 0; }
int BASS_RecordGetInfo(void *info) { (void)info; return 0; }
int BASS_RecordGetInput(int input, float *volume) { (void)input; (void)volume; return -1; }
const char *BASS_RecordGetInputName(int input) { (void)input; return 0; }
int BASS_RecordSetInput(int input, uint32_t flags, float volume) { (void)input; (void)flags; (void)volume; return 0; }
int BASS_RecordStart(uint32_t freq, uint32_t chans, uint32_t flags, void *proc, void *user) { (void)freq; (void)chans; (void)flags; (void)proc; (void)user; return 0; }

#endif /* SHIM_MODULE == 0 */

/* ------------------------------------------------------------------ */
/* libbassmix.so                                                       */
/* ------------------------------------------------------------------ */

#if SHIM_MODULE == 1

int BASS_Mixer_GetVersion(void) { return 0x02041200; }

int BASS_Mixer_StreamCreate(uint32_t freq, uint32_t chans, uint32_t flags)
{
    /* BASS_MIXER_NONSTOP = 0x200000；Decode 型子混音器本身不出声，
       但它的父混音器会把它当一个普通源拉取，所以两种都要登记成 mixer。 */
    (void)flags;
    extern int ohshim_channel_create(int freq, int chans, uint64_t len);
    int h = ohshim_channel_create((int)freq, (int)chans, 0);
    if (h > 0)
        ohshim_mixer_mark(h, 1);
    return h;
}

int BASS_Mixer_StreamAddChannel(int handle, int channel, uint32_t flags)
{
    (void)flags;
    return ohshim_mixer_add(handle, channel);
}

int BASS_Mixer_StreamAddChannelEx(int handle, int channel, uint32_t flags, uint64_t start, uint64_t length)
{
    (void)flags; (void)start; (void)length;
    return ohshim_mixer_add(handle, channel);
}

int BASS_Mixer_StreamGetChannels(int handle, int *channels, int count)
{
    (void)handle; (void)channels; (void)count;
    return 0;
}

int BASS_Mixer_ChannelRemove(int handle) { return ohshim_mixer_remove(handle); }
int BASS_Mixer_ChannelGetMixer(int handle)
{
    extern int ohshim_channel_get_parent(int handle);
    return ohshim_channel_get_parent(handle);
}

uint64_t BASS_Mixer_ChannelGetPosition(int handle, uint32_t mode)
{
    (void)mode;
    return ohshim_channel_pos(handle);
}

uint64_t BASS_Mixer_ChannelGetPositionEx(int handle, uint32_t mode, uint32_t delay)
{
    (void)mode; (void)delay;
    return ohshim_channel_pos(handle);
}

int BASS_Mixer_ChannelSetPosition(int handle, uint64_t pos, uint32_t mode)
{
    (void)mode;
    return ohshim_channel_set_pos(handle, pos);
}

int BASS_Mixer_ChannelGetLevel(int handle)
{
    (void)handle;
    return 0;
}

int BASS_Mixer_ChannelGetLevelEx(int handle, float *levels, float length, uint32_t flags)
{
    (void)handle; (void)length; (void)flags;
    if (levels)
    {
        levels[0] = 0.0f;
        levels[1] = 0.0f;
    }
    return 1;
}

uint32_t BASS_Mixer_ChannelGetData(int handle, void *buffer, uint32_t length)
{
    (void)handle; (void)buffer; (void)length;
    return 0;
}

uint32_t BASS_Mixer_ChannelFlags(int handle, uint32_t flags, uint32_t mask)
{
    (void)handle; (void)flags; (void)mask;
    return 0;
}

int BASS_Mixer_ChannelSetSync(int handle, uint32_t type, uint64_t param, void *proc, void *user)
{
    (void)handle; (void)type; (void)param; (void)proc; (void)user;
    return ohshim_new_sync();
}

int BASS_Mixer_ChannelRemoveSync(int handle, int sync) { (void)handle; (void)sync; return 1; }
int BASS_Mixer_ChannelSetMatrix(int handle, const void *matrix) { (void)handle; (void)matrix; return 1; }
int BASS_Mixer_ChannelSetMatrixEx(int handle, const void *matrix, float time) { (void)handle; (void)matrix; (void)time; return 1; }
int BASS_Mixer_ChannelGetMatrix(int handle, void *matrix) { (void)handle; (void)matrix; return 0; }
int BASS_Mixer_ChannelSetEnvelope(int handle, uint32_t type, const void *nodes, int count) { (void)handle; (void)type; (void)nodes; (void)count; return 1; }
int BASS_Mixer_ChannelSetEnvelopePos(int handle, uint32_t type, uint64_t pos) { (void)handle; (void)type; (void)pos; return 1; }
uint64_t BASS_Mixer_ChannelGetEnvelopePos(int handle, uint32_t type, float *value) { (void)handle; (void)type; (void)value; return 0; }

int BASS_Split_StreamCreate(int channel, uint32_t flags, const int *chanmap) { (void)channel; (void)flags; (void)chanmap; return 0; }
int BASS_Split_StreamGetSource(int handle) { (void)handle; return 0; }
uint32_t BASS_Split_StreamGetSplits(int handle, int *splits, uint32_t count) { (void)handle; (void)splits; (void)count; return 0; }
uint32_t BASS_Split_StreamGetAvailable(int handle) { (void)handle; return 0; }
int BASS_Split_StreamReset(int handle) { (void)handle; return 1; }
int BASS_Split_StreamResetEx(int handle, int offset) { (void)handle; (void)offset; return 1; }

#endif /* SHIM_MODULE == 1 */

/* ------------------------------------------------------------------ */
/* libbass_fx.so                                                       */
/* ------------------------------------------------------------------ */

#if SHIM_MODULE == 2

int BASS_FX_GetVersion(void) { return 0x02040900; }

/* tempo / reverse 直接复用源通道句柄：位置、播放状态天然一致，
   省掉一层「影子通道」的同步问题（静音垫片没有真正的重采样）。 */
int BASS_FX_TempoCreate(int channel, uint32_t flags)
{
    (void)flags;
    return channel;
}

int BASS_FX_TempoGetSource(int handle) { return handle; }
float BASS_FX_TempoGetRateRatio(int handle) { (void)handle; return 1.0f; }

int BASS_FX_ReverseCreate(int channel, float dec_block, uint32_t flags)
{
    (void)dec_block; (void)flags;
    return channel;
}

int BASS_FX_ReverseGetSource(int handle) { return handle; }

int BASS_FX_BPM_DecodeGet(int channel, double start, double end, uint32_t minmax, uint32_t flags, void *proc, void *user)
{
    (void)channel; (void)start; (void)end; (void)minmax; (void)flags; (void)proc; (void)user;
    return 0;
}

int BASS_FX_BPM_Free(int handle) { (void)handle; return 1; }
int BASS_FX_BPM_BeatDecodeGet(int channel, double start, double end, uint32_t flags, void *proc, void *user) { (void)channel; (void)start; (void)end; (void)flags; (void)proc; (void)user; return 0; }
int BASS_FX_BPM_BeatFree(int handle) { (void)handle; return 1; }
int BASS_FX_BPM_BeatCallbackSet(int handle, void *proc, void *user) { (void)handle; (void)proc; (void)user; return 0; }
int BASS_FX_BPM_BeatCallbackReset(int handle) { (void)handle; return 1; }
int BASS_FX_BPM_BeatSetParameters(int handle, float bandwidth, float centerfreq, float beat_attack, float beat_release) { (void)handle; (void)bandwidth; (void)centerfreq; (void)beat_attack; (void)beat_release; return 1; }
int BASS_FX_BPM_BeatGetParameters(int handle, float *bandwidth, float *centerfreq, float *beat_attack, float *beat_release) { (void)handle; (void)bandwidth; (void)centerfreq; (void)beat_attack; (void)beat_release; return 0; }
int BASS_FX_BPM_CallbackSet(int handle, void *proc, double period, uint32_t minmax, void *user) { (void)handle; (void)proc; (void)period; (void)minmax; (void)user; return 0; }
int BASS_FX_BPM_CallbackReset(int handle) { (void)handle; return 1; }

#endif /* SHIM_MODULE == 2 */
