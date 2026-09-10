#include "media_controls.h"
#include "desktop_integration.h"
#include <SystemMediaTransportControlsInterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <wrl/implements.h>
#include <mutex>

using namespace winrt::Windows::Media;
namespace {
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
MediaControls::MediaControls(HWND window) {
  auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
  winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(controls_)));
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
}
MediaControls::~MediaControls() {
  if (endpoints_ && endpoint_listener_) endpoints_->UnregisterEndpointNotificationCallback(endpoint_listener_.Get());
  if (controls_) { controls_.ButtonPressed(button_token_); controls_.IsEnabled(false); }
}
void MediaControls::Clear() { controls_.IsEnabled(false); controls_.DisplayUpdater().ClearAll(); }
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
