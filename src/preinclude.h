#pragma once

#include "raylib.h"

#ifdef _WIN32
#include <windows.h>
#include <Xinput.h>
#include <dbghelp.h>

// The core build normally suppresses Win32 USER/GDI declarations because a
// few of their global identifiers collide with raylib. Alpha.5 needs the
// shell COM interfaces for the native folder picker, so include the missing
// Windows layers manually while temporarily renaming the handful of true
// collisions. The Windows generic-name macros are then removed so application
// code continues to resolve DrawText/LoadImage/PlaySound to raylib.
#ifdef NOUSER
#undef NOUSER
#endif
#ifdef NOGDI
#undef NOGDI
#endif
#define CloseWindow GG_Win32_CloseWindow
#define ShowCursor GG_Win32_ShowCursor
#define Rectangle GG_Win32_Rectangle
#include <winuser.h>
#include <wingdi.h>
#include <commctrl.h>
#include <mmsystem.h>
#include <objbase.h>
#include <shobjidl.h>
#undef CloseWindow
#undef ShowCursor
#undef Rectangle
#ifdef DrawText
#undef DrawText
#endif
#ifdef DrawTextEx
#undef DrawTextEx
#endif
#ifdef LoadImage
#undef LoadImage
#endif
#ifdef PlaySound
#undef PlaySound
#endif
#endif

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <clocale>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <mutex>
#include <sstream>
#include <string>

inline std::string upper(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    return s;
}

namespace ggdiag {

#ifdef _WIN32
inline std::mutex& logMutex() {
    static std::mutex mutex;
    return mutex;
}

inline std::string executablePath() {
    char buffer[32768]{};
    const DWORD len = GetModuleFileNameA(nullptr, buffer, static_cast<DWORD>(sizeof(buffer)));
    if (len == 0 || len >= sizeof(buffer)) return "GitarGame.exe";
    return std::string(buffer, len);
}

inline std::string executableDirectory() {
    const std::string path = executablePath();
    const auto pos = path.find_last_of("\\/");
    if (pos == std::string::npos) return ".";
    return path.substr(0, pos);
}

inline std::string logPath() {
    return executableDirectory() + "\\GitarGame.log";
}

inline std::string dumpPath() {
    return executableDirectory() + "\\GitarGame-crash.dmp";
}

inline std::string timestamp() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    localtime_s(&tm, &t);
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
    return out.str();
}

inline void log(const std::string& message) noexcept {
    try {
        std::lock_guard lock(logMutex());
        std::ofstream out(logPath(), std::ios::app);
        if (out) {
            out << '[' << timestamp() << "] " << message << '\n';
            out.flush();
        }
    } catch (...) {
        // Diagnostics must never become a new failure source.
    }
}

inline void logWin32Error(const char* operation) noexcept {
    const DWORD error = GetLastError();
    std::ostringstream out;
    out << operation << " GetLastError=" << error;
    log(out.str());
}

