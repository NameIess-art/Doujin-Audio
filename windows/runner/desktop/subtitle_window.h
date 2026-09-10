#pragma once
#include <windows.h>
#include <flutter/encodable_value.h>
#include <string>

class SubtitleWindow {
 public:
  explicit SubtitleWindow(HINSTANCE instance);
  ~SubtitleWindow();
  void Show(bool visible);
  void Update(const std::string& text);
  void Style(const flutter::EncodableMap& style);
 private:
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  HWND window_ = nullptr;
  std::wstring text_;
  std::wstring family_ = L"Segoe UI";
  double font_size_ = 22;
  double border_depth_ = 1;
  COLORREF text_color_ = RGB(255,255,255);
  COLORREF background_ = RGB(24,24,24);
  BYTE opacity_ = 230;
};
