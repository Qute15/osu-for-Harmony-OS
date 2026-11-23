#include "audio_engine.h"

// hilog 的 domain/tag 默认是 0/NULL，那样打出来的日志在 hilog 缓冲区里根本查不到。
// 必须在 include 之前定义，顺序不能动。
#define LOG_DOMAIN 0x0F0F
#define LOG_TAG "OSU-AUDIO"
#include <hilog/log.h>

#include <cmath>
#include <cstring>

namespace osu {

namespace {

constexpr const char *kTag = "osu-audio";
constexpr double kPi = 3.14159265358979323846;

inline int16_t Clamp16(int32_t v)
{
    if (v > 32767) {
        return 32767;
    }
    if (v < -32768) {
        return -32768;
    }
    return static_cast<int16_t>(v);
}

/** 确定性噪声：同一个种子每次构建的打击音完全一样，便于回归对比。 */
struct Noise {
    uint32_t state;
    explicit Noise(uint32_t seed) : state(seed) {}
    float next()
    {
        state = state * 1664525u + 1013904223u;
        // [-1,1]
        return static_cast<float>(static_cast<int32_t>(state)) / 2147483648.0f;
    }
};

} // namespace

void AudioEngine::BuildSampleBank()
{
    const double sr = static_cast<double>(sampleRate_);

    // ---- Normal：短促木质敲击，osu! 默认 hitnormal 的体感 ----
    {
        const int len = static_cast<int>(sr * 0.085);
        auto &buf = bank_[static_cast<int>(HitSoundKind::Normal)];
        buf.resize(static_cast<size_t>(len));
        Noise noise(0x51ED2701u);
        for (int i = 0; i < len; i++) {
            const double t = static_cast<double>(i) / sr;
            const double body = std::sin(2.0 * kPi * 620.0 * t) * std::exp(-t / 0.013);
            const double sub = std::sin(2.0 * kPi * 300.0 * t) * std::exp(-t / 0.020) * 0.45;
            const double click = noise.next() * std::exp(-t / 0.0025) * 0.35;
            const double v = (body * 0.55 + sub + click) * 0.62;
            buf[static_cast<size_t>(i)] = Clamp16(static_cast<int32_t>(v * 32767.0));
        }
    }

    // ---- Whistle：高频长音 ----
    {
        const int len = static_cast<int>(sr * 0.170);
        auto &buf = bank_[static_cast<int>(HitSoundKind::Whistle)];
        buf.resize(static_cast<size_t>(len));
        for (int i = 0; i < len; i++) {
            const double t = static_cast<double>(i) / sr;
            const double env = std::exp(-t / 0.055) * 0.9 + std::exp(-t / 0.4) * 0.1;
            const double v = std::sin(2.0 * kPi * 1480.0 * t) * env * 0.34;
            buf[static_cast<size_t>(i)] = Clamp16(static_cast<int32_t>(v * 32767.0));
        }
    }

    // ---- Finish：三和弦 + 噪声爆发 ----
    {
        const int len = static_cast<int>(sr * 0.330);
        auto &buf = bank_[static_cast<int>(HitSoundKind::Finish)];
        buf.resize(static_cast<size_t>(len));
        Noise noise(0x2B7E1516u);
        for (int i = 0; i < len; i++) {
            const double t = static_cast<double>(i) / sr;
            const double env = std::exp(-t / 0.090);
            const double chord = std::sin(2.0 * kPi * 523.25 * t)
                               + std::sin(2.0 * kPi * 659.25 * t) * 0.8
                               + std::sin(2.0 * kPi * 783.99 * t) * 0.6;
            const double burst = noise.next() * std::exp(-t / 0.010) * 0.8;
            const double v = (chord * 0.16 + burst * 0.5) * env;
            buf[static_cast<size_t>(i)] = Clamp16(static_cast<int32_t>(v * 32767.0));
        }
    }

    // ---- Clap：三次连击的噪声 ----
    {
        const int len = static_cast<int>(sr * 0.150);
        auto &buf = bank_[static_cast<int>(HitSoundKind::Clap)];
        buf.resize(static_cast<size_t>(len));
        Noise noise(0x1F83D9ABu);
        const double bursts[3] = {0.0, 0.011, 0.022};
        for (int i = 0; i < len; i++) {
            const double t = static_cast<double>(i) / sr;
            double env = 0.0;
            for (double b : bursts) {
                if (t >= b) {
                    env += std::exp(-(t - b) / 0.0075);
                }
            }
            // 收尾的短混响尾巴
            env += std::exp(-t / 0.045) * 0.25;
            const double v = noise.next() * env * 0.30;
            buf[static_cast<size_t>(i)] = Clamp16(static_cast<int32_t>(v * 32767.0));
        }
    }
}

bool AudioEngine::Init(int sampleRate, int channels)
{
    if (renderer_ != nullptr) {
        return true;
    }

    sampleRate_ = sampleRate > 0 ? sampleRate : 48000;
    channels_ = channels > 0 ? channels : 2;
    BuildSampleBank();

    if (OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS
        || builder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] builder create failed", kTag);
        return false;
    }

