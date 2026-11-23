/*
 * ohosdec —— 给 BASS 垫片用的音频解码层（miniaudio + stb_vorbis）
 * ---------------------------------------------------------------------------
 * 为什么需要它
 *   BASS 是闭源的，它内部自带 mp3 / ogg / flac / wav 解码器。垫片要在
 *   BASS_StreamCreateFileUser 里报出**真实的**采样率、声道数、总帧数，
 *   否则 osu 的音轨长度、进度条、seek 全都不对（这些值只从解码器头部才能拿到，
 *   靠文件大小估算是错的：VBR mp3 与 ogg 的位速都不是常数）。
 *
 * 为什么只引解码、不引 miniaudio 的设备层
 *   miniaudio 没有 OpenHarmony 后端。设备输出走 OH_AudioRenderer
 *   （native_audiorenderer.h），由 bass_shim.c 自己接。所以这里用
 *   MA_NO_DEVICE_IO 把设备/线程那半边整个裁掉，只留 ma_decoder。
 *   顺带还裁掉 resource manager / node graph / engine / 波形生成，
 *   目标文件从 300 KB 级降到几十 KB。
 *
 * 支持格式（miniaudio 内置）
 *   wav / mp3(dr_mp3) / flac(dr_flac)
 *   ogg-vorbis —— 需要先把 stb_vorbis 的头导入，miniaudio 才会定义
 *   MA_HAS_VORBIS。osu 的谱面音频大量是 .ogg，这一条不能省。
 *
 * 对外只暴露不透明句柄 + 查询函数，bass_shim.c 不需要 include miniaudio.h
 * （那会让每个编译单元都去解析一个 4 MB 的头）。
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "ohosdec.h"

/* stb_vorbis 的「头模式」：只出声明，不出实现，让 miniaudio 认为 Vorbis 可用。 */
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

#define MA_NO_DEVICE_IO
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_GENERATION
#define MA_NO_ENCODING
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

/* 头模式之后再把实现拉进来（stb_vorbis.c 自己的实现部分）。 */
#undef STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

#include <stdlib.h>

struct ohosdec
{
    ma_decoder decoder;
    /* 原始压缩数据由调用方持有（它同时还要给 BASS_FILEPROCS 用），这里不复制。 */
    ma_uint32 freq;
    ma_uint32 chans;
    ma_uint64 frames;
};

void *ohosdec_open(const void *data, size_t size)
{
    if (data == NULL || size == 0)
        return NULL;

    struct ohosdec *d = (struct ohosdec *)calloc(1, sizeof(*d));
    if (d == NULL)
        return NULL;

    /* s16 + 源声道数 + 源采样率：垫片对外报的就是源格式，
       这样 BASS_ChannelBytes2Seconds 之类的换算与真实文件完全一致。 */
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_s16, 0, 0);

    if (ma_decoder_init_memory(data, size, &cfg, &d->decoder) != MA_SUCCESS)
    {
        free(d);
        return NULL;
    }

    ma_uint32 chans = 0;
    ma_uint32 freq = 0;
    if (ma_decoder_get_data_format(&d->decoder, NULL, &chans, &freq, NULL, 0) != MA_SUCCESS)
    {
        ma_decoder_uninit(&d->decoder);
        free(d);
        return NULL;
    }

    ma_uint64 frames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&d->decoder, &frames) != MA_SUCCESS)
        frames = 0;

    d->freq = freq > 0 ? freq : 44100;
    d->chans = chans > 0 ? chans : 2;
    d->frames = frames;

    return d;
}

void ohosdec_close(void *handle)
{
    struct ohosdec *d = (struct ohosdec *)handle;
    if (d == NULL)
        return;

    ma_decoder_uninit(&d->decoder);
    free(d);
}

uint32_t ohosdec_freq(void *handle)
{
    struct ohosdec *d = (struct ohosdec *)handle;
    return d ? d->freq : 0;
}

uint32_t ohosdec_chans(void *handle)
{
    struct ohosdec *d = (struct ohosdec *)handle;
    return d ? d->chans : 0;
}

uint64_t ohosdec_frames(void *handle)
{
    struct ohosdec *d = (struct ohosdec *)handle;
    return d ? d->frames : 0;
}

uint64_t ohosdec_read(void *handle, int16_t *out, uint64_t frames)
{
    struct ohosdec *d = (struct ohosdec *)handle;
    if (d == NULL || out == NULL || frames == 0)
        return 0;

    ma_uint64 got = 0;
    if (ma_decoder_read_pcm_frames(&d->decoder, out, frames, &got) != MA_SUCCESS)
        return 0;

    return got;
}

int ohosdec_seek(void *handle, uint64_t frame)
{
    struct ohosdec *d = (struct ohosdec *)handle;
    if (d == NULL)
        return 0;

    return ma_decoder_seek_to_pcm_frame(&d->decoder, frame) == MA_SUCCESS ? 1 : 0;
}
