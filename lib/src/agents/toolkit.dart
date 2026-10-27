import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/errors.dart';
import '../core/http.dart';
import '../core/tools.dart';

/// Something with a key people paste in: an AI provider or a toolkit.
/// [ApiKeySettings] shows a field for each.
abstract interface class KeyedService {
  String get id;
  String get name;
  String? get apiKeyUrl;
  bool get needsApiKey;
  bool get isConfigured;
  Future<String?> verify();
}

/// A set of ready-made tools for one service (web search, a code sandbox,
/// your apps…). Give toolkits to an `Agent`.
///
/// ```dart
/// Agent(toolkits: [ExaToolkit(apiKey: '…'), E2BToolkit(apiKey: '…')])
/// ```
abstract class Toolkit implements KeyedService {
  /// The tools this toolkit offers now. Some toolkits fetch theirs (Composio
  /// actions), so this is async.
  Future<List<Tool>> tools();

  /// A line for the system prompt: when to use these tools.
  String? get instructions => null;

  /// What this toolkit adds to the system prompt before each run. Defaults
  /// to [instructions]; memory toolkits add what they remember.
  Future<String?> prompt() async => instructions;

  @override
  String? get apiKeyUrl => null;

  @override
  bool get needsApiKey => true;

  /// Frees sandboxes or sessions the toolkit opened.
  Future<void> dispose() async {}

  @override
  String toString() => '$name toolkit';
}

/// Tools that need no key: the time, fetching a web page, and arithmetic.
class BasicToolkit extends Toolkit {
  BasicToolkit({this.fetch = true, http.Client? httpClient}) : _net = AiHttp(provider: 'the web', client: httpClient);

  /// Include `fetch_url`.
  final bool fetch;
  final AiHttp _net;

  @override
  String get id => 'basic';
  @override
  String get name => 'Basic tools';
  @override
  bool get needsApiKey => false;
  @override
  bool get isConfigured => true;
  @override
  Future<String?> verify() async => null;

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'current_time',
          label: 'Checking the time',
          description: 'The current date, time and time zone on this device.',
          execute: (_) {
            final now = DateTime.now();
            return {
              'iso': now.toIso8601String(),
              'utc': now.toUtc().toIso8601String(),
              'weekday': const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][now.weekday - 1],
              'timezone': now.timeZoneName,
              'utc_offset_minutes': now.timeZoneOffset.inMinutes,
            };
          },
        ),
        Tool(
          name: 'calculate',
          label: 'Calculating',
          description: 'Evaluates arithmetic exactly: + - * / % ^ and parentheses, e.g. "(12.5 * 4) ^ 2 / 3".',
          parameters: Schema.object({'expression': Schema.string()}),
          execute: (i) => {'result': calculate('${i['expression']}')},
        ),
        if (fetch)
          Tool(
            name: 'fetch_url',
            label: 'Reading a web page',
            description: 'Downloads a web page or text file and returns its readable text (HTML tags removed), up to max_characters.',
            parameters: Schema.object({
              'url': Schema.string(description: 'http or https URL'),
              'max_characters': Schema.integer(minimum: 500, maximum: 50000),
            }, required: [
              'url'
            ]),
            execute: (i) async {
              final url = Uri.tryParse('${i['url']}');
              if (url == null || !(url.scheme == 'http' || url.scheme == 'https')) return {'error': 'Give an http or https URL.'};
              final r = await _net.get(url, headers: {'User-Agent': 'omni_ai'}, timeout: const Duration(seconds: 30));
              if (r.statusCode >= 400) return {'error': 'The page answered ${r.statusCode}.'};
              final type = r.headers['content-type'] ?? '';
              final body = utf8.decode(r.bodyBytes, allowMalformed: true);
              final text = type.contains('html') ? htmlToText(body) : body;
              final max = (i['max_characters'] as num?)?.toInt() ?? 12000;
              return {
                'url': url.toString(),
                'content_type': type,
                'text': text.length > max ? '${text.substring(0, max)}… [${text.length - max} more characters]' : text,
              };
            },
          ),
      ];

  /// Readable text from HTML: scripts, styles and tags dropped.
  static String htmlToText(String html) => html
      .replaceAll(RegExp(r'<(script|style|noscript|svg)[\s\S]*?</\1>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<br\s*/?>|</(p|div|li|h[1-6]|tr)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n\n')
      .trim();

  /// Evaluates + - * / % ^ and parentheses.
  static num calculate(String expression) {
    final s = expression.replaceAll(' ', '');
    var i = 0;
    late num Function() expr;
    num atom() {
      if (i < s.length && s[i] == '(') {
        i++;
        final v = expr();
        if (i >= s.length || s[i] != ')') throw const FormatException('Missing )');
        i++;
        return v;
      }
      if (i < s.length && (s[i] == '-' || s[i] == '+')) {
        final neg = s[i] == '-';
        i++;
        final v = atom();
        return neg ? -v : v;
      }
      final m = RegExp(r'\d+(\.\d+)?([eE][-+]?\d+)?').matchAsPrefix(s, i);
      if (m == null) throw FormatException('Unexpected "${i < s.length ? s[i] : 'end'}"');
      i = m.end;
      return num.parse(m[0]!);
    }

    num power() {
      final b = atom();
      if (i < s.length && s[i] == '^') {
        i++;
        final e = power();
        return math.pow(b, e);
      }
      return b;
    }

    num term() {
      var v = power();
      while (i < s.length && '*/%'.contains(s[i])) {
        final op = s[i++];
        final r = power();
        v = op == '*' ? v * r : (op == '/' ? v / r : v % r);
      }
      return v;
    }

    expr = () {
      var v = term();
      while (i < s.length && (s[i] == '+' || s[i] == '-')) {
        final op = s[i++];
        final r = term();
        v = op == '+' ? v + r : v - r;
      }
      return v;
    };
    final v = expr();
    if (i != s.length) throw FormatException('Unexpected "${s[i]}"');
    return v;
  }
}

/// Throws a readable error when a toolkit has no key.
void requireKey(Toolkit t, String? key) {
  if (key == null || key.trim().isEmpty) throw MissingApiKeyException(t.id, t.name);
}
