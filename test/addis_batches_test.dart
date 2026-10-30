import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_ai/omni_ai.dart';

const batchId = 'batch_0123';
const fileId = 'file_0123';
const api = 'https://api.addisassistant.com/api/v1';

Map<String, dynamic> batch([Map<String, dynamic> overrides = const {}]) => {
      'id': batchId,
      'object': 'batch',
      'endpoint': '/v1/voice/generations',
      'input_file_id': fileId,
      'completion_window': '24h',
      'status': 'validating',
      'status_reason': null,
      'output_file_id': null,
      'error_file_id': null,
      'created_at': '2026-10-16T09:00:00Z',
      'expires_at': '2026-10-17T09:00:00Z',
      'request_counts': {'total': 2, 'succeeded': 0, 'failed': 0, 'expired': 0, 'cancelled': 0, 'pending': 2},
      'pricing': {'tier': 'batch', 'currency': 'ETB', 'unit': 'audio_minute', 'unit_price': 2.5, 'list_unit_price': 5},
      'estimated_cost': 5,
      'charged_cost': 0,
      'metadata': {'project_name': 'ch3'},
      ...overrides,
    };

http.Response ok(Object body, {int status = 200}) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

AddisAiProvider withClient(Future<http.Response> Function(http.Request req) handler) =>
    AddisAiProvider(apiKey: 'a-key', httpClient: MockClient(handler));

/// [MockClient] flattens multipart into [http.Request.body]; these find the parts.
String part(http.Request req, String name) =>
    RegExp('name="$name"(?:; filename="[^"]*")?\\r\\n(?:content-type: [^\\r]*\\r\\n)?\\r\\n([\\s\\S]*?)\\r\\n--')
        .firstMatch(utf8.decode(req.bodyBytes))![1]!;

const two = [
  AddisBatchRequest(customId: 'a', text: 'ሰላም', voiceId: 'selam-warm', language: 'am'),
  AddisBatchRequest(customId: 'b', text: 'Akkam', voiceId: 'om-bikila', language: 'om', outputFormat: 'wav_44100', speed: 60),
];

