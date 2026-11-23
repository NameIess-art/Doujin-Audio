#include "network_proxy.h"

#include <flutter/standard_method_codec.h>
#include <winhttp.h>
#include <shlwapi.h>
#include <winrt/base.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cwctype>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;

void Failure(Result& result, const std::string& code, const std::string& message) {
  result.Success(Value(Map{{Value("ok"), Value(false)},
      {Value("errorCode"), Value(code)}, {Value("error"), Value(message)}}));
}

std::wstring Lower(std::wstring text) {
  std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return text;
}

std::wstring Trim(const std::wstring& text) {
  const auto first = text.find_first_not_of(L" \t\r\n");
  if (first == std::wstring::npos) return {};
  const auto last = text.find_last_not_of(L" \t\r\n");
  return text.substr(first, last - first + 1);
}

std::vector<std::wstring> SplitEntries(const std::wstring& text,
                                       const wchar_t* delimiters) {
  std::vector<std::wstring> entries;
  size_t start = 0;
  while (start < text.size()) {
    const auto end = text.find_first_of(delimiters, start);
    const auto entry = Trim(text.substr(start, end - start));
    if (!entry.empty()) entries.push_back(entry);
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  return entries;
}

std::string ProtocolPrefix(const std::wstring& name) {
  if (name == L"socks5") return "SOCKS5 ";
  if (name == L"socks" || name == L"socks4") return "SOCKS ";
  if (name == L"https") return "HTTPS ";
  if (name == L"http") return "HTTP ";
  return "PROXY ";
}

bool Bypasses(const std::wstring& bypass, const std::wstring& host,
              const std::wstring& scheme, INTERNET_PORT port) {
  const auto address = host + L":" + std::to_wstring(port);
  for (auto pattern : SplitEntries(Lower(bypass), L"; \t\r\n")) {
    if (pattern == L"<local>" && host.find(L'.') == std::wstring::npos &&
        host.find(L':') == std::wstring::npos) return true;
    const auto separator = pattern.find(L"://");
    if (separator != std::wstring::npos) {
      if (pattern.substr(0, separator) != scheme) continue;
      pattern = pattern.substr(separator + 3);
    }
    if (PathMatchSpecW(host.c_str(), pattern.c_str()) ||
        PathMatchSpecW(address.c_str(), pattern.c_str())) return true;
  }
  return false;
}

bool IsPacKeyword(const std::wstring& token) {
  return token == L"proxy" || token == L"http" || token == L"https" ||
         token == L"socks" || token == L"socks4" || token == L"socks5";
}

std::string ProxyList(const std::wstring& proxies, const std::wstring& scheme) {
  enum class Kind { kSelected, kCommon, kSocks, kDirect };
  struct Entry {
    Kind kind;
    std::string value;
  };
  std::vector<Entry> entries;
  bool has_selected = false;
  bool has_common = false;
  bool has_socks = false;
  auto push = [&](Kind kind, std::string value) {
    if (kind == Kind::kSelected) has_selected = true;
    else if (kind == Kind::kCommon) has_common = true;
    else if (kind == Kind::kSocks) has_socks = true;
    entries.push_back({kind, std::move(value)});
  };

  for (const auto& segment : SplitEntries(proxies, L";")) {
    const auto tokens = SplitEntries(segment, L" \t\r\n");
    for (size_t i = 0; i < tokens.size(); ++i) {
      std::wstring entry = tokens[i];
      if (i + 1 < tokens.size() && tokens[i + 1] == L"=") {
        if (i + 2 < tokens.size() &&
            tokens[i + 2].find(L'=') == std::wstring::npos &&
            Lower(tokens[i + 2]) != L"direct") {
          entry += L"=";
          entry += tokens[i + 2];
          i += 2;
        } else {
          ++i;
          continue;
        }
      } else if (i + 1 < tokens.size() && !tokens[i + 1].empty() &&
                 tokens[i + 1].front() == L'=') {
        entry += tokens[++i];
      } else if (!entry.empty() && entry.back() == L'=' &&
                 i + 1 < tokens.size() &&
                 tokens[i + 1].find(L'=') == std::wstring::npos &&
                 Lower(tokens[i + 1]) != L"direct") {
        entry += tokens[++i];
      }

      const auto lower = Lower(entry);
      if (lower == L"direct") {
        push(Kind::kDirect, "DIRECT");
        continue;
      }
      if (IsPacKeyword(lower) && i + 1 < tokens.size() &&
          tokens[i + 1].find(L'=') == std::wstring::npos &&
          Lower(tokens[i + 1]) != L"direct") {
        auto rest = tokens[++i];
        const auto protocol = rest.find(L"://");
        if (protocol != std::wstring::npos) rest = rest.substr(protocol + 3);
        if (rest.empty()) continue;
        const std::string prefix =
            lower == L"proxy" ? "PROXY " : ProtocolPrefix(lower);
        push(Kind::kCommon, prefix + winrt::to_string(rest));
        continue;
      }

      const auto equals = entry.find(L'=');
      std::wstring type;
      if (equals != std::wstring::npos) {
        type = Lower(Trim(entry.substr(0, equals)));
        entry = Trim(entry.substr(equals + 1));
      }
      if (entry.empty()) continue;
      const bool is_socks =
          type == L"socks" || type == L"socks5" || type == L"socks4";
      if (!type.empty() && type != scheme && !is_socks) continue;
      std::string prefix =
          type == L"socks5" ? "SOCKS5 " : is_socks ? "SOCKS " : "PROXY ";
      const auto protocol = entry.find(L"://");
      if (protocol != std::wstring::npos) {
        const auto name = Lower(entry.substr(0, protocol));
        prefix = ProtocolPrefix(name);
        entry = entry.substr(protocol + 3);
        if (entry.empty()) continue;
      }
      const Kind kind = type.empty() ? Kind::kCommon
          : type == scheme ? Kind::kSelected : Kind::kSocks;
      push(kind, prefix + winrt::to_string(entry));
    }
  }

  if (!has_selected && !has_common && !has_socks) return "DIRECT";
  const Kind active = has_selected ? Kind::kSelected
      : has_common ? Kind::kCommon : Kind::kSocks;
  std::string result;
  for (const auto& item : entries) {
    if (item.kind != active && item.kind != Kind::kDirect) continue;
    if (!result.empty()) result += "; ";
    result += item.value;
  }
  return result.empty() ? "DIRECT" : result;
}

struct ProxyConfigFingerprint {
  bool auto_detect = false;
  std::wstring auto_config_url;
  std::wstring proxy;
  std::wstring bypass;
  bool operator==(const ProxyConfigFingerprint& other) const {
    return auto_detect == other.auto_detect &&
           auto_config_url == other.auto_config_url &&
           proxy == other.proxy &&
           bypass == other.bypass;
  }
  bool operator!=(const ProxyConfigFingerprint& other) const {
    return !(*this == other);
  }
};
}  // namespace

