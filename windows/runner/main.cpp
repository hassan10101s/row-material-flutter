#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

namespace {

// The app's design size, and the size it would like to open at.
constexpr int kDesignWidth = 1280;
constexpr int kDesignHeight = 720;

// Smallest window the app lays out sanely in, in logical pixels. Matches
// Win32Window's default minimum tracking size.
constexpr int kMinWidth = 480;
constexpr int kMinHeight = 360;

// Fraction of the work area to use when the design size does not fit.
constexpr double kWorkAreaFill = 0.9;

// Chooses the initial window rectangle, in logical pixels, for the primary
// monitor.
//
// The runner previously opened at a hardcoded 1280x720 pinned to (10,10). On a
// 1366x768 laptop that is taller than the work area, so the bottom of the app
// was below the taskbar with no way to reach it, and the window never appeared
// centred on any display. Now the design size is used when it fits and the
// window is centred in the work area either way.
//
// Returns the origin and size to hand to Win32Window::Create, which scales both
// by the monitor's DPI.
void FitInitialWindow(Win32Window::Point* origin, Win32Window::Size* size) {
  HMONITOR monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);

  UINT dpi = 96;
  int work_width = kDesignWidth;
  int work_height = kDesignHeight;

  if (monitor != nullptr && GetMonitorInfoW(monitor, &info)) {
    const UINT monitor_dpi = FlutterDesktopGetDpiForMonitor(monitor);
    if (monitor_dpi != 0) {
      dpi = monitor_dpi;
    }
    // The work area is physical; the origin and size below are logical, and
    // Create() multiplies them by this same factor.
    const double scale = dpi / 96.0;
    work_width = static_cast<int>((info.rcWork.right - info.rcWork.left) / scale);
    work_height = static_cast<int>((info.rcWork.bottom - info.rcWork.top) / scale);
  }

  int width = std::min(kDesignWidth, static_cast<int>(work_width * kWorkAreaFill));
  int height = std::min(kDesignHeight, static_cast<int>(work_height * kWorkAreaFill));

  // Clamp back up rather than letting a tiny work area produce a window the
  // min tracking size will immediately refuse to display.
  width = std::max(width, std::min(kMinWidth, work_width));
  height = std::max(height, std::min(kMinHeight, work_height));

  *origin = Win32Window::Point(
      static_cast<unsigned int>(std::max(0, (work_width - width) / 2)),
      static_cast<unsigned int>(std::max(0, (work_height - height) / 2)));
  *size = Win32Window::Size(static_cast<unsigned int>(width),
                            static_cast<unsigned int>(height));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  Win32Window::Size size(kDesignWidth, kDesignHeight);
  FitInitialWindow(&origin, &size);
  // The app replaces this from Dart as soon as the locale resolves, so the
  // bilingual title is not duplicated here. This is only what shows for the
  // frames before the first one is built.
  if (!window.Create(L"Material Lab", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
