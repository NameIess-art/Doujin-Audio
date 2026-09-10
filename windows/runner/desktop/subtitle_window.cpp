#include "subtitle_window.h"
#include <algorithm>
#include <cmath>
#include <winrt/base.h>

namespace {
COLORREF ParseColor(const std::string& value, COLORREF previous) {
  try {
    const auto hex = value.empty() || value[0] != '#' ? value : value.substr(1);
    const auto rgb = std::stoul(hex, nullptr, 16);
    return RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
  } catch (...) { return previous; }
}
}

SubtitleWindow::SubtitleWindow(HINSTANCE instance) {
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = instance;
  wc.lpszClassName = L"DoujinAudioSubtitle";
  wc.hCursor = LoadCursor(nullptr, IDC_SIZEALL);
  RegisterClassW(&wc);
  RECT area{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &area, 0);
  window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
      wc.lpszClassName, L"Doujin Audio subtitles", WS_POPUP,
      area.left + 80, area.bottom - 180, std::min<LONG>(800, area.right-area.left-100),
      110, nullptr, nullptr, instance, this);
}
SubtitleWindow::~SubtitleWindow() { if (window_) DestroyWindow(window_); }
void SubtitleWindow::Show(bool visible) {
  ShowWindow(window_, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
  if (visible) { InvalidateRect(window_,nullptr,FALSE); UpdateWindow(window_); }
}
void SubtitleWindow::Update(const std::string& text) {
  text_ = winrt::to_hstring(text);
  InvalidateRect(window_, nullptr, TRUE);
}
void SubtitleWindow::Style(const flutter::EncodableMap& style) {
  for (const auto& [key, value] : style) {
    const auto name = std::get_if<std::string>(&key);
    if (!name) continue;
    if (*name == "fontSize") {
      if (const auto number = std::get_if<double>(&value)) font_size_ = std::clamp(*number, 10.0, 100.0);
    } else if (*name == "backgroundOpacity") {
      if (const auto number = std::get_if<double>(&value)) opacity_ = static_cast<BYTE>(std::clamp(*number, 0.0, 1.0)*255);
    } else if (*name == "borderDepth") {
      if (const auto number = std::get_if<double>(&value)) border_depth_ = std::clamp(*number, 0.0, 8.0);
    } else if (const auto text = std::get_if<std::string>(&value)) {
      if (*name == "fontFamily") family_ = winrt::to_hstring(*text);
      if (*name == "textColor") text_color_ = ParseColor(*text, text_color_);
      if (*name == "backgroundColor") background_ = ParseColor(*text, background_);
    }
  }
  InvalidateRect(window_, nullptr, TRUE);
}
LRESULT CALLBACK SubtitleWindow::WndProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  auto self = reinterpret_cast<SubtitleWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<SubtitleWindow*>(reinterpret_cast<CREATESTRUCT*>(lp)->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wp, lp);
  if (message == WM_NCHITTEST) {
    RECT rect; GetWindowRect(hwnd,&rect);
    const int x = static_cast<short>(LOWORD(lp)), y = static_cast<short>(HIWORD(lp));
    const bool left = x < rect.left+8, right = x >= rect.right-8;
    const bool top = y < rect.top+8, bottom = y >= rect.bottom-8;
    if (top) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
    if (bottom) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
    return left ? HTLEFT : right ? HTRIGHT : HTCAPTION;
  }
  if (message == WM_GETMINMAXINFO) {
    reinterpret_cast<MINMAXINFO*>(lp)->ptMinTrackSize = {160,50}; return 0;
  }
  if (message == WM_SIZE) {
    InvalidateRect(hwnd,nullptr,FALSE);
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC screen = BeginPaint(hwnd, &ps);
    RECT rect; GetClientRect(hwnd, &rect);
    const int width = rect.right, rows = rect.bottom;
    if (width <= 0 || rows <= 0) { EndPaint(hwnd,&ps); return 0; }
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -rows;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    DWORD *pixels = nullptr, *coverage = nullptr;
    HDC output = CreateCompatibleDC(screen), dc = CreateCompatibleDC(screen);
    auto bitmap = CreateDIBSection(screen,&info,DIB_RGB_COLORS,reinterpret_cast<void**>(&pixels),nullptr,0);
    auto mask = CreateDIBSection(screen,&info,DIB_RGB_COLORS,reinterpret_cast<void**>(&coverage),nullptr,0);
    if (!bitmap || !mask || !output || !dc) {
      if (bitmap) DeleteObject(bitmap); if (mask) DeleteObject(mask);
      if (output) DeleteDC(output); if (dc) DeleteDC(dc);
      EndPaint(hwnd,&ps); return 0;
    }
    auto old_bitmap = SelectObject(output,bitmap), old_mask = SelectObject(dc,mask);
    const DWORD alpha = self->opacity_;
    const DWORD background = (alpha<<24) | ((GetRValue(self->background_)*alpha/255)<<16)
        | ((GetGValue(self->background_)*alpha/255)<<8) | (GetBValue(self->background_)*alpha/255);
    std::fill(pixels,pixels+width*rows,background);
    std::fill(coverage,coverage+width*rows,0);
    // A separate grayscale mask preserves text opacity on a translucent background.
    auto composite = [&](COLORREF color) {
      GdiFlush();
      for (int i=0; i<width*rows; ++i) {
        const DWORD a = coverage[i]&255, inverse = 255-a, destination = pixels[i];
        pixels[i] = ((a+((destination>>24)*inverse/255))<<24)
          | (((GetRValue(color)*a+((destination>>16)&255)*inverse)/255)<<16)
          | (((GetGValue(color)*a+((destination>>8)&255)*inverse)/255)<<8)
          | ((GetBValue(color)*a+(destination&255)*inverse)/255);
      }
    };
    const int height = static_cast<int>(self->font_size_ * GetDpiForWindow(hwnd) / 96.0);
    auto font = CreateFontW(-height, 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
        DEFAULT_PITCH, self->family_.c_str());
    auto previous = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    InflateRect(&rect, -12, -8);
    const auto flags = DT_CENTER | DT_WORDBREAK | DT_NOPREFIX;
    SetTextColor(dc, RGB(255,255,255));
    const int border = static_cast<int>(std::round(self->border_depth_));
    for (int x = -border; x <= border; ++x) for (int y = -border; y <= border; ++y) {
      if (x == 0 && y == 0) continue;
      auto outline = rect; OffsetRect(&outline, x, y);
      DrawTextW(dc, self->text_.c_str(), -1, &outline, flags);
    }
    composite(RGB(0,0,0));
    std::fill(coverage,coverage+width*rows,0);
    DrawTextW(dc, self->text_.c_str(), -1, &rect, flags);
    composite(self->text_color_);
    SelectObject(dc, previous); DeleteObject(font);
    RECT bounds; GetWindowRect(hwnd,&bounds);
    POINT position{bounds.left,bounds.top}, source{}; SIZE size{width,rows};
    BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd,screen,&position,&size,output,&source,0,&blend,ULW_ALPHA);
    SelectObject(output,old_bitmap); SelectObject(dc,old_mask);
    DeleteObject(bitmap); DeleteObject(mask); DeleteDC(output); DeleteDC(dc);
    EndPaint(hwnd, &ps); return 0;
  }
  return DefWindowProc(hwnd, message, wp, lp);
}
