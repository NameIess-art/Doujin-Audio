#include "desktop_integration.h"
#include "media_controls.h"
#include "subtitle_window.h"
#include "scheduled_tasks.h"
#include "network_proxy.h"
#include "../resource.h"
#include "../win32_window.h"
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <dwmapi.h>
#include <cwchar>
#include <deque>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <set>
#include <stdexcept>
#include <system_error>
#include <winternl.h>
#include <windowsx.h>
#include <winrt/base.h>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
void Success(Result& result, const Value& value = Value()) {
  result.Success(Value(Map{{Value("ok"),Value(true)},{Value("value"),value}}));
}
constexpr UINT kTray = WM_APP + 42;
constexpr UINT kFolderOpenReply = WM_APP + 46;
const UINT kTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
#ifdef _DEBUG
constexpr auto kSettingsKey = L"Software\\DoujinAudio\\Debug";
#else
constexpr auto kSettingsKey = L"Software\\DoujinAudio";
#endif
const Value* Find(const Map& map, const char* key) {
  const auto it = map.find(Value(key)); return it == map.end() ? nullptr : &it->second;
}
std::string RequiredText(const Map& map, const char* key) {
  const auto value = Find(map,key);
  const auto text = value ? std::get_if<std::string>(value) : nullptr;
  if (!text || text->empty()) throw std::invalid_argument(key);
  return *text;
}
bool RequiredBool(const Map& map, const char* key) {
  const auto value = Find(map,key);
  const auto flag = value ? std::get_if<bool>(value) : nullptr;
  if (!flag) throw std::invalid_argument(key);
  return *flag;
}
const Map& Arguments(const flutter::MethodCall<Value>& call) {
  static const Map empty;
  auto map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  return map ? *map : empty;
}
void Launch(const std::wstring& path) {
  const auto result = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr,L"open",path.c_str(),nullptr,nullptr,SW_SHOWNORMAL));
  if (result <= 32) throw std::runtime_error("Unable to open target: " + std::to_string(result));
}

class ScopedTrayMenuTheme {
 public:
  explicit ScopedTrayMenuTheme(bool dark) {
    static const bool supports_preferred_app_mode = [] {
      const auto ntdll = GetModuleHandleW(L"ntdll.dll");
      if (!ntdll) return false;
      const auto get_version = reinterpret_cast<NTSTATUS(WINAPI*)(PRTL_OSVERSIONINFOW)>(
          GetProcAddress(ntdll, "RtlGetVersion"));
      RTL_OSVERSIONINFOW version{sizeof(version)};
      // Ordinal 135 had a different signature before Windows 10 version 1903.
      return get_version && get_version(&version) == 0 &&
             version.dwMajorVersion >= 10 && version.dwBuildNumber >= 18362;
    }();
    HIGHCONTRASTW contrast{sizeof(contrast)};
    if (!supports_preferred_app_mode ||
        !SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) ||
        (contrast.dwFlags & HCF_HIGHCONTRASTON)) {
      return;
    }

    module_ = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module_) return;
    const auto set_mode =
        reinterpret_cast<SetMode>(GetProcAddress(module_, MAKEINTRESOURCEA(135)));
    const auto flush =
        reinterpret_cast<Flush>(GetProcAddress(module_, MAKEINTRESOURCEA(136)));
    if (!set_mode || !flush) return;

    // The native menu palette is process-wide, so restore it when the popup closes.
    set_mode_ = set_mode;
    flush_ = flush;
    previous_mode_ = set_mode_(dark ? Mode::kForceDark : Mode::kForceLight);
    flush_();
  }

  ~ScopedTrayMenuTheme() {
    if (set_mode_) {
      set_mode_(previous_mode_);
      flush_();
    }
    if (module_) FreeLibrary(module_);
  }

  ScopedTrayMenuTheme(const ScopedTrayMenuTheme&) = delete;
  ScopedTrayMenuTheme& operator=(const ScopedTrayMenuTheme&) = delete;

 private:
  enum class Mode { kDefault = 0, kForceDark = 2, kForceLight = 3 };
  using SetMode = Mode(WINAPI*)(Mode);
  using Flush = void(WINAPI*)();

  HMODULE module_ = nullptr;
  SetMode set_mode_ = nullptr;
  Flush flush_ = nullptr;
  Mode previous_mode_ = Mode::kDefault;
};
}

struct DesktopIntegration::FolderOpenState {
  static constexpr int kMaxWorkers = 2;

