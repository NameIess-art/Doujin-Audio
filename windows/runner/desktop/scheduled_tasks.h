#pragma once
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <windows.h>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
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
  struct Request {
    int64_t end_ms = 0;
    int64_t resume_ms = 0;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
    std::string error;
    std::string error_code = "windows_error";
  };
  void Run();
  HWND window_;
  std::mutex mutex_;
  std::condition_variable changed_;
  std::optional<Request> pending_;
  std::deque<Request> completed_;
  bool stopping_ = false;
  std::thread worker_;
};
