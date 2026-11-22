#include "scheduled_tasks.h"
#include <windows.h>
#include <taskschd.h>
#include <comdef.h>
#include <winrt/base.h>
#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sddl.h>
#include <vector>

namespace {
int64_t Millis(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end() || std::holds_alternative<std::monostate>(it->second)) return 0;
  if (auto v = std::get_if<int64_t>(&it->second)) return *v;
  if (auto v = std::get_if<int32_t>(&it->second)) return *v;
  throw std::invalid_argument(key);
}

std::wstring Boundary(int64_t milliseconds) {
  ULARGE_INTEGER ticks;
  ticks.QuadPart = static_cast<uint64_t>(milliseconds) * 10000 + 116444736000000000ULL;
  FILETIME ft{ticks.LowPart, ticks.HighPart};
  SYSTEMTIME time{};
  FileTimeToSystemTime(&ft, &time);
  wchar_t text[40];
  swprintf_s(text, L"%04u-%02u-%02uT%02u:%02u:%02uZ", time.wYear, time.wMonth,
             time.wDay, time.wHour, time.wMinute, time.wSecond);
  return text;
}

struct ProcessTaskIdentity {
  std::wstring user_sid;
  std::wstring task_name;
  std::wstring executable;
};

const ProcessTaskIdentity& GetProcessTaskIdentity() {
  static const ProcessTaskIdentity identity = [] {
    ProcessTaskIdentity info;
    HANDLE raw_token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
      winrt::throw_last_error();
    }
    winrt::handle token(raw_token);
    DWORD token_size = 0;
    GetTokenInformation(token.get(), TokenUser, nullptr, 0, &token_size);
    if (token_size == 0) winrt::throw_last_error();
    std::vector<BYTE> token_data(token_size);
    if (!GetTokenInformation(token.get(), TokenUser, token_data.data(),
                             token_size, &token_size)) {
      winrt::throw_last_error();
    }
    LPWSTR raw_sid = nullptr;
    if (!ConvertSidToStringSidW(
            reinterpret_cast<TOKEN_USER*>(token_data.data())->User.Sid,
            &raw_sid)) {
      winrt::throw_last_error();
    }
    const std::unique_ptr<wchar_t, decltype(&LocalFree)> sid_guard(raw_sid, LocalFree);
    info.user_sid = raw_sid;
#ifdef _DEBUG
    info.task_name = L"DoujinAudio-Timer-Debug-" + info.user_sid;
#else
    info.task_name = L"DoujinAudio-Timer-" + info.user_sid;
#endif
    std::wstring path(MAX_PATH, L'\0');
    for (;;) {
      const DWORD length =
          GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
      if (length == 0) winrt::throw_last_error();
      if (length < path.size()) {
        path.resize(length);
        break;
      }
      if (path.size() >= 32768) winrt::throw_last_error();
      path.resize(std::min<size_t>(path.size() * 2, 32768));
    }
    info.executable = std::move(path);
    return info;
  }();
  return identity;
}

void ReplySuccess(flutter::MethodResult<flutter::EncodableValue>& result) {
  using Value = flutter::EncodableValue;
  result.Success(Value(flutter::EncodableMap{
      {Value("ok"), Value(true)}, {Value("value"), Value()}}));
}

class TaskSchedulerSession {
 public:
  void Sync(int64_t end, int64_t resume) {
    const bool reused = connected_;
    try {
      SyncOnce(end, resume);
    } catch (const winrt::hresult_error&) {
      if (!reused) throw;
      // Retry once with a fresh COM connection if the service restarted.
      Reset();
      SyncOnce(end, resume);
    } catch (const _com_error&) {
      if (!reused) throw;
      Reset();
      SyncOnce(end, resume);
    }
  }

  void Reset() {
    folder_ = nullptr;
    service_ = nullptr;
    connected_ = false;
  }

 private:
  void EnsureConnected() {
    if (connected_ && service_ && folder_) return;
    Reset();
    auto service = winrt::create_instance<ITaskService>(CLSID_TaskScheduler);
    winrt::check_hresult(
        service->Connect(_variant_t(), _variant_t(), _variant_t(), _variant_t()));
    winrt::com_ptr<ITaskFolder> folder;
    winrt::check_hresult(service->GetFolder(_bstr_t(L"\\"), folder.put()));
    service_ = std::move(service);
    folder_ = std::move(folder);
    connected_ = true;
  }

