import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../constants/app_strings.dart';
import '../utils/app_exceptions.dart';

/// A transport interruption says nothing about a write's commit outcome.
class TransientNetworkError extends AppError {
  TransientNetworkError(this.cause)
    : super(
        AppText.t(
          'تعذر الاتصال بالسيرفر مؤقتًا. البيانات المحفوظة ما زالت متاحة.',
          'The server connection was interrupted. Cached data remains available.',
        ),
      );

  final Object cause;
}

bool isTransientNetworkFailure(Object error) =>
    error is TransientNetworkError ||
    error is http.ClientException ||
    error is SocketException ||
    error is TimeoutException ||
    error is HttpException;
