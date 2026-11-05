import 'dart:developer' as developer;

class AppLog {
  AppLog._();

  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    developer.log(
      '$message${error == null ? '' : ' (${error.runtimeType})'}',
      name: 'ARTFOXEL',
      error: error?.runtimeType.toString(),
      stackTrace: stackTrace,
      level: 1000,
    );
  }
}
