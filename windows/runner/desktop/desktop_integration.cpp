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
#include <filesystem>
#include <iostream>
#include <mutex>
#include <set>
#include <stdexcept>
#include <system_error>
#include <thread>
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

thread_local HMENU tray_popup_menu = nullptr;

void CALLBACK RoundTrayPopup(HWINEVENTHOOK, DWORD, HWND popup, LONG, LONG,
                             DWORD, DWORD) {
  if (!tray_popup_menu || !popup) return;
  wchar_t class_name[16]{};
  GetClassNameW(popup, class_name, ARRAYSIZE(class_name));
  if (wcscmp(class_name, L"#32768") != 0) return;

  RECT window{}, first{}, last{}, content{};
  const int count = GetMenuItemCount(tray_popup_menu);
  if (count <= 0 || !GetWindowRect(popup, &window) ||
      !GetMenuItemRect(nullptr, tray_popup_menu, 0, &first) ||
      !GetMenuItemRect(nullptr, tray_popup_menu, count - 1, &last)) {
    return;
  }
  UnionRect(&content, &first, &last);
  if (!IntersectRect(&content, &content, &window)) return;

  // Clip to the menu rows to remove the system-painted outer frame.
  OffsetRect(&content, -window.left, -window.top);
  const int diameter = MulDiv(16, GetDpiForWindow(popup), 96);
  const HRGN region = CreateRoundRectRgn(
      content.left, content.top, content.right, content.bottom,
      diameter, diameter);
  if (region && !SetWindowRgn(popup, region, TRUE)) DeleteObject(region);
}
}

struct DesktopIntegration::FolderOpenState {
  struct Request {
    std::unique_ptr<Result> result;
    std::string error;
    std::string error_code = "windows_error";
    bool completed = false;
  };
  std::mutex mutex;
  HWND window = nullptr;
  std::vector<std::shared_ptr<Request>> pending;
};

