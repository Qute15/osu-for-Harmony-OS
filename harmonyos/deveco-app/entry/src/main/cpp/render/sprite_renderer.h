#ifndef OSU_SPRITE_RENDERER_H
#define OSU_SPRITE_RENDERER_H

#include <GLES3/gl3.h>
#include <vector>

namespace osu {

struct Color {
    float r;
    float g;
    float b;
    float a;

    static Color FromHex(unsigned int rgb, float alpha = 1.0f)
    {
        return Color{
            static_cast<float>((rgb >> 16) & 0xFF) / 255.0f,
            static_cast<float>((rgb >> 8) & 0xFF) / 255.0f,
            static_cast<float>(rgb & 0xFF) / 255.0f,
            alpha};
    }
};

enum ShapeType {
    SHAPE_RECT = 0,
    SHAPE_CIRCLE = 1,
    SHAPE_RING = 2,
};

/**
 * 批量精灵渲染器（GLES3）。
 *
 * 两套画法共用一条管线：
 *   - 解析式：圆 / 圆环 / 矩形，fragment shader 用 SDF + fwidth 抗锯齿，
 *     不需要任何纹理，用于场地底色、滑条轨道、偏差条这类"纯几何"。
 *   - 纹理：皮肤图集上的任意子矩形，UV 由调用方给。
 *     图集是纯白 + alpha 的，顶点色乘上去就能着色成任意 combo 色 ——
 *     这正是 osu! 皮肤的工作方式。
 *
 * 两种模式在同一个 shader 里用 uniform 分支区别，所以整帧只有一个
 * draw call（除非四边形超过 kMaxQuads 才 Flush 一次）。
 *
 * 坐标：屏幕像素，左上角为原点（与 ArkUI 一致），y 向下。
 */
class SpriteRenderer {
public:
    bool Init();
    void Destroy();

    void Begin(int width, int height);
    void AddRect(float cx, float cy, float width, float height, float rotationRad, const Color &color);
    void AddCircle(float cx, float cy, float radius, const Color &color);
    void AddRing(float cx, float cy, float radius, float thickness, const Color &color);

    /**
     * 画一块图集子矩形。uv 是 0..1 归一化坐标，(u0,v0) 左上、(u1,v1) 右下。
     * 顶点色会和贴图相乘，贴图是白色时等于直接着色。
     */
    void AddSprite(float cx, float cy, float halfW, float halfH, float rotationRad,
                   float u0, float v0, float u1, float v1, const Color &color);

    /**
     * 上传图集。必须在 GL 上下文当前线程调用（也就是渲染线程），
     * 所以实际调用点在 RenderFrame 里，由 ArkTS 侧标记"有数据待上传"。
     */
    void SetAtlas(int width, int height, const unsigned char *rgba);

    /**
     * 谱面封面。和皮肤图集是两张独立的纹理，互不干扰：
     * 图集是"白 + alpha"的蒙版，封面是真正的彩色图，混在一起会让
     * 纯色图元（圆、滑条）去采样封面的像素颜色。
     */
    void SetBackground(int width, int height, const unsigned char *rgba);
    void ClearBackground();

    /**
     * 把封面铺满整个屏幕（保持比例、超出部分裁掉），再按 dim 压暗。
     * 必须在添加其它图元之前调用 —— 它自己会提交一次 draw call。
     * dim 是"亮度倍数"：lazer 默认 DimLevel=0.7 即亮度 0.3。
     */
    void DrawBackground(int screenWidth, int screenHeight, float dim);

    void End();

    int QuadCount() const { return quads_; }
    int DrawCalls() const { return drawCalls_; }
    bool HasAtlas() const { return texture_ != 0; }
    bool HasBackground() const { return bgTexture_ != 0; }

private:
    struct Vertex {
        float x;
        float y;
        float lx;
        float ly;
        float u;
        float v;
        float r;
        float g;
        float b;
        float a;
        float shape;
        float param;
    };

    void PushQuad(float cx, float cy, float halfW, float halfH, float rotationRad,
                  const Color &color, int shape, float param,
                  float u0, float v0, float u1, float v1);
    void Flush();
    /** 用指定纹理提交当前批次。默认 Flush() 用皮肤图集，背景另走一次。 */
    void FlushWith(GLuint tex);
    bool BuildProgram();

    static constexpr int kMaxQuads = 8192;

    GLuint program_ = 0;
    GLuint vao_ = 0;
    GLuint vbo_ = 0;
    GLuint texture_ = 0;
    GLuint bgTexture_ = 0;
    int bgWidth_ = 0;
    int bgHeight_ = 0;
    GLint uniformResolution_ = -1;
    GLint uniformTex_ = -1;
    GLint uniformHasTex_ = -1;

    /** 纯色图元采样的位置：图集左上角那块不透明白块的中心 */
    float whiteU_ = 0.5f;
    float whiteV_ = 0.5f;

    std::vector<Vertex> vertices_;
    int width_ = 0;
    int height_ = 0;
    int quads_ = 0;
    int drawCalls_ = 0;
};

} // namespace osu

#endif // OSU_SPRITE_RENDERER_H
