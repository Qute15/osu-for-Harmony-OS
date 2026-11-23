cmake_minimum_required(VERSION 3.5.0)
project(osu)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(osu SHARED
    napi_init.cpp
    render/egl_core.cpp
    render/sprite_renderer.cpp
    audio/audio_engine.cpp
    osu_scene.cpp
)

target_include_directories(osu PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(osu PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_vsync.so
    libohaudio.so
    EGL
    GLESv3
)

# M0：验证 NativeAOT 产物的 dlopen 尖刀（见 aot_sample.cpp 头注释），通过后可删
add_library(aotsample SHARED
    aot_sample.cpp
)

target_link_libraries(aotsample PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
)