struct NetworkProxy::State {
  static constexpr int kMaxWorkers = 4;
  static constexpr std::array<ULONGLONG, 3> kWpadNegativeCooldownsMs = {
      30000, 60000, 300000};

  enum class ResolveOutcome { kCompleted, kParked };

  struct Request {
    std::unique_ptr<Result> result;
    std::wstring url, host, scheme;
    INTERNET_PORT port;
    std::string value, error;
    bool completed = false;
  };
  std::mutex mutex;
  bool wpad_probe_in_flight = false;
  bool wpad_failed_cached = false;
  ULONGLONG wpad_failed_until_ms = 0;
  size_t wpad_consecutive_failures = 0;
  ProxyConfigFingerprint wpad_config;
  std::deque<std::shared_ptr<Request>> wpad_waiting;
  std::once_flag session_once;
  // WinHTTP caches PAC discovery per session. Reuse it across media requests.
  std::unique_ptr<void, decltype(&WinHttpCloseHandle)> session{nullptr, WinHttpCloseHandle};
  HWND window = nullptr;
  int workers = 0;
  bool reply_posted = false;
  std::deque<std::shared_ptr<Request>> queued;
  std::vector<std::shared_ptr<Request>> pending;

  void EnsureWorkersLocked(const std::shared_ptr<State>& self) {
    if (!window || queued.empty()) return;
    const int desired =
        std::min<int>(kMaxWorkers, static_cast<int>(queued.size()));
    while (workers < desired) {
      auto owner = std::make_unique<std::shared_ptr<State>>(self);
      if (!TrySubmitThreadpoolCallback(RunWorker, owner.get(), nullptr)) break;
      owner.release();
      ++workers;
    }
  }

