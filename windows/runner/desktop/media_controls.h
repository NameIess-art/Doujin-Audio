#pragma once
#include <windows.h>
#include <flutter/encodable_value.h>
#include <winrt/Windows.Media.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

class MediaControls {
 public:
  explicit MediaControls(HWND window);
  ~MediaControls();
  void Update(const flutter::EncodableMap& payload);
  void Clear();
 private:
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> endpoints_;
  Microsoft::WRL::ComPtr<IMMNotificationClient> endpoint_listener_;
};
