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
SubtitleWindow::~SubtitleWindow() {
  if (window_) DestroyWindow(window_);
  ReleaseSurface();
  if (font_) DeleteObject(font_);
}
void SubtitleWindow::Show(bool visible) {
  ShowWindow(window_, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
  if (visible) { InvalidateRect(window_,nullptr,FALSE); UpdateWindow(window_); }
}
void SubtitleWindow::Update(const std::string& text) {
  const std::wstring next(winrt::to_hstring(text));
  if (text_ == next) return;
  text_ = next;
  content_dirty_ = true;
  FitText();
  InvalidateRect(window_, nullptr, TRUE);
}
void SubtitleWindow::Style(const flutter::EncodableMap& style) {
  const auto old_family = family_;
  const auto old_size = font_size_, old_border = border_depth_;
  const auto old_text = text_color_, old_background = background_;
  const auto old_opacity = opacity_;
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
  const bool layout_changed = old_family != family_ || old_size != font_size_
      || old_border != border_depth_;
  const bool background_changed = old_size != font_size_ || old_border != border_depth_
      || old_background != background_ || old_opacity != opacity_;
  if (!layout_changed && !background_changed && old_text == text_color_) return;
  background_dirty_ = background_dirty_ || background_changed;
  content_dirty_ = true;
  if (layout_changed) FitText();
  InvalidateRect(window_, nullptr, TRUE);
}
void SubtitleWindow::FitText() {
  if (!window_) return;
  RECT bounds{}; GetWindowRect(window_, &bounds);
  const double scale = GetDpiForWindow(window_) / 96.0;
  const int padding = static_cast<int>((20 + border_depth_ * 4) * scale);
  if (!EnsureFont(GetDpiForWindow(window_))) return;
  HDC dc = GetDC(window_);
  if (!dc) return;
  auto previous = SelectObject(dc, font_);
  RECT text{0, 0, std::max(1L, bounds.right - bounds.left - 2 * padding), 0};
  DrawTextW(dc, text_.empty() ? L" " : text_.c_str(), -1, &text,
      DT_CENTER | DT_WORDBREAK | DT_NOPREFIX | DT_CALCRECT);
  SelectObject(dc, previous); ReleaseDC(window_, dc);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor);
  const auto& area = monitor.rcWork;
  const int height = std::min<LONG>(area.bottom - area.top,
      std::max<LONG>(static_cast<LONG>(50 * scale),
          text.bottom + static_cast<LONG>((20 + border_depth_ * 8) * scale)));
  const int top = std::clamp<LONG>(bounds.top, area.top, area.bottom - height);
  if (height != bounds.bottom - bounds.top || top != bounds.top) {
    SetWindowPos(window_, nullptr, bounds.left, top, bounds.right - bounds.left,
        height, SWP_NOACTIVATE | SWP_NOZORDER);
  }
}
bool SubtitleWindow::EnsureFont(UINT dpi) {
  const int height = static_cast<int>(font_size_ * dpi / 96.0);
  if (font_ && height == font_height_ && family_ == font_family_) return true;
  auto font = CreateFontW(-height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
      DEFAULT_PITCH, family_.empty() ? L"Segoe UI" : family_.c_str());
  if (!font) return false;
  if (font_) DeleteObject(font_);
  font_ = font;
  font_height_ = height;
  font_family_ = family_;
  content_dirty_ = true;
  return true;
}
void SubtitleWindow::ReleaseSurface() {
  if (previous_output_bitmap_) SelectObject(output_dc_, previous_output_bitmap_);
  if (previous_mask_bitmap_) SelectObject(mask_dc_, previous_mask_bitmap_);
  if (output_bitmap_) DeleteObject(output_bitmap_);
  if (mask_bitmap_) DeleteObject(mask_bitmap_);
  if (output_dc_) DeleteDC(output_dc_);
  if (mask_dc_) DeleteDC(mask_dc_);
  output_dc_ = mask_dc_ = nullptr;
  output_bitmap_ = mask_bitmap_ = nullptr;
  previous_output_bitmap_ = previous_mask_bitmap_ = nullptr;
  pixels_ = coverage_ = nullptr;
  surface_width_ = surface_rows_ = 0;
}
bool SubtitleWindow::EnsureSurface(HDC screen, int width, int rows) {
  if (surface_width_ == width && surface_rows_ == rows) return true;
  ReleaseSurface();
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -rows;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  output_dc_ = CreateCompatibleDC(screen);
  mask_dc_ = CreateCompatibleDC(screen);
  output_bitmap_ = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
      reinterpret_cast<void**>(&pixels_), nullptr, 0);
  mask_bitmap_ = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
      reinterpret_cast<void**>(&coverage_), nullptr, 0);
  if (!output_dc_ || !mask_dc_ || !output_bitmap_ || !mask_bitmap_) {
    ReleaseSurface();
    return false;
  }
  previous_output_bitmap_ = SelectObject(output_dc_, output_bitmap_);
  previous_mask_bitmap_ = SelectObject(mask_dc_, mask_bitmap_);
  if (!previous_output_bitmap_ || previous_output_bitmap_ == HGDI_ERROR
      || !previous_mask_bitmap_ || previous_mask_bitmap_ == HGDI_ERROR) {
    if (previous_output_bitmap_ == HGDI_ERROR) previous_output_bitmap_ = nullptr;
    if (previous_mask_bitmap_ == HGDI_ERROR) previous_mask_bitmap_ = nullptr;
    ReleaseSurface();
    return false;
  }
  surface_width_ = width;
  surface_rows_ = rows;
  background_pixels_.resize(static_cast<size_t>(width) * rows);
  background_dirty_ = content_dirty_ = true;
  return true;
}
void SubtitleWindow::Paint(HDC screen) {
  RECT rect; GetClientRect(window_, &rect);
  const int width = rect.right, rows = rect.bottom;
  const UINT dpi = GetDpiForWindow(window_);
  if (width <= 0 || rows <= 0 || !EnsureFont(dpi)
      || !EnsureSurface(screen, width, rows)) return;
  if (surface_dpi_ != dpi) {
    surface_dpi_ = dpi;
    background_dirty_ = content_dirty_ = true;
  }
  const double scale = dpi / 96.0;
  if (background_dirty_) {
    const DWORD alpha = opacity_;
    const DWORD background = (alpha<<24) | ((GetRValue(background_)*alpha/255)<<16)
        | ((GetGValue(background_)*alpha/255)<<8) | (GetBValue(background_)*alpha/255);
    const double radius = std::min({font_size_ * 1.2 * scale,
        width / 2.0, rows / 2.0});
    const double border = border_depth_ * 4 * scale;
    // Match the preview's rounded surface and translucent white frame.
    for (int y = 0; y < rows; ++y) for (int x = 0; x < width; ++x) {
      const double dx = std::max(std::abs(x + 0.5 - width / 2.0) - (width / 2.0 - radius), 0.0);
      const double dy = std::max(std::abs(y + 0.5 - rows / 2.0) - (rows / 2.0 - radius), 0.0);
      const double edge = radius - std::sqrt(dx * dx + dy * dy);
      DWORD color = background;
      if (edge < border || x < border || y < border || x >= width-border || y >= rows-border) {
        color = ((64 + alpha * 191 / 255) << 24)
            | ((64 + GetRValue(background_) * alpha / 255 * 191 / 255) << 16)
            | ((64 + GetGValue(background_) * alpha / 255 * 191 / 255) << 8)
            | (64 + GetBValue(background_) * alpha / 255 * 191 / 255);
      }
      background_pixels_[y * width + x] = edge < 0 ? 0 : color;
    }
    background_dirty_ = false;
  }
  if (content_dirty_) {
    // Cue changes reuse the rounded background; text-only updates do no geometry work.
    std::copy(background_pixels_.begin(), background_pixels_.end(), pixels_);
    std::fill(coverage_,coverage_+width*rows,0);
    // A separate grayscale mask preserves text opacity on a translucent background.
    auto composite = [&](COLORREF color) {
      GdiFlush();
      for (int i=0; i<width*rows; ++i) {
        const DWORD a = coverage_[i]&255, inverse = 255-a, destination = pixels_[i];
        pixels_[i] = ((a+((destination>>24)*inverse/255))<<24)
          | (((GetRValue(color)*a+((destination>>16)&255)*inverse)/255)<<16)
          | (((GetGValue(color)*a+((destination>>8)&255)*inverse)/255)<<8)
          | ((GetBValue(color)*a+(destination&255)*inverse)/255);
      }
    };
    auto previous = SelectObject(mask_dc_, font_);
    SetBkMode(mask_dc_, TRANSPARENT);
    InflateRect(&rect, -static_cast<int>((20 + border_depth_ * 4) * scale),
        -static_cast<int>((10 + border_depth_ * 4) * scale));
    const auto flags = DT_CENTER | DT_WORDBREAK | DT_NOPREFIX;
    SetTextColor(mask_dc_, RGB(255,255,255));
    DrawTextW(mask_dc_, text_.c_str(), -1, &rect, flags);
    composite(text_color_);
    SelectObject(mask_dc_, previous);
    content_dirty_ = false;
  }
  RECT bounds; GetWindowRect(window_, &bounds);
  POINT position{bounds.left, bounds.top}, source{}; SIZE size{width, rows};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(window_, screen, &position, &size, output_dc_, &source,
      0, &blend, ULW_ALPHA);
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
  if (message == WM_SIZE || message == WM_DPICHANGED) {
    self->content_dirty_ = true;
    self->FitText();
    InvalidateRect(hwnd,nullptr,FALSE);
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC screen = BeginPaint(hwnd, &ps);
    self->Paint(screen);
    EndPaint(hwnd, &ps); return 0;
  }
  return DefWindowProc(hwnd, message, wp, lp);
}