  void DrainWpadWaitingLocked(const std::shared_ptr<State>& self) {
    if (!window) {
      wpad_waiting.clear();
      return;
    }
    while (!wpad_waiting.empty()) {
      queued.push_back(std::move(wpad_waiting.front()));
      wpad_waiting.pop_front();
    }
    EnsureWorkersLocked(self);
  }

  ResolveOutcome ResolveRequest(const std::shared_ptr<State>& self,
                                const std::shared_ptr<Request>& request,
                                std::string& out_value) {
    WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config{};
    if (!WinHttpGetIEProxyConfigForCurrentUser(&config)) winrt::throw_last_error();
    const std::unique_ptr<void, decltype(&GlobalFree)> pac(config.lpszAutoConfigUrl, GlobalFree);
    const std::unique_ptr<void, decltype(&GlobalFree)> proxy(config.lpszProxy, GlobalFree);
    const std::unique_ptr<void, decltype(&GlobalFree)> bypass(config.lpszProxyBypass, GlobalFree);

    const ProxyConfigFingerprint fingerprint{
        config.fAutoDetect != FALSE,
        config.lpszAutoConfigUrl ? config.lpszAutoConfigUrl : L"",
        config.lpszProxy ? config.lpszProxy : L"",
        config.lpszProxyBypass ? config.lpszProxyBypass : L"",
    };

    const bool wpad_only = config.fAutoDetect && !config.lpszAutoConfigUrl;
    bool run_autoproxy = config.fAutoDetect || config.lpszAutoConfigUrl;
    bool is_wpad_leader = false;

    struct WpadLeaderGuard {
      State& state;
      const std::shared_ptr<State>& self;
      bool active = false;
      ~WpadLeaderGuard() {
        if (!active) return;
        std::lock_guard<std::mutex> lock(state.mutex);
        state.wpad_probe_in_flight = false;
        state.DrainWpadWaitingLocked(self);
      }
    } wpad_guard{*this, self, false};

    {
      std::lock_guard<std::mutex> lock(mutex);
      if (!window) return ResolveOutcome::kParked;
      if (fingerprint != wpad_config) {
        // Invalidate cached negative WPAD state immediately on proxy config change.
        wpad_config = fingerprint;
        wpad_failed_cached = false;
        wpad_failed_until_ms = 0;
        wpad_consecutive_failures = 0;
      }
      if (wpad_only) {
        const ULONGLONG now = GetTickCount64();
        if (wpad_failed_cached && now < wpad_failed_until_ms) {
          run_autoproxy = false;
        } else if (wpad_probe_in_flight) {
          // Single-flight: park the request without holding a threadpool worker.
          wpad_waiting.push_back(request);
          return ResolveOutcome::kParked;
        } else {
          wpad_probe_in_flight = true;
          is_wpad_leader = true;
          wpad_guard.active = true;
        }
      }
    }

    if (run_autoproxy) {
      WINHTTP_AUTOPROXY_OPTIONS options{};
      if (config.lpszAutoConfigUrl) {
        options.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL;
        options.lpszAutoConfigUrl = config.lpszAutoConfigUrl;
      }
      if (config.fAutoDetect) {
        options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
        options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP |
            WINHTTP_AUTO_DETECT_TYPE_DNS_A;
      }
      options.fAutoLogonIfChallenged = FALSE;
      WINHTTP_PROXY_INFO resolved{};
      const BOOL ok = WinHttpGetProxyForUrl(session.get(), request->url.c_str(), &options, &resolved);
      const DWORD last_error = ok ? ERROR_SUCCESS : GetLastError();

      if (is_wpad_leader) {
        {
          std::lock_guard<std::mutex> lock(mutex);
          wpad_probe_in_flight = false;
          if (fingerprint == wpad_config) {
            if (ok) {
              wpad_failed_cached = false;
              wpad_failed_until_ms = 0;
              wpad_consecutive_failures = 0;
            } else {
              // Negative-cache all WPAD failures (timeouts, DNS, script errors,
              // autodetect failures) with exponential backoff until config changes.
              const size_t index = std::min(
                  wpad_consecutive_failures, kWpadNegativeCooldownsMs.size() - 1);
              const ULONGLONG cooldown = kWpadNegativeCooldownsMs[index];
              if (wpad_consecutive_failures < kWpadNegativeCooldownsMs.size()) {
                ++wpad_consecutive_failures;
              }
              wpad_failed_cached = true;
              wpad_failed_until_ms = GetTickCount64() + cooldown;
            }
          }
          DrainWpadWaitingLocked(self);
        }
        wpad_guard.active = false;
      }

      if (ok) {
        const std::unique_ptr<void, decltype(&GlobalFree)> resolved_proxy(resolved.lpszProxy, GlobalFree);
        const std::unique_ptr<void, decltype(&GlobalFree)> resolved_bypass(resolved.lpszProxyBypass, GlobalFree);
        if (resolved.dwAccessType == WINHTTP_ACCESS_TYPE_NO_PROXY ||
            !resolved.lpszProxy || (resolved.lpszProxyBypass &&
                Bypasses(resolved.lpszProxyBypass, request->host, request->scheme, request->port))) {
          out_value = "DIRECT";
        } else {
          out_value = ProxyList(resolved.lpszProxy, request->scheme);
        }
        return ResolveOutcome::kCompleted;
      }
      // Windows falls back to the user's manual proxy when PAC discovery fails.
      // An explicit PAC error without a manual proxy must remain observable.
      if (config.lpszAutoConfigUrl && !config.lpszProxy) {
        winrt::throw_hresult(HRESULT_FROM_WIN32(last_error));
      }
    }
    if (!config.lpszProxy || (config.lpszProxyBypass &&
        Bypasses(config.lpszProxyBypass, request->host, request->scheme, request->port))) {
      out_value = "DIRECT";
    } else {
      out_value = ProxyList(config.lpszProxy, request->scheme);
    }
    return ResolveOutcome::kCompleted;
  }

