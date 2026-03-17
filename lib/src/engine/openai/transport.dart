import 'models.dart';

abstract interface class OpenAiTtsTransport {
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request);
}
