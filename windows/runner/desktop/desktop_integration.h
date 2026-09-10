#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <set>

class SubtitleWindow;
class MediaControls;

class DesktopIntegration {
 public:
  DesktopIntegration(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopIntegration();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void Show();
  void ShowInitial();
  static constexpr UINT kActivate = WM_APP + 40;
  static constexpr UINT kMediaAction = WM_APP + 41;

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;
  void Action(const std::string& action);
  void AddTray();
  void SetFullscreen(bool enabled);
  void SavePlacement();
  void RefreshPower();
  HWND window_;
  bool ready_ = false;
  bool quitting_ = false;
  bool fullscreen_ = false;
  bool screen_on_ = false;
  int initial_show_command_ = SW_SHOWNORMAL;
  std::set<std::string> wake_locks_;
  WINDOWPLACEMENT placement_{sizeof(WINDOWPLACEMENT)};
  std::vector<std::string> pending_;
  std::unique_ptr<Channel> desktop_;
  std::vector<std::unique_ptr<Channel>> channels_;
  std::unique_ptr<SubtitleWindow> subtitles_;
  std::unique_ptr<MediaControls> media_;
};
