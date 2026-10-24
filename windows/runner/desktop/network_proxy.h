#pragma once

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

// Reads the current user's proxy settings without changing system networking.
class NetworkProxy {
 public:
  static constexpr UINT kReply = WM_APP + 47;
  NetworkProxy(HWND window, flutter::BinaryMessenger* messenger);
  ~NetworkProxy();
  void Reply();

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
