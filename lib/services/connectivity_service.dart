import 'package:connectivity_plus/connectivity_plus.dart';

/// Monitors network connectivity for online/offline STT switching.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  bool _isOnline = false;
  bool get isOnline => _isOnline;

  Future<void> init() async {
    final result = await Connectivity().checkConnectivity();
    _isOnline = _resultIsOnline(result);
    Connectivity().onConnectivityChanged.listen((result) {
      _isOnline = _resultIsOnline(result);
    });
  }

  bool _resultIsOnline(List<ConnectivityResult> result) {
    return result.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);
  }
}