  struct Request {
    std::unique_ptr<Result> result;
    std::filesystem::path path;
    std::string error;
    std::string error_code = "windows_error";
    bool completed = false;
  };
  std::mutex mutex;
  HWND window = nullptr;
  int workers = 0;
  bool reply_posted = false;
  std::deque<std::shared_ptr<Request>> queued;
  std::vector<std::shared_ptr<Request>> pending;

  static void CALLBACK RunWorker(PTP_CALLBACK_INSTANCE instance, void* context) {
    CallbackMayRunLong(instance);
    const std::unique_ptr<std::shared_ptr<FolderOpenState>> owner(
        static_cast<std::shared_ptr<FolderOpenState>*>(context));
    (*owner)->RunQueuedRequests();
  }

  void RunQueuedRequests() {
    for (;;) {
      std::shared_ptr<Request> request;
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (!window || queued.empty()) {
          --workers;
          return;
        }
        request = std::move(queued.front());
        queued.pop_front();
      }
      std::string error, error_code = "windows_error";
      const HRESULT apartment =
          CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
      try {
        if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) {
          winrt::check_hresult(apartment);
        }
        const auto status = std::filesystem::status(request->path);
        const bool directory = std::filesystem::is_directory(status);
        if (!directory && !std::filesystem::is_regular_file(status)) {
          throw std::invalid_argument("path");
        }
        bool active;
        {
          std::lock_guard<std::mutex> lock(mutex);
          active = window != nullptr;
        }
        if (active) {
          const auto folder = (directory ? request->path : request->path.parent_path()).wstring();
          SHELLEXECUTEINFOW execute{sizeof(SHELLEXECUTEINFOW)};
          // The worker has no message loop, so Shell activation must finish here
          // before its apartment is released. Slow disk/Shell calls stay off the window.
          execute.fMask = SEE_MASK_NOASYNC;
          execute.lpVerb = L"open";
          execute.lpFile = folder.c_str();
          execute.nShow = SW_SHOWNORMAL;
          if (!ShellExecuteExW(&execute)) winrt::throw_last_error();
        }
      } catch (const std::invalid_argument& e) {
        error = e.what(); error_code = "invalid_argument";
      } catch (const winrt::hresult_error& e) {
        error = winrt::to_string(e.message());
      } catch (const std::exception& e) {
        error = e.what();
      }
      if (SUCCEEDED(apartment)) CoUninitialize();
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (!window) continue;
        request->error = std::move(error);
        request->error_code = std::move(error_code);
        request->completed = true;
      }
      for (int attempt = 0; attempt < 200; ++attempt) {
        {
          std::lock_guard<std::mutex> lock(mutex);
          if (!window || reply_posted) break;
          if (PostMessage(window, kFolderOpenReply, 0, 0)) {
            reply_posted = true;
            break;
          }
          if (GetLastError() == ERROR_INVALID_WINDOW_HANDLE) break;
        }
        Sleep(10);
      }
    }
  }
};

