#include "subtitle_window.h"
#include <flutter_windows.h>
#include <algorithm>
#include <cmath>
#include <winrt/base.h>

namespace {
constexpr UINT kTextFlags = DT_CENTER | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX;
#ifdef _DEBUG
constexpr auto kSubtitleSettingsKey = L"Software\\DoujinAudio\\Debug";
#else
constexpr auto kSubtitleSettingsKey = L"Software\\DoujinAudio";
#endif

struct SubtitleWindowPlacement {
  LONG x = 0;
  LONG y = 0;
  LONG width = 0;
  UINT dpi = 96;
};

// Exact integer division by 255 for all x in [0, 65534].
inline DWORD Div255(DWORD x) { return (x + 1 + (x >> 8)) >> 8; }

UINT SafeWindowDpi(HWND window) {
  const UINT dpi = window ? GetDpiForWindow(window) : 0;
  return dpi > 0 ? dpi : 96;
}

UINT SafeMonitorDpi(HMONITOR monitor) {
  UINT dpi = monitor ? FlutterDesktopGetDpiForMonitor(monitor) : 0;
  if (dpi == 0) dpi = GetDpiForSystem();
  return dpi > 0 ? dpi : 96;
}

COLORREF ParseColor(const std::string& value, COLORREF previous) {
  try {
    const auto hex = value.empty() || value[0] != '#' ? value : value.substr(1);
    const auto rgb = std::stoul(hex, nullptr, 16);
    return RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
  } catch (...) { return previous; }
}

const wchar_t* ResolveSubtitleFontFamily(const std::wstring& family) {
  if (family.empty() || family == L"sans-serif") return L"Segoe UI";
  if (family == L"serif") return L"Times New Roman";
  if (family == L"monospace") return L"Consolas";
  return family.c_str();
}

DWORD BlendAndScalePremul(DWORD outer, DWORD inner, double inner_cov, double outer_cov) {
  if (outer_cov <= 0.0) return 0;
  if (outer_cov == 1.0) {
    if (inner_cov == 1.0) return inner;
    if (inner_cov == 0.0) return outer;
  }
  const auto blend_channel = [&](int shift) -> DWORD {
    const double o = static_cast<double>((outer >> shift) & 255);
    const double i = static_cast<double>((inner >> shift) & 255);
    const double mixed = (o + (i - o) * inner_cov) * outer_cov;
    return static_cast<DWORD>(std::clamp(std::lround(mixed), 0L, 255L));
  };
  return (blend_channel(24) << 24)
      | (blend_channel(16) << 16)
      | (blend_channel(8) << 8)
      | blend_channel(0);
}
}

