#pragma once
#include <windows.h>
#include <flutter/encodable_value.h>
#include <string>
#include <vector>

class SubtitleWindow {
 public:
  explicit SubtitleWindow(HINSTANCE instance);
  ~SubtitleWindow();
  void Show(bool visible);
  void Update(const std::string& text);
  void Style(const flutter::EncodableMap& style);
 private:
  void FitText();
  bool EnsureFont(UINT dpi);
  bool EnsureSurface(HDC screen, int width, int rows);
  void ReleaseSurface();
  void Paint(HDC screen);
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  HWND window_ = nullptr;
  std::wstring text_;
  std::wstring family_ = L"Segoe UI";
  double font_size_ = 22;
  double border_depth_ = 1;
  COLORREF text_color_ = RGB(255,255,255);
  COLORREF background_ = RGB(24,24,24);
  BYTE opacity_ = 230;
  HDC output_dc_ = nullptr, mask_dc_ = nullptr;
  HBITMAP output_bitmap_ = nullptr, mask_bitmap_ = nullptr;
  HGDIOBJ previous_output_bitmap_ = nullptr, previous_mask_bitmap_ = nullptr;
  HFONT font_ = nullptr;
  int font_height_ = 0;
  std::wstring font_family_;
  DWORD *pixels_ = nullptr, *coverage_ = nullptr;
  int surface_width_ = 0, surface_rows_ = 0;
  UINT surface_dpi_ = 0;
  std::vector<DWORD> background_pixels_;
  bool background_dirty_ = true, content_dirty_ = true;
};
