abstract interface class AccessMonitor {
  void start();
  void stop();
}

class NoopAccessMonitor implements AccessMonitor {
  @override
  void start() {}
  @override
  void stop() {}
}
