#ifndef OSU_AUDIO_ENGINE_H
#define OSU_AUDIO_ENGINE_H

#include <atomic>
#include <cstdint>
#include <vector>

#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

namespace osu {

/**
 * 打击音种类。顺序与 osu! 的 HitSample 位标志一致：
 *   Normal=1, Whistle=2, Finish=4, Clap=8
 * 这里用序号索引，具体位组合在 ArkTS 侧展开成多次 Play()。
 */
enum class HitSoundKind : int {
    Normal = 0,
    Whistle = 1,
    Finish = 2,
    Clap = 3,
    Count = 4,
};

/**
 * 低延迟打击音渲染器。
 *
 * 为什么音乐不走这里：谱面音频是 mp3/ogg，本机没有现成的解码器能直接喂给
 * OHAudio 回调（OH_AVCodec 需要自己搭 demux+decode 线程池）。所以音乐交给
 * ArkTS 的 AVPlayer，这个引擎只负责"按下就要响"的打击音——它才是对延迟敏感的那部分。
 *
 * 线程模型：
 *   - Play() 由 JS 线程调用，只做无锁入队
 *   - OnWrite() 在系统音频线程，出队 + 混音，绝不加锁、绝不分配内存
 *   - 声音采样在 Init() 里一次性合成好，运行期只读
 */
class AudioEngine {
public:
    bool Init(int sampleRate, int channels);
    void Shutdown();
    bool Ready() const { return renderer_ != nullptr; }

    /** 立即触发一个打击音。volume 会被夹到 [0,1]。 */
    void Play(HitSoundKind kind, float volume);

    int SampleRate() const { return sampleRate_; }
    int Channels() const { return channels_; }

    /** 设备上报的整链路延迟（ms），-1 表示查询失败。只在 Init 时查一次。 */
    double RouteLatencyMs() const { return routeLatencyMs_; }
    /** 回调缓冲区时长（ms）= 一次写入要等多久才播完，这是低延迟的真实下限。 */
    double BufferLatencyMs() const;
    /** 是否真的进了 FAST 通路（0=普通 1=FAST），决定打击音还能不能再压低延迟。 */
    int FastStatus() const;
    uint32_t Underruns() const;
    uint64_t FramesRendered() const { return framesRendered_.load(std::memory_order_relaxed); }
    int VoiceCount() const { return activeVoices_; }

private:
    static OH_AudioData_Callback_Result OnWrite(OH_AudioRenderer *renderer, void *userData,
                                                void *audioData, int32_t audioDataSize);

    void Render(int16_t *out, int frames);
    void StartVoice(int kind, float volume);
    void BuildSampleBank();

    static constexpr int kMaxVoices = 64;
    static constexpr int kTriggerCapacity = 256; // 必须是 2 的幂

    struct Voice {
        int kind = -1;
        int pos = 0;
        float volume = 0.0f;
    };

    struct Trigger {
        int kind = 0;
        float volume = 0.0f;
    };

    OH_AudioRenderer *renderer_ = nullptr;
    OH_AudioStreamBuilder *builder_ = nullptr;
    int sampleRate_ = 48000;
    int channels_ = 2;
    int callbackFrames_ = 0;
    double routeLatencyMs_ = -1.0;
    int fastHint_ = 0;

    std::vector<int16_t> bank_[static_cast<int>(HitSoundKind::Count)];

    Voice voices_[kMaxVoices];
    int activeVoices_ = 0;

    // 单生产者（JS 线程）/ 单消费者（音频线程）无锁队列
    Trigger triggers_[kTriggerCapacity];
    std::atomic<uint32_t> triggerWrite_{0};
    std::atomic<uint32_t> triggerRead_{0};

    std::atomic<uint64_t> framesRendered_{0};
};

} // namespace osu

#endif // OSU_AUDIO_ENGINE_H
