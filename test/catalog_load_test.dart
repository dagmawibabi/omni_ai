import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var fetches = 0;
  Completer<void>? hold;

  ModelCatalog catalog() {
    final google = GoogleProvider(
      apiKey: 'test',
      httpClient: MockClient((_) async {
        fetches++;
        await hold?.future;
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-test', 'displayName': 'Gemini Test', 'supportedGenerationMethods': ['generateContent']},
            ],
          }),
          200,
        );
      }),
    );
    return ModelCatalog(() => [google]);
  }

  setUp(() {
    fetches = 0;
    hold = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('a load with nothing to do ends, so a later refresh still fetches', () async {
    final c = catalog();
    c.models = [const ModelInfo(provider: 'gateway', modelId: 'old', name: 'Old')];
    c.fetchedAt = DateTime.now();

    await c.load();
    await Future<void>.delayed(Duration.zero);
    expect(fetches, 0);
    expect(c.isLoading, isFalse);

    await c.refresh();
    expect(fetches, 1);
    expect(c.ofProvider('google').map((m) => m.id), ['google:gemini-test']);
  });

  test('a refresh during a load fetches again when it ends', () async {
    final c = catalog();
    hold = Completer<void>();

    final first = c.load();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fetches, 1);

    final again = c.refresh();
    final shared = c.refresh();
    final plain = c.load();
    hold!.complete();
    await Future.wait([first, again, shared, plain]);

    expect(fetches, 2);
    expect(c.isLoading, isFalse);
  });
}
