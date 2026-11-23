#ifndef OSU_SCENE_H
#define OSU_SCENE_H

#include "render/sprite_renderer.h"

namespace osu {

/**
 * 演示场景：证明 EGL + 批渲染 + 120Hz vsync 管线通了。
 *
 * 这一层很快会被真正的谱面渲染器替换（读 OsuPlayableBeatmap 的物件），
 * 现在先用固定数据把管线压出来：
 *   - letterbox 后的 512x384 虚拟场
 *   - 3 个带 approach ring 的判定圈（周期循环）
 *   - 1 条旋转的滑条轨道（验证任意角度四边形）
 */
class OsuScene {
public:
    void Draw(SpriteRenderer &renderer, int screenWidth, int screenHeight, double timeMs);

    /** 虚拟场 → 屏幕的映射参数（供输入层反算） */
    float Scale() const { return scale_; }
    float OffsetX() const { return offsetX_; }
    float OffsetY() const { return offsetY_; }

    static constexpr float kPlayfieldWidth = 512.0f;
    static constexpr float kPlayfieldHeight = 384.0f;

private:
    float scale_ = 1.0f;
    float offsetX_ = 0.0f;
    float offsetY_ = 0.0f;
};

} // namespace osu

#endif // OSU_SCENE_H
