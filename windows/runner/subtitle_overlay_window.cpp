#include "subtitle_overlay_window.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>
#include <variant>

#include <flutter/standard_method_codec.h>

namespace {

constexpr wchar_t kWindowClassName[] = L"NAMELESS_AUDIO_SUBTITLE_OVERLAY";
constexpr int kWindowWidth = 900;
constexpr int kWindowHeight = 120;
constexpr int kContentInset = 16;
constexpr int kCornerRadius = 20;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                         0);
  if (length <= 1) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), length);
  result.resize(length - 1);
  return result;
}

uint32_t ParseArgb(const std::string& value, uint32_t fallback) {
  const std::string hex = !value.empty() && value.front() == '#'
                              ? value.substr(1)
                              : value;
  if (hex.size() != 8) return fallback;
  try {
    return static_cast<uint32_t>(std::stoul(hex, nullptr, 16));
  } catch (...) {
    return fallback;
  }
}

bool IsInsideRoundedRect(int x, int y, int width, int height, int radius) {
  if (x < 0 || y < 0 || x >= width || y >= height) return false;
  if ((x >= radius && x < width - radius) ||
      (y >= radius && y < height - radius)) {
    return true;
  }
  const int center_x = x < radius ? radius : width - radius - 1;
  const int center_y = y < radius ? radius : height - radius - 1;
  const int dx = x - center_x;
  const int dy = y - center_y;
  return dx * dx + dy * dy <= radius * radius;
}

uint32_t PremultipliedArgb(BYTE alpha, BYTE red, BYTE green, BYTE blue) {
  return (static_cast<uint32_t>(alpha) << 24) |
         (static_cast<uint32_t>(red) * alpha / 255 << 16) |
         (static_cast<uint32_t>(green) * alpha / 255 << 8) |
         (static_cast<uint32_t>(blue) * alpha / 255);
}

template <typename T>
const T* ValueFor(const flutter::EncodableMap& map, const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  if (iterator == map.end()) return nullptr;
  return std::get_if<T>(&iterator->second);
}

double NumberFor(const flutter::EncodableMap& map, const char* key,
                  double fallback) {
  if (const auto* value = ValueFor<double>(map, key)) return *value;
  if (const auto* value = ValueFor<int32_t>(map, key)) return *value;
  if (const auto* value = ValueFor<int64_t>(map, key)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

bool IsNumber(const flutter::EncodableValue& value) {
  if (const auto* number = std::get_if<double>(&value)) {
    return std::isfinite(*number);
  }
  return std::holds_alternative<int32_t>(value) ||
         std::holds_alternative<int64_t>(value);
}

bool HasValidOptionalString(const flutter::EncodableMap& map,
                            const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  return iterator == map.end() ||
         std::holds_alternative<std::string>(iterator->second);
}

bool HasValidOptionalNumber(const flutter::EncodableMap& map,
                            const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  return iterator == map.end() || IsNumber(iterator->second);
}

const wchar_t* ResolveFontFamily(const std::wstring& family) {
  if (family.empty() || family == L"sans-serif") return L"Microsoft YaHei UI";
  if (family == L"monospace") return L"Consolas";
  if (family == L"serif") return L"SimSun";
  return family.c_str();
}

flutter::EncodableValue SuccessEnvelope(
    flutter::EncodableValue value = flutter::EncodableValue()) {
  flutter::EncodableMap envelope;
  envelope[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
  envelope[flutter::EncodableValue("value")] = std::move(value);
  return flutter::EncodableValue(envelope);
}

}  // namespace

SubtitleOverlayWindow::SubtitleOverlayWindow(
    flutter::BinaryMessenger* messenger) {
  WNDCLASS window_class = {};
  window_class.lpfnWndProc = SubtitleOverlayWindow::WndProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kWindowClassName;
  RegisterClass(&window_class);

  window_ = CreateWindowEx(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kWindowClassName, L"", WS_POPUP, 0, 0, kWindowWidth, kWindowHeight,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "nameless_audio/subtitle_overlay",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

SubtitleOverlayWindow::~SubtitleOverlayWindow() {
  if (window_ != nullptr) DestroyWindow(window_);
}

void SubtitleOverlayWindow::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  if (method == "canDrawOverlays") {
    result->Success(SuccessEnvelope(flutter::EncodableValue(window_ != nullptr)));
    return;
  }
  if (method == "openOverlaySettings") {
    result->Success(SuccessEnvelope(flutter::EncodableValue(true)));
    return;
  }
  if (method == "startOverlay") {
    Show();
    result->Success(SuccessEnvelope());
    return;
  }
  if (method == "stopOverlay") {
    Hide();
    result->Success(SuccessEnvelope());
    return;
  }

  if (method == "updateSubtitle") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_argument", "Expected an argument map.");
      return;
    }
    const auto* text = ValueFor<std::string>(*arguments, "text");
    if (text == nullptr) {
      result->Error("invalid_argument",
                    "Missing or invalid string argument: text");
      return;
    }
    text_ = Utf8ToWide(*text);
    Render();
    result->Success(SuccessEnvelope());
    return;
  }
  if (method == "updateStyle") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_argument", "Expected an argument map.");
      return;
    }
    if (!HasValidOptionalNumber(*arguments, "fontSize") ||
        !HasValidOptionalNumber(*arguments, "borderDepth") ||
        !HasValidOptionalNumber(*arguments, "backgroundOpacity") ||
        !HasValidOptionalString(*arguments, "fontFamily") ||
        !HasValidOptionalString(*arguments, "textColor") ||
        !HasValidOptionalString(*arguments, "backgroundColor")) {
      result->Error("invalid_argument", "Invalid subtitle style argument.");
      return;
    }
    UpdateStyle(*arguments);
    Render();
    result->Success(SuccessEnvelope());
    return;
  }
  result->NotImplemented();
}

