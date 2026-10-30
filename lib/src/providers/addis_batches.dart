import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/media.dart';
import 'addis_ai.dart';
import 'openai_compatible.dart' show downloadFile;

/// One text to speech request in an Addis AI batch.
class AddisBatchRequest {
  const AddisBatchRequest({
    required this.customId,
    required this.text,
    required this.voiceId,
    required this.language,
    this.outputFormat = 'mp3_44100',
    this.speed,
  });

  /// Your name for this request, unique in the batch. Results carry it back.
  final String customId;
  final String text;

  /// A voice matching [language], e.g. `am-hamen`, `om-bikila`, `ti-berhane`.
  final String voiceId;

  /// `am`, `om` or `ti`.
  final String language;

  /// `mp3_44100`, `wav_44100` or `pcm_16000`.
  final String outputFormat;
  final num? speed;

  /// One line of the batch's input file.
  Map<String, dynamic> toJson() => {
        'custom_id': customId,
        'body': {
          'text': text,
          'voice_id': voiceId,
          'language': language,
          'output_format': outputFormat,
          if (speed != null) 'voice_settings': {'speed': speed},
        },
      };
}

/// How many requests of a batch ended which way.
class AddisBatchCounts {
  const AddisBatchCounts({this.total = 0, this.succeeded = 0, this.failed = 0, this.expired = 0, this.cancelled = 0, this.pending = 0});

  factory AddisBatchCounts.fromJson(Map j) => AddisBatchCounts(
        total: _int(j['total']) ?? 0,
        succeeded: _int(j['succeeded']) ?? 0,
        failed: _int(j['failed']) ?? 0,
        expired: _int(j['expired']) ?? 0,
        cancelled: _int(j['cancelled']) ?? 0,
        pending: _int(j['pending']) ?? 0,
      );

  final int total;
  final int succeeded;
  final int failed;
  final int expired;
  final int cancelled;
  final int pending;

  /// Requests that have ended, for a progress bar.
  int get finished => total - pending;
}

/// A batch: its status, counts, cost and result files.
class AddisBatch {
  const AddisBatch({
    required this.id,
    required this.status,
    required this.raw,
    this.endpoint,
    this.inputFileId,
    this.outputFileId,
    this.errorFileId,
    this.statusReason,
    this.counts = const AddisBatchCounts(),
    this.currency,
    this.unit,
    this.unitPrice,
    this.listUnitPrice,
    this.estimatedCost,
    this.chargedCost,
    this.metadata = const {},
    this.createdAt,
    this.completedAt,
    this.expiresAt,
  });

  factory AddisBatch.fromJson(Map j) {
    final pricing = j['pricing'] is Map ? j['pricing'] as Map : const {};
    return AddisBatch(
      id: '${j['id']}',
      status: '${j['status']}',
      raw: j,
      endpoint: j['endpoint'] as String?,
      inputFileId: j['input_file_id'] as String?,
      outputFileId: j['output_file_id'] as String?,
      errorFileId: j['error_file_id'] as String?,
      statusReason: j['status_reason'] as String?,
      counts: j['request_counts'] is Map ? AddisBatchCounts.fromJson(j['request_counts'] as Map) : const AddisBatchCounts(),
      currency: pricing['currency'] as String?,
      unit: pricing['unit'] as String?,
      unitPrice: pricing['unit_price'] as num?,
      listUnitPrice: pricing['list_unit_price'] as num?,
      estimatedCost: j['estimated_cost'] as num?,
      chargedCost: j['charged_cost'] as num?,
      metadata: j['metadata'] is Map ? {for (final e in (j['metadata'] as Map).entries) '${e.key}': '${e.value}'} : const {},
      createdAt: _date(j['created_at']),
      completedAt: _date(j['completed_at']),
      expiresAt: _date(j['expires_at']),
    );
  }

  final String id;

  /// `validating`, `queued`, `in_progress`, `finalizing`, `completed`,
  /// `failed`, `expired`, `cancelling` or `cancelled`.
  final String status;
  final String? endpoint;
  final String? inputFileId;

  /// The JSONL of finished requests, once the batch has ended.
  final String? outputFileId;

