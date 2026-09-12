#include "desktop_integration.h"
#include "media_controls.h"
#include "subtitle_window.h"
#include "scheduled_tasks.h"
#include "../resource.h"
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <filesystem>
#include <set>
#include <stdexcept>
#include <winrt/base.h>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
void Success(Result& result, const Value& value = Value()) {
  result.Success(Value(Map{{Value("ok"),Value(true)},{Value("value"),value}}));
}
constexpr UINT kTray = WM_APP + 42;
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
}

DesktopIntegration::DesktopIntegration(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  WINDOWPLACEMENT saved{sizeof(WINDOWPLACEMENT)};
  DWORD bytes = sizeof(saved);
  if (RegGetValueW(HKEY_CURRENT_USER,kSettingsKey,L"WindowPlacement",RRF_RT_REG_BINARY,nullptr,&saved,&bytes) == ERROR_SUCCESS && bytes == sizeof(saved)) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromRect(&saved.rcNormalPosition,MONITOR_DEFAULTTONEAREST),&monitor);
    const auto dpi = GetDpiForWindow(window_);
    DWORD saved_dpi = dpi, dpi_bytes = sizeof(saved_dpi);
    RegGetValueW(HKEY_CURRENT_USER,kSettingsKey,L"WindowDpi",RRF_RT_REG_DWORD,nullptr,&saved_dpi,&dpi_bytes);
    if (saved_dpi == 0) saved_dpi = dpi;
    RECT minimum{0,0,MulDiv(960,dpi,96),MulDiv(600,dpi,96)};
    AdjustWindowRectExForDpi(&minimum,WS_OVERLAPPEDWINDOW,FALSE,0,dpi);
    const auto width = std::max<LONG>(minimum.right-minimum.left,MulDiv(saved.rcNormalPosition.right-saved.rcNormalPosition.left,dpi,saved_dpi));
    const auto height = std::max<LONG>(minimum.bottom-minimum.top,MulDiv(saved.rcNormalPosition.bottom-saved.rcNormalPosition.top,dpi,saved_dpi));
    const auto x = std::clamp<LONG>(saved.rcNormalPosition.left,monitor.rcWork.left,std::max(monitor.rcWork.left,monitor.rcWork.right-width));
    const auto y = std::clamp<LONG>(saved.rcNormalPosition.top,monitor.rcWork.top,std::max(monitor.rcWork.top,monitor.rcWork.bottom-height));
    SetWindowPos(window_,nullptr,x,y,width,height,SWP_NOZORDER | SWP_NOACTIVATE);
    if (saved.showCmd == SW_SHOWMAXIMIZED) initial_show_command_ = SW_SHOWMAXIMIZED;
  }
  subtitles_ = std::make_unique<SubtitleWindow>(GetModuleHandle(nullptr));
  media_ = std::make_unique<MediaControls>(window);
  desktop_ = std::make_unique<Channel>(messenger,"doujin_audio/windows_desktop",&flutter::StandardMethodCodec::GetInstance());
  desktop_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      if (call.method_name() == "ready") {
        ready_ = true;
        result->Success();
        auto pending = std::move(pending_); pending_.clear();
        for (const auto& action : pending) Action(action);
      } else if (call.method_name() == "exit") {
        quitting_ = true; result->Success(); PostMessage(window_,WM_CLOSE,0,0);
      } else if (call.method_name() == "setFullscreen") {
        SetFullscreen(RequiredBool(Arguments(call),"enabled")); result->Success();
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
      if (playing) wake_locks_.insert("playback"); else wake_locks_.erase("playback");
      RefreshPower(); media_->Update(args); Success(result);
    }
    else if (name == "clearUnifiedPlaybackNotifications") { media_->Clear(); wake_locks_.erase("playback"); RefreshPower(); Success(result); }
    else if (name == "areNotificationsEnabled") Success(result,Value(true));
    else if (name == "consumePendingNotificationSessionId") Success(result);
    else result.NotImplemented();
  });
  add("doujin_audio/app_lifecycle",[this](const auto& call, Result& result) {
    if (call.method_name() == "terminateForPendingRestore") {
      Success(result); Action("exit");
    } else if (call.method_name() == "syncAppTheme") {
      auto mode = RequiredText(Arguments(call),"themeMode");
      BOOL dark = mode == "dark";
      if (mode == "system") {
        DWORD value = 1, size = sizeof(value);
        RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&value,&size);
        dark = value == 0;
      }
      DwmSetWindowAttribute(window_,20,&dark,sizeof(dark)); Success(result);
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
  add("doujin_audio/power",[this](const auto& call, Result& result) {
    const auto& name = call.method_name(); const auto& args = Arguments(call);
    if (name == "syncPlaybackTimerAlarms") {
      RequiredBool(args,"timerWaitingForPlayback"); RequiredBool(args,"autoResumeEnabled");
      if (!Find(args,"generation") || !Find(args,"autoResumeHour") || !Find(args,"autoResumeMinute")) throw std::invalid_argument("timer arguments");
      SyncScheduledTasks(args); Success(result);
    }
    else if (name == "acquireWakeLock" || name == "releaseWakeLock" || name == "setKeepScreenOn") {
      if (name == "setKeepScreenOn") screen_on_ = RequiredBool(args,"enabled");
      else {
        auto tag = RequiredText(args,"tag");
        if (name == "acquireWakeLock") wake_locks_.insert(tag); else wake_locks_.erase(tag);
      }
      RefreshPower(); Success(result,Value(true));
    } else result.NotImplemented();
  });
  add("doujin_audio/file_cache",[](const auto& call, Result& result) {
    if (call.method_name() != "getStorageUsage") { result.NotImplemented(); return; }
    const auto cache = std::filesystem::path(winrt::to_hstring(RequiredText(Arguments(call),"cachePath")).c_str());
    if (!cache.is_absolute()) throw std::invalid_argument("cachePath");
    ULARGE_INTEGER available{},total{},free{};
    if (!GetDiskFreeSpaceExW(cache.root_path().c_str(),&available,&total,&free)) winrt::throw_last_error();
    uint64_t bytes = 0;
    std::error_code error;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(cache,std::filesystem::directory_options::skip_permission_denied,error)) {
      if (entry.is_regular_file(error)) { auto size = entry.file_size(error); if (!error) bytes += size; }
    }
    Success(result,Value(Map{{Value("totalBytes"),Value(static_cast<int64_t>(total.QuadPart))},
      {Value("availableBytes"),Value(static_cast<int64_t>(available.QuadPart))},
      {Value("cacheBytes"),Value(static_cast<int64_t>(bytes))}}));
  });
  AddTray();
}
DesktopIntegration::~DesktopIntegration() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE,&icon);
  SetThreadExecutionState(ES_CONTINUOUS);
}
void DesktopIntegration::AddTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; icon.uCallbackMessage = kTray;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr),MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip,L"Doujin Audio"); Shell_NotifyIconW(NIM_ADD,&icon);
}
void DesktopIntegration::Action(const std::string& action) {
  if (!ready_) { pending_.push_back(action); return; }
  desktop_->InvokeMethod("action",std::make_unique<Value>(action));
}
void DesktopIntegration::Show() {
  ShowWindow(window_,IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_); Action("resume");
}
void DesktopIntegration::ShowInitial() { ShowWindow(window_,initial_show_command_); }
void DesktopIntegration::RefreshPower() {
  const auto flags = ES_CONTINUOUS | (wake_locks_.empty() ? 0 : ES_SYSTEM_REQUIRED) | (screen_on_ ? ES_DISPLAY_REQUIRED : 0);
  if (SetThreadExecutionState(flags) == 0) winrt::throw_last_error();
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
  if (enabled) {
    GetWindowPlacement(window_,&placement_);
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(window_,MONITOR_DEFAULTTONEAREST),&monitor);
    SetWindowLongPtr(window_,GWL_STYLE,WS_POPUP | WS_VISIBLE);
    SetWindowPos(window_,HWND_TOP,monitor.rcMonitor.left,monitor.rcMonitor.top,
      monitor.rcMonitor.right-monitor.rcMonitor.left,monitor.rcMonitor.bottom-monitor.rcMonitor.top,SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(window_,GWL_STYLE,WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    SetWindowPlacement(window_,&placement_);
    SetWindowPos(window_,nullptr,0,0,0,0,SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  }
}
std::optional<LRESULT> DesktopIntegration::HandleMessage(UINT message, WPARAM wp, LPARAM lp) {
  if (message == kTaskbarCreated) { AddTray(); return 0; }
  if (message == kActivate) { if (wp == 0) Show(); else Action("resume"); return 0; }
  if (message == WM_EXITSIZEMOVE) SavePlacement();
  if (message == WM_CLOSE && !quitting_) { SavePlacement(); ShowWindow(window_,SW_HIDE); Action("background"); return 0; }
  if (message == WM_QUERYENDSESSION) { Action("exit"); return TRUE; }
  if (message == WM_APP + 43) { Action("exit"); return 0; }
  if (message == WM_APP + 44) { Action("deviceDisconnected"); return 0; }
  if (message == WM_GETMINMAXINFO && !fullscreen_) {
    const auto dpi = GetDpiForWindow(window_);
    RECT rect{0,0,MulDiv(960,dpi,96),MulDiv(600,dpi,96)};
    AdjustWindowRectExForDpi(&rect,WS_OVERLAPPEDWINDOW,FALSE,0,dpi);
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
    if (LOWORD(lp) == WM_RBUTTONUP) {
      auto menu = CreatePopupMenu();
      AppendMenuW(menu,MF_STRING,1,L"Open / 打开");
      AppendMenuW(menu,MF_STRING,2,L"Play / Pause / 播放暂停");
      AppendMenuW(menu,MF_STRING,3,L"Previous / 上一曲");
      AppendMenuW(menu,MF_STRING,4,L"Next / 下一曲");
      AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
      AppendMenuW(menu,MF_STRING,5,L"Exit / 退出");
      POINT pt; GetCursorPos(&pt); SetForegroundWindow(window_);
      const auto command = TrackPopupMenu(menu,TPM_RETURNCMD | TPM_RIGHTBUTTON,pt.x,pt.y,0,window_,nullptr);
      DestroyMenu(menu); PostMessage(window_,WM_NULL,0,0);
      switch (command) {
        case 1: Show(); break; case 2: Action("toggle"); break;
        case 3: Action("previous"); break; case 4: Action("next"); break; case 5: Action("exit"); break;
      }
    }
    return 0;
  }
  return std::nullopt;
}
