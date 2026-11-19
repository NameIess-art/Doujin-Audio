#include "network_proxy.h"

#include <flutter/standard_method_codec.h>
#include <winhttp.h>
#include <shlwapi.h>
#include <winrt/base.h>
#include <algorithm>
#include <cwctype>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
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

std::string ProxyList(const std::wstring& proxies, const std::wstring& scheme) {
  std::string common, selected, socks;
  auto append = [](std::string& target, const std::string& item) {
    if (!target.empty()) target += "; ";
    target += item;
  };
  for (auto entry : SplitEntries(proxies, L";")) {
    if (Lower(entry) == L"direct") {
      append(common, "DIRECT");
      continue;
    }
    const auto ws = entry.find_first_of(L" \t\r\n");
    if (ws != std::wstring::npos) {
      const auto keyword = Lower(entry.substr(0, ws));
      auto rest = Trim(entry.substr(ws + 1));
      if (!rest.empty() &&
          (keyword == L"proxy" || keyword == L"http" || keyword == L"https" ||
           keyword == L"socks" || keyword == L"socks5")) {
        const auto protocol = rest.find(L"://");
        if (protocol != std::wstring::npos) rest = rest.substr(protocol + 3);
        if (rest.empty()) continue;
        const std::string prefix = keyword == L"proxy" ? "PROXY " : ProtocolPrefix(keyword);
        append(common, prefix + winrt::to_string(rest));
        continue;
      }
    }
    const auto equals = entry.find(L'=');
    std::wstring type;
    if (equals != std::wstring::npos) {
      type = Lower(Trim(entry.substr(0, equals)));
      entry = Trim(entry.substr(equals + 1));
    }
    if (entry.empty()) continue;
    const bool is_socks = type == L"socks" || type == L"socks5" || type == L"socks4";
    if (!type.empty() && type != scheme && !is_socks) continue;
    std::string prefix = type == L"socks5" ? "SOCKS5 " : is_socks ? "SOCKS " : "PROXY ";
    const auto protocol = entry.find(L"://");
    if (protocol != std::wstring::npos) {
      const auto name = Lower(entry.substr(0, protocol));
      prefix = ProtocolPrefix(name);
      entry = entry.substr(protocol + 3);
      if (entry.empty()) continue;
    }
    auto& target = type.empty() ? common : type == scheme ? selected : socks;
    append(target, prefix + winrt::to_string(entry));
  }
  return !selected.empty() ? selected : !common.empty() ? common :
      !socks.empty() ? socks : "DIRECT";
}

std::string Resolve(HINTERNET session, const std::wstring& url, const std::wstring& host,
                    const std::wstring& scheme, INTERNET_PORT port) {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config{};
  if (!WinHttpGetIEProxyConfigForCurrentUser(&config)) winrt::throw_last_error();
  const std::unique_ptr<void, decltype(&GlobalFree)> pac(config.lpszAutoConfigUrl, GlobalFree);
  const std::unique_ptr<void, decltype(&GlobalFree)> proxy(config.lpszProxy, GlobalFree);
  const std::unique_ptr<void, decltype(&GlobalFree)> bypass(config.lpszProxyBypass, GlobalFree);
  if (config.fAutoDetect || config.lpszAutoConfigUrl) {
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
    if (WinHttpGetProxyForUrl(session, url.c_str(), &options, &resolved)) {
      const std::unique_ptr<void, decltype(&GlobalFree)> resolved_proxy(resolved.lpszProxy, GlobalFree);
      const std::unique_ptr<void, decltype(&GlobalFree)> resolved_bypass(resolved.lpszProxyBypass, GlobalFree);
      if (resolved.dwAccessType == WINHTTP_ACCESS_TYPE_NO_PROXY ||
          !resolved.lpszProxy || (resolved.lpszProxyBypass &&
              Bypasses(resolved.lpszProxyBypass, host, scheme, port))) return "DIRECT";
      return ProxyList(resolved.lpszProxy, scheme);
    }
    // Windows falls back to the user's manual proxy when PAC discovery fails.
    // An explicit PAC error without a manual proxy must remain observable.
    if (config.lpszAutoConfigUrl && !config.lpszProxy) winrt::throw_last_error();
  }
  if (!config.lpszProxy || (config.lpszProxyBypass &&
      Bypasses(config.lpszProxyBypass, host, scheme, port))) return "DIRECT";
  return ProxyList(config.lpszProxy, scheme);
}
}

struct NetworkProxy::State {
  struct Request {
    std::unique_ptr<Result> result;
    std::string value, error;
    bool completed = false;
  };
  std::mutex mutex;
  std::once_flag session_once;
  // WinHTTP caches PAC discovery per session. Reuse it across media requests.
  std::unique_ptr<void, decltype(&WinHttpCloseHandle)> session{nullptr, WinHttpCloseHandle};
  HWND window = nullptr;
  std::vector<std::shared_ptr<Request>> pending;
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
    } catch (const std::exception&) { Failure(*result, "invalid_argument", "A valid HTTP(S) url is required"); return; }
    const auto request = std::make_shared<State::Request>();
    request->result = std::move(result);
    { std::lock_guard<std::mutex> lock(state_->mutex); state_->pending.push_back(request); }
    const auto state = state_;
    try {
      std::thread([state, request, url, host, scheme, port] {
        std::string value, error;
        try {
          std::call_once(state->session_once, [&] {
            auto session = WinHttpOpen(L"DoujinAudio", WINHTTP_ACCESS_TYPE_NO_PROXY,
                WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
            if (!session) winrt::throw_last_error();
            state->session.reset(session);
            WinHttpSetTimeouts(session, 10000, 10000, 10000, 10000);
          });
          value = Resolve(state->session.get(), url, host, scheme, port);
        }
        catch (const winrt::hresult_error& e) { error = winrt::to_string(e.message()); }
        catch (const std::exception& e) { error = e.what(); }
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->window) return;
          request->value = std::move(value);
          request->error = std::move(error);
          request->completed = true;
        }
        for (int attempt = 0; attempt < 200; ++attempt) {
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->window) return;
            if (PostMessage(state->window, kReply, 0, 0)) return;
          }
          if (GetLastError() == ERROR_INVALID_WINDOW_HANDLE) return;
          Sleep(10);
        }
      }).detach();
    } catch (const std::exception& e) {
      request->error = e.what(); request->completed = true; Reply();
    }
  });
}

NetworkProxy::~NetworkProxy() {
  channel_->SetMethodCallHandler(nullptr);
  std::vector<std::shared_ptr<State::Request>> pending;
  { std::lock_guard<std::mutex> lock(state_->mutex); state_->window = nullptr; pending.swap(state_->pending); }
  // PAC/WPAD can block in Windows; do not stall engine teardown waiting for it.
  for (const auto& request : pending) {
    Failure(*request->result, "windows_error", "Window closed before proxy resolution completed");
    request->result.reset();
  }
}

void NetworkProxy::Reply() {
  std::vector<std::shared_ptr<State::Request>> completed;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    auto& pending = state_->pending;
    for (auto it = pending.begin(); it != pending.end();) {
      if ((*it)->completed) { completed.push_back(*it); it = pending.erase(it); }
      else ++it;
    }
  }
  for (const auto& request : completed) {
    if (!request->error.empty()) Failure(*request->result, "windows_error", request->error);
    else request->result->Success(Value(Map{{Value("ok"), Value(true)},
        {Value("value"), Value(request->value)}}));
    request->result.reset();
  }
}
