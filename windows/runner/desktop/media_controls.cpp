#include "media_controls.h"
#include "desktop_integration.h"
#include <SystemMediaTransportControlsInterop.h>
#include <dwmapi.h>
#include <shlwapi.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <wrl/implements.h>
#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <iostream>
#include <mutex>
#include <utility>

using namespace winrt::Windows::Media;
namespace {
constexpr int kControlId = 0x4100;
constexpr UINT kAudioEndpointChanged = WM_APP + 44;
const UINT kTaskbarButtonCreated = RegisterWindowMessageW(L"TaskbarButtonCreated");
constexpr UINT kHotkeyKeys[] = {VK_SPACE, VK_LEFT, VK_RIGHT, VK_UP};
constexpr const char* kHotkeyActions[] = {"toggle", "previous", "next", "showWindow"};

// The notification gateway supplies opaque RGBA pixels at this size.
constexpr int kCoverWidth = 320;
constexpr int kCoverHeight = 240;

uint64_t HashBytes(const uint8_t* data, size_t size) {
  uint64_t hash = 14695981039346656037ULL;
  for (size_t i = 0; i < size; ++i) {
    hash ^= static_cast<uint64_t>(data[i]);
    hash *= 1099511628211ULL;
  }
  return hash;
}

BITMAPINFO ThumbnailBitmapInfo(int width, int height) {
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  return info;
}

bool TaskbarUsesDarkTheme() {
  DWORD light = 1;
  DWORD size = sizeof(light);
  return RegGetValueW(
             HKEY_CURRENT_USER,
             L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
             L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light,
             &size) == ERROR_SUCCESS &&
         light == 0;
}

HICON ButtonIcon(int button, bool playing, bool dark) {
  // A 32-bit alpha icon remains transparent on both light and dark taskbars.
  constexpr int size = 32;
  std::array<DWORD, size * size> pixels{};
  for (int y = 7; y < 25; ++y) {
    for (int x = 5; x < 27; ++x) {
      bool filled;
      if (button == 1 && playing) {
        filled = (x >= 9 && x < 14) || (x >= 18 && x < 23);
      } else {
        const int oriented = button == 0 ? 31 - x : x;
        filled = oriented >= 9 && oriented <= 23 - abs(y - 16) * 3 / 2;
        if (button != 1) filled = filled || (oriented >= 24 && oriented < 27);
      }
      if (filled) pixels[y * size + x] = dark ? 0xffffffff : 0xff000000;
    }
  }
  const auto color = CreateBitmap(size, size, 1, 32, pixels.data());
  std::array<BYTE, size * size / 8> mask_bits{};
  const auto mask = CreateBitmap(size, size, 1, 1, mask_bits.data());
  ICONINFO info{TRUE, 0, 0, mask, color};
  const auto icon = color && mask ? CreateIconIndirect(&info) : nullptr;
  if (color) DeleteObject(color);
  if (mask) DeleteObject(mask);
  return icon;
}

std::optional<std::wstring> LocalPathToFileUri(const std::string& utf8_path) {
  std::wstring path(winrt::to_hstring(utf8_path));
  if (path.empty()) return std::nullopt;
  // UrlCreateFromPathW does not strip extended-length prefixes (\\?\ or \\?\UNC\).
  if (path.size() >= 8 && _wcsnicmp(path.c_str(), L"\\\\?\\UNC\\", 8) == 0) {
    path = L"\\\\" + path.substr(8);
  } else if (path.size() >= 4 && path.compare(0, 4, L"\\\\?\\") == 0) {
    path = path.substr(4);
  }
  DWORD length = std::max<DWORD>(2084, static_cast<DWORD>(path.size() * 3 + 32));
  std::wstring uri(length, L'\0');
  HRESULT hr = UrlCreateFromPathW(path.c_str(), uri.data(), &length, 0);
  if (hr == E_POINTER && length > 0) {
    uri.resize(length);
    hr = UrlCreateFromPathW(path.c_str(), uri.data(), &length, 0);
  }
  if (FAILED(hr) || length == 0) return std::nullopt;
  uri.resize(length);
  return uri;
}
}  // namespace