inline LONG WINAPI unhandledExceptionFilter(EXCEPTION_POINTERS* info) noexcept {
    try {
        const auto code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0UL;
        const auto address = info && info->ExceptionRecord ? reinterpret_cast<uintptr_t>(info->ExceptionRecord->ExceptionAddress) : 0ULL;
        const auto base = reinterpret_cast<uintptr_t>(GetModuleHandleA(nullptr));

        std::ostringstream line;
        line << "FATAL unhandled exception: code=0x" << std::hex << std::uppercase << code
             << " address=0x" << address;
        if (base != 0 && address >= base) line << " module_rva=0x" << (address - base);
        log(line.str());

        const std::string path = dumpPath();
        HANDLE file = CreateFileA(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file != INVALID_HANDLE_VALUE) {
            MINIDUMP_EXCEPTION_INFORMATION exceptionInfo{};
            exceptionInfo.ThreadId = GetCurrentThreadId();
            exceptionInfo.ExceptionPointers = info;
            exceptionInfo.ClientPointers = FALSE;
            const BOOL ok = MiniDumpWriteDump(
                GetCurrentProcess(), GetCurrentProcessId(), file,
                static_cast<MINIDUMP_TYPE>(MiniDumpNormal | MiniDumpWithThreadInfo),
                info ? &exceptionInfo : nullptr, nullptr, nullptr);
            CloseHandle(file);
            log(ok ? "Crash dump written: GitarGame-crash.dmp" : "MiniDumpWriteDump failed");
        } else {
            log("Could not create GitarGame-crash.dmp");
        }
    } catch (...) {
        // Last-resort crash path: do not throw from an exception filter.
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

struct DiagnosticsInstall {
    DiagnosticsInstall() noexcept {
        SetUnhandledExceptionFilter(unhandledExceptionFilter);

        // MSVC std::filesystem::path::string() uses the active C locale code page.
        // Force UTF-8 before main() so Unicode song/file names cannot raise
        // ERROR_NO_UNICODE_TRANSLATION (1113) during recursive library scans.
        const char* locale = std::setlocale(LC_CTYPE, ".UTF-8");
        if (!locale) locale = std::setlocale(LC_CTYPE, ".UTF8");

        log("============================================================");
        log("GitarGame process starting");
        log(locale ? std::string("LC_CTYPE: ") + locale : "LC_CTYPE UTF-8 setup failed; using process default");
        log(std::string("Executable: ") + executablePath());
        char cwd[32768]{};
        const DWORD len = GetCurrentDirectoryA(static_cast<DWORD>(sizeof(cwd)), cwd);
        if (len > 0 && len < sizeof(cwd)) log(std::string("Working directory: ") + cwd);
    }
    ~DiagnosticsInstall() noexcept {
        log("GitarGame process shutting down normally");
    }
};

inline DiagnosticsInstall diagnosticsInstall;

inline void setConfigFlagsLogged(unsigned int flags) {
    std::ostringstream out; out << "SetConfigFlags flags=0x" << std::hex << flags;
    log(out.str());
    ::SetConfigFlags(flags);
}

inline void initWindowLogged(int width, int height, const char* title) {
    {
        std::ostringstream out; out << "InitWindow begin " << width << 'x' << height;
        log(out.str());
    }
    ::InitWindow(width, height, title);
    log(std::string("InitWindow end ready=") + (::IsWindowReady() ? "true" : "false"));
}

inline void toggleFullscreenLogged() {
    log("ToggleFullscreen begin");
    ::ToggleFullscreen();
    log("ToggleFullscreen end");
}

inline void setTargetFPSLogged(int fps) {
    std::ostringstream out; out << "SetTargetFPS " << fps;
    log(out.str());
    ::SetTargetFPS(fps);
}

inline void initAudioDeviceLogged() {
    log("InitAudioDevice begin");
    ::InitAudioDevice();
    log(std::string("InitAudioDevice end ready=") + (::IsAudioDeviceReady() ? "true" : "false"));
}

inline void setMasterVolumeLogged(float volume) {
    if (!::IsAudioDeviceReady()) {
        log("SetMasterVolume skipped: audio device is not ready");
        return;
    }
    {
        std::ostringstream out; out << "SetMasterVolume " << volume;
        log(out.str());
    }
    ::SetMasterVolume(volume);
}

inline void closeAudioDeviceLogged() {
    if (!::IsAudioDeviceReady()) {
        log("CloseAudioDevice skipped: audio device is not ready");
        return;
    }
    log("CloseAudioDevice begin");
    ::CloseAudioDevice();
    log("CloseAudioDevice end");
}

inline DWORD xInputGetStateLogged(DWORD index, XINPUT_STATE* state) {
    const DWORD result = ::XInputGetState(index, state);
    static std::atomic<bool> first{true};
    if (first.exchange(false)) {
        std::ostringstream out;
        out << "XInput first poll: controller=" << index << " result=" << result
            << (result == ERROR_SUCCESS ? " (connected)" : " (not connected/error)");
        log(out.str());
    }
    return result;
}

inline void beginDrawingLogged() {
    static std::atomic<bool> first{true};
    if (first.exchange(false)) log("Entering first rendered frame");
    ::BeginDrawing();
}

inline void endDrawingLogged() {
    ::EndDrawing();
    static std::atomic<bool> first{true};
    if (first.exchange(false)) log("First rendered frame completed");
}

inline void closeWindowLogged() {
    log("CloseWindow begin");
    ::CloseWindow();
    log("CloseWindow end");
}

#endif // _WIN32

} // namespace ggdiag

#ifdef _WIN32
// These macros are defined only after raylib/Win32/XInput declarations are loaded,
// so they instrument calls in the application without altering third-party headers.
#define SetConfigFlags ggdiag::setConfigFlagsLogged
#define InitWindow ggdiag::initWindowLogged
#define ToggleFullscreen ggdiag::toggleFullscreenLogged
#define SetTargetFPS ggdiag::setTargetFPSLogged
#define InitAudioDevice ggdiag::initAudioDeviceLogged
#define SetMasterVolume ggdiag::setMasterVolumeLogged
#define CloseAudioDevice ggdiag::closeAudioDeviceLogged
#define XInputGetState ggdiag::xInputGetStateLogged
#define BeginDrawing ggdiag::beginDrawingLogged
#define EndDrawing ggdiag::endDrawingLogged
#define CloseWindow ggdiag::closeWindowLogged
#endif
