#include "scheduled_tasks.h"
#include <windows.h>
#include <taskschd.h>
#include <comdef.h>
#include <winrt/base.h>
#include <algorithm>
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
  ticks.QuadPart = static_cast<uint64_t>(milliseconds)*10000 + 116444736000000000ULL;
  FILETIME ft{ticks.LowPart, ticks.HighPart};
  SYSTEMTIME time{}; FileTimeToSystemTime(&ft, &time);
  wchar_t text[40];
  swprintf_s(text,L"%04u-%02u-%02uT%02u:%02u:%02uZ",time.wYear,time.wMonth,time.wDay,time.wHour,time.wMinute,time.wSecond);
  return text;
}
}

void SyncScheduledTasks(const flutter::EncodableMap& payload) {
  using winrt::check_hresult;
  auto service = winrt::create_instance<ITaskService>(CLSID_TaskScheduler);
  check_hresult(service->Connect(_variant_t(),_variant_t(),_variant_t(),_variant_t()));
  winrt::com_ptr<ITaskFolder> folder;
  check_hresult(service->GetFolder(_bstr_t(L"\\"),folder.put()));
  HANDLE raw_token;
  if (!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&raw_token)) winrt::throw_last_error();
  winrt::handle token(raw_token);
  DWORD token_size = 0;
  GetTokenInformation(token.get(),TokenUser,nullptr,0,&token_size);
  std::vector<BYTE> token_data(token_size);
  if (!GetTokenInformation(token.get(),TokenUser,token_data.data(),token_size,&token_size)) winrt::throw_last_error();
  LPWSTR raw_sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(token_data.data())->User.Sid,&raw_sid)) winrt::throw_last_error();
  const std::wstring user_sid(raw_sid); LocalFree(raw_sid);
#ifdef _DEBUG
  const auto task_name = L"DoujinAudio-Timer-Debug-" + user_sid;
#else
  const auto task_name = L"DoujinAudio-Timer-" + user_sid;
#endif
  const auto end = Millis(payload,"timerEndsAtWallClockMs");
  const auto resume = Millis(payload,"autoResumeAtMs");
  const auto mode = payload.find(flutter::EncodableValue("timerMode"));
  const bool armed = end > 0 || resume > 0 ||
      (mode != payload.end() && !std::holds_alternative<std::monostate>(mode->second));
  if (!armed) {
    auto hr = folder->DeleteTask(_bstr_t(task_name.c_str()),0);
    if (hr != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) check_hresult(hr);
    return;
  }
  winrt::com_ptr<ITaskDefinition> task;
  check_hresult(service->NewTask(0,task.put()));
  winrt::com_ptr<IRegistrationInfo> registration;
  check_hresult(task->get_RegistrationInfo(registration.put()));
  check_hresult(registration->put_Description(_bstr_t(L"Restore pending Doujin Audio playback timers for the current user.")));
  winrt::com_ptr<IPrincipal> principal;
  check_hresult(task->get_Principal(principal.put()));
  check_hresult(principal->put_LogonType(TASK_LOGON_INTERACTIVE_TOKEN));
  check_hresult(principal->put_RunLevel(TASK_RUNLEVEL_LUA));
  winrt::com_ptr<ITaskSettings> settings;
  check_hresult(task->get_Settings(settings.put()));
  check_hresult(settings->put_WakeToRun(VARIANT_TRUE));
  check_hresult(settings->put_StartWhenAvailable(VARIANT_TRUE));
  check_hresult(settings->put_DisallowStartIfOnBatteries(VARIANT_FALSE));
  check_hresult(settings->put_StopIfGoingOnBatteries(VARIANT_FALSE));
  check_hresult(settings->put_ExecutionTimeLimit(_bstr_t(L"PT0S")));
  check_hresult(settings->put_MultipleInstances(TASK_INSTANCES_IGNORE_NEW));
  winrt::com_ptr<ITriggerCollection> triggers;
  check_hresult(task->get_Triggers(triggers.put()));
  winrt::com_ptr<ITrigger> logon;
  check_hresult(triggers->Create(TASK_TRIGGER_LOGON,logon.put()));
  // Restrict the logon trigger to the same interactive user as the principal.
  auto logon_trigger = logon.as<ILogonTrigger>();
  check_hresult(logon_trigger->put_UserId(_bstr_t(user_sid.c_str())));
  for (const auto at : {end,resume}) {
    if (at <= 0) continue;
    winrt::com_ptr<ITrigger> trigger;
    check_hresult(triggers->Create(TASK_TRIGGER_TIME,trigger.put()));
    check_hresult(trigger->put_StartBoundary(_bstr_t(Boundary(at).c_str())));
  }
  winrt::com_ptr<IActionCollection> actions;
  check_hresult(task->get_Actions(actions.put()));
  winrt::com_ptr<IAction> action;
  check_hresult(actions->Create(TASK_ACTION_EXEC,action.put()));
  auto exec = action.as<IExecAction>();
  wchar_t executable[32768];
  if (!GetModuleFileNameW(nullptr,executable,32768)) winrt::throw_last_error();
  check_hresult(exec->put_Path(_bstr_t(executable)));
  check_hresult(exec->put_Arguments(_bstr_t(L"--background")));
  winrt::com_ptr<IRegisteredTask> registered;
  check_hresult(folder->RegisterTaskDefinition(_bstr_t(task_name.c_str()),task.get(),
      TASK_CREATE_OR_UPDATE,_variant_t(user_sid.c_str()),_variant_t(),TASK_LOGON_INTERACTIVE_TOKEN,
      _variant_t(),registered.put()));
}