  void SyncOnce(int64_t end, int64_t resume) {
    using winrt::check_hresult;
    EnsureConnected();
    const auto& identity = GetProcessTaskIdentity();
    if (end <= 0 && resume <= 0) {
      const auto hr = folder_->DeleteTask(_bstr_t(identity.task_name.c_str()), 0);
      if (hr != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) check_hresult(hr);
      return;
    }
    winrt::com_ptr<ITaskDefinition> task;
    check_hresult(service_->NewTask(0, task.put()));
    winrt::com_ptr<IRegistrationInfo> registration;
    check_hresult(task->get_RegistrationInfo(registration.put()));
    check_hresult(registration->put_Description(
        _bstr_t(L"Restore pending playback timers for this user.")));
    winrt::com_ptr<IPrincipal> principal;
    check_hresult(task->get_Principal(principal.put()));
    check_hresult(principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN));
    check_hresult(principal->put_RunLevel(TASK_RUNLEVEL_LUA));
    winrt::com_ptr<ITaskSettings> settings;
    check_hresult(task->get_Settings(settings.put()));
    check_hresult(settings->put_WakeToRun(VARIANT_TRUE));
    // A missed timer must not launch the app after Windows starts again.
    check_hresult(settings->put_StartWhenAvailable(VARIANT_FALSE));
    check_hresult(settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE));
    check_hresult(settings->put_StopIfGoingOnBatteries(VARIANT_FALSE));
    check_hresult(settings->put_ExecutionTimeLimit(_bstr_t(L"PT0S")));
    check_hresult(settings->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW));
    winrt::com_ptr<ITriggerCollection> triggers;
    check_hresult(task->get_Triggers(triggers.put()));
    for (const auto at : {end, resume}) {
      if (at <= 0) continue;
      winrt::com_ptr<ITrigger> trigger;
      check_hresult(triggers->Create(TASK_TRIGGER_TIME, trigger.put()));
      check_hresult(trigger->put_StartBoundary(_bstr_t(Boundary(at).c_str())));
    }
    winrt::com_ptr<IActionCollection> actions;
    check_hresult(task->get_Actions(actions.put()));
    winrt::com_ptr<IAction> action;
    check_hresult(actions->Create(TASK_ACTION_EXEC, action.put()));
    auto exec = action.as<IExecAction>();
    check_hresult(exec->put_Path(_bstr_t(identity.executable.c_str())));
    check_hresult(exec->put_Arguments(_bstr_t(L"--background")));
    winrt::com_ptr<IRegisteredTask> registered;
    check_hresult(folder_->RegisterTaskDefinition(
        _bstr_t(identity.task_name.c_str()), task.get(), TASK_CREATE_OR_UPDATE,
        _variant_t(identity.user_sid.c_str()), _variant_t(),
        TASK_LOGON_INTERACTIVE_TOKEN, _variant_t(), registered.put()));
  }

  winrt::com_ptr<ITaskService> service_;
  winrt::com_ptr<ITaskFolder> folder_;
  bool connected_ = false;
};
}  // namespace

void SyncScheduledTasks(const flutter::EncodableMap& payload) {
  const auto end = Millis(payload, "timerEndsAtWallClockMs");
  const auto resume = Millis(payload, "autoResumeAtMs");
  TaskSchedulerSession session;
  session.Sync(end, resume);
}

struct ScheduledTasks::State {
  struct Request {
    int64_t end_ms = 0;
    int64_t resume_ms = 0;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
    std::string error;
    std::string error_code = "platform_error";
    bool completed = false;
  };

  std::mutex mutex;
  std::condition_variable changed;
  HWND window = nullptr;
  std::shared_ptr<Request> queued;
  std::vector<std::shared_ptr<Request>> pending;
  bool stopping = false;
  bool reply_posted = false;

