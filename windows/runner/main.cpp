#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

struct WindowSearch {
  const wchar_t* marker;
  HWND found;
};

BOOL CALLBACK FindMarkedWindow(HWND window, LPARAM lparam) {
  auto* search = reinterpret_cast<WindowSearch*>(lparam);
  if (::GetPropW(window, search->marker) != nullptr) {
    search->found = window;
    return FALSE;
  }
  return TRUE;
}

// Hands |arguments| to the copy that is already running and brings its
// window to the front. Returns false if its window did not appear in time.
bool ForwardToRunningCopy(const std::wstring& marker,
                          const std::vector<std::string>& arguments) {
  WindowSearch search{marker.c_str(), nullptr};
  // The running copy may have just started and not created its window yet.
  for (int attempt = 0; attempt < 50 && search.found == nullptr; ++attempt) {
    ::EnumWindows(FindMarkedWindow, reinterpret_cast<LPARAM>(&search));
    if (search.found == nullptr) {
      ::Sleep(100);
    }
  }
  HWND window = search.found;
  if (window == nullptr) {
    return false;
  }

  // This process was started by the shell the user has just worked with, so
  // it may set the foreground window; pass that right to the running copy.
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  ::AllowSetForegroundWindow(process_id);

  std::string payload;
  for (const auto& argument : arguments) {
    payload.append(argument);
    payload.push_back('\0');
  }
  COPYDATASTRUCT data{};
  data.dwData = FlutterWindow::kArgumentsMessage;
  data.cbData = static_cast<DWORD>(payload.size());
  data.lpData = payload.empty() ? nullptr : payload.data();
  DWORD_PTR result = 0;
  ::SendMessageTimeoutW(window, WM_COPYDATA, 0,
                        reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                        5000, &result);

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // One copy per user session. A video dropped on the program's icon while
  // the program is open must go to the open window: a second copy would
  // share the log, the work folder and the settings with the first one and
  // could process (and pay for) the same video twice.
  const std::wstring instance_name = GetInstanceName();
  const std::wstring window_marker = instance_name + L".window";
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, (L"Local\\" + instance_name).c_str());
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS &&
      ForwardToRunningCopy(window_marker, command_line_arguments)) {
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }
  // No window of the running copy within 5 s (it hangs while starting):
  // better a second window than a program that does not open at all.

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, window_marker);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Subtitler", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
