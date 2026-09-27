#include "native_folder_picker.h"

#ifdef _WIN32

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>

#include <string>

namespace ggwindows {
namespace {

std::string wideToUtf8(const wchar_t* value) {
    if (!value || !*value) return {};
    const int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string out(static_cast<size_t>(needed), '\0');
    const int written = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                                            out.data(), needed, nullptr, nullptr);
    if (written <= 1) return {};
    out.resize(static_cast<size_t>(written - 1));
    return out;
}

struct ComApartment {
    HRESULT result = E_FAIL;
    bool uninitialize = false;

    ComApartment() {
        result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        uninitialize = result == S_OK || result == S_FALSE;
    }

    ~ComApartment() {
        if (uninitialize) CoUninitialize();
    }

    bool usable() const {
        // RPC_E_CHANGED_MODE means COM was already initialized on this thread
        // with a different apartment model. CoCreateInstance can still be used.
        return SUCCEEDED(result) || result == RPC_E_CHANGED_MODE;
    }
};

} // namespace

std::optional<std::string> chooseFolder(void* ownerWindow, const wchar_t* title) {
    ComApartment apartment;
    if (!apartment.usable()) return std::nullopt;

    IFileOpenDialog* dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog) return std::nullopt;

    DWORD options = 0;
    hr = dialog->GetOptions(&options);
    if (SUCCEEDED(hr)) {
        hr = dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                                FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
    }
    if (SUCCEEDED(hr) && title && *title) hr = dialog->SetTitle(title);

    const HWND owner = reinterpret_cast<HWND>(ownerWindow);
    if (SUCCEEDED(hr)) hr = dialog->Show(owner);

    std::optional<std::string> result;
    if (SUCCEEDED(hr)) {
        IShellItem* item = nullptr;
        hr = dialog->GetResult(&item);
        if (SUCCEEDED(hr) && item) {
            PWSTR path = nullptr;
            hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
            if (SUCCEEDED(hr) && path) {
                std::string utf8 = wideToUtf8(path);
                if (!utf8.empty()) result = std::move(utf8);
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }

    dialog->Release();
    return result;
}

} // namespace ggwindows

#endif // _WIN32