SubtitleWindow::SubtitleWindow(HINSTANCE instance) : instance_(instance) {}
SubtitleWindow::~SubtitleWindow() {
  if (window_) {
    SavePlacement();
    DestroyWindow(window_);
  }
  ReleaseSurface();
  if (font_) DeleteObject(font_);
}
bool SubtitleWindow::EnsureWindow() {
  if (window_) return true;
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = instance_;
  wc.lpszClassName = L"DoujinAudioSubtitle";
  wc.hCursor = LoadCursor(nullptr, IDC_SIZEALL);
  RegisterClassW(&wc);
  RECT area{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &area, 0);
  const UINT default_dpi = SafeMonitorDpi(
      MonitorFromRect(&area, MONITOR_DEFAULTTONEAREST));
  const double scale = default_dpi / 96.0;
  const LONG margin_x = static_cast<LONG>(std::lround(80 * scale));
  const LONG margin_bottom = static_cast<LONG>(std::lround(180 * scale));
  const LONG margin_total = static_cast<LONG>(std::lround(100 * scale));
  const LONG min_width = static_cast<LONG>(std::lround(160 * scale));
  const LONG max_width = static_cast<LONG>(std::lround(800 * scale));
  LONG initial_width = std::max<LONG>(min_width,
      std::min<LONG>(max_width, area.right - area.left - margin_total));
  LONG initial_height = static_cast<LONG>(std::lround(110 * scale));
  LONG initial_x = area.left + margin_x;
  LONG initial_y = std::max<LONG>(area.top, area.bottom - margin_bottom);
  LoadPlacement(initial_x, initial_y, initial_width, initial_height);
  window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
      wc.lpszClassName, L"Doujin Audio subtitles", WS_POPUP,
      initial_x, initial_y, initial_width, initial_height,
      nullptr, nullptr, instance_, this);
  return window_ != nullptr;
}
void SubtitleWindow::SavePlacement() {
  if (!window_ || !placement_dirty_) return;
  RECT bounds{};
  if (!GetWindowRect(window_, &bounds)) return;
  SubtitleWindowPlacement placement{};
  placement.x = bounds.left;
  placement.y = bounds.top;
  placement.width = bounds.right - bounds.left;
  placement.dpi = SafeWindowDpi(window_);
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kSubtitleSettingsKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(key, L"SubtitleWindowPlacement", 0, REG_BINARY,
                   reinterpret_cast<const BYTE*>(&placement), sizeof(placement));
    RegCloseKey(key);
    placement_dirty_ = false;
  }
}
void SubtitleWindow::LoadPlacement(LONG& x, LONG& y, LONG& width, LONG& height) const {
  SubtitleWindowPlacement saved{};
  DWORD bytes = sizeof(saved);
  if (RegGetValueW(HKEY_CURRENT_USER, kSubtitleSettingsKey,
                   L"SubtitleWindowPlacement", RRF_RT_REG_BINARY, nullptr,
                   &saved, &bytes) != ERROR_SUCCESS ||
      bytes != sizeof(saved) || saved.width <= 0) {
    return;
  }
  const POINT anchor{saved.x, saved.y};
  MONITORINFO monitor{sizeof(MONITORINFO)};
  HMONITOR target_monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  if (!target_monitor || !GetMonitorInfo(target_monitor, &monitor)) return;
  const auto& area = monitor.rcWork;
  const UINT target_dpi = SafeMonitorDpi(target_monitor);
  const double target_scale = target_dpi / 96.0;
  const UINT saved_dpi = saved.dpi > 0 ? saved.dpi : 96;
  const LONG target_min_width = static_cast<LONG>(std::lround(160 * target_scale));
  const LONG scaled_width = MulDiv(saved.width, target_dpi, saved_dpi);
  const LONG work_width = std::max<LONG>(target_min_width, area.right - area.left);
  width = std::clamp<LONG>(scaled_width, target_min_width, work_width);
  height = static_cast<LONG>(std::lround(110 * target_scale));
  const LONG max_x = std::max<LONG>(area.left, area.right - width);
  const LONG max_y = std::max<LONG>(
      area.top, area.bottom - static_cast<LONG>(std::lround(50.0 * target_scale)));
  x = std::clamp<LONG>(saved.x, area.left, max_x);
  y = std::clamp<LONG>(saved.y, area.top, max_y);
}
void SubtitleWindow::Show(bool visible) {
  if (visible) {
    if (!EnsureWindow()) return;
    if (!IsWindowVisible(window_)) FitText();
    ShowWindow(window_, SW_SHOWNOACTIVATE);
    InvalidateRect(window_, nullptr, FALSE);
  } else {
    if (!window_) return;
    ShowWindow(window_, SW_HIDE);
    hovered_ = false;
    ReleaseSurface();
    std::vector<DWORD>().swap(background_pixels_);
    background_dirty_ = true;
    content_dirty_ = true;
    painted_text_bounds_ = {};
  }
}
void SubtitleWindow::Update(const std::string& text) {
  const std::wstring next(winrt::to_hstring(text));
  if (text_ == next) return;
  text_ = next;
  measured_text_width_ = 0;
  content_dirty_ = true;
  if (!window_ || !IsWindowVisible(window_)) return;
  FitText();
  InvalidateRect(window_, nullptr, FALSE);
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
  if (!window_ || !IsWindowVisible(window_)) return;
  if (layout_changed) FitText();
  InvalidateRect(window_, nullptr, FALSE);
}
void SubtitleWindow::FitText() {
  // Keep the current window bounds during gaps between cues or interactive drag.
  if (!window_ || fitting_text_ || resizing_ || text_.empty()) return;
  fitting_text_ = true;
  RECT bounds{}; GetWindowRect(window_, &bounds);
  RECT client{}; GetClientRect(window_, &client);
  const UINT dpi = SafeWindowDpi(window_);
  const double scale = dpi / 96.0;
  const int padding = static_cast<int>((20 + border_depth_ * 4) * scale);
  if (!EnsureFont(dpi)) {
    fitting_text_ = false;
    return;
  }
  const int text_width = std::max(1L, client.right - 2 * padding);
  int text_height = measured_text_height_;
  if (text_width != measured_text_width_) {
    HDC dc = GetDC(window_);
    if (!dc) {
      fitting_text_ = false;
      return;
    }
    text_height = MeasureText(dc, text_width);
    ReleaseDC(window_, dc);
  }
  MONITORINFO monitor{sizeof(MONITORINFO)};
  const HMONITOR target_monitor =
      MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  if (!target_monitor || !GetMonitorInfo(target_monitor, &monitor) ||
      monitor.rcWork.bottom <= monitor.rcWork.top) {
    fitting_text_ = false;
    return;
  }
  const auto& area = monitor.rcWork;
  const int height = std::min<LONG>(area.bottom - area.top,
      std::max<LONG>(static_cast<LONG>(50 * scale),
          text_height + static_cast<LONG>((20 + border_depth_ * 8) * scale)));
  const int top = std::clamp<LONG>(bounds.top, area.top, area.bottom - height);
  if (height != bounds.bottom - bounds.top || top != bounds.top) {
    SetWindowPos(window_, nullptr, bounds.left, top, bounds.right - bounds.left,
        height, SWP_NOACTIVATE | SWP_NOZORDER);
  }
  fitting_text_ = false;
}

