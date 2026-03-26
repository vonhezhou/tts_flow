import 'package:http/http.dart' as http;

import 'models.dart';

abstract interface class OpenAiApiClient {
  Future<http.StreamedResponse> send(OpenAiApiRequest request);
}
