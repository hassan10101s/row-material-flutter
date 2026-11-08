/// Presentation attaches the shared Save draft / Cancel dialog while the app
/// shell is mounted. Headless/background code never chooses on the user's behalf.
class OfflineWritePrompt {
  Future<bool> Function()? askSaveDraft;
  void Function(String message)? showNotice;
  void notify(String message) => showNotice?.call(message);
  bool _asking = false;
  Future<bool> choose() async {
    if (_asking) return false;
    _asking = true;
    try {
      return await askSaveDraft?.call() ?? false;
    } finally {
      _asking = false;
    }
  }
}
