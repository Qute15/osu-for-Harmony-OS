#include "egl_core.h"

#include <GLES3/gl3.h>
#include <hilog/log.h>
#include <native_window/external_window.h>

namespace osu {

namespace {
constexpr const char *kTag = "osu-egl";
}

bool EglCore::Init(void *window)
{
    if (window == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] window is null", kTag);
        return false;
    }
    if (IsValid()) {
        return true;
    }

    display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display_ == EGL_NO_DISPLAY) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] eglGetDisplay failed", kTag);
        return false;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display_, &major, &minor) != EGL_TRUE) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] eglInitialize failed 0x%{public}x", kTag, eglGetError());
        display_ = EGL_NO_DISPLAY;
        return false;
    }

    // 只要 RGBA8888 窗口表面；depth/stencil 为 0，osu! 的 2D 渲染用不到。
    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0,
        EGL_STENCIL_SIZE, 0,
        EGL_SAMPLES, 0,
        EGL_NONE
    };
    EGLint numConfigs = 0;
    if (eglChooseConfig(display_, configAttribs, &config_, 1, &numConfigs) != EGL_TRUE || numConfigs < 1) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] eglChooseConfig failed 0x%{public}x", kTag, eglGetError());
        Destroy();
        return false;
    }

    surface_ = eglCreateWindowSurface(display_, config_, reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface_ == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] eglCreateWindowSurface failed 0x%{public}x", kTag, eglGetError());
        Destroy();
        return false;
    }

    const EGLint contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, contextAttribs);
    if (context_ == EGL_NO_CONTEXT) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] eglCreateContext failed 0x%{public}x", kTag, eglGetError());
        Destroy();
        return false;
    }

    if (!MakeCurrent()) {
        Destroy();
        return false;
    }

    UpdateSize();
    // 关键：窗口表面的 buffer 尺寸必须显式设一次，否则部分机型 eglQuerySurface 拿到 0x0，
    // 后续 glViewport(0,0) + 空尺寸渲染 = 纯黑，且不报错。
    if (width_ <= 0 || height_ <= 0) {
        int fallbackW = 0;
        int fallbackH = 0;
        auto *nativeWindow = reinterpret_cast<OHNativeWindow *>(window);
        OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, GET_BUFFER_GEOMETRY, &fallbackW, &fallbackH);
        OH_LOG_WARN(LOG_APP, "[%{public}s] eglQuerySurface size invalid, buffer geometry=%{public}dx%{public}d",
                    kTag, fallbackW, fallbackH);
        if (fallbackW > 0 && fallbackH > 0) {
            width_ = fallbackW;
            height_ = fallbackH;
        }
    }

    const char *version = reinterpret_cast<const char *>(glGetString(GL_VERSION));
    OH_LOG_INFO(LOG_APP, "[%{public}s] EGL ready, GL_VERSION=%{public}s, size=%{public}dx%{public}d", kTag,
                version == nullptr ? "unknown" : version, width_, height_);
    return true;
}

bool EglCore::MakeCurrent()
{
    if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE || context_ == EGL_NO_CONTEXT) {
        return false;
    }
    if (eglMakeCurrent(display_, surface_, surface_, context_) != EGL_TRUE) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] eglMakeCurrent failed 0x%{public}x", kTag, eglGetError());
        return false;
    }
    return true;
}

bool EglCore::SwapBuffers()
{
    if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE) {
        return false;
    }
    return eglSwapBuffers(display_, surface_) == EGL_TRUE;
}

void EglCore::UpdateSize()
{
    if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE) {
        return;
    }
    EGLint w = 0;
    EGLint h = 0;
    eglQuerySurface(display_, surface_, EGL_WIDTH, &w);
    eglQuerySurface(display_, surface_, EGL_HEIGHT, &h);
    if (w > 0 && h > 0) {
        width_ = w;
        height_ = h;
    }
}

void EglCore::Destroy()
{
    if (display_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (context_ != EGL_NO_CONTEXT) {
            eglDestroyContext(display_, context_);
            context_ = EGL_NO_CONTEXT;
        }
        if (surface_ != EGL_NO_SURFACE) {
            eglDestroySurface(display_, surface_);
            surface_ = EGL_NO_SURFACE;
        }
        eglTerminate(display_);
        display_ = EGL_NO_DISPLAY;
    }
    width_ = 0;
    height_ = 0;
}

} // namespace osu
