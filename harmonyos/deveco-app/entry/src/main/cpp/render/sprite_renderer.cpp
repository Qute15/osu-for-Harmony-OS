#include "sprite_renderer.h"

#include <cmath>

// hilog 的 domain/tag 必须在 include 之前定义，否则日志进不了缓冲区（查不到）
#define LOG_DOMAIN 0x0F0F
#define LOG_TAG "OSU-GL"
#include <hilog/log.h>

namespace osu {

namespace {

constexpr const char *kTag = "osu-gl";

const char *kVertexShader = R"(#version 300 es
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aLocal;
layout(location = 2) in vec4 aColor;
layout(location = 3) in vec2 aShape;
layout(location = 4) in vec2 aUV;

uniform vec2 uResolution;

out vec2 vLocal;
out vec4 vColor;
flat out vec2 vShape;
out vec2 vUV;

void main()
{
    // 像素坐标 → NDC，y 轴翻转（屏幕坐标左上原点）
    vec2 ndc = vec2(aPos.x / uResolution.x * 2.0 - 1.0,
                    1.0 - aPos.y / uResolution.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vLocal = aLocal;
    vColor = aColor;
    vShape = aShape;
    vUV = aUV;
}
)";

const char *kFragmentShader = R"(#version 300 es
precision mediump float;

in vec2 vLocal;
in vec4 vColor;
flat in vec2 vShape;
in vec2 vUV;

uniform sampler2D uTex;
uniform int uHasTex;

out vec4 fragColor;

void main()
{
    float shape = vShape.x;
    float param = vShape.y;
    float alpha = vColor.a;
    vec3 rgb = vColor.rgb;

    if (shape > 0.5) {
        // 纯几何：解析式画圆/环，fwidth 做屏幕空间抗锯齿
        float d = length(vLocal);
        float aa = fwidth(d) * 1.5 + 0.002;

        if (shape < 1.5) {
            alpha *= 1.0 - smoothstep(1.0 - aa, 1.0, d);
        } else {
            alpha *= smoothstep(param - aa, param, d) * (1.0 - smoothstep(1.0 - aa, 1.0, d));
        }
    } else if (uHasTex == 1) {
        // 皮肤贴图：白色 + alpha，颜色由顶点色决定。
        // 不做 v 翻转：glTexImage2D 按行上传，图像第 0 行落到的那个 texel
        // 的 v 就是 0，和"用 y/h 算 UV"是自洽的。翻一次反而会采到图集下半的空白区。
        vec4 tex = texture(uTex, vUV);
        rgb *= tex.rgb;
        alpha *= tex.a;
    }

    if (alpha <= 0.003) {
        discard;
    }
    fragColor = vec4(rgb, alpha);
}
)";

GLuint CompileShader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        char log[512] = {0};
        glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] shader compile failed: %{public}s", kTag, log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

} // namespace

bool SpriteRenderer::Init()
{
    if (program_ != 0) {
        return true;
    }
    if (!BuildProgram()) {
        return false;
    }

    glGenVertexArrays(1, &vao_);
    glBindVertexArray(vao_);

    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertex) * kMaxQuads * 6, nullptr, GL_DYNAMIC_DRAW);

    // 属性偏移必须与 Vertex 的字段顺序严格对应：
    // x,y | lx,ly | u,v | r,g,b,a | shape,param
    const GLsizei stride = sizeof(Vertex);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<void *>(0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<void *>(sizeof(float) * 2));
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 2, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<void *>(sizeof(float) * 4));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<void *>(sizeof(float) * 6));
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, stride, reinterpret_cast<void *>(sizeof(float) * 10));

    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    vertices_.reserve(static_cast<size_t>(kMaxQuads) * 6);

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    OH_LOG_INFO(LOG_APP, "[%{public}s] renderer ready (stride=%{public}zu)", kTag, sizeof(Vertex));
    return true;
}

