#pragma once

#include <optional>
#include <string>

namespace ggwindows {

// Opens the native Windows Common Item Dialog in folder-picker mode.
// ownerWindow is a native HWND passed as void* so this header remains free of
// Win32/COM declarations and can be included beside raylib safely.
std::optional<std::string> chooseFolder(void* ownerWindow, const wchar_t* title);

} // namespace ggwindows
