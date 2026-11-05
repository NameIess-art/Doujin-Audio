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
#include <vector>

class MediaControls {
 public:
  explicit MediaControls(HWND window);
  ~MediaControls();
  void Update(const flutter::EncodableMap& payload);
  void Clear();
  std::optional<std::string> HandleMessage(UINT message, WPARAM wparam,
                                           LPARAM lparam);
  flutter::EncodableMap HotkeyStatus() const;
 private:
  void UpdateThumbnailButtons();
  void SetThumbnailCover(const flutter::EncodableValue* cover);
  void SupplyThumbnail(int max_width, int max_height);
  HWND window_;
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar_;
  bool thumbnail_added_ = false;
  bool thumbnail_playing_ = false;
  std::optional<std::array<bool, 5>> thumbnail_state_;
  bool taskbar_dark_ = false;
  std::vector<DWORD> thumbnail_cover_;
  bool metadata_ready_ = false;
  std::string title_, subtitle_, art_path_;
  std::array<bool, 4> hotkeys_{};
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> endpoints_;
  Microsoft::WRL::ComPtr<IMMNotificationClient> endpoint_listener_;
};
