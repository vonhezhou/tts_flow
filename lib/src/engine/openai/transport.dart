import 'models.dart';

abstract interface class OpenAiTtsTransport {
  Stream<List<int>> synthesize(OpenAiTtsRequest request);
}