    OH_AudioStreamBuilder_SetSamplingRate(builder_, sampleRate_);
    OH_AudioStreamBuilder_SetChannelCount(builder_, channels_);
    OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_GAME);
    OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_, OnWrite, this);

    OH_AudioStream_Result ret = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (ret != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
        // FAST 通路在部分机型/路由上不可用，退回普通模式也要能出声，
        // 否则打击音会静默消失，比延迟大得多的问题。
        OH_LOG_WARN(LOG_APP, "[%{public}s] FAST mode failed (%{public}d), retry NORMAL", kTag,
                    static_cast<int>(ret));
        fastHint_ = -1;
        OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_NORMAL);
        ret = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
        if (ret != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
            OH_LOG_ERROR(LOG_APP, "[%{public}s] GenerateRenderer failed: %{public}d", kTag,
                         static_cast<int>(ret));
            OH_AudioStreamBuilder_Destroy(builder_);
            builder_ = nullptr;
            renderer_ = nullptr;
            return false;
        }
    }

    int32_t frameSize = 0;
    if (OH_AudioRenderer_GetFrameSizeInCallback(renderer_, &frameSize) == AUDIOSTREAM_SUCCESS) {
        callbackFrames_ = frameSize;
    }

    int32_t latencyMs = 0;
    if (OH_AudioRenderer_GetLatency(renderer_, AUDIOSTREAM_LATENCY_TYPE_ALL, &latencyMs)
        == AUDIOSTREAM_SUCCESS) {
        routeLatencyMs_ = static_cast<double>(latencyMs);
    }

    ret = OH_AudioRenderer_Start(renderer_);
    if (ret != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] renderer start failed: %{public}d", kTag, static_cast<int>(ret));
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return false;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] ready sr=%{public}d ch=%{public}d cbFrames=%{public}d latency=%{public}.1fms",
                kTag, sampleRate_, channels_, callbackFrames_, routeLatencyMs_);
    return true;
}

void AudioEngine::Shutdown()
{
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Stop(renderer_);
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }
    if (builder_ != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }
    activeVoices_ = 0;
}

void AudioEngine::Play(HitSoundKind kind, float volume)
{
    if (renderer_ == nullptr) {
        return;
    }
    const int k = static_cast<int>(kind);
    if (k < 0 || k >= static_cast<int>(HitSoundKind::Count)) {
        return;
    }
    if (volume < 0.0f) {
        volume = 0.0f;
    }
    if (volume > 1.0f) {
        volume = 1.0f;
    }

    const uint32_t w = triggerWrite_.load(std::memory_order_relaxed);
    const uint32_t r = triggerRead_.load(std::memory_order_acquire);
    if (w - r >= static_cast<uint32_t>(kTriggerCapacity)) {
        return; // 队列满就丢弃，绝不阻塞 JS 线程
    }
    triggers_[w & (kTriggerCapacity - 1)] = Trigger{k, volume};
    triggerWrite_.store(w + 1, std::memory_order_release);
}

