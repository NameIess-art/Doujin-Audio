#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "desktop/scheduled_tasks.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (std::wstring(command_line) == L"--remove-timers") {
    CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    int result = EXIT_SUCCESS;
    try { SyncScheduledTasks(flutter::EncodableMap{}); } catch (...) { result = EXIT_FAILURE; }
    CoUninitialize(); return result;
  }
#ifdef _DEBUG
  constexpr auto mutex_name = L"Local\\DoujinAudio-Desktop-Debug";
  constexpr auto window_class = L"DOUJIN_AUDIO_WIN32_WINDOW_DEBUG";
#else
  constexpr auto mutex_name = L"Local\\DoujinAudio-Desktop";
  constexpr auto window_class = L"DOUJIN_AUDIO_WIN32_WINDOW";
#endif
  HANDLE singleton = CreateMutexW(nullptr,TRUE,mutex_name);
  if (!singleton) return EXIT_FAILURE;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    if (auto existing = FindWindowW(window_class,nullptr)) {
      PostMessage(existing,DesktopIntegration::kActivate,
        std::wstring(command_line).find(L"--background") != std::wstring::npos ? 1 : 0,0);
    }
    CloseHandle(singleton); return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Doujin Audio", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  window.Destroy();
  ::CoUninitialize();
  ReleaseMutex(singleton); CloseHandle(singleton);
  return EXIT_SUCCESS;
}