int SubtitleWindow::MeasureText(HDC dc, int width) {
  if (width != measured_text_width_) {
    auto previous = SelectObject(dc, font_);
    RECT measured{0, 0, width, 0};
    DrawTextW(dc, text_.c_str(), -1, &measured, kTextFlags | DT_CALCRECT);
    SelectObject(dc, previous);
    measured_text_width_ = width;
    measured_text_height_ = measured.bottom;
  }
  return measured_text_height_;
}

bool SubtitleWindow::EnsureFont(UINT dpi) {
  const int height = static_cast<int>(font_size_ * dpi / 96.0);
  if (font_ && height == font_height_ && family_ == font_family_) return true;
  auto font = CreateFontW(-height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
      DEFAULT_PITCH, ResolveSubtitleFontFamily(family_));
  if (!font) return false;
  if (font_) DeleteObject(font_);
  font_ = font;
  font_height_ = height;
  font_family_ = family_;
  measured_text_width_ = 0;
  content_dirty_ = true;
  return true;
}
void SubtitleWindow::ReleaseMaskSurface() {
  if (previous_mask_bitmap_) SelectObject(mask_dc_, previous_mask_bitmap_);
  if (mask_bitmap_) DeleteObject(mask_bitmap_);
  if (mask_dc_) DeleteDC(mask_dc_);
  mask_dc_ = nullptr;
  mask_bitmap_ = nullptr;
  previous_mask_bitmap_ = nullptr;
  coverage_ = nullptr;
  mask_capacity_width_ = mask_capacity_rows_ = 0;
}
void SubtitleWindow::ReleaseSurface() {
  ReleaseMaskSurface();
  if (previous_output_bitmap_) SelectObject(output_dc_, previous_output_bitmap_);
  if (output_bitmap_) DeleteObject(output_bitmap_);
  if (output_dc_) DeleteDC(output_dc_);
  output_dc_ = nullptr;
  output_bitmap_ = nullptr;
  previous_output_bitmap_ = nullptr;
  pixels_ = nullptr;
  surface_width_ = surface_rows_ = 0;
  surface_capacity_width_ = surface_capacity_rows_ = 0;
  surface_uploaded_ = false;
}
bool SubtitleWindow::EnsureSurface(HDC screen, int width, int rows) {
  const auto next_capacity = [this](int size, int capacity, int min_shrink) {
    if (size > capacity) {
      // A live resize can deliver a new width for every mouse move. Keep spare
      // DIB space so most sizes only change the painted rectangle.
      return std::max(size, capacity + std::max(64, capacity / 4));
    }
    if (!resizing_ && capacity > min_shrink && size * 4 < capacity) {
      return size * 2;
    }
    return capacity;
  };
  const int capacity_width = next_capacity(width, surface_capacity_width_, 512);
  const int capacity_rows = next_capacity(rows, surface_capacity_rows_, 384);
  const bool realloc_output = !output_dc_ || !output_bitmap_
      || capacity_width != surface_capacity_width_
      || capacity_rows != surface_capacity_rows_;
  if (!realloc_output && width == surface_width_ && rows == surface_rows_) {
    return true;
  }
  if (realloc_output) {
    if (previous_output_bitmap_) SelectObject(output_dc_, previous_output_bitmap_);
    if (output_bitmap_) DeleteObject(output_bitmap_);
    if (output_dc_) DeleteDC(output_dc_);
    output_dc_ = nullptr;
    output_bitmap_ = nullptr;
    previous_output_bitmap_ = nullptr;
    pixels_ = nullptr;
    surface_width_ = surface_rows_ = 0;
    surface_capacity_width_ = surface_capacity_rows_ = 0;
    surface_uploaded_ = false;

    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = capacity_width;
    info.bmiHeader.biHeight = -capacity_rows;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    output_dc_ = CreateCompatibleDC(screen);
    output_bitmap_ = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
        reinterpret_cast<void**>(&pixels_), nullptr, 0);
    if (!output_dc_ || !output_bitmap_) {
      ReleaseSurface();
      return false;
    }
    previous_output_bitmap_ = SelectObject(output_dc_, output_bitmap_);
    if (!previous_output_bitmap_ || previous_output_bitmap_ == HGDI_ERROR) {
      if (previous_output_bitmap_ == HGDI_ERROR) previous_output_bitmap_ = nullptr;
      ReleaseSurface();
      return false;
    }
    surface_capacity_width_ = capacity_width;
    surface_capacity_rows_ = capacity_rows;
  }
  surface_width_ = width;
  surface_rows_ = rows;
  background_dirty_ = content_dirty_ = true;
  return true;
}
bool SubtitleWindow::EnsureMaskSurface(HDC screen, int width, int rows) {
  const auto next_capacity = [this](int size, int capacity, int min_shrink) {
    if (size > capacity) {
      return std::max(size, capacity + std::max(32, capacity / 4));
    }
    if (!resizing_ && capacity > min_shrink && size * 4 < capacity) {
      return size * 2;
    }
    return capacity;
  };
  const int capacity_width = next_capacity(width, mask_capacity_width_, 256);
  const int capacity_rows = next_capacity(rows, mask_capacity_rows_, 256);
  if (mask_dc_ && mask_bitmap_
      && capacity_width == mask_capacity_width_
      && capacity_rows == mask_capacity_rows_) {
    return true;
  }
  ReleaseMaskSurface();
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = capacity_width;
  info.bmiHeader.biHeight = -capacity_rows;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  mask_dc_ = CreateCompatibleDC(screen);
  mask_bitmap_ = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
      reinterpret_cast<void**>(&coverage_), nullptr, 0);
  if (!mask_dc_ || !mask_bitmap_) {
    ReleaseMaskSurface();
    return false;
  }
  previous_mask_bitmap_ = SelectObject(mask_dc_, mask_bitmap_);
  if (!previous_mask_bitmap_ || previous_mask_bitmap_ == HGDI_ERROR) {
    if (previous_mask_bitmap_ == HGDI_ERROR) previous_mask_bitmap_ = nullptr;
    ReleaseMaskSurface();
    return false;
  }
  mask_capacity_width_ = capacity_width;
  mask_capacity_rows_ = capacity_rows;
  return true;
}
void SubtitleWindow::PaintBackground(DWORD* target, size_t stride, int width, int rows, double scale) {
  const bool fully_transparent_hover =
      hovered_ && opacity_ == 0 && border_depth_ <= 0.0;
  // Keep alpha >= 1 inside the rounded rectangle even at 0% opacity so
  // UpdateLayeredWindow does not turn the whole window click-through and
  // prevent dragging or resizing.
  const DWORD alpha = opacity_ == 0 ? 1 : opacity_;
  const DWORD red = Div255(GetRValue(background_) * alpha);
  const DWORD green = Div255(GetGValue(background_) * alpha);
  const DWORD blue = Div255(GetBValue(background_) * alpha);
  const DWORD background = (alpha << 24) | (red << 16) | (green << 8) | blue;
  const DWORD frame = fully_transparent_hover
      ? ((44u << 24) | (44u << 16) | (44u << 8) | 44u)
      : (((64 + Div255(alpha * 191)) << 24)
          | ((64 + Div255(red * 191)) << 16)
          | ((64 + Div255(green * 191)) << 8)
          | (64 + Div255(blue * 191)));
  const double half_width = width / 2.0, half_height = rows / 2.0;
  const double radius = std::min({font_size_ * 1.2 * scale, half_width, half_height});
  const double border = fully_transparent_hover
      ? std::max(1.5 * scale, 1.0)
      : border_depth_ * 4 * scale;
  const int edge_span = static_cast<int>(std::ceil(std::max(radius, border + 0.5)));
  const int side_columns = std::min(width / 2, edge_span);
  const int top_rows = std::min(rows / 2, edge_span);
  const auto row_at = [&](int y) {
    return target + static_cast<size_t>(y) * stride;
  };
  const auto paint_row = [&](int y) {
    auto* row = row_at(y);
    const double qy = std::abs(y + 0.5 - half_height) - (half_height - radius);
    const auto pixel_at = [&](int x) {
      const double qx = std::abs(x + 0.5 - half_width) - (half_width - radius);
      const double out_x = std::max(qx, 0.0);
      const double out_y = std::max(qy, 0.0);
      const double signed_dist = std::sqrt(out_x * out_x + out_y * out_y)
          + std::min(std::max(qx, qy), 0.0) - radius;
      const double edge = -signed_dist;
      const double outer_cov = std::clamp(edge + 0.5, 0.0, 1.0);
      const double inner_cov = border > 0.0
          ? std::clamp(edge - border + 0.5, 0.0, 1.0)
          : 1.0;
      return BlendAndScalePremul(frame, background, inner_cov, outer_cov);
    };
    // The coverage in the middle of the row is constant. Only the side
    // strips can vary, and the right strip mirrors the left one.
    std::fill(row + side_columns, row + width - side_columns, pixel_at(width / 2));
    for (int x = 0; x < side_columns; ++x) {
      row[x] = row[width - x - 1] = pixel_at(x);
    }
  };
  for (int y = 0; y < top_rows; ++y) {
    paint_row(y);
    std::copy_n(row_at(y), width, row_at(rows - y - 1));
  }
  if (top_rows < rows - top_rows) {
    paint_row(top_rows);
    for (int y = top_rows + 1; y < rows - top_rows; ++y) {
      std::copy_n(row_at(top_rows), width, row_at(y));
    }
  }
  background_dirty_ = false;
}
void SubtitleWindow::Paint(HDC screen) {
  if (!window_) return;
  RECT rect; GetClientRect(window_, &rect);
  const int width = rect.right, rows = rect.bottom;
  const UINT dpi = SafeWindowDpi(window_);
  if (width <= 0 || rows <= 0 || !EnsureFont(dpi)
      || !EnsureSurface(screen, width, rows)) return;
  if (surface_dpi_ != dpi) {
    surface_dpi_ = dpi;
    background_dirty_ = content_dirty_ = true;
  }
  const bool background_changed = background_dirty_;
  const bool was_content_dirty = content_dirty_;
  if (!background_changed && !was_content_dirty && surface_uploaded_) return;
  const double scale = dpi / 96.0;
  const size_t stride = surface_capacity_width_;
  bool background_painted_directly = false;
  if (resizing_) {
    // During live resize, avoid populating and copying background_pixels_ on
    // every drag frame; paint straight into the DIB and rebuild the cache once
    // in WM_EXITSIZEMOVE.
    if (background_changed || was_content_dirty) {
      PaintBackground(pixels_, stride, width, rows, scale);
      background_painted_directly = true;
    }
  } else if (background_changed) {
    const size_t pixel_count = static_cast<size_t>(width) * rows;
    if (background_pixels_.capacity() > pixel_count * 4) {
      std::vector<DWORD>(pixel_count).swap(background_pixels_);
    } else if (background_pixels_.size() != pixel_count) {
      background_pixels_.resize(pixel_count);
    }
    PaintBackground(background_pixels_.data(), width, width, rows, scale);
  }
  if (was_content_dirty || (background_changed && !background_painted_directly)) {
    if (!background_painted_directly) {
      // Only the previous caption's clipped text and shadow can differ from the
      // cached background when the window geometry and appearance are unchanged.
      const RECT restore = background_changed ? rect : painted_text_bounds_;
      if (restore.right > restore.left && restore.bottom > restore.top) {
        for (LONG y = restore.top; y < restore.bottom; ++y) {
          const auto* background_row = background_pixels_.data() + static_cast<size_t>(y) * width;
          std::copy_n(background_row + restore.left, restore.right - restore.left,
              pixels_ + y * stride + restore.left);
        }
      }
    }
    painted_text_bounds_ = {};
    RECT text_rect = rect;
    InflateRect(&text_rect, -static_cast<int>((20 + border_depth_ * 4) * scale),
        -static_cast<int>((10 + border_depth_ * 4) * scale));
    if (!text_.empty() && !IsRectEmpty(&text_rect)) {
      const int text_w = text_rect.right - text_rect.left;
      const int text_height = MeasureText(output_dc_, text_w);
      const int available_height = text_rect.bottom - text_rect.top;
      if (text_height > 0 && available_height > text_height) {
        text_rect.top += (available_height - text_height) / 2;
      }
      if (text_height > 0) {
        text_rect.bottom = std::min<LONG>(text_rect.bottom, text_rect.top + text_height);
      }
      const int text_h = text_rect.bottom - text_rect.top;
      if (text_height > 0 && text_w > 0 && text_h > 0 &&
          EnsureMaskSurface(screen, text_w, text_h)) {
        // The separate grayscale mask is sized to the clipped text box, keeping
        // text opacity independent from the translucent background.
        const size_t mask_stride = mask_capacity_width_;
        for (int y = 0; y < text_h; ++y) {
          std::fill_n(coverage_ + static_cast<size_t>(y) * mask_stride, text_w, 0);
        }
        RECT local_rect{0, 0, text_w, text_h};
        auto previous = SelectObject(mask_dc_, font_);
        SetBkMode(mask_dc_, TRANSPARENT);
        SetTextColor(mask_dc_, RGB(255, 255, 255));
        DrawTextW(mask_dc_, text_.c_str(), -1, &local_rect, kTextFlags);
        GdiFlush();
        const DWORD red = GetRValue(text_color_), green = GetGValue(text_color_);
        const DWORD blue = GetBValue(text_color_);
        const int shadow_dy = std::max(1, static_cast<int>(std::lround(2.0 * scale)));
        const int blur_r = std::max(1, static_cast<int>(std::lround(1.5 * scale)));
        painted_text_bounds_.left = std::max<LONG>(0, text_rect.left - blur_r);
        painted_text_bounds_.top = std::max<LONG>(0, text_rect.top - blur_r);
        painted_text_bounds_.right = std::min<LONG>(width, text_rect.right + blur_r);
        painted_text_bounds_.bottom =
            std::min<LONG>(rows, text_rect.bottom + shadow_dy + blur_r);
        const auto sample_mask = [&](LONG mx, LONG my) -> DWORD {
          if (mx < 0 || mx >= text_w || my < 0 || my >= text_h) return 0;
          return coverage_[static_cast<size_t>(my) * mask_stride + mx] & 255;
        };
        for (LONG y = painted_text_bounds_.top; y < painted_text_bounds_.bottom; ++y) {
          auto* output_row = pixels_ + y * stride;
          const LONG local_y = y - text_rect.top;
          const LONG sy = local_y - shadow_dy;
          for (LONG x = painted_text_bounds_.left; x < painted_text_bounds_.right; ++x) {
            const LONG local_x = x - text_rect.left;
            const DWORD a = sample_mask(local_x, local_y);
            // Soft 3x3 separable [1, 2, 1] kernel around (local_x, sy) for blurred shadow.
            const DWORD blurred_shadow =
                (sample_mask(local_x - blur_r, sy - blur_r)
                + 2 * sample_mask(local_x, sy - blur_r)
                + sample_mask(local_x + blur_r, sy - blur_r)
                + 2 * sample_mask(local_x - blur_r, sy)
                + 4 * sample_mask(local_x, sy)
                + 2 * sample_mask(local_x + blur_r, sy)
                + sample_mask(local_x - blur_r, sy + blur_r)
                + 2 * sample_mask(local_x, sy + blur_r)
                + sample_mask(local_x + blur_r, sy + blur_r) + 8) >> 4;
            const DWORD alpha_s = Div255(blurred_shadow * 128);
            if (a == 0 && alpha_s == 0) continue;
            DWORD destination = output_row[x];
            if (alpha_s > 0) {
              const DWORD inv_s = 255 - alpha_s;
              destination =
                  ((alpha_s + Div255((destination >> 24) * inv_s)) << 24)
                  | (Div255(((destination >> 16) & 255) * inv_s) << 16)
                  | (Div255(((destination >> 8) & 255) * inv_s) << 8)
                  | Div255((destination & 255) * inv_s);
            }
            if (a == 0) {
              output_row[x] = destination;
              continue;
            }
            const DWORD inverse = 255 - a;
            output_row[x] = ((a + Div255((destination >> 24) * inverse)) << 24)
              | (Div255(red * a + ((destination >> 16) & 255) * inverse) << 16)
              | (Div255(green * a + ((destination >> 8) & 255) * inverse) << 8)
              | Div255(blue * a + (destination & 255) * inverse);
          }
        }
        SelectObject(mask_dc_, previous);
      }
    }
    content_dirty_ = false;
  }
  RECT bounds; GetWindowRect(window_, &bounds);
  POINT position{bounds.left, bounds.top}, source{}; SIZE size{width, rows};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  if (UpdateLayeredWindow(window_, screen, &position, &size, output_dc_, &source,
      0, &blend, ULW_ALPHA)) {
    surface_uploaded_ = true;
  }
}
LRESULT CALLBACK SubtitleWindow::WndProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  auto self = reinterpret_cast<SubtitleWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<SubtitleWindow*>(reinterpret_cast<CREATESTRUCT*>(lp)->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wp, lp);
  if (message == WM_NCHITTEST) {
    RECT rect; GetWindowRect(hwnd, &rect);
    const int hit_border =
        std::max(4, static_cast<int>(std::lround(8.0 * SafeWindowDpi(hwnd) / 96.0)));
    const int x = static_cast<short>(LOWORD(lp));
    // Vertical height auto-fits subtitle text, so expose horizontal resize only.
    if (x < rect.left + hit_border) return HTLEFT;
    if (x >= rect.right - hit_border) return HTRIGHT;
    return HTCAPTION;
  }
  if (message == WM_NCMOUSEMOVE) {
    if (!self->hovered_) {
      self->hovered_ = true;
      TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE | TME_NONCLIENT, hwnd, 0};
      TrackMouseEvent(&tme);
      if (self->opacity_ == 0 && self->border_depth_ <= 0.0 && IsWindowVisible(hwnd)) {
        self->background_dirty_ = true;
        self->content_dirty_ = true;
        InvalidateRect(hwnd, nullptr, FALSE);
      }
    }
  }
  if (message == WM_NCMOUSELEAVE) {
    if (self->hovered_) {
      self->hovered_ = false;
      if (self->opacity_ == 0 && self->border_depth_ <= 0.0 && IsWindowVisible(hwnd)) {
        self->background_dirty_ = true;
        self->content_dirty_ = true;
        InvalidateRect(hwnd, nullptr, FALSE);
      }
    }
  }
  if (message == WM_GETMINMAXINFO) {
    const double scale = SafeWindowDpi(hwnd) / 96.0;
    reinterpret_cast<MINMAXINFO*>(lp)->ptMinTrackSize = {
        static_cast<LONG>(std::lround(160 * scale)),
        static_cast<LONG>(std::lround(50 * scale))};
    return 0;
  }
  if (message == WM_ENTERSIZEMOVE) {
    self->resizing_ = true;
  }
  if (message == WM_EXITSIZEMOVE) {
    self->resizing_ = false;
    self->background_dirty_ = true;
    self->content_dirty_ = true;
    self->SavePlacement();
    if (IsWindowVisible(hwnd)) {
      self->FitText();
      InvalidateRect(hwnd, nullptr, FALSE);
    }
  }
  if (message == WM_DPICHANGED) {
    self->background_dirty_ = true;
    self->content_dirty_ = true;
    self->measured_text_width_ = 0;
    self->dpi_changing_ = true;
    self->sized_during_dpi_change_ = false;
    const auto* suggested = reinterpret_cast<const RECT*>(lp);
    SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
        suggested->right - suggested->left, suggested->bottom - suggested->top,
        SWP_NOZORDER | SWP_NOACTIVATE);
    self->dpi_changing_ = false;
    if (!self->sized_during_dpi_change_ && IsWindowVisible(hwnd)) {
      self->FitText();
      InvalidateRect(hwnd, nullptr, FALSE);
    }
    return 0;
  }
  if (message == WM_MOVE) {
    if (IsWindowVisible(hwnd) && !self->fitting_text_) {
      self->placement_dirty_ = true;
    }
  }
  if (message == WM_SIZE) {
    if (self->dpi_changing_) self->sized_during_dpi_change_ = true;
    if (IsWindowVisible(hwnd) && !self->fitting_text_) {
      self->placement_dirty_ = true;
    }
    self->content_dirty_ = true;
    if (IsWindowVisible(hwnd)) {
      if (!self->resizing_) self->FitText();
      InvalidateRect(hwnd, nullptr, FALSE);
    }
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC screen = BeginPaint(hwnd, &ps);
    self->Paint(screen);
    EndPaint(hwnd, &ps); return 0;
  }
  return DefWindowProc(hwnd, message, wp, lp);
}
