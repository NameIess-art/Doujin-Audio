#include "media_controls.h"
#include "desktop_integration.h"
#include <SystemMediaTransportControlsInterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <wrl/implements.h>
#include <mutex>

using namespace winrt::Windows::Media;
namespace {
constexpr int kControlId = 0x4100;
const UINT kTaskbarButtonCreated = RegisterWindowMessageW(L"TaskbarButtonCreated");
constexpr UINT kHotkeyKeys[] = {VK_SPACE, VK_LEFT, VK_RIGHT, VK_UP};
constexpr const char* kHotkeyActions[] = {"toggle", "previous", "next", "showWindow"};

HICON ButtonIcon(int button, bool playing) {
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
      if (filled) pixels[y * size + x] = 0xff777777;
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
class EndpointNotifications : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>, IMMNotificationClient> {
 public:
  EndpointNotifications(HWND window, const std::wstring& initial) : window_(window), current_(initial) {}
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR id,DWORD state) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (id && current_ == id && state != DEVICE_STATE_ACTIVE) PostMessage(window_,WM_APP+44,0,0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR id) override { return OnDeviceStateChanged(id,DEVICE_STATE_NOTPRESENT); }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR,const PROPERTYKEY) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow,ERole role,LPCWSTR id) override {
    if (flow == eRender && role == eMultimedia) {
      std::lock_guard<std::mutex> lock(mutex_);
      const std::wstring next = id ? id : L"";
      if (!current_.empty() && current_ != next) PostMessage(window_,WM_APP+44,0,0);
      current_ = next;
    }
    return S_OK;
  }
 private:
  HWND window_; std::wstring current_; std::mutex mutex_;
};
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
MediaControls::MediaControls(HWND window) : window_(window) {
  auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
  winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(controls_)));
  controls_.IsEnabled(false);
  controls_.IsPlayEnabled(true); controls_.IsPauseEnabled(true);
  button_token_ = controls_.ButtonPressed([window](auto const&, auto const& args) {
    PostMessage(window, DesktopIntegration::kMediaAction, static_cast<WPARAM>(args.Button()), 0);
  });
  winrt::check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_ALL,IID_PPV_ARGS(&endpoints_)));
  Microsoft::WRL::ComPtr<IMMDevice> device;
  std::wstring id;
  if (SUCCEEDED(endpoints_->GetDefaultAudioEndpoint(eRender,eMultimedia,&device))) {
    LPWSTR text = nullptr;
    if (SUCCEEDED(device->GetId(&text))) { id = text; CoTaskMemFree(text); }
  }
  endpoint_listener_ = Microsoft::WRL::Make<EndpointNotifications>(window,id);
  winrt::check_hresult(endpoints_->RegisterEndpointNotificationCallback(endpoint_listener_.Get()));
  for (int i = 0; i < 4; ++i) {
    hotkeys_[i] = RegisterHotKey(window_, kControlId + i,
        MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, kHotkeyKeys[i]) != FALSE;
  }
}
MediaControls::~MediaControls() {
  for (int i = 0; i < 4; ++i) {
    if (hotkeys_[i]) UnregisterHotKey(window_, kControlId + i);
  }
  if (endpoints_ && endpoint_listener_) endpoints_->UnregisterEndpointNotificationCallback(endpoint_listener_.Get());
  if (controls_) { controls_.ButtonPressed(button_token_); controls_.IsEnabled(false); }
}
void MediaControls::Clear() {
  controls_.IsEnabled(false);
  controls_.DisplayUpdater().ClearAll();
  UpdateThumbnailButtons();
}
flutter::EncodableMap MediaControls::HotkeyStatus() const {
  flutter::EncodableMap status;
  for (int i = 0; i < 4; ++i) {
    status.emplace(flutter::EncodableValue(kHotkeyActions[i]), flutter::EncodableValue(hotkeys_[i]));
  }
  return status;
}
std::optional<std::string> MediaControls::HandleMessage(UINT message, WPARAM wp) {
  if (message == kTaskbarButtonCreated) {
    // Explorer creates a new toolbar after restart or restoring from the tray.
    thumbnail_added_ = false;
    taskbar_.Reset();
    if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_)))) {
      if (FAILED(taskbar_->HrInit())) taskbar_.Reset();
    }
    UpdateThumbnailButtons();
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
  }
  if (action < 0) return std::nullopt;
  if (!controls_.IsEnabled() ||
      (action == 1 && !controls_.IsPreviousEnabled()) ||
      (action == 2 && !controls_.IsNextEnabled())) return std::string();
  return kHotkeyActions[action];
}
void MediaControls::UpdateThumbnailButtons() {
  if (!taskbar_) return;
  const bool enabled = controls_.IsEnabled();
  const bool playing = enabled && controls_.PlaybackStatus() == MediaPlaybackStatus::Playing;
  const bool available[] = {enabled && controls_.IsPreviousEnabled(), enabled,
      enabled && controls_.IsNextEnabled()};
  const wchar_t* tips[] = {L"Previous / 上一曲", playing ? L"Pause / 暂停" : L"Play / 播放", L"Next / 下一曲"};
  const UINT ids[] = {kControlId + 1, kControlId, kControlId + 2};
  THUMBBUTTON buttons[3]{};
  for (int i = 0; i < 3; ++i) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    buttons[i].hIcon = ButtonIcon(i, playing);
    wcscpy_s(buttons[i].szTip, tips[i]);
    buttons[i].dwFlags = available[i] ? THBF_ENABLED : THBF_DISABLED;
  }
  const auto result = thumbnail_added_
      ? taskbar_->ThumbBarUpdateButtons(window_, 3, buttons)
      : taskbar_->ThumbBarAddButtons(window_, 3, buttons);
  if (SUCCEEDED(result)) thumbnail_added_ = true;
  for (const auto& button : buttons) if (button.hIcon) DestroyIcon(button.hIcon);
}
void MediaControls::Update(const flutter::EncodableMap& payload) {
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
  controls_.IsEnabled(true);
  controls_.IsNextEnabled(Flag(*selected,"hasNext"));
  controls_.IsPreviousEnabled(Flag(*selected,"hasPrevious"));
  controls_.PlaybackStatus(Flag(*selected,"playing") ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
  UpdateThumbnailButtons();
  auto updater = controls_.DisplayUpdater();
  updater.Type(MediaPlaybackType::Music);
  updater.MusicProperties().Title(winrt::to_hstring(Text(*selected,"title")));
  updater.MusicProperties().Artist(winrt::to_hstring(Text(*selected,"subtitle")));
  const auto art = Text(*selected,"artPath");
  if (!art.empty()) {
    try {
      std::wstring uri = L"file:///" + std::wstring(winrt::to_hstring(art));
      for (auto& c : uri) if (c == L'\\') c = L'/';
      updater.Thumbnail(winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(
          winrt::Windows::Foundation::Uri(uri)));
    } catch (const winrt::hresult_error&) { updater.Thumbnail(nullptr); }
  } else { updater.Thumbnail(nullptr); }
  updater.Update();
}
