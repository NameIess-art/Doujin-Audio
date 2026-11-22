#pragma once
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <windows.h>
#include <memory>
#include <thread>

// Schedules only wakeups. Timer state and execution stay in the Dart runtime.
// Also used by the installer cleanup command before a window is created.
void SyncScheduledTasks(const flutter::EncodableMap& payload);

class ScheduledTasks {
 public:
  static constexpr UINT kReply = WM_APP + 45;
  explicit ScheduledTasks(HWND window);
  ~ScheduledTasks();
  void Sync(const flutter::EncodableMap& payload,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
  void Reply();

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::thread worker_;
};
