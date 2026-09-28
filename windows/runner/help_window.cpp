#include "help_window.h"

#include <flutter/dart_project.h>

#include <optional>

HelpWindow::HelpWindow() {}

HelpWindow::~HelpWindow() {}

bool HelpWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  flutter::DartProject project(L"data");
  // lib/main.dart, marked @pragma('vm:entry-point') so that the AOT build
  // keeps it.
  project.set_dart_entrypoint("helpMain");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Shown with its first frame, not blank before it.
  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void HelpWindow::OnDestroy() {
  flutter_controller_ = nullptr;
  Win32Window::OnDestroy();
}

LRESULT
HelpWindow::MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam,
                           LPARAM const lparam) noexcept {
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
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
