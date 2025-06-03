class RateLimiter {

  RateLimiter({required this.maxRequests, required this.timeWindow});
  final int maxRequests;
  final Duration timeWindow;
  final List<DateTime> _requests = [];

  Future<void> checkRateLimit() async {
    final now = DateTime.now();
    _requests.removeWhere((time) => now.difference(time) > timeWindow);

    if (_requests.length >= maxRequests) {
      final waitTime = timeWindow - now.difference(_requests.first);
      await Future<void>.delayed(waitTime); // Fixed: Explicit type
    }

    _requests.add(now);
  }

  void reset() {
    _requests.clear();
  }
}