  /// The JSONL of failed requests, once the batch has ended.
  final String? errorFileId;
  final String? statusReason;
  final AddisBatchCounts counts;
  final String? currency;
  final String? unit;
  final num? unitPrice;
  final num? listUnitPrice;
  final num? estimatedCost;
  final num? chargedCost;

  /// Your own keys and values, exactly as sent.
  final Map<String, String> metadata;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final DateTime? expiresAt;

  /// The whole answer, for fields not named here.
  final Map raw;

  /// True once the status can no longer change.
  bool get isFinished => const {'completed', 'failed', 'expired', 'cancelled'}.contains(status);
}

/// Why a request in a batch did not finish.
class AddisBatchError {
  const AddisBatchError({this.code, this.message});
  factory AddisBatchError.fromJson(Map j) => AddisBatchError(code: j['code'] as String?, message: j['message'] as String?);

  final String? code;
  final String? message;

  @override
  String toString() => '${code ?? 'error'}: ${message ?? ''}';
}

/// The clip a finished request made. Download it with [AddisBatches.audio].
class AddisBatchAudio {
  const AddisBatchAudio({this.audioFileId, this.contentType, this.durationSeconds, this.billableSeconds, this.cost, this.currency});

  factory AddisBatchAudio.fromJson(Map j) => AddisBatchAudio(
        audioFileId: j['audio_file_id'] as String?,
        contentType: j['content_type'] as String?,
        durationSeconds: j['duration_seconds'] as num?,
        billableSeconds: j['billable_seconds'] as num?,
        cost: j['cost'] as num?,
        currency: j['currency'] as String?,
      );

  final String? audioFileId;
  final String? contentType;
  final num? durationSeconds;
  final num? billableSeconds;
  final num? cost;
  final String? currency;
}

/// One line of a finished batch's results.
class AddisBatchResult {
  const AddisBatchResult({required this.status, required this.raw, this.customId, this.line, this.response, this.error});

  factory AddisBatchResult.fromJson(Map j) => AddisBatchResult(
        status: '${j['status']}',
        raw: j,
        customId: j['custom_id'] as String?,
        line: _int(j['line']),
        response: j['response'] is Map ? AddisBatchAudio.fromJson(j['response'] as Map) : null,
        error: j['error'] is Map ? AddisBatchError.fromJson(j['error'] as Map) : null,
      );

  final String? customId;

  /// The request's line in the input file.
  final int? line;

  /// `succeeded`, `failed`, `expired` or `cancelled`.
  final String status;
  final AddisBatchAudio? response;
  final AddisBatchError? error;
  final Map raw;

  bool get isSucceeded => status == 'succeeded';
}

/// A request's live state in a batch that may still be running.
class AddisBatchRequestRecord {
  const AddisBatchRequestRecord({required this.status, required this.raw, this.customId, this.line, this.result, this.error, this.cost});

  factory AddisBatchRequestRecord.fromJson(Map j) => AddisBatchRequestRecord(
        status: '${j['status']}',
        raw: j,
        customId: j['custom_id'] as String?,
        line: _int(j['line']),
        result: j['result'] is Map ? AddisBatchAudio.fromJson(j['result'] as Map) : null,
        error: j['error'] is Map ? AddisBatchError.fromJson(j['error'] as Map) : null,
        cost: j['cost'] as num?,
      );

  final String? customId;
  final int? line;

  /// `queued`, `in_progress`, `succeeded`, `failed`, `expired` or `cancelled`.
  final String status;
  final AddisBatchAudio? result;
  final AddisBatchError? error;
  final num? cost;
  final Map raw;
}

/// A batch's input, results, errors or generated audio.
class AddisFile {
  const AddisFile({
    required this.id,
    required this.raw,
    this.purpose,
    this.filename,
    this.contentType,
    this.bytes,
    this.status,
    this.batchId,
    this.lineCount,
    this.createdAt,
    this.expiresAt,
  });

  factory AddisFile.fromJson(Map j) => AddisFile(
        id: '${j['id']}',
        raw: j,
        purpose: j['purpose'] as String?,
        filename: j['filename'] as String?,
        contentType: j['content_type'] as String?,
        bytes: _int(j['bytes']),
        status: j['status'] as String?,
        batchId: j['batch_id'] as String?,
        lineCount: _int(j['line_count']),
        createdAt: _date(j['created_at']),
        expiresAt: _date(j['expires_at']),
      );