bool SpriteRenderer::BuildProgram()
{
    GLuint vs = CompileShader(GL_VERTEX_SHADER, kVertexShader);
    if (vs == 0) {
        return false;
    }
    GLuint fs = CompileShader(GL_FRAGMENT_SHADER, kFragmentShader);
    if (fs == 0) {
        glDeleteShader(vs);
        return false;
    }

    program_ = glCreateProgram();
    glAttachShader(program_, vs);
    glAttachShader(program_, fs);
    glLinkProgram(program_);

    GLint linked = 0;
    glGetProgramiv(program_, GL_LINK_STATUS, &linked);
    glDeleteShader(vs);
    glDeleteShader(fs);

    if (linked != GL_TRUE) {
        char log[512] = {0};
        glGetProgramInfoLog(program_, sizeof(log) - 1, nullptr, log);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] program link failed: %{public}s", kTag, log);
        glDeleteProgram(program_);
        program_ = 0;
        return false;
    }

    uniformResolution_ = glGetUniformLocation(program_, "uResolution");
    uniformTex_ = glGetUniformLocation(program_, "uTex");
    uniformHasTex_ = glGetUniformLocation(program_, "uHasTex");
    return true;
}

void SpriteRenderer::Destroy()
{
    if (texture_ != 0) {
        glDeleteTextures(1, &texture_);
        texture_ = 0;
    }
    if (bgTexture_ != 0) {
        glDeleteTextures(1, &bgTexture_);
        bgTexture_ = 0;
        bgWidth_ = 0;
        bgHeight_ = 0;
    }
    if (vbo_ != 0) {
        glDeleteBuffers(1, &vbo_);
        vbo_ = 0;
    }
    if (vao_ != 0) {
        glDeleteVertexArrays(1, &vao_);
        vao_ = 0;
    }
    if (program_ != 0) {
        glDeleteProgram(program_);
        program_ = 0;
    }
    vertices_.clear();
    quads_ = 0;
    drawCalls_ = 0;
}

void SpriteRenderer::SetAtlas(int width, int height, const unsigned char *rgba)
{
    if (width <= 0 || height <= 0 || rgba == nullptr) {
        return;
    }
    if (texture_ == 0) {
        glGenTextures(1, &texture_);
    }
    glBindTexture(GL_TEXTURE_2D, texture_);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);

    // 纯色图元采样图集左上角白块（8x8，(0,0)-(8,8)）的中心
    whiteU_ = 4.0f / static_cast<float>(width);
    whiteV_ = 4.0f / static_cast<float>(height);

    // 诊断：统计不透明像素，确认传上来的不是一张空图
    const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
    size_t opaque = 0;
    unsigned int sum = 0;
    for (size_t i = 0; i < pixels; i++) {
        const unsigned char a = rgba[i * 4 + 3];
        if (a > 8) {
            opaque++;
        }
        sum += a;
    }

    const GLenum err = glGetError();
    OH_LOG_INFO(LOG_APP, "[%{public}s] atlas uploaded %{public}dx%{public}d opaque=%{public}zu/%{public}zu sumA=%{public}u err=%{public}u",
                kTag, width, height, opaque, pixels, sum, err);
}

void SpriteRenderer::SetBackground(int width, int height, const unsigned char *rgba)
{
    if (width <= 0 || height <= 0 || rgba == nullptr) {
        return;
    }
    if (bgTexture_ == 0) {
        glGenTextures(1, &bgTexture_);
    }
    glBindTexture(GL_TEXTURE_2D, bgTexture_);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    // 封面是全屏拉伸的，边缘用 CLAMP 避免出现一条接缝色带
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);

    bgWidth_ = width;
    bgHeight_ = height;

    // 诊断：确认 RGB 真有内容（不是一张全黑图）
    const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
    size_t opaque = 0;
    unsigned int rgbSum = 0;
    for (size_t i = 0; i < count; i += 97) {
        if (rgba[i * 4 + 3] > 8) {
            opaque++;
        }
        rgbSum += rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2];
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] background uploaded %{public}dx%{public}d opaque=%{public}zu/%{public}zu rgbSum=%{public}u err=%{public}u",
                kTag, width, height, opaque, count / 97, rgbSum, glGetError());
}

