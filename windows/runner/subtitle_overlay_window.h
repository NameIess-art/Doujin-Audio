#ifndef RUNNER_SUBTITLE_OVERLAY_WINDOW_H_
#define RUNNER_SUBTITLE_OVERLAY_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include <windows.h>

class SubtitleOverlayWindow {
 public:
  explicit SubtitleOverlayWindow(flutter::BinaryMessenger* messenger);
  ~SubtitleOverlayWindow();

 private:
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Show();
  void Hide();
  void Render();
  void UpdateStyle(const flutter::EncodableMap& arguments);

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::wstring text_;
  std::wstring font_family_;
  COLORREF text_color_ = RGB(255, 255, 255);
  COLORREF background_color_ = RGB(0, 0, 0);
  BYTE background_alpha_ = 51;
  double font_size_ = 16.0;
  double border_depth_ = 0.5;
  bool positioned_ = false;
};

#endif  // RUNNER_SUBTITLE_OVERLAY_WINDOW_H_