  static void Run(const std::shared_ptr<State>& state) {
    const auto apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    {
      TaskSchedulerSession session;
      for (;;) {
        std::shared_ptr<Request> request;
        {
          std::unique_lock<std::mutex> lock(state->mutex);
          state->changed.wait(lock, [&] {
            return state->stopping || state->queued != nullptr;
          });
          if (state->stopping || !state->queued) break;
          request = std::move(state->queued);
        }
        std::string error;
        std::string error_code = "platform_error";
        try {
          if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) {
            winrt::check_hresult(apartment);
          }
          session.Sync(request->end_ms, request->resume_ms);
        } catch (const std::invalid_argument& e) {
          error = e.what();
          error_code = "invalid_argument";
        } catch (const winrt::hresult_error& e) {
          error = winrt::to_string(e.message());
        } catch (const _com_error& e) {
          error = winrt::to_string(e.ErrorMessage());
        } catch (const std::exception& e) {
          error = e.what();
        }
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->stopping || !state->window) break;
          request->error = std::move(error);
          request->error_code = std::move(error_code);
          request->completed = true;
        }
        bool posted = false;
        bool aborted = false;
        for (int attempt = 0; attempt < 200; ++attempt) {
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->stopping || !state->window || state->reply_posted) {
              aborted = true;
              break;
            }
            if (PostMessage(state->window, kReply, 0, 0)) {
              state->reply_posted = true;
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
              L"DoujinAudio: ScheduledTasks failed to post reply message after 200 attempts\n");
        }
      }
    }
    if (SUCCEEDED(apartment)) CoUninitialize();
  }
};

ScheduledTasks::ScheduledTasks(HWND window) : state_(std::make_shared<State>()) {
  state_->window = window;
}

ScheduledTasks::~ScheduledTasks() {
  std::vector<std::shared_ptr<State::Request>> pending;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->stopping = true;
    state_->window = nullptr;
    state_->queued.reset();
    pending.swap(state_->pending);
  }
  state_->changed.notify_one();
  // Task Scheduler COM calls cannot be cancelled reliably; detach the worker
  // and complete pending channel replies on the platform thread immediately.
  if (worker_.joinable()) worker_.detach();
  for (const auto& request : pending) {
    if (!request->result) continue;
    if (request->completed) {
      if (request->error.empty()) {
        ReplySuccess(*request->result);
      } else {
        request->result->Error(request->error_code, request->error);
      }
    } else {
      request->result->Error(
          "platform_error",
          "Window closed before scheduled task sync completed");
    }
    request->result.reset();
  }
}

void ScheduledTasks::Sync(const flutter::EncodableMap& payload,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  // Validate synchronously so malformed payloads fail immediately without
  // spawning the worker thread or displacing a valid queued sync.
  const auto end_ms = Millis(payload, "timerEndsAtWallClockMs");
  const auto resume_ms = Millis(payload, "autoResumeAtMs");
  std::shared_ptr<State::Request> superseded;
  bool rejected = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->stopping || !state_->window) {
      rejected = true;
    } else {
      if (!worker_.joinable()) {
        auto worker_state = state_;
        worker_ = std::thread([worker_state = std::move(worker_state)] {
          State::Run(worker_state);
        });
      }
      const auto request = std::make_shared<State::Request>();
      request->end_ms = end_ms;
      request->resume_ms = resume_ms;
      request->result = std::move(result);
      if (state_->queued) {
        superseded = std::move(state_->queued);
        auto& pending = state_->pending;
        pending.erase(std::remove(pending.begin(), pending.end(), superseded),
                      pending.end());
      }
      state_->queued = request;
      state_->pending.push_back(request);
    }
  }
  if (rejected) {
    result->Error("platform_error", "Window closed before scheduled task sync completed");
    result.reset();
    return;
  }
  state_->changed.notify_one();
  if (superseded && superseded->result) {
    ReplySuccess(*superseded->result);
    superseded->result.reset();
  }
}

void ScheduledTasks::Reply() {
  std::vector<std::shared_ptr<State::Request>> replies;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->reply_posted = false;
    auto& pending = state_->pending;
    for (auto it = pending.begin(); it != pending.end();) {
      if ((*it)->completed) {
        replies.push_back(std::move(*it));
        it = pending.erase(it);
      } else {
        ++it;
      }
    }
  }
  for (const auto& reply : replies) {
    if (!reply->result) continue;
    if (reply->error.empty()) {
      ReplySuccess(*reply->result);
    } else {
      reply->result->Error(reply->error_code, reply->error);
    }
    reply->result.reset();
  }
}
