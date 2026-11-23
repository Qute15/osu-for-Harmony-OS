/*
 * ohosdec.h —— 音频解码层的窄接口。
 *
 * 设计原则：bass_shim.c 只看见不透明句柄和几个查询/读取函数，
 * 不 include miniaudio.h（4 MB 头，每个编译单元解析一次太浪费），
 * 也不暴露 ma_* 类型，这样以后换解码器（比如直接接 OH_AVCodec）
 * 只需要改 ma_decode.c，垫片本身不用动。
 */
#ifndef OHSODEC_H
#define OHSODEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 从内存里的压缩音频打开解码器；失败返回 NULL。数据由调用方持有并保证存活。 */
void *ohosdec_open(const void *data, size_t size);

void ohosdec_close(void *handle);

/* 源格式参数（解码输出为 s16、源声道数、源采样率）。 */
uint32_t ohosdec_freq(void *handle);
uint32_t ohosdec_chans(void *handle);

/* 总帧数；无法确定（少数流式容器）时为 0。 */
uint64_t ohosdec_frames(void *handle);

/* 读取交错 s16 PCM，返回实际读到的帧数。 */
uint64_t ohosdec_read(void *handle, int16_t *out, uint64_t frames);

/* 定位到指定帧，成功返回 1。 */
int ohosdec_seek(void *handle, uint64_t frame);

#ifdef __cplusplus
}
#endif

#endif /* OHSODEC_H */