void main() {
  group('toJsonl', () {
    test('writes one line per request, with the default format', () {
      final lines = const LineSplitter().convert(AddisBatches.toJsonl(two)).map(jsonDecode).toList();
      expect(lines, [
        {
          'custom_id': 'a',
          'body': {'text': 'ሰላም', 'voice_id': 'selam-warm', 'language': 'am', 'output_format': 'mp3_44100'},
        },
        {
          'custom_id': 'b',
          'body': {
            'text': 'Akkam',
            'voice_id': 'om-bikila',
            'language': 'om',
            'output_format': 'wav_44100',
            'voice_settings': {'speed': 60},
          },
        },
      ]);
      expect(AddisBatches.toJsonl(two), endsWith('\n'));
    });

    test('rejects what the API would reject', () {
      AddisBatchRequest r({String id = 'a', String text = 'x', String voice = 'v', String lang = 'am'}) =>
          AddisBatchRequest(customId: id, text: text, voiceId: voice, language: lang);
      expect(() => AddisBatches.toJsonl([]), throwsArgumentError);
      expect(() => AddisBatches.toJsonl([r(), r()]), throwsArgumentError);
      expect(() => AddisBatches.toJsonl([r(id: '')]), throwsArgumentError);
      expect(() => AddisBatches.toJsonl([r(text: '  ')]), throwsArgumentError);
      expect(() => AddisBatches.toJsonl([r(lang: 'en')]), throwsArgumentError);
      expect(() => AddisBatches.toJsonl([r(voice: 'ti-berhane', lang: 'am')]), throwsArgumentError);
      expect(AddisBatches.toJsonl([r(voice: 'ti-berhane', lang: 'ti')]), contains('ti-berhane'));
      expect(() => AddisBatches.toJsonl([for (var i = 0; i <= AddisBatches.maxRequests; i++) r(id: '$i')]), throwsArgumentError);
    });
  });

  group('create', () {
    test('uploads the requests, then creates the batch with an idempotency key', () async {
      final calls = <http.Request>[];
      final addis = withClient((req) async {
        calls.add(req);
        return req.url.path.endsWith('/files')
            ? ok({'id': fileId, 'object': 'file', 'purpose': 'batch_input', 'status': 'ready', 'filename': 'batch.jsonl'}, status: 201)
            : ok(batch(), status: 201);
      });

      final b = await addis.batches.createFromRequests(two, metadata: {'project_name': 'ch3'});

      expect(calls, hasLength(2));
      expect(calls[0].url.toString(), '$api/files');
      expect(calls[0].headers['x-api-key'], 'a-key');
      expect(part(calls[0], 'purpose'), 'batch_input');
      final body = utf8.decode(calls[0].bodyBytes);
      expect(body, contains('filename="batch.jsonl"'));
      expect(body.toLowerCase(), contains('content-type: application/jsonl'));
      expect(body, contains('ሰላም'));

      expect(calls[1].url.toString(), '$api/batches');
      expect(jsonDecode(calls[1].body), {
        'input_file_id': fileId,
        'endpoint': '/v1/voice/generations',
        'completion_window': '24h',
        'metadata': {'project_name': 'ch3'},
      });
      expect(calls[1].headers['Idempotency-Key'], matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));

      expect(b.id, batchId);
      expect(b.status, 'validating');
      expect(b.isFinished, isFalse);
      expect(b.unitPrice, 2.5);
      expect(b.currency, 'ETB');
      expect(b.counts.pending, 2);
      expect(b.metadata, {'project_name': 'ch3'});
      expect(b.expiresAt, DateTime.utc(2026, 10, 17, 9));
    });

    test('sends nothing when a request is invalid', () async {
      var calls = 0;
      final addis = withClient((req) async {
        calls++;
        return ok({});
      });
      await expectLater(addis.batches.createFromRequests(const []), throwsArgumentError);
      expect(calls, 0);
    });

    test('a retry reuses the idempotency key, so it can\'t make a second batch', () async {
      final keys = <String?>[];
      final addis = withClient((req) async {
        keys.add(req.headers['Idempotency-Key']);
        return keys.length == 1 ? http.Response('{"error":{"message":"busy"}}', 503, headers: {'retry-after': '0'}) : ok(batch());
      });
      await addis.batches.create(inputFileId: fileId);
      expect(keys, hasLength(2));
      expect(keys[0], isNotNull);
      expect(keys[0], keys[1]);
    });

    test('a client error is not retried and reads well', () async {
      var calls = 0;
      final addis = withClient((req) async {
        calls++;
        return http.Response('{"error":{"code":"insufficient_credits","message":"Top up first."}}', 402);
      });
      await expectLater(
        addis.batches.create(inputFileId: fileId),
        throwsA(isA<AiException>().having((e) => e.message, 'message', 'Top up first.').having((e) => e.statusCode, 'status', 402)),
      );
      expect(calls, 1);
    });

    test('needs a key', () async {
      final addis = AddisAiProvider(httpClient: MockClient((_) async => ok({})));
      await expectLater(addis.batches.create(inputFileId: fileId), throwsA(isA<MissingApiKeyException>()));
    });
  });

  group('reading', () {
    test('retrieve and cancel hit the right addresses', () async {
      final calls = <http.Request>[];
      final addis = withClient((req) async {
        calls.add(req);
        return ok(batch({'status': req.method == 'POST' ? 'cancelling' : 'in_progress'}));
      });
      expect((await addis.batches.retrieve(batchId)).status, 'in_progress');
      expect((await addis.batches.cancel(batchId)).status, 'cancelling');
      expect(calls[0].url.toString(), '$api/batches/$batchId');
      expect(calls[1].method, 'POST');
      expect(calls[1].url.toString(), '$api/batches/$batchId/cancel');
    });

    test('list follows last_id across pages', () async {
      final urls = <String>[];
      final addis = withClient((req) async {
        urls.add(req.url.toString());
        return urls.length == 1
            ? ok({
                'data': [batch()],
                'has_more': true,
                'last_id': batchId
              })
            : ok({
                'data': [
                  batch({'id': 'batch_2'})
                ],
                'has_more': false,
                'last_id': 'batch_2'
              });
      });
      final ids = await addis.batches.list(limit: 1).map((b) => b.id).toList();
      expect(ids, [batchId, 'batch_2']);
      expect(urls[1], '$api/batches?limit=1&after=$batchId');
    });

    test('list stops fetching when the reader stops', () async {
      var calls = 0;
      final addis = withClient((req) async {
        calls++;
        return ok({
          'data': [batch()],
          'has_more': true,
          'last_id': batchId
        });
      });
      await addis.batches.list().first;
      expect(calls, 1);
    });

    test('requests pages by line number and keeps the status filter', () async {
      final urls = <String>[];
      final addis = withClient((req) async {
        urls.add(req.url.toString());
        return urls.length == 1
            ? ok({
                'data': [
                  {
                    'custom_id': 'a',
                    'line': 1,
                    'status': 'failed',
                    'error': {'code': 'voice_not_found', 'message': 'm'},
                    'result': null,
                    'cost': null
                  },
                ],
                'has_more': true,
              })
            : ok({'data': [], 'has_more': false});
      });
      final rows = await addis.batches.requests(batchId, status: 'failed').toList();
      expect(rows.single.customId, 'a');
      expect(rows.single.error?.code, 'voice_not_found');
      expect(urls[1], contains('status=failed'));
      expect(urls[1], contains('after=1'));
    });
  });

  group('results and files', () {
    const output = '{"custom_id":"a","line":1,"status":"succeeded","response":'
        '{"audio_file_id":"file_x","content_type":"audio/mpeg","duration_seconds":4.2,"billable_seconds":5,"cost":0.2,"currency":"ETB"}}\n';
    const errors = '{"custom_id":"b","line":2,"status":"failed","error":{"code":"voice_not_found","message":"m"}}\n';

    final storageCalls = <http.Request>[];
    final contentCalls = <http.Request>[];
    AddisAiProvider finished() {
      storageCalls.clear();
      contentCalls.clear();
      return withClient((req) async {
        final url = req.url.toString();
        if (url == '$api/batches/$batchId') {
          return ok(batch({'status': 'completed', 'output_file_id': 'file_out', 'error_file_id': 'file_err'}));
        }
        final m = RegExp(r'/files/(\w+)/content$').firstMatch(req.url.path);
        if (m != null) {
          contentCalls.add(req);
          return http.Response('', 302, headers: {'location': 'https://storage.test/${m[1]}?sig=1'});
        }
        storageCalls.add(req);
        if (url.contains('file_out')) return http.Response.bytes(utf8.encode(output), 200, headers: {'content-type': 'application/jsonl'});
        if (url.contains('file_err')) return http.Response.bytes(utf8.encode(errors), 200, headers: {'content-type': 'application/jsonl'});
        return http.Response.bytes([0xFF, 0xFB, 0x90, 0x00], 200, headers: {'content-type': 'audio/mpeg'});
      });
    }

    test('reads successes then failures', () async {
      final results = await finished().batches.results(batchId).toList();
      expect(results.map((r) => r.customId), ['a', 'b']);
      expect(results[0].isSucceeded, isTrue);
      expect(results[0].response?.audioFileId, 'file_x');
      expect(results[0].response?.durationSeconds, 4.2);
      expect(results[1].isSucceeded, isFalse);
      expect(results[1].error?.code, 'voice_not_found');
    });

    test('never sends the API key to the storage host', () async {
      await finished().batches.results(batchId).toList();
      expect(contentCalls, isNotEmpty);
      for (final c in contentCalls) {
        expect(c.followRedirects, isFalse);
        expect(c.headers['x-api-key'], 'a-key');
      }
      expect(storageCalls, isNotEmpty);
      for (final c in storageCalls) {
        expect(c.url.host, 'storage.test');
        expect(c.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-api-key')));
      }
    });

    test('downloads a result\'s audio', () async {
      final addis = finished();
      final results = await addis.batches.results(batchId).toList();
      final clip = await addis.batches.audio(results.first);
      expect(clip.isAudio, isTrue);
      expect(clip.mediaType, 'audio/mpeg');
      expect(clip.bytes, hasLength(4));
      expect(() => addis.batches.audio(results.last), throwsA(isA<AiException>()));
    });

    test('are empty until the batch has written its files', () async {
      final addis = withClient((req) async => ok(batch({'status': 'in_progress'})));
      expect(await addis.batches.results(batchId).toList(), isEmpty);
    });

    test('contentUrl resolves the redirect and reports a missing one', () async {
      var redirect = true;
      final addis = withClient((req) async => redirect
          ? http.Response('', 302, headers: {'location': 'https://storage.test/a.mp3?sig=1'})
          : http.Response('{"error":{"message":"No such file"}}', 404));
      expect(await addis.files.contentUrl('file_a'), 'https://storage.test/a.mp3?sig=1');
      redirect = false;
      await expectLater(addis.files.contentUrl('file_a'), throwsA(isA<AiException>().having((e) => e.statusCode, 'status', 404)));
    });

    test('over 25 MB goes by signed upload, without the key on the PUT', () async {
      final calls = <http.Request>[];
      final addis = withClient((req) async {
        calls.add(req);
        if (req.url.host == 'storage.test') return http.Response('', 200);
        if (req.url.path.endsWith('/complete')) return ok({'id': fileId, 'status': 'ready'});
        return ok({
          'id': fileId,
          'status': 'pending',
          'upload': {
            'method': 'PUT',
            'url': 'https://storage.test/put?sig=1',
            'headers': {'content-type': 'application/jsonl'},
            'expires_at': '2026-10-16T10:00:00Z',
          },
        }, status: 201);
      });
      final file = await addis.files.upload(Uint8List(AddisFiles.directUploadLimit + 1), filename: 'big.jsonl');
      expect(file.status, 'ready');
      expect(jsonDecode(calls[0].body), {
        'purpose': 'batch_input',
        'filename': 'big.jsonl',
        'bytes': AddisFiles.directUploadLimit + 1,
        'content_type': 'application/jsonl',
      });
      expect(calls[1].method, 'PUT');
      expect(calls[1].bodyBytes, hasLength(AddisFiles.directUploadLimit + 1));
      expect(calls[1].headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-api-key')));
      expect(calls[2].url.toString(), '$api/files/$fileId/complete');
    });

    test('over 100 MB is refused before sending', () async {
      var calls = 0;
      final addis = withClient((req) async {
        calls++;
        return ok({});
      });
      await expectLater(addis.files.upload(Uint8List(AddisFiles.uploadLimit + 1)), throwsA(isA<AiException>()));
      expect(calls, 0);
    });
  });

  group('waitFor', () {
    test('returns at once for a finished batch', () async {
      var calls = 0;
      final addis = withClient((req) async {
        calls++;
        return ok(batch({'status': 'failed', 'status_reason': 'bad input'}));
      });
      final seen = <String>[];
      final done = await addis.batches.waitFor(batchId, onProgress: (b) => seen.add(b.status));
      expect(done.status, 'failed');
      expect(done.statusReason, 'bad input');
      expect(seen, ['failed']);
      expect(calls, 1);
    });

    test('polls until finished, riding out a lost connection', () async {
      var calls = 0;
      final addis = withClient((req) async {
        calls++;
        // Three 503s use up retrieve's own retries; the poll loop tries again.
        if (calls <= 3) return http.Response('busy', 503, headers: {'retry-after': '0'});
        return ok(batch({'status': 'completed'}));
      });
      final done = await addis.batches.waitFor(batchId, pollInterval: Duration.zero);
      expect(done.status, 'completed');
      expect(calls, 4);
    });

    test('an answer that won\'t change is not ridden out', () async {
      final addis = withClient((req) async => http.Response('{"error":{"message":"No such batch"}}', 404));
      await expectLater(addis.batches.waitFor(batchId), throwsA(isA<AiException>().having((e) => e.statusCode, 'status', 404)));
    });

    test('timeout gives up without cancelling the batch', () async {
      final methods = <String>[];
      final addis = withClient((req) async {
        methods.add(req.method);
        return ok(batch({'status': 'in_progress'}));
      });
      await expectLater(
        addis.batches.waitFor(batchId, timeout: const Duration(seconds: 1)),
        throwsA(isA<AiException>().having((e) => e.message, 'message', contains('still in_progress'))),
      );
      expect(methods, ['GET']);
    });

    test('cancel stops the waiting right away', () async {
      final addis = withClient((req) async => ok(batch({'status': 'queued'})));
      final token = CancelToken();
      final clock = Stopwatch()..start();
      final wait = addis.batches.waitFor(batchId, cancelToken: token);
      Future<void>.delayed(const Duration(milliseconds: 20), token.cancel);
      await expectLater(wait, throwsA(isA<AiCancelledException>()));
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