class EndpointNotifications : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>, IMMNotificationClient> {
 public:
  EndpointNotifications(HWND window, const std::wstring& initial) : window_(window), current_(initial) {}
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR id,DWORD state) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (id && current_ == id && state != DEVICE_STATE_ACTIVE) {
      current_.clear();
      disconnected_ = true;
      PostMessage(window_, kAudioEndpointChanged, 0, 0);
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR id) override { return OnDeviceStateChanged(id,DEVICE_STATE_NOTPRESENT); }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR,const PROPERTYKEY) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow,ERole role,LPCWSTR id) override {
    if (flow == eRender && role == eMultimedia) {
      std::lock_guard<std::mutex> lock(mutex_);
      const std::wstring next = id ? id : L"";
      if (!current_.empty() && current_ != next) {
        // A default change can arrive ahead of the loss notification. Check the
        // old device on the window thread, keeping COM callbacks nonblocking.
        previous_defaults_.push_back(std::move(current_));
        PostMessage(window_, kAudioEndpointChanged, 0, 0);
      }
      current_ = next;
    }
    return S_OK;
  }

  bool TakeDisconnect(IMMDeviceEnumerator* enumerator) {
    std::vector<std::wstring> previous_defaults;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      previous_defaults.swap(previous_defaults_);
      if (std::exchange(disconnected_, false)) return true;
    }
    for (const auto& id : previous_defaults) {
      Microsoft::WRL::ComPtr<IMMDevice> device;
      const auto result = enumerator->GetDevice(id.c_str(), &device);
      if (result == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) return true;
      DWORD state = 0;
      if (SUCCEEDED(result) && SUCCEEDED(device->GetState(&state)) &&
          state != DEVICE_STATE_ACTIVE) return true;
    }
    return false;
  }

 private:
  HWND window_;
  std::wstring current_;
  std::mutex mutex_;
  std::vector<std::wstring> previous_defaults_;
  bool disconnected_ = false;
};

