#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Sets the native title bar text.
  //
  // MaterialApp's `title` is Dart-side only and never reaches the OS with the
  // stock runner, so the title bar used to keep showing the build's
  // `material_lab` while the app branded itself "Material Lab". Doing a no-op
  // when the text is unchanged avoids a needless frame repaint on every
  // rebuild, which happens on each locale switch.
  void SetTitle(const std::wstring& title);

  // Overrides the title bar's dark mode, or clears the override.
  //
  // Passing an empty optional hands control back to the Windows registry value
  // that `UpdateTheme` reads, which is what the app wants under
  // ThemeMode.system. Without this the app's own light/dark toggle left a light
  // title bar framing a dark app.
  void SetDarkModeOverride(const std::optional<bool>& dark);

  // Minimum size the user can drag the window to, in logical (96 DPI) pixels.
  //
  // Without a floor the window could be dragged to a few pixels across, which
  // left the shell sidebar and the data tables with nowhere to lay out.
  void SetMinTrackSize(const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme, unless
  // dark_mode_override_ says the app has taken over.
  void UpdateTheme();

  // Minimum size the user may drag the window to, in logical pixels. Clamped by
  // the monitor's own minimum tracking size during WM_GETMINMAXINFO.
  Size min_track_size_{480, 360};

  // Empty = follow the OS, otherwise force the contained value.
  std::optional<bool> dark_mode_override_;

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
