import 'package:http/http.dart' as http;

// Adapter transport contract.

import 'models.dart';

abstract interface class OpenAiApiClient {
  Future<http.StreamedResponse> send(OpenAiApiRequest request);
}

/// Optional lifecycle contract for transports that own network resources.
abstract interface class OpenAiDisposableApiClient implements OpenAiApiClient {
  Future<void> dispose();
}