namespace {
const flutter::EncodableValue* Find(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key)); return it == map.end() ? nullptr : &it->second;
}
std::string Text(const flutter::EncodableMap& map, const char* key) {
  auto v = Find(map, key); auto s = v ? std::get_if<std::string>(v) : nullptr; return s ? *s : "";
}
bool Flag(const flutter::EncodableMap& map, const char* key) {
  auto v = Find(map,key); auto b = v ? std::get_if<bool>(v) : nullptr; return b && *b;
}
}
MediaControls::MediaControls(HWND window) : window_(window) {}
void MediaControls::EnsureHotkeysRegistered() {
  if (hotkeys_registered_) return;
  hotkeys_registered_ = true;
  for (int i = 0; i < 4; ++i) {
    hotkeys_[i] = RegisterHotKey(window_, kControlId + i,
        MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, kHotkeyKeys[i]) != FALSE;
  }
}
void MediaControls::Initialize() {
  if (initialized_) return;
  initialized_ = true;
  try {
    auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(window_, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(controls_)));
    controls_.IsEnabled(false);
    controls_.IsPlayEnabled(true); controls_.IsPauseEnabled(true);
    const HWND window = window_;
    button_token_ = controls_.ButtonPressed([window](auto const&, auto const& args) {
      PostMessage(window, DesktopIntegration::kMediaAction, static_cast<WPARAM>(args.Button()), 0);
    });
  } catch (const winrt::hresult_error& e) {
    controls_ = nullptr;
    const auto message = "DoujinAudio: SMTC unavailable: " + winrt::to_string(e.message()) + "\n";
    OutputDebugStringA(message.c_str());
    std::cerr << message;
  }
  try {
    winrt::check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&endpoints_)));
    Microsoft::WRL::ComPtr<IMMDevice> device;
    std::wstring id;
    if (SUCCEEDED(endpoints_->GetDefaultAudioEndpoint(eRender,eMultimedia,&device))) {
      LPWSTR text = nullptr;
      if (SUCCEEDED(device->GetId(&text))) { id = text; CoTaskMemFree(text); }
    }
    auto listener = Microsoft::WRL::Make<EndpointNotifications>(window_,id);
    winrt::check_hresult(endpoints_->RegisterEndpointNotificationCallback(listener.Get()));
    endpoint_listener_ = std::move(listener);
  } catch (const winrt::hresult_error& e) {
    endpoints_.Reset();
    endpoint_listener_.Reset();
    const auto message = "DoujinAudio: audio endpoint notifications unavailable: " + winrt::to_string(e.message()) + "\n";
    OutputDebugStringA(message.c_str());
    std::cerr << message;
  }
  EnsureHotkeysRegistered();
  if (pending_update_) {
    auto payload = std::move(*pending_update_);
    pending_update_.reset();
    Update(payload);
  }
}
MediaControls::~MediaControls() {
  for (int i = 0; i < 4; ++i) {
    if (hotkeys_[i]) UnregisterHotKey(window_, kControlId + i);
  }
  if (endpoints_ && endpoint_listener_) endpoints_->UnregisterEndpointNotificationCallback(endpoint_listener_.Get());
  if (controls_) {
    try {
      controls_.ButtonPressed(button_token_);
      controls_.IsEnabled(false);
    } catch (const winrt::hresult_error&) {}
  }
}
void MediaControls::Clear() {
  if (!initialized_) {
    pending_update_.reset();
    return;
  }
  SetThumbnailCover(nullptr);
  if (!active_ && !metadata_ready_ && (!controls_ || !smtc_enabled_)) return;
  active_ = false;
  has_next_ = false;
  has_previous_ = false;
  if (controls_) {
    try {
      if (smtc_enabled_) {
        controls_.IsEnabled(false);
        smtc_enabled_ = false;
      }
      controls_.DisplayUpdater().ClearAll();
    } catch (const winrt::hresult_error&) {
      smtc_enabled_ = false;
      smtc_next_enabled_.reset();
      smtc_previous_enabled_.reset();
      smtc_status_.reset();
    }
  }
  metadata_ready_ = false;
  title_.clear(); subtitle_.clear(); art_path_.clear();
  thumbnail_playing_ = false;
  UpdateThumbnailButtons();
}
flutter::EncodableMap MediaControls::HotkeyStatus() {
  EnsureHotkeysRegistered();
  flutter::EncodableMap status;
  for (int i = 0; i < 4; ++i) {
    status.emplace(flutter::EncodableValue(kHotkeyActions[i]), flutter::EncodableValue(hotkeys_[i]));
  }
  return status;
}
std::optional<std::string> MediaControls::HandleMessage(UINT message, WPARAM wp,
                                                        LPARAM lp) {
  if (message == kAudioEndpointChanged) {
    if (endpoint_listener_ && endpoints_ && endpoint_listener_->TakeDisconnect(endpoints_.Get())) {
      return "deviceDisconnected";
    }
    return std::string();
  }
  if (message == kTaskbarButtonCreated) {
    // Explorer creates a new toolbar after restart or restoring from the tray.
    thumbnail_added_ = false;
    taskbar_dark_ = TaskbarUsesDarkTheme();
    taskbar_.Reset();
    if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_)))) {
      if (FAILED(taskbar_->HrInit())) taskbar_.Reset();
    }
    UpdateThumbnailButtons();
    return std::string();
  }
  if (message == WM_THEMECHANGED ||
      (message == WM_SETTINGCHANGE &&
       lp != 0 &&
       _wcsicmp(reinterpret_cast<const wchar_t*>(lp), L"ImmersiveColorSet") == 0)) {
    const bool dark = TaskbarUsesDarkTheme();
    if (dark != taskbar_dark_) {
      taskbar_dark_ = dark;
      UpdateThumbnailButtons();
    }
  }
  if (message == WM_DWMSENDICONICTHUMBNAIL && !thumbnail_cover_.empty()) {
    SupplyThumbnail(HIWORD(lp), LOWORD(lp));
    return std::string();
  }
  int action = -1;
  if (message == WM_HOTKEY && wp >= kControlId && wp < kControlId + 4) {
    action = static_cast<int>(wp) - kControlId;
    if (!hotkeys_[action]) return std::string();
    // The application decides whether a restored or non-notified session can act.
    return kHotkeyActions[action];
  } else if (message == WM_COMMAND && HIWORD(wp) == THBN_CLICKED &&
      LOWORD(wp) >= kControlId && LOWORD(wp) < kControlId + 3) {
    action = LOWORD(wp) - kControlId;
    if (action == 0 && active_) return "taskbarToggle";
  }
  if (action < 0) return std::nullopt;
  if (!active_ ||
      (action == 1 && !has_previous_) ||
      (action == 2 && !has_next_)) return std::string();
  return kHotkeyActions[action];
}
void MediaControls::UpdateThumbnailButtons() {
  if (!taskbar_) return;
  const bool enabled = active_;
  const bool playing = enabled && thumbnail_playing_;
  const bool available[] = {enabled && has_previous_, enabled,
      enabled && has_next_};
  const std::array<bool, 5> next_state{
      playing, available[0], available[1], available[2], taskbar_dark_};
  if (thumbnail_added_ && thumbnail_state_ == next_state) return;
  const wchar_t* tips[] = {L"Previous / 上一曲", playing ? L"Pause / 暂停" : L"Play / 播放", L"Next / 下一曲"};
  const UINT ids[] = {kControlId + 1, kControlId, kControlId + 2};
  THUMBBUTTON buttons[3]{};
  for (int i = 0; i < 3; ++i) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    buttons[i].hIcon = ButtonIcon(i, playing, taskbar_dark_);
    wcscpy_s(buttons[i].szTip, tips[i]);
    // Keep the requested glyph color even when there is no adjacent track.
    buttons[i].dwFlags = available[i] ? THBF_ENABLED : THBF_NONINTERACTIVE;
  }
  const auto result = thumbnail_added_
      ? taskbar_->ThumbBarUpdateButtons(window_, 3, buttons)
      : taskbar_->ThumbBarAddButtons(window_, 3, buttons);
  if (SUCCEEDED(result)) { thumbnail_added_ = true; thumbnail_state_ = next_state; }
  for (const auto& button : buttons) if (button.hIcon) DestroyIcon(button.hIcon);
}

