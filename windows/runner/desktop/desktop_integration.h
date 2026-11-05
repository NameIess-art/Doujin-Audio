#pragma once
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <array>
#include <memory>
#include <optional>
#include <string>
#include <vector>

class SubtitleWindow;
class MediaControls;
class ScheduledTasks;
class NetworkProxy;

class DesktopIntegration {
 public:
  DesktopIntegration(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopIntegration();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void AttachContent(HWND content);
  void Show();
  void ShowInitial();
  static constexpr UINT kActivate = WM_APP + 40;
  static constexpr UINT kMediaAction = WM_APP + 41;

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;
  void Action(const std::string& action);
  void AddTray();
  void ShowTrayMenu();
  void SetFullscreen(bool enabled);
  void RunWindowCommand(const std::string& command);
  void PublishWindowMaximized();
  LRESULT TopResizeHit(POINT screen) const;
  static LRESULT CALLBACK ContentProc(HWND content, UINT message, WPARAM wparam,
      LPARAM lparam, UINT_PTR id, DWORD_PTR data);
  void SavePlacement();
  void RefreshPower();
  void EndSession();
  void UpdateTheme();
  bool UsesDarkTheme() const;
  void OpenContainingFolder(const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void ReplyFolderOpens();
  struct FolderOpenState;
  std::shared_ptr<FolderOpenState> folder_opens_;
  HWND window_;
  HWND content_ = nullptr;
  bool ready_ = false;
  bool quitting_ = false;
  bool ending_session_ = false;
  bool fullscreen_ = false;
  std::optional<bool> window_maximized_;
  bool screen_on_ = false;
  bool playback_active_ = false;
  std::string theme_mode_ = "system";
  std::array<std::wstring, 5> tray_labels_ = {
      L"Open", L"Play / pause", L"Previous", L"Next", L"Exit"};
  struct TrayMenuAppearance;
  const TrayMenuAppearance* active_tray_menu_ = nullptr;
  EXECUTION_STATE power_flags_ = 0;
  int initial_show_command_ = SW_SHOWNORMAL;
  WINDOWPLACEMENT placement_{sizeof(WINDOWPLACEMENT)};
  std::vector<std::string> pending_;
  std::unique_ptr<Channel> desktop_;
  std::vector<std::unique_ptr<Channel>> channels_;
  std::unique_ptr<SubtitleWindow> subtitles_;
  std::unique_ptr<MediaControls> media_;
  std::unique_ptr<ScheduledTasks> scheduled_tasks_;
  std::unique_ptr<NetworkProxy> network_proxy_;
};