  static void CALLBACK RunWorker(PTP_CALLBACK_INSTANCE instance, void* context) {
    CallbackMayRunLong(instance);
    const std::unique_ptr<std::shared_ptr<State>> owner(
        static_cast<std::shared_ptr<State>*>(context));
    (*owner)->ResolveQueuedRequests(*owner);
  }

  void ResolveQueuedRequests(const std::shared_ptr<State>& self) {
    for (;;) {
      std::shared_ptr<Request> request;
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (!window || queued.empty()) {
          --workers;
          return;
        }
        request = std::move(queued.front());
        queued.pop_front();
      }
      std::string value, error;
      ResolveOutcome outcome = ResolveOutcome::kCompleted;
      try {
        std::call_once(session_once, [&] {
          auto handle = WinHttpOpen(L"DoujinAudio", WINHTTP_ACCESS_TYPE_NO_PROXY,
              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
          if (!handle) winrt::throw_last_error();
          session.reset(handle);
          WinHttpSetTimeouts(handle, 3500, 3500, 3500, 3500);
        });
        outcome = ResolveRequest(self, request, value);
      }
      catch (const winrt::hresult_error& e) { error = winrt::to_string(e.message()); }
      catch (const std::exception& e) { error = e.what(); }
      if (outcome == ResolveOutcome::kParked) continue;
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (!window) continue;
        request->value = std::move(value);
        request->error = std::move(error);
        request->completed = true;
      }
      // One posted message can deliver all completed requests on the UI thread.
      bool posted = false;
      bool aborted = false;
      for (int attempt = 0; attempt < 200; ++attempt) {
        {
          std::lock_guard<std::mutex> lock(mutex);
          if (!window || reply_posted) {
            aborted = true;
            break;
          }
          if (PostMessage(window, kReply, 0, 0)) {
            reply_posted = true;
            posted = true;
            break;
          }
          if (GetLastError() == ERROR_INVALID_WINDOW_HANDLE) {
            aborted = true;
            break;
          }
        }
        Sleep(10);
      }
      if (!posted && !aborted) {
        OutputDebugStringW(
            L"DoujinAudio: NetworkProxy failed to post reply message after 200 attempts\n");
      }
    }
  }
};