void SpriteRenderer::ClearBackground()
{
    if (bgTexture_ != 0) {
        glDeleteTextures(1, &bgTexture_);
        bgTexture_ = 0;
    }
    bgWidth_ = 0;
    bgHeight_ = 0;
}

void SpriteRenderer::DrawBackground(int screenWidth, int screenHeight, float dim)
{
    if (bgTexture_ == 0 || bgWidth_ <= 0 || bgHeight_ <= 0) {
        return;
    }
    if (screenWidth <= 0 || screenHeight <= 0) {
        return;
    }

    // 保持比例铺满（cover）：图比屏幕"更宽"就裁左右，否则裁上下。
    // 只改 UV，不动几何，所以永远是一块正好覆盖屏幕的四边形。
    const float imgAspect = static_cast<float>(bgWidth_) / static_cast<float>(bgHeight_);
    const float screenAspect = static_cast<float>(screenWidth) / static_cast<float>(screenHeight);
    float u0 = 0.0f;
    float v0 = 0.0f;
    float u1 = 1.0f;
    float v1 = 1.0f;
    if (imgAspect > screenAspect) {
        const float keep = screenAspect / imgAspect;
        const float margin = (1.0f - keep) * 0.5f;
        u0 = margin;
        u1 = 1.0f - margin;
    } else if (imgAspect < screenAspect) {
        const float keep = imgAspect / screenAspect;
        const float margin = (1.0f - keep) * 0.5f;
        v0 = margin;
        v1 = 1.0f - margin;
    }

    if (dim < 0.0f) {
        dim = 0.0f;
    }
    if (dim > 1.0f) {
        dim = 1.0f;
    }

    // 顶点色当"调光"用：rgb 乘上去等于压暗，alpha 固定 1 盖住底色。
    const Color tint{dim, dim, dim, 1.0f};
    PushQuad(static_cast<float>(screenWidth) * 0.5f, static_cast<float>(screenHeight) * 0.5f,
             static_cast<float>(screenWidth) * 0.5f, static_cast<float>(screenHeight) * 0.5f,
             0.0f, tint, SHAPE_RECT, 0.0f, u0, v0, u1, v1);
    FlushWith(bgTexture_);

    static int dbgBg = 0;
    if (dbgBg < 3) {
        dbgBg++;
        OH_LOG_INFO(LOG_APP, "[%{public}s] bg quad %{public}dx%{public}d src=%{public}dx%{public}d uv=(%{public}.2f,%{public}.2f)-(%{public}.2f,%{public}.2f) dim=%{public}.2f err=%{public}u",
                    kTag, screenWidth, screenHeight, bgWidth_, bgHeight_, u0, v0, u1, v1, dim, glGetError());
    }
}

void SpriteRenderer::Begin(int width, int height)
{    width_ = width > 0 ? width : 1;
    height_ = height > 0 ? height : 1;
    vertices_.clear();
    quads_ = 0;
    drawCalls_ = 0;

    glViewport(0, 0, width_, height_);
}

void SpriteRenderer::AddRect(float cx, float cy, float width, float height, float rotationRad, const Color &color)
{
    PushQuad(cx, cy, width * 0.5f, height * 0.5f, rotationRad, color, SHAPE_RECT, 0.0f,
             whiteU_, whiteV_, whiteU_, whiteV_);
}

void SpriteRenderer::AddCircle(float cx, float cy, float radius, const Color &color)
{
    PushQuad(cx, cy, radius, radius, 0.0f, color, SHAPE_CIRCLE, 0.0f,
             whiteU_, whiteV_, whiteU_, whiteV_);
}

