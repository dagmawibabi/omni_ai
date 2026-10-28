import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cancel.dart';
import 'errors.dart';

/// Shared HTTP plumbing: cancellable requests, timeouts and readable errors.
class AiHttp {
  AiHttp({required this.provider, http.Client? client}) : _injected = client;

  final String provider;
  final http.Client? _injected;

  /// A client for one request; closed on cancel unless it was injected.
  ({http.Client client, void Function() done}) _open(CancelToken? token) {
    if (_injected != null) {
      return (client: _injected, done: () {});
    }
    final c = http.Client();
    final remove = token?.onCancel(c.close) ?? () {};
    return (
      client: c,
      done: () {
        remove();
        c.close();
      }
    );
  }

  Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 45),
    CancelToken? cancelToken,
  }) =>
      _run(cancelToken, (c) => c.get(url, headers: headers).timeout(timeout));

  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? json,
    Object? body,
    Duration timeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) =>
      _run(
        cancelToken,
        (c) => c
            .post(
              url,
              headers: {if (json != null) 'Content-Type': 'application/json', ...?headers},
              body: json != null ? jsonEncode(json) : body,
            )
            .timeout(timeout),
      );

  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 45),
    CancelToken? cancelToken,
  }) =>
      _run(cancelToken, (c) => c.delete(url, headers: headers).timeout(timeout));

  /// Sends [request] and waits for the whole body. Use [lines] or [bytes]
  /// when the answer is a stream.
  Future<http.Response> sendRequest(
    http.BaseRequest request, {
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 120),
  }) =>
      _run(cancelToken, (c) async => http.Response.fromStream(await c.send(request).timeout(timeout)));

  Future<http.Response> multipart(
    Uri url, {
    Map<String, String>? headers,
    Map<String, String> fields = const {},
    List<http.MultipartFile> files = const [],
    Duration timeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) =>
      _run(cancelToken, (c) async {
        final req = http.MultipartRequest('POST', url)
          ..headers.addAll(headers ?? const {})
          ..fields.addAll(fields)
          ..files.addAll(files);
        return http.Response.fromStream(await c.send(req).timeout(timeout));
      });

  Future<http.Response> _run(CancelToken? token, Future<http.Response> Function(http.Client) f) async {
    if (token?.isCancelled ?? false) throw const AiCancelledException();
    final h = _open(token);
    try {
      return await f(h.client);
    } on TimeoutException {
      throw AiException('$provider took too long to answer.', provider: provider);
    } catch (e) {
      if (token?.isCancelled ?? false) throw const AiCancelledException();
      if (e is AiException) rethrow;
      throw AiException('Could not reach $provider: $e', provider: provider);
    } finally {
      h.done();
    }
  }

  /// Sends [request] and returns its body as a stream of text lines.
  /// Throws [AiException] on a non-2xx answer.
  Stream<String> lines(
    http.BaseRequest request, {
    CancelToken? cancelToken,
    Duration connectTimeout = const Duration(seconds: 120),
    Duration idleTimeout = const Duration(seconds: 180),
  }) async* {
    if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
    final h = _open(cancelToken);
    try {
      final http.StreamedResponse res;
      try {
        res = await h.client.send(request).timeout(connectTimeout);
      } on TimeoutException {
        throw AiException('$provider took too long to answer.', provider: provider);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = await res.stream.bytesToString();
        throw apiError(res.statusCode, body);
      }
      await for (final line in res.stream.timeout(idleTimeout).transform(utf8.decoder).transform(const LineSplitter())) {
        if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
        yield line;
      }
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw AiException('$provider stopped answering.', provider: provider);
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
      throw AiException('Lost the connection to $provider: $e', provider: provider);
    } finally {
      h.done();
    }
  }

  /// Sends [request] and streams its raw bytes (for audio streaming).
  Stream<List<int>> bytes(http.BaseRequest request, {CancelToken? cancelToken}) async* {
    final h = _open(cancelToken);
    try {
      final res = await h.client.send(request).timeout(const Duration(seconds: 120));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw apiError(res.statusCode, await res.stream.bytesToString());
      }
      yield* res.stream;
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
      rethrow;
    } finally {
      h.done();
    }
  }

  /// Throws unless [r] is 2xx; returns its decoded JSON otherwise.
  dynamic json(http.Response r) {
    ensureOk(r);
    final text = utf8.decode(r.bodyBytes);
    if (text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw AiException('$provider answered with something that is not JSON.', provider: provider, body: text);
    }
  }

  void ensureOk(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw apiError(r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  AiException apiError(int status, String body) {
    final text = errorText(body);
    final hint = switch (status) {
      401 || 403 => ' Check your $provider API key.',
      429 => ' Slow down or check your $provider quota.',
      _ => '',
    };
    return AiException(
      text.isEmpty ? '$provider answered $status.$hint' : '$text$hint',
      provider: provider,
      statusCode: status,
      body: body,
    );
  }

  /// The readable message inside an error body from any provider.
  static String errorText(String body) {
    try {
      var j = jsonDecode(body);
      // Google wraps errors in a one-item list sometimes.
      if (j is List && j.isNotEmpty) j = j.first;
      if (j is Map) {
        final e = j['error'];
        if (e is Map && e['message'] != null) return '${e['message']}';
        if (e is String) return e;
        final d = j['detail'];
        if (d is Map && d['message'] != null) return '${d['message']}';
        if (d is String) return d;
        if (d is List && d.isNotEmpty && d.first is Map) return '${(d.first as Map)['msg'] ?? d.first}';
        if (j['message'] != null) return '${j['message']}';
      }
    } catch (_) {}
    final t = body.trim();
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }
}

/// Reads Server-Sent Events from text lines: yields each `data:` payload
/// (multi-line data joined), skipping `[DONE]`.
Stream<String> sseData(Stream<String> lines) async* {
  final buf = StringBuffer();
  await for (final raw in lines) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      if (buf.isNotEmpty) {
        final data = buf.toString();
        buf.clear();
        if (data != '[DONE]') yield data;
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    if (line.startsWith('data:')) {
      final d = line.substring(5).trimLeft();
      // Many servers send one JSON object per data line without a blank
      // line between; emit those at once.
      if (buf.isEmpty && _looksWhole(d)) {
        if (d != '[DONE]') yield d;
        continue;
      }
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(d);
    }
  }
  if (buf.isNotEmpty && buf.toString() != '[DONE]') yield buf.toString();
}

bool _looksWhole(String d) {
  if (d == '[DONE]') return true;
  if (!(d.startsWith('{') || d.startsWith('['))) return false;
  try {
    jsonDecode(d);
    return true;
  } catch (_) {
    return false;
  }
}

Map<String, String> bearer(String key) => {'Authorization': 'Bearer $key'};
