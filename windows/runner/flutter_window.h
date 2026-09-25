#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // WM_COPYDATA tag of the message a repeated launch sends to the running
  // copy (see main.cpp): its command line arguments, each UTF-8 string
  // followed by '\0'.
  static constexpr ULONG_PTR kArgumentsMessage = 0x53554254;  // "SUBT"

  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |instance_marker| names the window property by which a repeated launch
  // finds this window.
  FlutterWindow(const flutter::DartProject& project,
                std::wstring instance_marker);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Arguments of a repeated launch go to Dart ("ru.subtitler/instance"),
  // or wait until Dart says it is ready to take them.
  void ReceiveArguments(const COPYDATASTRUCT& data);
  void SendArguments(const std::vector<std::string>& arguments);

  // The project to run.
  flutter::DartProject project_;

  std::wstring instance_marker_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      instance_channel_;
  bool dart_ready_ = false;
  std::vector<std::vector<std::string>> pending_arguments_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
