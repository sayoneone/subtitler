#ifndef RUNNER_HELP_WINDOW_H_
#define RUNNER_HELP_WINDOW_H_

#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// The "How to use" window (lib/ui/help/help_window.dart): a separate
// top-level window with its own Flutter engine that runs the helpMain entry
// point of lib/main.dart. It needs no plugins, so none are registered.
class HelpWindow : public Win32Window {
 public:
  HelpWindow();
  virtual ~HelpWindow();

  // False once the user has closed the window.
  bool IsOpen() { return GetHandle() != nullptr; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_HELP_WINDOW_H_
