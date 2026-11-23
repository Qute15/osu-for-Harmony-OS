#include "osu_scene.h"

#include <cmath>

namespace osu {

namespace {

struct DemoObject {
    float x;
    float y;
    float phase;
    unsigned int colour;
};

// 固定演示数据（x, y 在 512x384 虚拟场内）
const DemoObject kObjects[] = {
    {140.0f, 120.0f, 0.0f, 0xFF66CC},
    {300.0f, 220.0f, 0.33f, 0x66CCFF},
    {400.0f, 110.0f, 0.66f, 0xCCFF66},
};
constexpr int kObjectCount = 3;
constexpr double kPreemptMs = 900.0;

} // namespace

void OsuScene::Draw(SpriteRenderer &renderer, int screenWidth, int screenHeight, double timeMs)
{
    const float w = static_cast<float>(screenWidth);
    const float h = static_cast<float>(screenHeight);
    if (w <= 0.0f || h <= 0.0f) {
        return;
    }

    // 等比缩放 + 居中（letterbox），与 osu! 的 4:3 场一致
    const float sx = w / kPlayfieldWidth;
    const float sy = h / kPlayfieldHeight;
    scale_ = sx < sy ? sx : sy;
    const float playW = kPlayfieldWidth * scale_;
    const float playH = kPlayfieldHeight * scale_;
    offsetX_ = (w - playW) * 0.5f;
    offsetY_ = (h - playH) * 0.5f;

    // 场外底色
    renderer.AddRect(w * 0.5f, h * 0.5f, w, h, 0.0f, Color::FromHex(0x0E0E12));

    // 场地
    renderer.AddRect(offsetX_ + playW * 0.5f, offsetY_ + playH * 0.5f, playW, playH, 0.0f,
                     Color::FromHex(0x17171F));

    const float radius = 32.0f * (1.0f - 0.7f * (4.0f - 5.0f) / 5.0f) * 0.5f * scale_ * 2.0f;

    for (int i = 0; i < kObjectCount; i++) {
        const DemoObject &obj = kObjects[i];
        const float cx = offsetX_ + obj.x * scale_;
        const float cy = offsetY_ + obj.y * scale_;

        // approach ring：从 2.6 倍半径收到 1 倍，收完停一小会儿再重来
        double local = std::fmod(timeMs / kPreemptMs + obj.phase, 1.0);
        const float t = static_cast<float>(local);
        const float ringScale = 1.0f + 1.6f * (1.0f - t);
        const float ringAlpha = 0.15f + 0.85f * t;

        // 滑条轨道（旋转矩形，验证任意角度四边形）
        renderer.AddRect(cx, cy + radius * 3.4f, radius * 1.6f, radius * 4.6f,
                         -0.35f, Color::FromHex(obj.colour, 0.35f));

        // 判定圈
        renderer.AddCircle(cx, cy, radius, Color::FromHex(0x1B1B24, 0.92f));
        renderer.AddRing(cx, cy, radius, radius * 0.12f, Color::FromHex(obj.colour, 0.95f));
        renderer.AddRing(cx, cy, radius * ringScale, radius * ringScale * 0.055f,
                         Color::FromHex(obj.colour, ringAlpha * 0.8f));
    }

    renderer.End();
}

} // namespace osu