  final String id;

  /// `batch_input`, `batch_output`, `batch_error` or `batch_audio_output`.
  final String? purpose;
  final String? filename;
  final String? contentType;
  final int? bytes;

  /// `pending`, `ready` or `deleted`.
  final String? status;
  final String? batchId;
  final int? lineCount;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final Map raw;
}

/// Addis AI batch files: `ai.addis.files`.
class AddisFiles {
  AddisFiles(this.p);
  final AddisAiProvider p;

  /// Files up to this size go in one request; larger ones go straight to storage.
  static const directUploadLimit = 25 * 1024 * 1024;

  /// The largest batch input file the API takes.
  static const uploadLimit = 100 * 1024 * 1024;

  Uri _url(String path) => Uri.parse('${AddisAiProvider.baseUrl}/api/v1/files$path');

  /// Uploads a batch input file (JSONL: one `{"custom_id", "body"}` per line).
  Future<AddisFile> upload(Uint8List bytes, {String filename = 'input.jsonl', CancelToken? cancelToken}) async {
    if (bytes.length > uploadLimit) {
      throw AiException('Addis AI batch input files are limited to 100 MB. Split the batch.', provider: p.id);
    }
    if (bytes.length > directUploadLimit) return _uploadSigned(bytes, filename, cancelToken);
    final j = p.net.json(await _withRetries(
      () => p.net.multipart(
        _url(''),
        headers: p.headers(json: false),
        fields: {'purpose': 'batch_input'},
        files: [http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: MediaType('application', 'jsonl'))],
        timeout: const Duration(minutes: 5),
        cancelToken: cancelToken,
      ),
      cancelToken,
    ));
    return AddisFile.fromJson(j as Map);
  }

  Future<AddisFile> _uploadSigned(Uint8List bytes, String filename, CancelToken? cancelToken) async {
    final j = p.net.json(await _withRetries(
      () => p.net.post(
        _url(''),
        headers: p.headers(),
        json: {'purpose': 'batch_input', 'filename': filename, 'bytes': bytes.length, 'content_type': 'application/jsonl'},
        cancelToken: cancelToken,
      ),
      cancelToken,
    )) as Map;
    final file = AddisFile.fromJson(j);
    final upload = j['upload'] as Map;
    // No API key here: the signed link carries its own authorization.
    final put = http.Request('PUT', Uri.parse('${upload['url']}'))
      ..headers.addAll({for (final e in ((upload['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'})
      ..bodyBytes = bytes;
    final r = await p.net.sendRequest(put, cancelToken: cancelToken, timeout: const Duration(minutes: 15));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw AiException('Upload to Addis AI storage failed (${r.statusCode}).', provider: p.id, statusCode: r.statusCode);
    }
    final done = p.net.json(await _withRetries(
      () => p.net.post(_url('/${_seg(file.id)}/complete'), headers: p.headers(), cancelToken: cancelToken),
      cancelToken,
    ));
    return AddisFile.fromJson(done as Map);
  }

  Future<AddisFile> retrieve(String fileId, {CancelToken? cancelToken}) async {
    final j = p.net
        .json(await _withRetries(() => p.net.get(_url('/${_seg(fileId)}'), headers: p.headers(), cancelToken: cancelToken), cancelToken));
    return AddisFile.fromJson(j as Map);
  }

  Future<AddisFile> delete(String fileId, {CancelToken? cancelToken}) async {
    final j = p.net.json(
        await _withRetries(() => p.net.delete(_url('/${_seg(fileId)}'), headers: p.headers(), cancelToken: cancelToken), cancelToken));
    return AddisFile.fromJson(j as Map);
  }

  /// A signed download link, good for about five minutes.
  ///
  /// The API answers with a redirect, which is read here instead of followed:
  /// following it would carry the API key on to the storage host. Browsers
  /// won't show a redirect to a page, so this doesn't work on web; fetch batch
  /// files from your server there.
  Future<String> contentUrl(String fileId, {CancelToken? cancelToken}) async {
    if (kIsWeb) {
      throw UnsupportedFeatureException('Addis AI batch files can\'t be downloaded from a browser. Fetch them on your server.',
          provider: p.id);
    }
    final url = _url('/${_seg(fileId)}/content');
    final r = await _withRetries(
      () => p.net.sendRequest(
        http.Request('GET', url)
          ..followRedirects = false
          ..headers.addAll(p.headers(json: false)),
        cancelToken: cancelToken,
      ),
      cancelToken,
    );
    final location = r.headers['location'];
    if (r.statusCode >= 300 && r.statusCode < 400 && location != null) return url.resolve(location).toString();
    p.net.ensureOk(r);
    throw AiException('Addis AI returned no download link for the file.', provider: p.id, statusCode: r.statusCode);
  }

  /// Downloads a file: result lines, error lines or generated audio.
  Future<GeneratedFile> content(String fileId, {String? mediaType, CancelToken? cancelToken}) async {
    final url = await contentUrl(fileId, cancelToken: cancelToken);
    return downloadFile(p.net, url, mediaType: mediaType, cancelToken: cancelToken);
  }
}

/// Addis AI batch generation: `ai.addis.batches`.
///
/// Up to [maxRequests] text to speech requests in one go, run off-peak, done
/// within 24 hours, at half the standard price. Only finished requests are
/// billed. The account needs at least one paid top-up.
///
/// A batch outlives the app, so keep its id: [waitFor] and [results] pick it
/// up again after a restart.
class AddisBatches {
  AddisBatches(this.p);
  final AddisAiProvider p;

  /// The most requests one batch takes.
  static const maxRequests = 10000;

  /// Text to speech, the default [create] endpoint.
  static const speechEndpoint = '/v1/voice/generations';

  /// The shortest wait between polls in [waitFor].
  static const minPollInterval = Duration(seconds: 5);

  Uri _url(String path, [Map<String, String>? query]) {
    final url = Uri.parse('${AddisAiProvider.baseUrl}/api/v1/batches$path');
    return query == null || query.isEmpty ? url : url.replace(queryParameters: query);
  }

  /// Creates a batch from an uploaded input file (see [AddisFiles.upload]).
  ///
  /// [idempotencyKey] makes a repeated call create one batch. One is generated
  /// when not given, and reused for the automatic retries here.
  Future<AddisBatch> create({
    required String inputFileId,
    String endpoint = speechEndpoint,
    Map<String, String> metadata = const {},
    String? idempotencyKey,
    CancelToken? cancelToken,
  }) async {
    final key = idempotencyKey ?? _newIdempotencyKey();
    final j = p.net.json(await _withRetries(
      () => p.net.post(
        _url(''),
        headers: {...p.headers(), 'Idempotency-Key': key},
        json: {'input_file_id': inputFileId, 'endpoint': endpoint, 'completion_window': '24h', 'metadata': metadata},
        cancelToken: cancelToken,
      ),
      cancelToken,
    ));
    return AddisBatch.fromJson(j as Map);
  }

  /// Checks [requests] before anything is sent, uploads them and creates the batch.
  Future<AddisBatch> createFromRequests(
    List<AddisBatchRequest> requests, {
    Map<String, String> metadata = const {},
    String filename = 'batch.jsonl',
    CancelToken? cancelToken,
  }) async {
    final jsonl = toJsonl(requests);
    final file = await p.files.upload(utf8.encode(jsonl), filename: filename, cancelToken: cancelToken);
    return create(inputFileId: file.id, metadata: metadata, cancelToken: cancelToken);
  }

  /// The input file for [requests]: one JSON object per line. Throws
  /// [ArgumentError] on what Addis AI would reject anyway: an empty or
  /// oversized batch, a repeated `customId`, blank text, or a language no
  /// voice speaks or that the voice's own prefix contradicts.
  static String toJsonl(List<AddisBatchRequest> requests) {
    if (requests.isEmpty) throw ArgumentError('A batch needs at least one request.');
    if (requests.length > maxRequests) throw ArgumentError('A batch takes at most $maxRequests requests, not ${requests.length}.');
    final seen = <String>{};
    final out = StringBuffer();
    for (final r in requests) {
      if (r.customId.isEmpty) throw ArgumentError('Every batch request needs a customId.');
      if (!seen.add(r.customId)) throw ArgumentError('customId "${r.customId}" is used twice.');
      if (r.text.trim().isEmpty) throw ArgumentError('Request "${r.customId}" has no text.');
      if (!AddisAiProvider.voiceLanguages.contains(r.language)) {
        throw ArgumentError(
            'Request "${r.customId}": language must be am (Amharic), om (Afaan Oromo) or ti (Tigrinya), not "${r.language}".');
      }
      final prefix = r.voiceId.split(RegExp(r'[-_]')).first.toLowerCase();
      if (AddisAiProvider.voiceLanguages.contains(prefix) && prefix != r.language) {
        throw ArgumentError('Request "${r.customId}": voice "${r.voiceId}" does not speak "${r.language}".');
      }
      out.writeln(jsonEncode(r.toJson()));
    }
    return out.toString();
  }

  Future<AddisBatch> retrieve(String batchId, {CancelToken? cancelToken}) async {
    final j = p.net
        .json(await _withRetries(() => p.net.get(_url('/${_seg(batchId)}'), headers: p.headers(), cancelToken: cancelToken), cancelToken));
    return AddisBatch.fromJson(j as Map);
  }

  /// Every batch, newest first. Pages are fetched as the stream is read;
  /// [limit] is the page size. Use `.take(n)` to stop early.
  Stream<AddisBatch> list({int? limit, String? after, CancelToken? cancelToken}) async* {
    var cursor = after;
    while (true) {
      final j = p.net.json(await _withRetries(
        () => p.net.get(
          _url('', {if (limit != null) 'limit': '$limit', if (cursor != null) 'after': cursor}),
          headers: p.headers(),
          cancelToken: cancelToken,
        ),
        cancelToken,
      )) as Map;
      for (final b in (j['data'] as List? ?? const []).whereType<Map>()) {
        yield AddisBatch.fromJson(b);
      }
      cursor = j['last_id'] as String?;
      if (j['has_more'] != true || cursor == null) return;
    }
  }

  /// Stops queued requests. Running ones finish and are billed.
  Future<AddisBatch> cancel(String batchId, {CancelToken? cancelToken}) async {
    final j = p.net.json(await _withRetries(
      () => p.net.post(_url('/${_seg(batchId)}/cancel'), headers: p.headers(), cancelToken: cancelToken),
      cancelToken,
    ));
    return AddisBatch.fromJson(j as Map);
  }

  /// Each request's state in input order, also while the batch runs. [status]
  /// filters: `queued`, `in_progress`, `succeeded`, `failed`, `expired`,
  /// `cancelled`.
  Stream<AddisBatchRequestRecord> requests(String batchId, {String? status, int? limit, CancelToken? cancelToken}) async* {
    String? after;
    while (true) {
      final j = p.net.json(await _withRetries(
        () => p.net.get(
          _url('/${_seg(batchId)}/requests', {
            if (status != null) 'status': status,
            if (limit != null) 'limit': '$limit',
            if (after != null) 'after': after,
          }),
          headers: p.headers(),
          cancelToken: cancelToken,
        ),
        cancelToken,
      )) as Map;
      final rows = [for (final r in (j['data'] as List? ?? const []).whereType<Map>()) AddisBatchRequestRecord.fromJson(r)];
      yield* Stream.fromIterable(rows);
      final last = rows.isEmpty ? null : rows.last.line;
      if (j['has_more'] != true || last == null) return;
      after = '$last';
    }
  }

  /// Every result line, successes then failures. Empty until the batch has
  /// ended and written its files.
  Stream<AddisBatchResult> results(String batchId, {CancelToken? cancelToken}) async* {
    final batch = await retrieve(batchId, cancelToken: cancelToken);
    for (final fileId in [batch.outputFileId, batch.errorFileId]) {
      if (fileId == null || fileId.isEmpty) continue;
      final file = await p.files.content(fileId, mediaType: 'application/jsonl', cancelToken: cancelToken);
      for (final line in const LineSplitter().convert(utf8.decode(file.bytes))) {
        if (line.trim().isEmpty) continue;
        yield AddisBatchResult.fromJson(jsonDecode(line) as Map);
      }
    }
  }

  /// Downloads the clip of a succeeded result.
  Future<GeneratedFile> audio(AddisBatchResult result, {CancelToken? cancelToken}) {
    final fileId = result.response?.audioFileId;
    if (fileId == null || fileId.isEmpty) {
      throw AiException('Batch request "${result.customId}" has no audio (${result.status}).', provider: p.id);
    }
    return p.files.content(fileId, mediaType: result.response?.contentType, cancelToken: cancelToken);
  }

  /// Polls until the batch is completed, failed, expired or cancelled, and
  /// returns it. A batch can take up to 24 hours, so this rides out dropped
  /// connections and busy answers. Cancelling [cancelToken] or passing
  /// [timeout] only stops the waiting, not the batch ([cancel] does that).
  ///
  /// [pollInterval] is at least [minPollInterval]. [onProgress] gets every
  /// status read, finished or not.
  Future<AddisBatch> waitFor(
    String batchId, {
    Duration pollInterval = const Duration(seconds: 30),
    Duration? timeout,
    void Function(AddisBatch batch)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final interval = pollInterval < minPollInterval ? minPollInterval : pollInterval;
    final clock = Stopwatch()..start();
    var failures = 0;
    while (true) {
      String still;
      try {
        final batch = await retrieve(batchId, cancelToken: cancelToken);
        failures = 0;
        onProgress?.call(batch);
        if (batch.isFinished) return batch;
        still = batch.status;
      } on AiException catch (e) {
        if (!_isTransient(e) || ++failures > _maxPollFailures) rethrow;
        still = 'not answering';
      }
      if (timeout != null && clock.elapsed + interval > timeout) {
        throw AiException('Addis AI batch $batchId is still $still.', provider: p.id);
      }
      await _wait(interval, cancelToken);
    }
  }
}

/// Failed polls in a row that [AddisBatches.waitFor] rides out.
const _maxPollFailures = 20;

int? _int(Object? v) => v is num ? v.toInt() : null;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
String _seg(String id) => Uri.encodeComponent(id);

bool _isRetryableStatus(int s) => s == 408 || s == 425 || s == 429 || s >= 500;

/// A lost connection or a busy server, not an answer to act on.
bool _isTransient(AiException e) {
  if (e is AiCancelledException || e is MissingApiKeyException) return false;
  final s = e.statusCode;
  return s == null || _isRetryableStatus(s);
}

/// Sends with up to [retries] more tries on a busy answer or lost connection,
/// honouring `retry-after`. Only for calls safe to repeat.
Future<http.Response> _withRetries(Future<http.Response> Function() send, CancelToken? token, {int retries = 2}) async {
  for (var attempt = 0;; attempt++) {
    try {
      final r = await send();
      if (attempt >= retries || !_isRetryableStatus(r.statusCode)) return r;
      final after = double.tryParse(r.headers['retry-after'] ?? '');
      await _wait(after != null ? Duration(milliseconds: (math.min(after, 60) * 1000).round()) : _backoff(attempt), token);
    } on AiException catch (e) {
      if (attempt >= retries || e.statusCode != null || !_isTransient(e)) rethrow;
      await _wait(_backoff(attempt), token);
    }
  }
}

Duration _backoff(int attempt) => Duration(milliseconds: math.min(8000, 500 * (1 << attempt)));

/// Waits, but wakes early (and throws) on cancel.
Future<void> _wait(Duration d, CancelToken? token) async {
  if (token == null) return Future.delayed(d);
  await Future.any([Future<void>.delayed(d), token.whenCancelled]);
  if (token.isCancelled) throw const AiCancelledException();
}

/// A ULID, the key format Addis's own SDKs send.
String _newIdempotencyKey() {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final random = math.Random.secure();
  var now = DateTime.now().millisecondsSinceEpoch;
  final time = List.filled(10, '');
  for (var i = 9; i >= 0; i--) {
    time[i] = alphabet[now % 32];
    now ~/= 32;
  }
  return time.join() + List.generate(16, (_) => alphabet[random.nextInt(32)]).join();
}
