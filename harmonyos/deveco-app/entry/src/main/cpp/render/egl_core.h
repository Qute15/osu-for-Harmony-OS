#ifndef OSU_EGL_CORE_H
#define OSU_EGL_CORE_H

#include <EGL/egl.h>
#include <EGL/eglext.h>

namespace osu {

/**
 * EGL/GLES3 上下文封装。
 *
 * HarmonyOS 上没有 GLFW/SDL，窗口来自 XComponent 的 OHNativeWindow。
 * 所有 GL 调用都必须在"持有上下文的线程"上执行，所以初始化不在 UI 线程，
 * 而是推迟到 vsync 回调里第一次渲染时（见 napi_init.cpp）。
 */
class EglCore {
public:
    bool Init(void *window);
    void Destroy();

    /** 把上下文绑定到当前线程（vsync 线程）。 */
    bool MakeCurrent();

    bool SwapBuffers();

    bool IsValid() const { return surface_ != EGL_NO_SURFACE; }

    int Width() const { return width_; }
    int Height() const { return height_; }

    void UpdateSize();

private:
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLSurface surface_ = EGL_NO_SURFACE;
    EGLConfig config_ = nullptr;
    int width_ = 0;
    int height_ = 0;
};

} // namespace osu

#endif // OSU_EGL_CORE_H