DesktopIntegration::DesktopIntegration(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  folder_opens_ = std::make_shared<FolderOpenState>();
  folder_opens_->window = window;
  WINDOWPLACEMENT saved{sizeof(WINDOWPLACEMENT)};
  DWORD bytes = sizeof(saved);
  if (RegGetValueW(HKEY_CURRENT_USER,kSettingsKey,L"WindowPlacement",RRF_RT_REG_BINARY,nullptr,&saved,&bytes) == ERROR_SUCCESS && bytes == sizeof(saved)) {
    const auto dpi = GetDpiForWindow(window_);
    DWORD saved_dpi = dpi, dpi_bytes = sizeof(saved_dpi);
    RegGetValueW(HKEY_CURRENT_USER,kSettingsKey,L"WindowDpi",RRF_RT_REG_DWORD,nullptr,&saved_dpi,&dpi_bytes);
    if (saved_dpi == 0) saved_dpi = dpi;
    RECT minimum{0,0,MulDiv(960,dpi,96),MulDiv(600,dpi,96)};
    Win32Window::AdjustFrameRect(minimum, dpi);
    const auto width = std::max<LONG>(minimum.right-minimum.left,MulDiv(saved.rcNormalPosition.right-saved.rcNormalPosition.left,dpi,saved_dpi));
    const auto height = std::max<LONG>(minimum.bottom-minimum.top,MulDiv(saved.rcNormalPosition.bottom-saved.rcNormalPosition.top,dpi,saved_dpi));
    if (saved.showCmd == SW_SHOWMAXIMIZED) initial_show_command_ = SW_SHOWMAXIMIZED;
    saved.rcNormalPosition.right = saved.rcNormalPosition.left + width;
    saved.rcNormalPosition.bottom = saved.rcNormalPosition.top + height;
    saved.length = sizeof(saved);
    saved.flags = 0;
    // Get/SetWindowPlacement use workspace coordinates and handle changed monitors.
    // Keep startup hidden until Flutter's first frame is ready.
    saved.showCmd = SW_HIDE;
    SetWindowPlacement(window_,&saved);
  }
  subtitles_ = std::make_unique<SubtitleWindow>(GetModuleHandle(nullptr));
  media_ = std::make_unique<MediaControls>(window);
  scheduled_tasks_ = std::make_unique<ScheduledTasks>(window);
  network_proxy_ = std::make_unique<NetworkProxy>(window, messenger);
  desktop_ = std::make_unique<Channel>(messenger,"doujin_audio/windows_desktop",&flutter::StandardMethodCodec::GetInstance());
  desktop_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      if (call.method_name() == "ready") {
        ready_ = true;
        result->Success();
        window_maximized_.reset();
        PublishWindowMaximized();
        auto pending = std::move(pending_); pending_.clear();
        for (const auto& action : pending) Action(action);
      } else if (call.method_name() == "exit") {
        result->Success();
        if (!ending_session_) { quitting_ = true; PostMessage(window_,WM_CLOSE,0,0); }
      } else if (call.method_name() == "setFullscreen") {
        SetFullscreen(RequiredBool(Arguments(call),"enabled")); result->Success();
      } else if (call.method_name() == "windowCommand") {
        RunWindowCommand(RequiredText(Arguments(call), "command"));
        result->Success();
      } else if (call.method_name() == "getHotkeyStatus") {
        result->Success(Value(media_->HotkeyStatus()));
      } else { result->NotImplemented(); }
    } catch (const std::invalid_argument& e) { result->Error("invalid_argument",e.what()); }
      catch (const std::exception& e) { result->Error("desktop_error",e.what()); }
  });
  auto add = [&](const char* name, auto handler) {
    auto channel = std::make_unique<Channel>(messenger,name,&flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([handler](const auto& call, auto result) {
      try { handler(call,*result); }
      catch (const std::invalid_argument& e) { result->Error("invalid_argument",e.what()); }
      catch (const winrt::hresult_error& e) { result->Error("windows_error",winrt::to_string(e.message())); }
      catch (const std::exception& e) { result->Error("windows_error",e.what()); }
    });
    channels_.push_back(std::move(channel));
  };
  add("doujin_audio/subtitle_overlay",[this](const auto& call, Result& result) {
    const auto& name = call.method_name(); const auto& args = Arguments(call);
    if (name == "canDrawOverlays") Success(result,Value(true));
    else if (name == "startOverlay") { subtitles_->Show(true); Success(result); }
    else if (name == "stopOverlay") { subtitles_->Show(false); Success(result); }
    else if (name == "updateSubtitle") {
      auto value = Find(args,"text"); auto text = value ? std::get_if<std::string>(value) : nullptr;
      if (!text) throw std::invalid_argument("text");
      subtitles_->Update(*text); Success(result);
    } else if (name == "updateStyle") { subtitles_->Style(args); Success(result); }
    else result.NotImplemented();
  });
  add("doujin_audio/notifications",[this](const auto& call, Result& result) {
    const auto& name = call.method_name();
    if (name == "syncUnifiedPlaybackNotifications") {
      const auto& args = Arguments(call);
      const auto raw = Find(args,"items");
      const auto items = raw ? std::get_if<flutter::EncodableList>(raw) : nullptr;
      if (!items) throw std::invalid_argument("items");
      bool playing = false;
      for (const auto& item : *items) {
        const auto map = std::get_if<Map>(&item);
        if (!map) throw std::invalid_argument("items");
        playing = RequiredBool(*map,"playing") || playing;
      }
      playback_active_ = playing;
      RefreshPower(); media_->Update(args); Success(result);
    }
    else if (name == "clearUnifiedPlaybackNotifications") { media_->Clear(); playback_active_ = false; RefreshPower(); Success(result); }
    else result.NotImplemented();
  });
  add("doujin_audio/app_lifecycle",[this](const auto& call, Result& result) {
    if (call.method_name() == "terminateForPendingRestore") {
      Success(result); Action("exit");
    } else if (call.method_name() == "syncAppTheme") {
      const auto& args = Arguments(call);
      auto mode = RequiredText(args,"themeMode");
      if (mode != "system" && mode != "dark" && mode != "light") throw std::invalid_argument("themeMode");
      const auto read_optional_rgb = [&args](const char* key) -> std::optional<COLORREF> {
        const auto value = Find(args, key);
        if (!value || std::holds_alternative<std::monostate>(*value)) return std::nullopt;
        const auto color = std::get_if<int32_t>(value);
        if (!color || *color < 0 || *color > 0xffffff) throw std::invalid_argument(key);
        return RGB((*color >> 16) & 0xff, (*color >> 8) & 0xff, *color & 0xff);
      };
      if (Find(args, "lightWindowBorderColor") || Find(args, "darkWindowBorderColor")) {
        light_window_border_color_ = read_optional_rgb("lightWindowBorderColor");
        dark_window_border_color_ = read_optional_rgb("darkWindowBorderColor");
      }
      theme_mode_ = mode;
      UpdateTheme(); Success(result);
    } else if (call.method_name() == "getSystemAccentColor") {
      DWORD color = 0;
      BOOL opaque = FALSE;
      if (SUCCEEDED(DwmGetColorizationColor(&color, &opaque))) {
        const int64_t argb = static_cast<int64_t>(0xff000000u | (color & 0x00ffffffu));
        Success(result, Value(argb));
      } else {
        Success(result);
      }
    } else if (call.method_name() == "syncTrayMenu") {
      const auto& args = Arguments(call);
      tray_labels_ = {
          std::wstring(winrt::to_hstring(RequiredText(args, "open"))),
          std::wstring(winrt::to_hstring(RequiredText(args, "toggle"))),
          std::wstring(winrt::to_hstring(RequiredText(args, "previous"))),
          std::wstring(winrt::to_hstring(RequiredText(args, "next"))),
          std::wstring(winrt::to_hstring(RequiredText(args, "exit"))),
      };
      Success(result);
    } else result.NotImplemented();
  });
  add("doujin_audio/update",[this](const auto& call, Result& result) {
    const auto& name = call.method_name(); const auto& args = Arguments(call);
    if (name == "getAppVersion") {
      Success(result,Value(Map{{Value("versionName"),Value(FLUTTER_VERSION)},
        {Value("buildNumber"),Value(FLUTTER_VERSION_BUILD)}, {Value("platform"),Value("windows")}}));
    } else if (name == "openReleasePage") {
      auto url = RequiredText(args,"url");
      if (url.rfind("https://",0) != 0 && url.rfind("http://",0) != 0 && url.rfind("mailto:",0) != 0) throw std::invalid_argument("url");
      Launch(winrt::to_hstring(url).c_str()); Success(result,Value(true));
    } else if (name == "installWindowsUpdate") {
      const auto path = std::filesystem::path(winrt::to_hstring(RequiredText(args,"path")).c_str());
      if (!path.is_absolute() || path.extension() != L".exe" || !std::filesystem::is_regular_file(path)) throw std::invalid_argument("path");
      Launch(path.wstring());
      Success(result,Value(Map{{Value("ok"),Value(true)},{Value("needsPermission"),Value(false)}}));
      // The installer asks the running app to exit only when the user commits installation.
    } else result.NotImplemented();
  });
  auto power = std::make_unique<Channel>(messenger,"doujin_audio/power",&flutter::StandardMethodCodec::GetInstance());
  power->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
    const auto& name = call.method_name(); const auto& args = Arguments(call);
    if (name == "syncPlaybackTimerAlarms") {
      RequiredBool(args,"timerWaitingForPlayback"); RequiredBool(args,"autoResumeEnabled");
      if (!Find(args,"generation") || !Find(args,"autoResumeHour") || !Find(args,"autoResumeMinute")) throw std::invalid_argument("timer arguments");
      scheduled_tasks_->Sync(args,std::move(result));
    }
    else if (name == "setKeepScreenOn") {
      screen_on_ = RequiredBool(args,"enabled");
      RefreshPower(); Success(*result,Value(true));
    } else result->NotImplemented();
    } catch (const std::invalid_argument& e) { result->Error("invalid_argument",e.what()); }
      catch (const winrt::hresult_error& e) { result->Error("windows_error",winrt::to_string(e.message())); }
      catch (const std::exception& e) { result->Error("windows_error",e.what()); }
  });
  channels_.push_back(std::move(power));
  auto file_cache = std::make_unique<Channel>(messenger,"doujin_audio/file_cache",&flutter::StandardMethodCodec::GetInstance());
  file_cache->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
    if (call.method_name() == "openContainingFolder") {
      OpenContainingFolder(Arguments(call),result);
      return;
    }
    if (call.method_name() != "getStorageUsage") { result->NotImplemented(); return; }
    PWSTR directory = nullptr;
    winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&directory));
    const std::filesystem::path app_data(directory);
    CoTaskMemFree(directory);
    ULARGE_INTEGER available{},total{},free{};
    if (!GetDiskFreeSpaceExW(app_data.c_str(),&available,&total,&free)) winrt::throw_last_error();
    Success(*result,Value(Map{{Value("totalBytes"),Value(static_cast<int64_t>(total.QuadPart))},
      {Value("availableBytes"),Value(static_cast<int64_t>(available.QuadPart))}}));
    } catch (const std::invalid_argument& e) { result->Error("invalid_argument",e.what()); }
      catch (const winrt::hresult_error& e) { result->Error("windows_error",winrt::to_string(e.message())); }
      catch (const std::exception& e) { result->Error("windows_error",e.what()); }
  });
  channels_.push_back(std::move(file_cache));
  AddTray();
}
DesktopIntegration::~DesktopIntegration() {
  *alive_ = false;
  if (tray_menu_open_) {
    tray_menu_open_ = false;
    EndMenu();
  }
  if (content_) RemoveWindowSubclass(content_, ContentProc, 0);
  std::vector<std::shared_ptr<FolderOpenState::Request>> pending;
  {
    std::lock_guard<std::mutex> lock(folder_opens_->mutex);
    folder_opens_->window = nullptr;
    folder_opens_->queued.clear();
    pending.swap(folder_opens_->pending);
  }
  // Network filesystem calls cannot be cancelled reliably. Complete replies on
  // the platform thread without waiting for those workers during engine teardown.
  for (const auto& request : pending) {
    request->result->Error("windows_error","Window closed before folder operation completed");
    request->result.reset();
  }
  scheduled_tasks_.reset();
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE,&icon);
  SetThreadExecutionState(ES_CONTINUOUS);
}
void DesktopIntegration::OpenContainingFolder(const Map& args,
    std::unique_ptr<Result>& result) {
  const auto target = RequiredText(args,"path");
  if (target.find('\0') != std::string::npos) throw std::invalid_argument("path");
  std::filesystem::path path(winrt::to_hstring(target).c_str());
  if (!path.is_absolute()) throw std::invalid_argument("path");
  const auto state = folder_opens_;
  const auto request = std::make_shared<FolderOpenState::Request>();
  request->result = std::move(result);
  request->path = std::move(path);
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->pending.push_back(request);
    state->queued.push_back(request);
    if (state->workers == FolderOpenState::kMaxWorkers) return;
    auto owner = std::make_unique<std::shared_ptr<FolderOpenState>>(state);
    if (TrySubmitThreadpoolCallback(FolderOpenState::RunWorker, owner.get(), nullptr)) {
      owner.release();
      ++state->workers;
      return;
    }
    if (state->workers > 0) return;
    state->pending.pop_back();
    state->queued.pop_back();
  }
  request->result->Error("windows_error", "Unable to schedule folder open");
}
void DesktopIntegration::ReplyFolderOpens() {
  std::vector<std::shared_ptr<FolderOpenState::Request>> replies;
  {
    std::lock_guard<std::mutex> lock(folder_opens_->mutex);
    folder_opens_->reply_posted = false;
    auto& pending = folder_opens_->pending;
    for (auto it = pending.begin(); it != pending.end();) {
      if ((*it)->completed) { replies.push_back(*it); it = pending.erase(it); }
      else ++it;
    }
  }
  for (const auto& reply : replies) {
    if (reply->error.empty()) Success(*reply->result,Value(true));
    else reply->result->Error(reply->error_code,reply->error);
    reply->result.reset();
  }
}
void DesktopIntegration::AddTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; icon.uCallbackMessage = kTray;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr),MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip,L"Doujin Audio"); Shell_NotifyIconW(NIM_ADD,&icon);
}
void DesktopIntegration::Action(const std::string& action) {
  if (ending_session_) return;
  if (!ready_) { pending_.push_back(action); return; }
  desktop_->InvokeMethod("action",std::make_unique<Value>(action));
}
void DesktopIntegration::EndSession() {
  if (ending_session_) return;
  ending_session_ = true;
  SavePlacement();
  struct Completion { bool finished = false; bool success = false; };
  // A reply may arrive after the deadline, so it must not capture stack state.
  const auto completion = std::make_shared<Completion>();
  const auto deadline = GetTickCount64() + 4000;
  bool sent = false;
  while (!completion->finished && GetTickCount64() < deadline) {
    if (ready_ && !sent) {
      sent = true;
      desktop_->InvokeMethod("action",std::make_unique<Value>("endSession"),
        std::make_unique<flutter::MethodResultFunctions<Value>>(
          [completion](const Value*) { completion->finished = true; completion->success = true; },
          [completion](const std::string&, const std::string&, const Value*) { completion->finished = true; },
          [completion]() { completion->finished = true; }));
    }
    if (completion->finished) break;
    // Flutter runs channel replies on the window thread; keep its messages moving.
    MSG message;
    while (PeekMessage(&message,nullptr,0,0,PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        PostQuitMessage(static_cast<int>(message.wParam));
        completion->finished = true;
        break;
      }
      TranslateMessage(&message);
      DispatchMessage(&message);
      if (completion->finished || GetTickCount64() >= deadline) break;
    }
    const auto now = GetTickCount64();
    if (ready_ && !sent) continue;
    if (!completion->finished && now < deadline) {
      MsgWaitForMultipleObjectsEx(0,nullptr,static_cast<DWORD>(deadline-now),
        QS_ALLINPUT,MWMO_INPUTAVAILABLE);
    }
  }
  const char* status = !completion->finished ? "DoujinAudio: endSession timed out after 4 seconds\n"
    : completion->success ? "DoujinAudio: endSession completed\n" : "DoujinAudio: endSession failed\n";
  OutputDebugStringA(status);
  std::cerr << status;
}
bool DesktopIntegration::UsesDarkTheme() const {
  if (theme_mode_ != "system") return theme_mode_ == "dark";
  DWORD value = 1, size = sizeof(value);
  RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&value,&size);
  return value == 0;
}
void DesktopIntegration::UpdateTheme() {
  const BOOL dark = UsesDarkTheme() ? TRUE : FALSE;
  if (applied_dark_mode_ != dark) {
    DwmSetWindowAttribute(window_, 20, &dark, sizeof(dark));
    applied_dark_mode_ = dark;
  }
  HIGHCONTRASTW contrast{sizeof(contrast)};
  SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0);
  const bool high_contrast = (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
  constexpr DWORD kDwmwaBorderColor = 34;
  constexpr COLORREF kDwmwaColorDefault = 0xFFFFFFFF;
  const auto& preferred = dark ? dark_window_border_color_ : light_window_border_color_;
  const COLORREF border_color =
      (!high_contrast && preferred.has_value()) ? *preferred : kDwmwaColorDefault;
  if (applied_border_color_ != border_color) {
    DwmSetWindowAttribute(window_, kDwmwaBorderColor, &border_color, sizeof(border_color));
    applied_border_color_ = border_color;
  }
}

