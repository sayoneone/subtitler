#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::wstring instance_marker)
    : project_(project), instance_marker_(std::move(instance_marker)) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Arguments of repeated launches (lib/app/launch_args.dart). Dart calls
  // "ready" once it listens; until then they are kept here, so a video
  // dropped on the icon while the program is starting is not lost.
  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "ru.subtitler/instance",
          &flutter::StandardMethodCodec::GetInstance());
  instance_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "ready") {
          result->NotImplemented();
          return;
        }
        dart_ready_ = true;
        for (const auto& arguments : pending_arguments_) {
          SendArguments(arguments);
        }
        pending_arguments_.clear();
        result->Success();
      });
  // A repeated launch looks for the window with this property (main.cpp).
  ::SetPropW(GetHandle(), instance_marker_.c_str(),
             reinterpret_cast<HANDLE>(1));

  // "How to use" (lib/ui/help/help_window.dart): {"title": <UTF-8>}.
  help_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "ru.subtitler/help",
          &flutter::StandardMethodCodec::GetInstance());
  help_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "open") {
          result->NotImplemented();
          return;
        }
        std::wstring title = L"Subtitler";
        if (const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          auto found = args->find(flutter::EncodableValue("title"));
          if (found != args->end()) {
            if (const auto* text = std::get_if<std::string>(&found->second)) {
              title = Utf16FromUtf8(*text);
            }
          }
        }
        result->Success(flutter::EncodableValue(OpenHelp(title)));
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  instance_channel_ = nullptr;
  help_channel_ = nullptr;
  // The program ends with its main window: the guide goes with it.
  help_window_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::OpenHelp(const std::wstring& title) {
  if (help_window_ && help_window_->IsOpen()) {
    HWND help = help_window_->GetHandle();
    if (::IsIconic(help)) {
      ::ShowWindow(help, SW_RESTORE);
    }
    ::SetForegroundWindow(help);
    return true;
  }

  // A closed window is not reused: it has lost its Flutter engine.
  help_window_ = std::make_unique<HelpWindow>();
  RECT main_frame{};
  ::GetWindowRect(GetHandle(), &main_frame);
  const Win32Window::Point origin(static_cast<unsigned int>(main_frame.left),
                                  static_cast<unsigned int>(main_frame.top));
  if (!help_window_->Create(title, origin, Win32Window::Size(900, 860))) {
    help_window_ = nullptr;
    return false;
  }

  // Create() centers the window on the screen, over the main window and
  // its key field. On the first launch both are needed, so the guide goes
  // to the right edge of the main window's screen.
  HWND help = help_window_->GetHandle();
  HMONITOR monitor = ::MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  RECT help_frame{};
  if (::GetMonitorInfo(monitor, &monitor_info) &&
      ::GetWindowRect(help, &help_frame)) {
    const RECT& work = monitor_info.rcWork;
    const LONG width = help_frame.right - help_frame.left;
    const LONG margin = (work.right - work.left) / 100;
    const LONG x = std::max(work.left, work.right - width - margin);
    const LONG y = work.top + std::min(margin, help_frame.top - work.top);
    ::SetWindowPos(help, nullptr, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
  return true;
}

void FlutterWindow::ReceiveArguments(const COPYDATASTRUCT& data) {
  std::vector<std::string> arguments;
  const char* bytes = static_cast<const char*>(data.lpData);
  size_t start = 0;
  for (size_t i = 0; bytes != nullptr && i < data.cbData; ++i) {
    if (bytes[i] == '\0') {
      arguments.emplace_back(bytes + start, i - start);
      start = i + 1;
    }
  }
  if (dart_ready_) {
    SendArguments(arguments);
  } else {
    pending_arguments_.push_back(std::move(arguments));
  }
}

void FlutterWindow::SendArguments(const std::vector<std::string>& arguments) {
  if (!instance_channel_) {
    return;
  }
  flutter::EncodableList list;
  for (const auto& argument : arguments) {
    list.emplace_back(argument);
  }
  instance_channel_->InvokeMethod(
      "open", std::make_unique<flutter::EncodableValue>(std::move(list)));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data != nullptr && data->dwData == kArgumentsMessage) {
        ReceiveArguments(*data);
        // The sender allowed this process to take the foreground
        // (AllowSetForegroundWindow in main.cpp).
        if (::IsIconic(hwnd)) {
          ::ShowWindow(hwnd, SW_RESTORE);
        }
        ::SetForegroundWindow(hwnd);
        return TRUE;
      }
      break;
    }
    case WM_DESTROY:
      // Properties must be removed before the window is gone.
      ::RemovePropW(hwnd, instance_marker_.c_str());
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