void AudioEngine::StartVoice(int kind, float volume)
{
    if (kind < 0 || kind >= static_cast<int>(HitSoundKind::Count)) {
        return;
    }
    if (bank_[kind].empty()) {
        return;
    }

    // 找空槽；满了就抢最老的（index 0 视作最老，够用且不会爆音）
    int slot = -1;
    for (int i = 0; i < kMaxVoices; i++) {
        if (voices_[i].kind < 0) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        slot = 0;
    } else {
        activeVoices_++;
    }

    voices_[slot].kind = kind;
    voices_[slot].pos = 0;
    // 同一时刻叠多个打击音很容易削顶，按 1/sqrt(n) 压一下
    const float scale = activeVoices_ > 1 ? 1.0f / std::sqrt(static_cast<float>(activeVoices_)) : 1.0f;
    voices_[slot].volume = volume * scale;
}

void AudioEngine::Render(int16_t *out, int frames)
{
    // 1) 出队：把 JS 线程投递的触发搬成活动音源
    uint32_t w = triggerWrite_.load(std::memory_order_acquire);
    uint32_t r = triggerRead_.load(std::memory_order_relaxed);
    while (r != w) {
        const Trigger &t = triggers_[r & (kTriggerCapacity - 1)];
        StartVoice(t.kind, t.volume);
        r++;
    }
    triggerRead_.store(r, std::memory_order_release);

    // 2) 混音
    std::memset(out, 0, sizeof(int16_t) * static_cast<size_t>(frames) * static_cast<size_t>(channels_));

    if (activeVoices_ <= 0) {
        return; // 静音直接返回，省电
    }

    for (int v = 0; v < kMaxVoices; v++) {
        Voice &voice = voices_[v];
        if (voice.kind < 0) {
            continue;
        }
        const std::vector<int16_t> &bank = bank_[voice.kind];
        const int len = static_cast<int>(bank.size());
        int pos = voice.pos;

        for (int i = 0; i < frames; i++) {
            if (pos >= len) {
                break;
            }
            const int32_t s = static_cast<int32_t>(static_cast<float>(bank[static_cast<size_t>(pos)]) * voice.volume);
            const int base = i * channels_;
            for (int c = 0; c < channels_; c++) {
                const int32_t mixed = static_cast<int32_t>(out[base + c]) + s;
                out[base + c] = Clamp16(mixed);
            }
            pos++;
        }

        voice.pos = pos;
        if (pos >= len) {
            voice.kind = -1;
            activeVoices_--;
        }
    }
    if (activeVoices_ < 0) {
        activeVoices_ = 0;
    }
}

OH_AudioData_Callback_Result AudioEngine::OnWrite(OH_AudioRenderer * /*renderer*/, void *userData,
                                                  void *audioData, int32_t audioDataSize)
{
    auto *self = static_cast<AudioEngine *>(userData);
    if (self == nullptr || audioData == nullptr || self->channels_ <= 0) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }

    const int bytesPerFrame = static_cast<int>(sizeof(int16_t)) * self->channels_;
    const int frames = audioDataSize / bytesPerFrame;
    if (frames <= 0) {
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    self->Render(static_cast<int16_t *>(audioData), frames);
    self->framesRendered_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

double AudioEngine::BufferLatencyMs() const
{
    if (callbackFrames_ <= 0 || sampleRate_ <= 0) {
        return -1.0;
    }
    return static_cast<double>(callbackFrames_) * 1000.0 / static_cast<double>(sampleRate_);
}

int AudioEngine::FastStatus() const
{
    if (renderer_ == nullptr) {
        return fastHint_;
    }
    OH_AudioStream_FastStatus status = AUDIOSTREAM_FASTSTATUS_NORMAL;
    if (OH_AudioRenderer_GetFastStatus(renderer_, &status) == AUDIOSTREAM_SUCCESS) {
        return status == AUDIOSTREAM_FASTSTATUS_FAST ? 1 : 0;
    }
    return fastHint_;
}

uint32_t AudioEngine::Underruns() const
{
    if (renderer_ == nullptr) {
        return 0;
    }
    uint32_t count = 0;
    if (OH_AudioRenderer_GetUnderflowCount(renderer_, &count) == AUDIOSTREAM_SUCCESS) {
        return count;
    }
    return 0;
}

} // namespace osu