void DesktopIntegration::ShowTrayMenu() {
  if (tray_menu_open_) return;
  const HMENU menu = CreatePopupMenu();
  if (!menu) return;

  for (size_t index = 0; index < tray_labels_.size(); ++index) {
    if (index + 1 == tray_labels_.size()) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    }
    AppendMenuW(menu, MF_STRING, index + 1, tray_labels_[index].c_str());
  }

  POINT point{};
  GetCursorPos(&point);
  const auto alive = alive_;
  tray_menu_open_ = true;
  SetForegroundWindow(window_);
  int command;
  {
    const ScopedTrayMenuTheme theme(UsesDarkTheme());
    command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                             point.x, point.y, 0, window_, nullptr);
  }
  DestroyMenu(menu);
  if (!*alive) return;
  tray_menu_open_ = false;
  PostMessage(window_, WM_NULL, 0, 0);
  switch (command) {
    case 1: Show(); break;
    case 2: Action("toggle"); break;
    case 3: Action("previous"); break;
    case 4: Action("next"); break;
    case 5: Action("exit"); break;
  }
}

void DesktopIntegration::Show() {
  if (!first_frame_ready_) {
    Activate(true);
    return;
  }
  if (!initial_shown_) ShowInitial();
  else ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_); Action("resume");
}
void DesktopIntegration::ShowInitial() {
  initial_shown_ = true;
  ShowWindow(window_, initial_show_command_);
}
void DesktopIntegration::OnFirstFrame(bool show_initially) {
  if (first_frame_ready_) return;
  first_frame_ready_ = true;
  const bool show = show_initially || (pending_activate_ && pending_activate_show_);
  const bool activate = pending_activate_;
  pending_activate_ = false;
  pending_activate_show_ = false;
  if (show) {
    ShowInitial();
    if (activate) SetForegroundWindow(window_);
  }
  if (activate) Action("resume");
}
void DesktopIntegration::Activate(bool show_window) {
  if (!first_frame_ready_) {
    pending_activate_ = true;
    if (show_window) pending_activate_show_ = true;
    return;
  }
  if (show_window) Show();
  else Action("resume");
}
void DesktopIntegration::AttachContent(HWND content) {
  content_ = content;
  if (!SetWindowSubclass(content_, ContentProc, 0, reinterpret_cast<DWORD_PTR>(this))) {
    winrt::throw_last_error();
  }
  // The window was created before this object handled WM_NCCALCSIZE.
  SetWindowPos(window_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}
LRESULT DesktopIntegration::TopResizeHit(POINT screen) const {
  if (fullscreen_ || IsZoomed(window_)) return HTNOWHERE;
  RECT client{};
  GetClientRect(window_, &client);
  MapWindowPoints(window_, nullptr, reinterpret_cast<POINT*>(&client), 2);
  const UINT dpi = GetDpiForWindow(window_);
  const int padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  const int height = GetSystemMetricsForDpi(SM_CYFRAME, dpi) + padding;
  if (!PtInRect(&client, screen) || screen.y >= client.top + height) return HTNOWHERE;
  const int width = GetSystemMetricsForDpi(SM_CXFRAME, dpi) + padding;
  if (screen.x < client.left + width) return HTTOPLEFT;
  if (screen.x >= client.right - width) return HTTOPRIGHT;
  return HTTOP;
}
LRESULT CALLBACK DesktopIntegration::ContentProc(HWND content, UINT message, WPARAM wp,
                                                 LPARAM lp, UINT_PTR, DWORD_PTR data) {
  // The Flutter view covers the former caption. Let its top strip fall through
  // to the top-level window so native top-edge resizing keeps working.
  if (message == WM_NCHITTEST &&
      reinterpret_cast<const DesktopIntegration*>(data)->TopResizeHit(
          {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)}) != HTNOWHERE) {
    return HTTRANSPARENT;
  }
  return DefSubclassProc(content, message, wp, lp);
}
void DesktopIntegration::RefreshPower() {
  const auto flags = ES_CONTINUOUS | (playback_active_ ? ES_SYSTEM_REQUIRED : 0) | (screen_on_ ? ES_DISPLAY_REQUIRED : 0);
  if (power_flags_ == flags) return;
  if (SetThreadExecutionState(flags) == 0) winrt::throw_last_error();
  power_flags_ = flags;
}
void DesktopIntegration::SavePlacement() {
  if (fullscreen_) return;
  WINDOWPLACEMENT placement{sizeof(WINDOWPLACEMENT)};
  if (!GetWindowPlacement(window_,&placement)) return;
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER,kSettingsKey,0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(key,L"WindowPlacement",0,REG_BINARY,reinterpret_cast<const BYTE*>(&placement),sizeof(placement));
    const DWORD dpi = GetDpiForWindow(window_);
    RegSetValueExW(key,L"WindowDpi",0,REG_DWORD,reinterpret_cast<const BYTE*>(&dpi),sizeof(dpi));
    RegCloseKey(key);
  }
}
void DesktopIntegration::SetFullscreen(bool enabled) {
  if (fullscreen_ == enabled) return;
  fullscreen_ = enabled;
  const LONG_PTR visible = GetWindowLongPtr(window_, GWL_STYLE) & WS_VISIBLE;
  const UINT hidden_flags = visible ? 0 : (SWP_NOZORDER | SWP_NOACTIVATE);
  if (enabled) {
    GetWindowPlacement(window_, &placement_);
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor);
    SetWindowLongPtr(window_, GWL_STYLE, WS_POPUP | visible);
    SetWindowPos(window_, visible ? HWND_TOP : nullptr,
      monitor.rcMonitor.left, monitor.rcMonitor.top,
      monitor.rcMonitor.right - monitor.rcMonitor.left,
      monitor.rcMonitor.bottom - monitor.rcMonitor.top,
      SWP_FRAMECHANGED | hidden_flags);
  } else {
    SetWindowLongPtr(window_, GWL_STYLE, WS_OVERLAPPEDWINDOW | visible);
    WINDOWPLACEMENT placement = placement_;
    if (!visible) placement.showCmd = SW_HIDE;
    SetWindowPlacement(window_, &placement);
    SetWindowPos(window_, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | (visible ? 0 : SWP_NOACTIVATE));
  }
}
void DesktopIntegration::RunWindowCommand(const std::string& command) {
  UINT message = WM_SYSCOMMAND;
  WPARAM param;
  LPARAM position = 0;
  if (command == "drag") {
    POINT cursor{};
    if (!GetCursorPos(&cursor)) winrt::throw_last_error();
    ReleaseCapture();
    message = WM_NCLBUTTONDOWN;
    param = HTCAPTION;
    position = MAKELPARAM(cursor.x, cursor.y);
  } else if (command == "minimize") {
    param = SC_MINIMIZE;
  } else if (command == "toggleMaximized") {
    param = IsZoomed(window_) ? SC_RESTORE : SC_MAXIMIZE;
  } else if (command == "close") {
    param = SC_CLOSE;
  } else {
    throw std::invalid_argument("command");
  }
  if (!PostMessage(window_, message, param, position)) winrt::throw_last_error();
}