void SpriteRenderer::AddRing(float cx, float cy, float radius, float thickness, const Color &color)
{
    float t = thickness / (radius > 0.0001f ? radius : 0.0001f);
    if (t <= 0.0f || t >= 1.0f) {
        // 退化成立即弃掉，避免 shader 里 inner>=outer 造成整圈消失
        return;
    }
    PushQuad(cx, cy, radius, radius, 0.0f, color, SHAPE_RING, 1.0f - t,
             whiteU_, whiteV_, whiteU_, whiteV_);
}

void SpriteRenderer::AddSprite(float cx, float cy, float halfW, float halfH, float rotationRad,
                               float u0, float v0, float u1, float v1, const Color &color)
{
    PushQuad(cx, cy, halfW, halfH, rotationRad, color, SHAPE_RECT, 0.0f, u0, v0, u1, v1);
}

void SpriteRenderer::PushQuad(float cx, float cy, float halfW, float halfH, float rotationRad,
                              const Color &color, int shape, float param,
                              float u0, float v0, float u1, float v1)
{
    if (static_cast<int>(vertices_.size()) + 6 > kMaxQuads * 6) {
        Flush();
    }

    const float c = std::cos(rotationRad);
    const float s = std::sin(rotationRad);

    // 局部 (-1,-1)..(1,1) 旋转后映射到屏幕
    const float lxs[4] = {-1.0f, 1.0f, 1.0f, -1.0f};
    const float lys[4] = {-1.0f, -1.0f, 1.0f, 1.0f};
    const float us[4] = {u0, u1, u1, u0};
    const float vs[4] = {v0, v0, v1, v1};

    Vertex corners[4];
    for (int i = 0; i < 4; i++) {
        float ox = lxs[i] * halfW;
        float oy = lys[i] * halfH;
        corners[i].x = cx + c * ox - s * oy;
        corners[i].y = cy + s * ox + c * oy;
        corners[i].lx = lxs[i];
        corners[i].ly = lys[i];
        corners[i].u = us[i];
        corners[i].v = vs[i];
        corners[i].r = color.r;
        corners[i].g = color.g;
        corners[i].b = color.b;
        corners[i].a = color.a;
        corners[i].shape = static_cast<float>(shape);
        corners[i].param = param;
    }

    vertices_.push_back(corners[0]);
    vertices_.push_back(corners[1]);
    vertices_.push_back(corners[2]);
    vertices_.push_back(corners[0]);
    vertices_.push_back(corners[2]);
    vertices_.push_back(corners[3]);

    quads_++;
}

void SpriteRenderer::Flush()
{
    FlushWith(texture_);
}

void SpriteRenderer::FlushWith(GLuint tex)
{
    if (vertices_.empty()) {
        return;
    }

    glUseProgram(program_);
    glUniform2f(uniformResolution_, static_cast<float>(width_), static_cast<float>(height_));

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glUniform1i(uniformTex_, 0);
    glUniform1i(uniformHasTex_, tex != 0 ? 1 : 0);

    static bool dbgUniform = false;
    if (!dbgUniform) {
        dbgUniform = true;
        GLint v = -99;
        glGetUniformiv(program_, uniformHasTex_, &v);
        OH_LOG_INFO(LOG_APP, "[%{public}s] flush#1 locTex=%{public}d locHas=%{public}d tex=%{public}u hasTex=%{public}d verts=%{public}zu",
                    kTag, uniformTex_, uniformHasTex_, texture_, v, vertices_.size());
    }

    glBindVertexArray(vao_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);

    const GLsizeiptr bytes = static_cast<GLsizeiptr>(vertices_.size() * sizeof(Vertex));
    glBufferSubData(GL_ARRAY_BUFFER, 0, bytes, vertices_.data());
    glDrawArrays(GL_TRIANGLES, 0, static_cast<GLsizei>(vertices_.size()));

    drawCalls_++;
    vertices_.clear();
}

void SpriteRenderer::End()
{
    Flush();
    glBindVertexArray(0);
}

} // namespace osu