void MediaControls::SetThumbnailCover(const flutter::EncodableValue* cover) {
  const bool had_cover = !thumbnail_cover_.empty();
  const auto bytes = cover ? std::get_if<std::vector<uint8_t>>(cover) : nullptr;
  if (bytes && bytes->size() == kCoverWidth * kCoverHeight * 4) {
    const uint64_t hash = HashBytes(bytes->data(), bytes->size());
    if (had_cover && thumbnail_cover_hash_ == hash) return;
    thumbnail_cover_.resize(kCoverWidth * kCoverHeight);
    for (size_t i = 0; i < thumbnail_cover_.size(); ++i) {
      const auto pixel = bytes->data() + 4 * i;
      thumbnail_cover_[i] = 0xff000000 | (DWORD{pixel[0]} << 16) |
                            (DWORD{pixel[1]} << 8) | DWORD{pixel[2]};
    }
    thumbnail_cover_hash_ = hash;
  } else {
    thumbnail_cover_hash_.reset();
    if (!had_cover) return;
    thumbnail_cover_.clear();
  }
  const BOOL has_cover = !thumbnail_cover_.empty();
  if (had_cover != (has_cover != FALSE)) {
    DwmSetWindowAttribute(window_, DWMWA_HAS_ICONIC_BITMAP, &has_cover,
                          sizeof(has_cover));
    DwmSetWindowAttribute(window_, DWMWA_FORCE_ICONIC_REPRESENTATION, &has_cover,
                          sizeof(has_cover));
  }
  if (had_cover || has_cover) DwmInvalidateIconicBitmaps(window_);
}

