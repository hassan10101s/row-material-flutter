#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/standard_message_codec.h"

const char FlutterWindow::kWindowChannelName[] = "material_lab/window";

namespace {

// Converts a UTF-8 string from Dart into a wide string for the Win32 API.
//
// The app's title is bilingual, so an Arabic title reaches the runner as UTF-8
// and has to be widened before SetWindowTextW, which would otherwise render
// replacement boxes.
std::wstring WidenUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return L"";
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                           static_cast<int>(utf8.size()),
                                           nullptr, 0);
  if (length <= 0) {
    return L"";
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                        static_cast<int>(utf8.size()), wide.data(), length);
  return wide;
}

// Reads a key out of the method call's argument map.
//
// EncodableValue derives from std::variant rather than aliasing it, so
// std::get_if needs the base type spelled out to deduce.
template <typename T>
const T* ArgumentAt(const flutter::EncodableMap* map, const char* key) {
  if (map == nullptr) {
    return nullptr;
  }
  const auto entry = map->find(flutter::EncodableValue(key));
  if (entry == map->end()) {
    return nullptr;
  }
  return std::get_if<T>(
      static_cast<const flutter::internal::EncodableValueVariant*>(&entry->second));
}

// Whether the map carries |key| at all, as distinct from carrying it as null.
bool HasArgument(const flutter::EncodableMap* map, const char* key) {
  return map != nullptr &&
         map->find(flutter::EncodableValue(key)) != map->end();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          FlutterWindow::kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance(
              &flutter::StandardCodecSerializer::GetInstance()));
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        OnWindowChannelCall(call, std::move(result));
      });

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
  // The channel holds a raw pointer into the engine's messenger, which is torn
  // down with the controller. It has to go first or the handler outlives the
  // engine it points at.
  window_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnWindowChannelCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // EncodableValue exposes no typed accessors in this client wrapper, so pull
  // the map out first and then look each key up by name.
  const flutter::EncodableValue* arguments = call.arguments();
  const flutter::EncodableMap* map =
      arguments == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableMap>(
                static_cast<const flutter::internal::EncodableValueVariant*>(
                    arguments));

  if (call.method_name() == "setTitle") {
    const std::string* title = ArgumentAt<std::string>(map, "title");
    if (title == nullptr) {
      result->Error("bad_arguments", "setTitle requires a string 'title'.");
      return;
    }
    SetTitle(WidenUtf8(*title));
    result->Success();
    return;
  }

  if (call.method_name() == "setDarkMode") {
    if (map == nullptr) {
      result->Error("bad_arguments", "setDarkMode requires a 'dark' argument.");
      return;
    }
    // An absent or null 'dark' means "stop overriding, follow the OS", which is
    // what ThemeMode.system needs.
    if (!HasArgument(map, "dark") ||
        map->find(flutter::EncodableValue("dark"))->second.IsNull()) {
      SetDarkModeOverride(std::nullopt);
      result->Success();
      return;
    }
    const bool* dark = ArgumentAt<bool>(map, "dark");
    if (dark == nullptr) {
      result->Error("bad_arguments",
                    "setDarkMode 'dark' must be a bool or null.");
      return;
    }
    SetDarkModeOverride(*dark);
    result->Success();
    return;
  }

  result->NotImplemented();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