struct DesktopIntegration::TrayMenuAppearance {
  std::array<std::wstring, 5> labels;
  HFONT font;
  COLORREF background;
  COLORREF foreground;
  COLORREF highlight;
  int padding;
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
      auto mode = RequiredText(Arguments(call),"themeMode");
      if (mode != "system" && mode != "dark" && mode != "light") throw std::invalid_argument("themeMode");
      theme_mode_ = mode;
      UpdateTheme(); Success(result);
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
  if (content_) RemoveWindowSubclass(content_, ContentProc, 0);
  std::vector<std::shared_ptr<FolderOpenState::Request>> pending;
  {
    std::lock_guard<std::mutex> lock(folder_opens_->mutex);
    folder_opens_->window = nullptr;
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
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->pending.push_back(request);
  }
  request->result = std::move(result);
  try {
    std::thread([state,request,path = std::move(path)] {
      std::string error, error_code = "windows_error";
      const auto apartment = CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
      try {
        winrt::check_hresult(apartment);
        const auto status = std::filesystem::status(path);
        const bool directory = std::filesystem::is_directory(status);
        if (!directory && !std::filesystem::is_regular_file(status)) throw std::invalid_argument("path");
        bool active;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          active = state->window != nullptr;
        }
        if (active) {
          const auto folder = (directory ? path : path.parent_path()).wstring();
          SHELLEXECUTEINFOW execute{sizeof(SHELLEXECUTEINFOW)};
          // The worker has no message loop, so Shell activation must finish here
          // before its STA is released. Slow disk/Shell calls stay off the window.
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
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->window) return;
        request->error = std::move(error);
        request->error_code = std::move(error_code);
        request->completed = true;
      }
      for (;;) {
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->window) return;
          if (PostMessage(state->window,kFolderOpenReply,0,0)) return;
        }
        // A full window queue must not strand the channel result. Back off
        // without holding the teardown mutex, and stop once the window closes.
        Sleep(10);
      }
    }).detach();
  } catch (const std::system_error& e) {
    request->error = e.what();
    request->completed = true;
    ReplyFolderOpens();
  }
}
void DesktopIntegration::ReplyFolderOpens() {
  std::vector<std::shared_ptr<FolderOpenState::Request>> replies;
  {
    std::lock_guard<std::mutex> lock(folder_opens_->mutex);
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
  const BOOL dark = UsesDarkTheme();
  DwmSetWindowAttribute(window_,20,&dark,sizeof(dark));
}

void DesktopIntegration::ShowTrayMenu() {
  if (active_tray_menu_) return;
  const HMENU menu = CreatePopupMenu();
  if (!menu) return;

  const UINT dpi = GetDpiForWindow(window_);
  HIGHCONTRASTW contrast{sizeof(contrast)};
  SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0);
  const bool custom_colors = !(contrast.dwFlags & HCF_HIGHCONTRASTON);
  const bool dark = UsesDarkTheme();
  NONCLIENTMETRICSW metrics{sizeof(metrics)};
  HFONT font = nullptr;
  if (custom_colors && SystemParametersInfoForDpi(
      SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, dpi)) {
    font = CreateFontIndirectW(&metrics.lfMenuFont);
  }
  TrayMenuAppearance appearance{
      tray_labels_,
      font ? font : static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT)),
      dark ? RGB(32, 32, 32) : RGB(250, 250, 250),
      dark ? RGB(245, 245, 245) : RGB(23, 23, 23),
      dark ? RGB(65, 65, 65) : RGB(222, 234, 250),
      MulDiv(12, dpi, 96),
  };
  const HBRUSH background = custom_colors ? CreateSolidBrush(appearance.background) : nullptr;
  if (background) {
    MENUINFO info{sizeof(info)};
    info.fMask = MIM_BACKGROUND;
    info.hbrBack = background;
    SetMenuInfo(menu, &info);
  }

  for (size_t index = 0; index < appearance.labels.size(); ++index) {
    if (index == 4) AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    MENUITEMINFOW item{sizeof(item)};
    item.fMask = MIIM_ID | MIIM_STRING | MIIM_FTYPE | MIIM_DATA;
    item.wID = static_cast<UINT>(index + 1);
    item.fType = custom_colors ? MFT_OWNERDRAW : MFT_STRING;
    item.dwTypeData = appearance.labels[index].data();
    item.dwItemData = reinterpret_cast<ULONG_PTR>(&appearance);
    InsertMenuItemW(menu, static_cast<UINT>(GetMenuItemCount(menu)), TRUE, &item);
  }

  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(window_);
  active_tray_menu_ = &appearance;
  const HWINEVENTHOOK frame_hook = custom_colors
      ? SetWinEventHook(EVENT_SYSTEM_MENUPOPUPSTART, EVENT_SYSTEM_MENUPOPUPSTART,
                        nullptr, RoundTrayPopup, GetCurrentProcessId(),
                        GetCurrentThreadId(), WINEVENT_OUTOFCONTEXT)
      : nullptr;
  tray_popup_menu = frame_hook ? menu : nullptr;
  const auto command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                      point.x, point.y, 0, window_, nullptr);
  tray_popup_menu = nullptr;
  if (frame_hook) UnhookWinEvent(frame_hook);
  active_tray_menu_ = nullptr;
  DestroyMenu(menu);
  if (background) DeleteObject(background);
  if (font) DeleteObject(font);
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
  ShowWindow(window_,IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_); Action("resume");
}
void DesktopIntegration::ShowInitial() { ShowWindow(window_,initial_show_command_); }
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
  if (enabled) {
    GetWindowPlacement(window_,&placement_);
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(window_,MONITOR_DEFAULTTONEAREST),&monitor);
    SetWindowLongPtr(window_,GWL_STYLE,WS_POPUP | WS_VISIBLE);
    SetWindowPos(window_,HWND_TOP,monitor.rcMonitor.left,monitor.rcMonitor.top,
      monitor.rcMonitor.right-monitor.rcMonitor.left,monitor.rcMonitor.bottom-monitor.rcMonitor.top,SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(window_, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    SetWindowPlacement(window_,&placement_);
    SetWindowPos(window_,nullptr,0,0,0,0,SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
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
  if (active_tray_menu_ && message == WM_MEASUREITEM) {
    auto& item = *reinterpret_cast<MEASUREITEMSTRUCT*>(lp);
    const auto& style = *active_tray_menu_;
    if (item.CtlType == ODT_MENU &&
        item.itemData == reinterpret_cast<ULONG_PTR>(&style)) {
      const auto& label = style.labels[item.itemID - 1];
      const HDC dc = GetDC(window_);
      const auto previous_font = SelectObject(dc, style.font);
      SIZE text{};
      GetTextExtentPoint32W(dc, label.c_str(), static_cast<int>(label.size()), &text);
      SelectObject(dc, previous_font);
      ReleaseDC(window_, dc);
      item.itemWidth = text.cx + 2 * style.padding;
      item.itemHeight = text.cy + style.padding;
      return TRUE;
    }
  }
  if (active_tray_menu_ && message == WM_DRAWITEM) {
    const auto& item = *reinterpret_cast<const DRAWITEMSTRUCT*>(lp);
    const auto& style = *active_tray_menu_;
    if (item.CtlType == ODT_MENU &&
        item.itemData == reinterpret_cast<ULONG_PTR>(&style)) {
      const int saved = SaveDC(item.hDC);
      SetDCBrushColor(item.hDC, item.itemState & ODS_SELECTED
                                  ? style.highlight : style.background);
      FillRect(item.hDC, &item.rcItem, static_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
      SelectObject(item.hDC, style.font);
      SetBkMode(item.hDC, TRANSPARENT);
      SetTextColor(item.hDC, style.foreground);
      RECT text = item.rcItem;
      text.left += style.padding;
      text.right -= style.padding;
      const auto& label = style.labels[item.itemID - 1];
      DrawTextW(item.hDC, label.c_str(), static_cast<int>(label.size()), &text,
                DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
      RestoreDC(item.hDC, saved);
      return TRUE;
    }
  }
  if (message == WM_DWMCOLORIZATIONCOLORCHANGED) { UpdateTheme(); return 0; }
  if (message == WM_SETTINGCHANGE && theme_mode_ == "system") UpdateTheme();
  if (message == ScheduledTasks::kReply) { scheduled_tasks_->Reply(); return 0; }
  if (message == NetworkProxy::kReply) { network_proxy_->Reply(); return 0; }
  if (message == kFolderOpenReply) { ReplyFolderOpens(); return 0; }
  if (auto action = media_->HandleMessage(message, wp, lp)) {
    if (*action == "showWindow") Show();
    else if (!action->empty()) Action(*action);
    return 0;
  }
  if (message == kTaskbarCreated) { AddTray(); return 0; }
  if (message == kActivate) { if (wp == 0) Show(); else Action("resume"); return 0; }
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
  if (message == WM_APP + 44) { Action("deviceDisconnected"); return 0; }
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