void SubtitleOverlayWindow::Show() {
  Render();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
}

void SubtitleOverlayWindow::Hide() {
  ShowWindow(window_, SW_HIDE);
}

void SubtitleOverlayWindow::UpdateStyle(
    const flutter::EncodableMap& arguments) {
  font_size_ = NumberFor(arguments, "fontSize", font_size_);
  if (const auto* value = ValueFor<std::string>(arguments, "fontFamily")) {
    font_family_ = Utf8ToWide(*value);
  }
  border_depth_ = NumberFor(arguments, "borderDepth", border_depth_);
  background_alpha_ = static_cast<BYTE>(
      std::clamp(NumberFor(arguments, "backgroundOpacity",
                           background_alpha_ / 255.0),
                 0.0, 1.0) *
      255.0);
  if (const auto* value = ValueFor<std::string>(arguments, "textColor")) {
    const uint32_t argb = ParseArgb(*value, 0xFFFFFFFF);
    text_color_ = RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  }
  if (const auto* value = ValueFor<std::string>(arguments, "backgroundColor")) {
    const uint32_t argb = ParseArgb(*value, 0xFF000000);
    background_color_ =
        RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  }
}

void SubtitleOverlayWindow::Render() {
  if (window_ == nullptr) return;

  HDC screen = GetDC(nullptr);
  if (screen == nullptr) return;
  HDC memory = CreateCompatibleDC(screen);
  if (memory == nullptr) {
    ReleaseDC(nullptr, screen);
    return;
  }
  BITMAPINFO bitmap_info = {};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = kWindowWidth;
  bitmap_info.bmiHeader.biHeight = -kWindowHeight;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;
  uint32_t* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(memory, &bitmap_info, DIB_RGB_COLORS,
                                    reinterpret_cast<void**>(&pixels), nullptr,
                                    0);
  if (bitmap == nullptr || pixels == nullptr) {
    if (bitmap != nullptr) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return;
  }
  HGDIOBJ old_bitmap = SelectObject(memory, bitmap);
  std::fill_n(pixels, kWindowWidth * kWindowHeight, 0u);

  const BYTE red = GetRValue(background_color_);
  const BYTE green = GetGValue(background_color_);
  const BYTE blue = GetBValue(background_color_);
  const int border = std::max(0, static_cast<int>(std::round(border_depth_)));
  const int content_width = kWindowWidth - kContentInset * 2;
  const int content_height = kWindowHeight - kContentInset * 2;
  for (int y = 0; y < kWindowHeight; ++y) {
    for (int x = 0; x < kWindowWidth; ++x) {
      const int content_x = x - kContentInset;
      const int content_y = y - kContentInset;
      if (!IsInsideRoundedRect(content_x, content_y, content_width,
                               content_height, kCornerRadius)) {
        continue;
      }
      const bool is_border =
          border > 0 &&
          !IsInsideRoundedRect(content_x - border, content_y - border,
                               content_width - border * 2,
                               content_height - border * 2,
                               std::max(0, kCornerRadius - border));
      const BYTE alpha = is_border ? static_cast<BYTE>(180) : background_alpha_;
      pixels[y * kWindowWidth + x] =
          PremultipliedArgb(alpha, red, green, blue);
    }
  }

  const UINT dpi = std::max(96u, GetDpiForWindow(window_));
  const int font_height =
      -MulDiv(static_cast<int>(std::round(font_size_)), dpi, 96);
  HFONT font = CreateFont(font_height, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                          CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                          DEFAULT_PITCH, ResolveFontFamily(font_family_));
  HDC text_memory = CreateCompatibleDC(screen);
  uint32_t* text_pixels = nullptr;
  HBITMAP text_bitmap = text_memory == nullptr
                            ? nullptr
                            : CreateDIBSection(
                                  text_memory, &bitmap_info, DIB_RGB_COLORS,
                                  reinterpret_cast<void**>(&text_pixels),
                                  nullptr, 0);
  HGDIOBJ old_text_bitmap = nullptr;
  HGDIOBJ old_font = nullptr;
  if (font != nullptr && text_memory != nullptr && text_bitmap != nullptr &&
      text_pixels != nullptr) {
    old_text_bitmap = SelectObject(text_memory, text_bitmap);
    std::fill_n(text_pixels, kWindowWidth * kWindowHeight, 0u);
    old_font = SelectObject(text_memory, font);
    SetBkMode(text_memory, TRANSPARENT);
    SetTextColor(text_memory, RGB(255, 255, 255));
    RECT text_rect = {kContentInset + 20, kContentInset + 8,
                      kWindowWidth - kContentInset - 20,
                      kWindowHeight - kContentInset - 8};
    DrawText(text_memory, text_.c_str(), -1, &text_rect,
             DT_CENTER | DT_VCENTER | DT_WORDBREAK | DT_NOPREFIX);

    const BYTE text_red = GetRValue(text_color_);
    const BYTE text_green = GetGValue(text_color_);
    const BYTE text_blue = GetBValue(text_color_);
    for (int i = 0; i < kWindowWidth * kWindowHeight; ++i) {
      const BYTE text_alpha = static_cast<BYTE>(text_pixels[i] & 0xFF);
      if (text_alpha == 0) continue;
      const uint32_t background = pixels[i];
      const BYTE inverse = 255 - text_alpha;
      const BYTE background_alpha = (background >> 24) & 0xFF;
      const BYTE background_red = (background >> 16) & 0xFF;
      const BYTE background_green = (background >> 8) & 0xFF;
      const BYTE background_blue = background & 0xFF;
      pixels[i] =
          (static_cast<uint32_t>(
               text_alpha + background_alpha * inverse / 255)
           << 24) |
          (static_cast<uint32_t>(
               text_red * text_alpha / 255 + background_red * inverse / 255)
           << 16) |
          (static_cast<uint32_t>(text_green * text_alpha / 255 +
                                 background_green * inverse / 255)
           << 8) |
          (text_blue * text_alpha / 255 + background_blue * inverse / 255);
    }
  }

  POINT source = {0, 0};
  SIZE size = {kWindowWidth, kWindowHeight};
  RECT work_area = {};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  RECT current_bounds = {};
  GetWindowRect(window_, &current_bounds);
  POINT destination =
      positioned_
          ? POINT{current_bounds.left, current_bounds.top}
          : POINT{
                work_area.left +
                    (work_area.right - work_area.left - kWindowWidth) / 2,
                work_area.top + 72,
            };
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(window_, screen, &destination, &size, memory, &source, 0,
                      &blend, ULW_ALPHA);
  positioned_ = true;

  if (old_font != nullptr) SelectObject(text_memory, old_font);
  if (old_text_bitmap != nullptr) SelectObject(text_memory, old_text_bitmap);
  SelectObject(memory, old_bitmap);
  if (text_bitmap != nullptr) DeleteObject(text_bitmap);
  if (font != nullptr) DeleteObject(font);
  DeleteObject(bitmap);
  if (text_memory != nullptr) DeleteDC(text_memory);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK SubtitleOverlayWindow::WndProc(HWND window, UINT message,
                                                WPARAM wparam,
                                                LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  if (message == WM_NCHITTEST) return HTCAPTION;
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_CLOSE) {
    ShowWindow(window, SW_HIDE);
    return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