void MediaControls::SupplyThumbnail(int max_width, int max_height) {
  const int scale = std::min({max_width / 4, max_height / 3, kCoverWidth / 4});
  if (scale < 1) return;
  const int width = scale * 4;
  const int height = scale * 3;
  const auto info = ThumbnailBitmapInfo(width, height);
  const auto source = ThumbnailBitmapInfo(kCoverWidth, kCoverHeight);
  const auto dc = CreateCompatibleDC(nullptr);
  if (!dc) return;
  void* pixels = nullptr;
  const auto bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels,
                                       nullptr, 0);
  if (bitmap) {
    const auto previous = SelectObject(dc, bitmap);
    if (previous && previous != HGDI_ERROR) {
      SetStretchBltMode(dc, HALFTONE);
      SetBrushOrgEx(dc, 0, 0, nullptr);
      const int lines = StretchDIBits(
          dc, 0, 0, width, height, 0, 0, kCoverWidth, kCoverHeight,
          thumbnail_cover_.data(), &source, DIB_RGB_COLORS, SRCCOPY);
      SelectObject(dc, previous);
      if (lines > 0) {
        GdiFlush();
        auto colors = static_cast<DWORD*>(pixels);
        // GDI scaling can clear the high byte. DWM expects opaque pixels.
        for (int i = 0; i < width * height; ++i) colors[i] |= 0xff000000;
        DwmSetIconicThumbnail(window_, bitmap, 0);
      }
    }
    DeleteObject(bitmap);
  }
  DeleteDC(dc);
}

void MediaControls::Update(const flutter::EncodableMap& payload) {
  if (!initialized_) {
    pending_update_ = payload;
    return;
  }
  auto raw = Find(payload,"items");
  auto items = raw ? std::get_if<flutter::EncodableList>(raw) : nullptr;
  if (!items || items->empty()) { Clear(); return; }
  const flutter::EncodableMap* selected = nullptr;
  const auto main_id = Text(payload,"mainSessionId");
  for (const auto& item : *items) {
    auto map = std::get_if<flutter::EncodableMap>(&item);
    if (!map) continue;
    if (!selected || Text(*map,"id") == main_id) selected = map;
    if (Text(*map,"id") == main_id) break;
  }
  if (!selected) { Clear(); return; }
  if (const auto cover = Find(payload, "taskbarCover")) SetThumbnailCover(cover);
  thumbnail_playing_ = false;
  for (const auto& item : *items) {
    const auto map = std::get_if<flutter::EncodableMap>(&item);
    if (map && Flag(*map,"playing")) {
      thumbnail_playing_ = true;
      break;
    }
  }
  active_ = true;
  has_next_ = Flag(*selected,"hasNext");
  has_previous_ = Flag(*selected,"hasPrevious");
  UpdateThumbnailButtons();
  if (!controls_) return;
  try {
    if (!smtc_enabled_) {
      controls_.IsEnabled(true);
      smtc_enabled_ = true;
    }
    if (smtc_next_enabled_ != has_next_) {
      controls_.IsNextEnabled(has_next_);
      smtc_next_enabled_ = has_next_;
    }
    if (smtc_previous_enabled_ != has_previous_) {
      controls_.IsPreviousEnabled(has_previous_);
      smtc_previous_enabled_ = has_previous_;
    }
    const auto status = Flag(*selected,"playing") ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused;
    if (smtc_status_ != status) {
      controls_.PlaybackStatus(status);
      smtc_status_ = status;
    }
    const auto title = Text(*selected,"title");
    const auto subtitle = Text(*selected,"subtitle");
    const auto art = Text(*selected,"artPath");
    if (metadata_ready_ && title_ == title && subtitle_ == subtitle && art_path_ == art) return;
    auto updater = controls_.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    if (!metadata_ready_ || title_ != title) updater.MusicProperties().Title(winrt::to_hstring(title));
    if (!metadata_ready_ || subtitle_ != subtitle) updater.MusicProperties().Artist(winrt::to_hstring(subtitle));
    if (!metadata_ready_ || art_path_ != art) {
      if (!art.empty()) {
        try {
          if (const auto uri = LocalPathToFileUri(art)) {
            updater.Thumbnail(
                winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(
                    winrt::Windows::Foundation::Uri(*uri)));
          } else {
            updater.Thumbnail(nullptr);
          }
        } catch (const winrt::hresult_error&) {
          updater.Thumbnail(nullptr);
        }
      } else {
        updater.Thumbnail(nullptr);
      }
    }
    updater.Update();
    title_ = title; subtitle_ = subtitle; art_path_ = art; metadata_ready_ = true;
  } catch (const winrt::hresult_error&) {}
}