NetworkProxy::NetworkProxy(HWND window, flutter::BinaryMessenger* messenger)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "doujin_audio/network", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "resolveSystemProxy") { result->NotImplemented(); return; }
    const auto map = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const auto found = map ? map->find(Value("url")) : Map::const_iterator{};
    const auto text = map && found != map->end() ? std::get_if<std::string>(&found->second) : nullptr;
    std::wstring url, host, scheme;
    INTERNET_PORT port = 0;
    try {
      if (!text || text->empty() || text->find('\0') != std::string::npos) throw std::invalid_argument("url");
      url = winrt::to_hstring(*text).c_str();
      URL_COMPONENTS parts{};
      parts.dwStructSize = sizeof(parts);
      parts.dwSchemeLength = parts.dwHostNameLength = static_cast<DWORD>(-1);
      if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts) ||
          (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS) ||
          parts.dwHostNameLength == 0) throw std::invalid_argument("url");
      host = Lower(std::wstring(parts.lpszHostName, parts.dwHostNameLength));
      scheme = Lower(std::wstring(parts.lpszScheme, parts.dwSchemeLength));
      port = parts.nPort;
    } catch (const std::invalid_argument&) {
      Failure(*result, "invalid_argument", "A valid HTTP(S) url is required");
      return;
    } catch (const winrt::hresult_error& e) {
      Failure(*result, "platform_error", winrt::to_string(e.message()));
      return;
    } catch (const std::exception& e) {
      Failure(*result, "platform_error", e.what());
      return;
    }
    const auto request = std::make_shared<State::Request>();
    request->result = std::move(result);
    request->url = std::move(url);
    request->host = std::move(host);
    request->scheme = std::move(scheme);
    request->port = port;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->pending.push_back(request);
      state_->queued.push_back(request);
      if (state_->workers == State::kMaxWorkers) return;
      auto owner = std::make_unique<std::shared_ptr<State>>(state_);
      if (TrySubmitThreadpoolCallback(State::RunWorker, owner.get(), nullptr)) {
        owner.release();
        ++state_->workers;
        return;
      }
      if (state_->workers > 0) return;
      state_->pending.pop_back();
      state_->queued.pop_back();
    }
    Failure(*request->result, "platform_error", "Unable to schedule proxy resolution");
  });
}

NetworkProxy::~NetworkProxy() {
  channel_->SetMethodCallHandler(nullptr);
  std::vector<std::shared_ptr<State::Request>> pending;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->window = nullptr;
    state_->queued.clear();
    state_->wpad_waiting.clear();
    pending.swap(state_->pending);
  }
  // PAC/WPAD can block in Windows; do not stall engine teardown waiting for it.
  for (const auto& request : pending) {
    Failure(*request->result, "platform_error", "Window closed before proxy resolution completed");
    request->result.reset();
  }
}

void NetworkProxy::Reply() {
  std::vector<std::shared_ptr<State::Request>> completed;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->reply_posted = false;
    auto& pending = state_->pending;
    for (size_t i = 0; i < pending.size();) {
      if (!pending[i]->completed) {
        ++i;
        continue;
      }
      completed.push_back(std::move(pending[i]));
      if (i != pending.size() - 1) pending[i] = std::move(pending.back());
      pending.pop_back();
    }
  }
  for (const auto& request : completed) {
    if (!request->error.empty()) Failure(*request->result, "platform_error", request->error);
    else request->result->Success(Value(Map{{Value("ok"), Value(true)},
        {Value("value"), Value(request->value)}}));
    request->result.reset();
  }
}
