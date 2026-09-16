#pragma once
#include <windows.h>
#include <flutter/encodable_value.h>
#include <winrt/Windows.Media.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <shobjidl.h>
#include <array>
#include <optional>
#include <string>

class MediaControls {
 public:
  explicit MediaControls(HWND window);
  ~MediaControls();
  void Update(const flutter::EncodableMap& payload);
  void Clear();
  std::optional<std::string> HandleMessage(UINT message, WPARAM wparam);
  flutter::EncodableMap HotkeyStatus() const;
 private:
  void UpdateThumbnailButtons();
  HWND window_;
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar_;
  bool thumbnail_added_ = false;
  std::array<bool, 4> hotkeys_{};
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> endpoints_;
  Microsoft::WRL::ComPtr<IMMNotificationClient> endpoint_listener_;
};