void DesktopIntegration::PublishWindowMaximized() {
  if (!ready_ || fullscreen_ || IsIconic(window_)) return;
  const bool maximized = IsZoomed(window_) != FALSE;
  if (window_maximized_ == maximized) return;
  window_maximized_ = maximized;
  desktop_->InvokeMethod("windowMaximized", std::make_unique<Value>(maximized));
}
std::optional<LRESULT> DesktopIntegration::HandleMessage(UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_NCCALCSIZE && wp && !fullscreen_) {
    auto& client = reinterpret_cast<NCCALCSIZE_PARAMS*>(lp)->rgrc[0];
    const LONG top = client.top;
    DefWindowProc(window_, message, wp, lp);
    // Drop the system caption but keep native side and bottom frames. A
    // maximized window extends past the monitor by its frame on every side.
    const UINT dpi = GetDpiForWindow(window_);
    client.top = top + (IsZoomed(window_)
        ? GetSystemMetricsForDpi(SM_CYFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
        : 0);
    return 0;
  }
  if (message == WM_NCHITTEST) {
    const LRESULT hit = TopResizeHit({GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
    if (hit != HTNOWHERE) return hit;
  }
  if (message == WM_SIZE) PublishWindowMaximized();
  if (message == WM_DWMCOLORIZATIONCOLORCHANGED) { UpdateTheme(); return 0; }
  if (message == WM_SETTINGCHANGE &&
      (lp == 0 ||
       (theme_mode_ == "system" &&
        _wcsicmp(reinterpret_cast<const wchar_t*>(lp), L"ImmersiveColorSet") == 0))) {
    UpdateTheme();
  }
  if (message == ScheduledTasks::kReply) { scheduled_tasks_->Reply(); return 0; }
  if (message == NetworkProxy::kReply) { network_proxy_->Reply(); return 0; }
  if (message == kFolderOpenReply) { ReplyFolderOpens(); return 0; }
  if (auto action = media_->HandleMessage(message, wp, lp)) {
    if (*action == "showWindow") Show();
    else if (!action->empty()) Action(*action);
    return 0;
  }
  if (message == kTaskbarCreated) { AddTray(); return 0; }
  if (message == kActivate) { Activate(wp == 0); return 0; }
  if (message == WM_EXITSIZEMOVE) SavePlacement();
  // A previously queued tray exit must not destroy the engine during the reply wait.
  if (message == WM_CLOSE && ending_session_) return 0;
  if (message == WM_CLOSE && !quitting_) { SavePlacement(); ShowWindow(window_,SW_HIDE); Action("background"); return 0; }
  if (message == WM_QUERYENDSESSION) return TRUE;
  if (message == WM_ENDSESSION) {
    if (wp) EndSession();
    return 0;
  }
  if (message == WM_APP + 43) { Action("exit"); return 0; }
  if (message == WM_GETMINMAXINFO && !fullscreen_) {
    const auto dpi = GetDpiForWindow(window_);
    RECT rect{0,0,MulDiv(960,dpi,96),MulDiv(600,dpi,96)};
    Win32Window::AdjustFrameRect(rect, dpi);
    auto info = reinterpret_cast<MINMAXINFO*>(lp);
    info->ptMinTrackSize = {rect.right-rect.left,rect.bottom-rect.top}; return 0;
  }
  if (message == kMediaAction) {
    using Button = winrt::Windows::Media::SystemMediaTransportControlsButton;
    switch (static_cast<Button>(wp)) {
      case Button::Play: Action("play"); break;
      case Button::Pause: case Button::Stop: Action("pause"); break;
      case Button::Next: Action("next"); break;
      case Button::Previous: Action("previous"); break;
      default: break;
    }
    return 0;
  }
  if (message == kTray) {
    if (LOWORD(lp) == WM_LBUTTONDBLCLK) Show();
    if (LOWORD(lp) == WM_RBUTTONUP) ShowTrayMenu();
    return 0;
  }
  return std::nullopt;
}
