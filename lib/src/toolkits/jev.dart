import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../agents/toolkit.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/tools.dart';

/// One question for Jev. Its name (the key it is asked under) names the
/// answer.
///
/// ```dart
/// JevQuestion.noul('Is this message about billing?')
/// JevQuestion.choice('How urgent is it?', {'low': '', 'high': 'needs a reply today'})
/// JevQuestion.score('How polite is it?', ['rude', 'neutral', 'warm'])
/// ```
class JevQuestion {
  const JevQuestion._(this.type, this.instructions, this.criteria);

  /// AI SDK's name for a Noul question.
  factory JevQuestion.boolean(Object? instructions, {Object? ifTrue, Object? ifFalse}) =>
      JevQuestion.noul(instructions, ifTrue: ifTrue, ifFalse: ifFalse);

  /// Yes or no. [ifTrue] / [ifFalse] describe what each outcome means.
  factory JevQuestion.noul(Object? instructions, {Object? ifTrue, Object? ifFalse}) => JevQuestion._(
        'noul',
        instructions,
        ifTrue == null && ifFalse == null ? null : {if (ifTrue != null) 'true': ifTrue, if (ifFalse != null) 'false': ifFalse},
      );

  /// One of 1 to 255 named options; each option's description may be empty
  /// (then its name alone is judged).
  factory JevQuestion.choice(Object? instructions, Map<String, Object?> options) {
    if (options.isEmpty || options.length > 255) throw ArgumentError('A choice takes 1 to 255 options.');
    return JevQuestion._('choice', instructions, options);
  }

  /// A rubric of 2 to 10 levels, lowest first; the score is the
  /// probability-weighted level.
  factory JevQuestion.score(Object? instructions, List<Object?> levels) {
    if (levels.length < 2 || levels.length > 10) throw ArgumentError('A score takes 2 to 10 levels.');
    return JevQuestion._('score', instructions, levels);
  }

  /// Where in an image (an asset) the thing [instructions] describes is.
  /// Needs `images: true` on the request.
  factory JevQuestion.box(Object? instructions) => JevQuestion._('box', instructions, null);

  /// `noul`, `choice`, `score` or `box`.
  final String type;

  /// What to judge: text, or any JSON.
  final Object? instructions;
  final Object? criteria;

  Map<String, dynamic> toJson() => {
        'type': type == 'boolean' ? 'noul' : type,
        if (instructions != null) 'instructions': instructions,
        if (criteria != null) 'criteria': criteria,
      };

  /// Reads the shape the API (and the `jev_decide` tool) take. `boolean`
  /// is the AI SDK name for a noul. Models don't always send criteria as
  /// documented, so options may also come as `options` / `choices` /
  /// `levels`, a list, a JSON string or a comma-separated string.
  factory JevQuestion.fromJson(Map j) {
    final type = '${j['type'] ?? 'noul'}';
    final c = _criteria(j['criteria'] ?? j['options'] ?? j['choices'] ?? j['levels']);
    return switch (type) {
      'choice' => _choice(j['instructions'], c),
      'score' => _score(j['instructions'], c),
      'box' => JevQuestion.box(j['instructions']),
      'noul' || 'boolean' => JevQuestion.noul(
          j['instructions'],
          ifTrue: c is Map ? c['true'] : null,
          ifFalse: c is Map ? c['false'] : null,
        ),
      _ => throw ArgumentError('Unknown Jev question type: $type'),
    };
  }

  static Object? _criteria(Object? c) {
    if (c is! String) return c;
    final t = c.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(t);
      } on FormatException {/* Fall back to a comma list. */}
    }
    return [
      for (final x in t.split(RegExp('[,;|]'))) if (x.trim().isNotEmpty) x.trim()
    ];
  }

  static JevQuestion _choice(Object? instructions, Object? c) {
    final options = <String, Object?>{
      if (c is Map)
        for (final e in c.entries) '${e.key}': e.value,
      if (c is List)
        for (final x in c)
          if (x is Map && (x['name'] ?? x['option'] ?? x['label']) != null)
            '${x['name'] ?? x['option'] ?? x['label']}': x['description'] ?? ''
          else if (x != null && '$x'.trim().isNotEmpty)
            '$x'.trim(): '',
    };
    if (options.isEmpty) {
      throw ArgumentError('A choice question needs its options in criteria, e.g. '
          '{"type": "choice", "instructions": "...", "criteria": {"positive": "", "negative": ""}}.');
    }
    return JevQuestion.choice(instructions, options);
  }

  static JevQuestion _score(Object? instructions, Object? c) {
    final levels = <Object?>[
      if (c is List) ...c,
      if (c is Map) ...c.values,
    ];
    if (levels.length < 2) {
      throw ArgumentError('A score question needs 2 to 10 levels in criteria, lowest first, e.g. '
          '{"type": "score", "instructions": "...", "criteria": ["low", "medium", "high"]}.');
    }
    return JevQuestion.score(instructions, levels);
  }
}

/// Gives the bytes of a picture a tool call names (a file, a link), or null.
typedef JevImageResolver = Future<List<int>?> Function(String ref);

/// A Jev call's pictures: [images] by their ids, and [ids], the name the
/// call used for each picture → its id.
class JevPictures {
  const JevPictures(this.images, this.ids);
  final Map<String, JevImage> images;
  final Map<String, String> ids;

  /// [v] with each name the call used, as a whole word, replaced by the
  /// picture's id, in every string inside it.
  Object? rewrite(Object? v) {
    final renames = {
      for (final e in ids.entries)
        if (e.key != e.value) e.key: e.value,
    };
    if (renames.isEmpty) return v;
    Object? walk(Object? x) {
      if (x is String) {
        var out = x;
        for (final e in renames.entries) {
          out = out == e.key ? e.value : out.replaceAll(RegExp('(?<![\\w-])${RegExp.escape(e.key)}(?![\\w-])'), e.value);
        }
        return out;
      }
      if (x is Map) return {for (final e in x.entries) '${e.key}': walk(e.value)};
      if (x is List) return [for (final y in x) walk(y)];
      return x;
    }

    return walk(v);
  }

  /// [state] rewritten, with any picture it (or [also]) doesn't mention
  /// added under "images", so each one is seen.
  Object place(Object state, {Object? also}) {
    final rewritten = rewrite(state) ?? '';
    final seen = jsonEncode([rewritten, also]);
    final missing = [
      for (final id in images.keys)
        if (!seen.contains(id)) id,
    ];
    if (missing.isEmpty) return rewritten;
    final value = missing.length == 1 ? missing.first : missing;
    if (rewritten is Map) return {...rewritten, 'images': value};
    final empty = rewritten is String && rewritten.trim().isEmpty;
    return {if (!empty) 'content': rewritten, 'images': value};
  }
}

/// Where something sits in an image, as fractions of width and height
/// from the top-left (`left < right`, `top < bottom`).
class JevBox {
  const JevBox({required this.top, required this.bottom, required this.left, required this.right});

  factory JevBox.fromJson(Map j) => JevBox(
        top: (j['top'] as num?)?.toDouble() ?? 0,
        bottom: (j['bottom'] as num?)?.toDouble() ?? 0,
        left: (j['left'] as num?)?.toDouble() ?? 0,
        right: (j['right'] as num?)?.toDouble() ?? 0,
      );

  final double top;
  final double bottom;
  final double left;
  final double right;

  Map<String, double> toJson() => {'top': top, 'bottom': bottom, 'left': left, 'right': right};
}

/// An image a question can look at: put [placeholder] (the key it is
/// given under) in the state or instructions where the image belongs.
class JevImage {
  const JevImage(this.bytes, {this.format = 'png'});

  /// [bytes] as PNG or JPEG, read from the file itself; null for any other
  /// format (Jev takes png, jpg and jpeg).
  static JevImage? detect(List<int> bytes) {
    if (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return JevImage(bytes, format: 'png');
    }
    if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return JevImage(bytes, format: 'jpg');
    return null;
  }

  final List<int> bytes;

  /// `png`, `jpg` or `jpeg`.
  final String format;

  Map<String, dynamic> toJson() => {'type': 'image', 'format': format, 'data_base64': base64Encode(bytes)};
}

/// Jev's answer to one question. Which fields are set follows [type].
class JevAnswer {
  const JevAnswer({
    required this.type,
    this.probability,
    this.choice,
    this.score,
    this.confidence,
    this.probabilities = const {},
    this.legend = const {},
    this.box,
    this.raw = const {},
  });

  factory JevAnswer.fromJson(Map j) {
    Map<String, double> probs(Object? v) => {
          if (v is Map)
            for (final e in v.entries) '${e.key}': (e.value as num).toDouble(),
        };
    final b = j['box'];
    return JevAnswer(
      type: '${j['type']}',
      probability: (j['noul'] as num?)?.toDouble(),
      choice: j['choice'] as String?,
      score: (j['score'] as num?)?.toDouble(),
      confidence: (j['confidence'] as num?)?.toDouble(),
      probabilities: probs(j['probabilities']),
      legend: {
        if (j['legend'] is Map)
          for (final e in (j['legend'] as Map).entries) '${e.key}': '${e.value}'
      },
      box: b is Map ? {for (final e in b.entries) '${e.key}': (e.value as num).toDouble()} : null,
      raw: Map<String, dynamic>.from(j),
    );
  }

  final String type;

  /// For `noul`: how likely the answer is yes/true, 0 to 1.
  final double? probability;

  /// TypeSafe's field name for [probability].
  double? get noul => probability;

  /// For `choice`: the most likely option.
  final String? choice;

  /// For `score`: the probability-weighted level (may fall between levels).
  final double? score;

  /// For `choice`, `score` and `box`: 0 to 1.
  final double? confidence;

  /// For `choice` (option → p) and `score` (level → p).
  final Map<String, double> probabilities;

  /// For `score`: level → its description.
  final Map<String, String> legend;

  /// For `box`: top, bottom, left, right as fractions of the image.
  final Map<String, double>? box;

  /// [box] as a [JevBox], when this is a box answer.
  JevBox? get location => box == null ? null : JevBox.fromJson(box!);

  /// The answer as Jev sent it.
  final Map<String, dynamic> raw;

  /// For `noul`: yes when [probability] reaches [threshold].
  bool isTrue([double threshold = 0.5]) => (probability ?? 0) >= threshold;

  /// For `choice` / `score`: the selected option's own probability, if known.
  double? get selectedProbability => switch (type) {
        'choice' when choice != null => probabilities[choice],
        _ => null,
      };
}

/// A whole decision: the model that made it, each answer, and the tokens.
class JevDecision {
  const JevDecision({required this.model, required this.answers, this.inputTokens = 0, this.outputTokens = 0, this.requestId});

  factory JevDecision.fromJson(Map j, {String? requestId}) {
    final usage = j['usage'] as Map? ?? const {};
    return JevDecision(
      model: '${j['model'] ?? ''}',
      answers: {
        for (final e in ((j['answers'] as Map?) ?? const {}).entries)
          if (e.value is Map) '${e.key}': JevAnswer.fromJson(e.value as Map),
      },
      inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
      requestId: requestId,
    );
  }

  /// The versioned model that answered (`jev-1.13.0`), even when an alias was asked for.
  final String model;
  final Map<String, JevAnswer> answers;

  /// Billed tokens; output tokens are free.
  final int inputTokens;
  final int outputTokens;

  /// TypeSafe's `x-typesafe-request-id`, for support.
  final String? requestId;

  /// The answer named [id], or null.
  JevAnswer? operator [](String id) => answers[id];

  Map<String, dynamic> toJson() => {
        'model': model,
        'answers': {for (final e in answers.entries) e.key: e.value.raw},
        'usage': {'input_tokens': inputTokens, 'output_tokens': outputTokens},
        if (requestId != null) 'request_id': requestId,
      };
}

/// TypeSafe AI's Jev: a decision model that answers yes/no, multiple-choice,
/// rubric and image-location questions about a piece of content with
/// calibrated probabilities, rather than writing text.
/// Get a key at https://console.typesafe.ai.
///
/// ```dart
/// final d = await JevClient(apiKey: 'ts_…').decide(
///   state: 'Hi, my card was charged twice this month.',
///   questions: {'billing': JevQuestion.noul('Is this message about billing?')},
/// );
/// print(d.answers['billing']!.probability); // 0.98
/// ```
class JevClient {
  JevClient({
    this.apiKey,
    this.baseUrl = 'https://api.typesafe.ai',
    this.maxRetries = 2,
    this.headers = const {},
    this.timeout = const Duration(seconds: 120),
    http.Client? httpClient,
  }) : _net = AiHttp(provider: 'TypeSafe', client: httpClient);

  /// TypeSafe's hosted API, `TYPESAFE_AI_API_KEY`.
  factory JevClient.typeSafe({String? apiKey, Map<String, String> headers = const {}, http.Client? httpClient}) =>
      JevClient(apiKey: apiKey, headers: headers, httpClient: httpClient);

  /// A TypeSafe-compatible server (self-hosted Jev, a proxy, OpenRouter's
  /// System One route). [baseUrl] is the origin, without `/v1`.
  factory JevClient.compatible({
    required String baseUrl,
    String? apiKey,
    Map<String, String> headers = const {},
    http.Client? httpClient,
  }) =>
      JevClient(apiKey: apiKey, baseUrl: baseUrl, headers: headers, httpClient: httpClient);

  /// The aliases the API takes; versioned ids (`jev-1.13.0`, `jev-1.14.0`) work too.
  static const models = ['jev-latest', 'jev-preview', 'jev-1.14.0', 'jev-1.13.0'];

  String? apiKey;
  String baseUrl;

  /// Extra headers on every call (after auth and danger-zone flags).
  Map<String, String> headers;

  /// How long a single attempt may take.
  Duration timeout;

  /// How many times a 429 (rate limit) or 529/5xx (overloaded) is retried,
  /// with backoff from 0.5 s up to 5 s, honouring `retry-after`.
  int maxRetries;
  final AiHttp _net;

  Uri _endpoint(String path) {
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse('${base.endsWith('/v1') ? base : '$base/v1'}/$path');
    // The key travels in a header: never over plain HTTP to another machine.
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && isLoopbackHost(uri.host))) {
      throw AiException('Jev needs an https:// API address (plain http only for localhost).', provider: 'jev');
    }
    return uri;
  }

  /// localhost, 127.x and ::1: the only hosts a key may reach over http.
  static bool isLoopbackHost(String host) =>
      host == 'localhost' || host == '::1' || host == '[::1]' || host.startsWith('127.');

  Map<String, String> _headers({bool images = false, bool longContext = false, String? idempotencyKey}) {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) throw const MissingApiKeyException('jev', 'TypeSafe Jev');
    return {
      'Authorization': 'Bearer $key',
      if (images) 'TypeSafe-Danger-Zone-Images': 'true',
      if (longContext) 'TypeSafe-Danger-Zone-Long-Context': 'true',
      if (idempotencyKey != null && idempotencyKey.isNotEmpty) 'Idempotency-Key': idempotencyKey,
      ...headers,
    };
  }

  Future<http.Response> _withRetries(Future<http.Response> Function() send, {CancelToken? cancelToken}) async {
    for (var attempt = 0;; attempt++) {
      if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
      final r = await send();
      final retryable = r.statusCode == 429 || r.statusCode >= 500;
      if (!retryable || attempt >= maxRetries) return r;
      final after = double.tryParse(r.headers['retry-after'] ?? '');
      final wait =
          after != null ? Duration(milliseconds: (after * 1000).round()) : Duration(milliseconds: math.min(5000, 500 * (1 << attempt)));
      await Future.any<void>([
        Future<void>.delayed(wait),
        if (cancelToken != null) cancelToken.whenCancelled.then((_) => throw const AiCancelledException()),
      ]);
    }
  }

  /// Asks every question in [questions] about [state] (text, or any JSON).
  ///
  /// [images] are assets keyed by placeholders that appear in [state] or the
  /// instructions (box questions need them). [longContext] raises the 64k/32k
  /// limits to 262k. [model] defaults to `jev-latest`. [idempotencyKey]
  /// makes a retry bill once. [multipart] sends image bytes as file parts
  /// instead of base64 in JSON.
  Future<JevDecision> decide({
    required Object state,
    required Map<String, JevQuestion> questions,
    String model = 'jev-latest',
    Map<String, JevImage> images = const {},
    bool longContext = false,
    bool multipart = false,
    String? idempotencyKey,
    CancelToken? cancelToken,
  }) async {
    if (questions.isEmpty) throw ArgumentError('Ask at least one question.');
    if (questions.values.any((q) => q.type == 'box') && images.isEmpty) {
      throw ArgumentError('Box questions require at least one image.');
    }
    final needsImages = images.isNotEmpty || questions.values.any((q) => q.type == 'box');
    final body = {
      'model': model,
      'state': state,
      'questions': {for (final e in questions.entries) e.key: e.value.toJson()},
      if (images.isNotEmpty)
        'assets': {
          for (final e in images.entries) e.key: multipart ? {'type': 'image', 'part': e.key} : e.value.toJson(),
        },
    };
    final key = idempotencyKey ?? (maxRetries > 0 ? _newIdempotencyKey() : null);
    final hdr = _headers(images: needsImages, longContext: longContext, idempotencyKey: key);
    final r = await _withRetries(() async {
      if (multipart && images.isNotEmpty) {
        return _net.multipart(
          _endpoint('systemone'),
          headers: hdr,
          fields: {'request': jsonEncode(body)},
          files: [
            for (final e in images.entries)
              http.MultipartFile.fromBytes(
                e.key,
                e.value.bytes,
                filename: '${e.key}.${e.value.format}',
              ),
          ],
          timeout: timeout,
          cancelToken: cancelToken,
        );
      }
      return _net.post(
        _endpoint('systemone'),
        headers: hdr,
        json: body,
        timeout: timeout,
        cancelToken: cancelToken,
      );
    }, cancelToken: cancelToken);
    return JevDecision.fromJson(_net.json(r) as Map, requestId: r.headers['x-typesafe-request-id']);
  }

  /// Asks the same [questions] about each of [states]: one request per
  /// state (Jev has no batch endpoint), at most [concurrency] at a time.
  /// Results keep the order of [states]; a state that fails holds its error
  /// instead of failing the rest.
  Future<List<({JevDecision? decision, Object? error})>> decideEach({
    required List<Object> states,
    required Map<String, JevQuestion> questions,
    String model = 'jev-latest',
    bool longContext = false,
    int concurrency = 4,
    List<Map<String, JevImage>>? images,
    CancelToken? cancelToken,
  }) async {
    if (questions.isEmpty) throw ArgumentError('Ask at least one question.');
    final everyHasImages = images != null && images.length == states.length && images.every((m) => m.isNotEmpty);
    if (questions.values.any((q) => q.type == 'box') && !everyHasImages) {
      throw ArgumentError('Box questions need an image for every item.');
    }
    final out = List<({JevDecision? decision, Object? error})>.filled(states.length, (decision: null, error: null));
    var next = 0;
    Future<void> worker() async {
      while (next < states.length) {
        final i = next++;
        if (cancelToken?.isCancelled ?? false) throw const AiCancelledException();
        try {
          final d = await decide(
            state: states[i],
            questions: questions,
            model: model,
            images: images == null || i >= images.length ? const {} : images[i],
            longContext: longContext,
            cancelToken: cancelToken,
          );
          out[i] = (decision: d, error: null);
        } on AiCancelledException {
          rethrow;
        } catch (e) {
          out[i] = (decision: null, error: e);
        }
      }
    }

    await Future.wait([for (var w = 0; w < concurrency.clamp(1, 16) && w < states.length; w++) worker()]);
    return out;
  }

  static final _random = math.Random.secure();

  static String _newIdempotencyKey() =>
      List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  /// [decide] under the AI SDK name `experimental_evaluate` / `experimental_decide`.
  Future<JevDecision> evaluate({
    required Object state,
    required Map<String, JevQuestion> questions,
    String model = 'jev-latest',
    Map<String, JevImage> images = const {},
    bool longContext = false,
    bool multipart = false,
    String? idempotencyKey,
    CancelToken? cancelToken,
  }) =>
      decide(
        state: state,
        questions: questions,
        model: model,
        images: images,
        longContext: longContext,
        multipart: multipart,
        idempotencyKey: idempotencyKey,
        cancelToken: cancelToken,
      );

  /// One yes/no (noul) question. The answer is `answers['answer']`.
  Future<JevAnswer> noul(
    Object state,
    Object? instructions, {
    String name = 'answer',
    Object? ifTrue,
    Object? ifFalse,
    String model = 'jev-latest',
    Map<String, JevImage> images = const {},
    bool longContext = false,
    CancelToken? cancelToken,
  }) async =>
      (await decide(
        state: state,
        questions: {name: JevQuestion.noul(instructions, ifTrue: ifTrue, ifFalse: ifFalse)},
        model: model,
        images: images,
        longContext: longContext,
        cancelToken: cancelToken,
      ))
          .answers[name]!;

  /// One multiple-choice question.
  Future<JevAnswer> choice(
    Object state,
    Object? instructions,
    Map<String, Object?> options, {
    String name = 'answer',
    String model = 'jev-latest',
    Map<String, JevImage> images = const {},
    bool longContext = false,
    CancelToken? cancelToken,
  }) async =>
      (await decide(
        state: state,
        questions: {name: JevQuestion.choice(instructions, options)},
        model: model,
        images: images,
        longContext: longContext,
        cancelToken: cancelToken,
      ))
          .answers[name]!;

  /// One rubric score question.
  Future<JevAnswer> score(
    Object state,
    Object? instructions,
    List<Object?> levels, {
    String name = 'answer',
    String model = 'jev-latest',
    Map<String, JevImage> images = const {},
    bool longContext = false,
    CancelToken? cancelToken,
  }) async =>
      (await decide(
        state: state,
        questions: {name: JevQuestion.score(instructions, levels)},
        model: model,
        images: images,
        longContext: longContext,
        cancelToken: cancelToken,
      ))
          .answers[name]!;

  /// One image-location (box) question. Needs [images] and Jev 1.14+.
  Future<JevAnswer> box(
    Object state,
    Object? instructions, {
    String name = 'answer',
    String model = 'jev-latest',
    Map<String, JevImage> images = const {},
    bool longContext = false,
    CancelToken? cancelToken,
  }) async =>
      (await decide(
        state: state,
        questions: {name: JevQuestion.box(instructions)},
        model: model,
        images: images,
        longContext: longContext,
        cancelToken: cancelToken,
      ))
          .answers[name]!;

  /// The model names the key may use (aliases; versioned ids work too).
  Future<List<JevModel>> listModels({CancelToken? cancelToken}) async {
    final j = _net.json(await _net.get(_endpoint('models'), headers: _headers(), timeout: timeout, cancelToken: cancelToken));
    final list = j is Map ? (j['models'] ?? j['data']) : j;
    return [
      for (final m in (list as List? ?? const []))
        if (m is Map)
          JevModel(id: '${m['id'] ?? m['name']}', name: '${m['name'] ?? m['id'] ?? ''}', raw: Map<String, dynamic>.from(m))
        else
          JevModel(id: '$m', name: '$m'),
    ];
  }

  /// Model ids only, for a quick check.
  Future<List<String>> listModelIds({CancelToken? cancelToken}) async => [for (final m in await listModels(cancelToken: cancelToken)) m.id];

  /// Null when the key works; what went wrong otherwise. Sends no content.
  Future<String?> verify() async {
    try {
      await listModels();
      return null;
    } on AiException catch (e) {
      return e.message;
    }
  }
}

/// One Jev / System One model the key may call.
class JevModel {
  const JevModel({required this.id, required this.name, this.raw = const {}});
  final String id;
  final String name;
  final Map<String, dynamic> raw;
}

/// Jev for agents: `jev_decide` for any mix of questions, plus one-shot
/// `jev_noul` / `jev_choice` / `jev_score` / `jev_box` tools and
/// `jev_models`. Use them to classify, route, moderate or grade instead
/// of judging in prose. Code keeps the thresholds.
class JevToolkit extends Toolkit {
  JevToolkit({
    String? apiKey,
    String baseUrl = 'https://api.typesafe.ai',
    Map<String, String> headers = const {},
    this.model = 'jev-latest',
    this.longContext = false,
    this.threshold = 0.5,
    this.minConfidence,
    this.images = const {},
    this.resolveImage,
    this.visionModel = 'jev-preview',
    http.Client? httpClient,
  }) : client = JevClient(apiKey: apiKey, baseUrl: baseUrl, headers: headers, httpClient: httpClient);

  final JevClient client;

  /// Images supplied by the app; keys must occur in state or questions.
  Map<String, JevImage> images;

  /// Turns what a tool call names in `images` (a file, a link, whatever the
  /// app understands) into PNG or JPEG bytes; null when it can't. Without
  /// it, tools take only [images].
  JevImageResolver? resolveImage;

  /// The model asked whenever a request has images (they need a
  /// vision-language model), unless [model] is already a preview. Null
  /// keeps [model].
  String? visionModel;

  /// The model asked: `jev-latest`, `jev-preview` or a pinned version.
  String model;

  /// Allow states longer than the default limit.
  bool longContext;

  /// A yes/no answer counts as yes from this probability on.
  double threshold;

  /// When set, choice/score answers below this confidence are marked
  /// `uncertain` so the agent can escalate instead of acting.
  double? minConfidence;

  String? get apiKey => client.apiKey;
  set apiKey(String? v) => client.apiKey = v;

  @override
  String get id => 'jev';
  @override
  String get name => 'TypeSafe Jev';
  @override
  String? get apiKeyUrl => 'https://console.typesafe.ai';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;
  @override
  Future<String?> verify() => client.verify();

  @override
  String get instructions => 'Jev is a decision model: it returns typed answers with probabilities, never prose. '
      'jev_decide asks several questions at once about the same state (cheapest). '
      'For many items (a list of messages, reviews, rows), call jev_batch once with all of them, never one call per item. '
      'jev_noul is yes/no (probability of true). jev_choice picks one named option. '
      'jev_score rates on a rubric. jev_box locates something in an image. '
      'To judge pictures, pass images {placeholder: file or link} and put each placeholder in state, e.g. '
      'state {"post": "...", "photo": "img1"} with images {"img1": "photo.jpg"}. '
      'state may be text or JSON; JSON keeps its structure. '
      'jev_models lists model ids. Apply thresholds in the answers (yes/uncertain) — do not re-judge.';

  /// The `images` input every Jev tool takes.
  static final imagesParameter = Schema({
    'type': 'object',
    'additionalProperties': {'type': 'string'},
    'description': 'Pictures to judge: placeholder → the picture (a file or https link). Put each placeholder in '
        'state, e.g. state {"caption": "...", "photo": "img1"} with images {"img1": "beach.jpg"}; a placeholder '
        'missing from state is added to it. PNG and JPEG; others are converted when possible.',
  });

  /// [v] as Jev's state: JSON written as text is sent as JSON.
  static Object stateOf(Object? v) {
    if (v is String) {
      final t = v.trim();
      if ((t.startsWith('{') && t.endsWith('}')) || (t.startsWith('[') && t.endsWith(']'))) {
        try {
          return jsonDecode(t) as Object;
        } on FormatException {/* Plain text after all. */}
      }
      return v;
    }
    return v ?? '';
  }

  static final _ids = math.Random.secure();

  /// The pictures a call names, resolved, plus the app's [images]. Each
  /// gets an id no text contains by accident: Jev swaps a placeholder
  /// wherever it appears, so "p" would also hit the p in "photo".
  Future<JevPictures> picturesOf(Object? spec) async {
    final named = <String, String>{
      if (spec is Map)
        for (final e in spec.entries) '${e.key}': '${e.value}',
      if (spec is List)
        for (final (i, x) in spec.indexed) 'img${i + 1}': '$x',
      if (spec is String && spec.trim().isNotEmpty) 'img1': spec.trim(),
    };
    final out = {...images};
    final ids = {for (final k in images.keys) k: k};
    for (final e in named.entries) {
      final resolve = resolveImage;
      if (resolve == null) throw ArgumentError('This app can\'t attach images to Jev.');
      final bytes = await resolve(e.value);
      if (bytes == null) throw ArgumentError('Couldn\'t open the picture "${e.value}". Name a file in the chat or an https link.');
      final image = JevImage.detect(bytes);
      if (image == null) throw ArgumentError('"${e.value}" is not a PNG or JPEG picture.');
      final id = 'img-${List.generate(4, (_) => _ids.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      ids[e.key] = id;
      out[id] = image;
    }
    return JevPictures(out, ids);
  }

  /// The model for a request with or without images.
  String modelFor(Map<String, JevImage> images) =>
      images.isEmpty || visionModel == null || model.contains('preview') ? model : visionModel!;

  /// One question through [ask], with the call's state and images.
  Future<Map<String, dynamic>> _one(
    Map<String, dynamic> i,
    Future<JevAnswer> Function(Object state, Object? instructions, String model, Map<String, JevImage> images) ask,
  ) async {
    final pictures = await picturesOf(i['images']);
    final instructions = pictures.rewrite(i['instructions']);
    final state = pictures.place(stateOf(i['state']), also: instructions);
    final used = modelFor(pictures.images);
    final a = await ask(state, instructions, used, pictures.images);
    return {'model': used, ..._answerJson(a)};
  }

  /// The `jev_decide` tool's input shape, also used by apps that wrap it.
  static final parameters = Schema.object({
    'state': Schema.string(description: 'The content every question is about: text, or JSON (sent as JSON).'),
    'images': imagesParameter,
    'questions': Schema({
      'type': 'object',
      'description': 'Questions keyed by a short name. Each: {type: noul|choice|score, instructions, criteria}. '
          'noul criteria: optional {true, false} descriptions. choice criteria: {option: description} (1-255). '
          'score criteria: list of 2-10 level descriptions, lowest first.',
      'additionalProperties': {
        'type': 'object',
        'properties': {
          'type': {
            'type': 'string',
            'enum': ['noul', 'boolean', 'choice', 'score', 'box']
          },
          'instructions': {'type': 'string'},
          'criteria': {'description': 'See above; depends on type.'},
        },
        'required': ['type', 'instructions'],
      },
    }),
  }, required: [
    'state',
    'questions'
  ]);

  /// Runs a `jev_decide` call: the answers as plain JSON for a model.
  Future<Map<String, dynamic>> run(Map<String, dynamic> input, {CancelToken? cancelToken}) async {
    final qs = input['questions'];
    if (qs is! Map || qs.isEmpty) return {'error': 'questions must name at least one question.'};
    final pictures = await picturesOf(input['images']);
    final questions = {
      for (final e in qs.entries) '${e.key}': JevQuestion.fromJson(pictures.rewrite(JevQuestion.fromJson(e.value as Map).toJson()) as Map),
    };
    final d = await client.decide(
      state: pictures.place(stateOf(input['state']), also: [for (final q in questions.values) q.toJson()]),
      questions: questions,
      model: modelFor(pictures.images),
      images: pictures.images,
      longContext: longContext,
      cancelToken: cancelToken,
    );
    return {
      'model': d.model,
      'answers': {for (final e in d.answers.entries) e.key: _answerJson(e.value)},
      'usage': {'input_tokens': d.inputTokens, 'output_tokens': d.outputTokens},
      if (d.requestId != null) 'request_id': d.requestId,
    };
  }

  /// Most items one `jev_batch` call takes.
  static const maxBatchItems = 100;

  /// The `jev_batch` tool's input shape, also used by apps that wrap it.
  static final batchParameters = Schema.object({
    'items': Schema({
      'type': 'array',
      'description': 'The contents to judge, 1-$maxBatchItems. Each is a string, or {id, state, images} to get your id '
          'back and judge pictures (images: placeholder → file or link, as in jev_decide).',
      'items': {
        'anyOf': [
          {'type': 'string'},
          {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'state': {'type': 'string'},
              'images': imagesParameter.json,
            },
            'required': ['state'],
          },
        ],
      },
    }),
    'questions': Schema({
      ...parameters.json['properties']['questions'] as Map<String, dynamic>,
      'description': 'The same questions for every item, keyed by a short name. Each: {type: noul|choice|score, instructions, criteria}. '
          'noul criteria: optional {true, false}. choice criteria: {option: description} (1-255). score criteria: 2-10 levels, lowest first.',
    }),
  }, required: [
    'items',
    'questions'
  ]);

  /// Runs a `jev_batch` call: compact answers per item plus totals.
  Future<Map<String, dynamic>> runBatch(Map<String, dynamic> input, {CancelToken? cancelToken}) async {
    final qs = input['questions'];
    if (qs is! Map || qs.isEmpty) return {'error': 'questions must name at least one question.'};
    final raw = input['items'];
    if (raw is! List || raw.isEmpty) return {'error': 'items must hold at least one item.'};
    if (raw.length > maxBatchItems) return {'error': 'At most $maxBatchItems items per call; split the rest into another call.'};
    final questions = {for (final e in qs.entries) '${e.key}': JevQuestion.fromJson(e.value as Map)};
    final ids = <String>[];
    final states = <Object>[];
    final pictures = <Map<String, JevImage>>[];
    for (final (i, item) in raw.indexed) {
      if (item is Map) {
        ids.add('${item['id'] ?? i + 1}');
        final own = await picturesOf(item['images']);
        pictures.add(own.images);
        states.add(own.place(stateOf(item['state'])));
      } else {
        ids.add('${i + 1}');
        pictures.add(images);
        states.add(stateOf('$item'));
      }
    }
    final anyImages = pictures.any((p) => p.isNotEmpty);
    final used = anyImages ? modelFor(pictures.firstWhere((p) => p.isNotEmpty)) : model;
    final results = await client.decideEach(
      states: states,
      questions: questions,
      model: used,
      images: anyImages ? pictures : null,
      longContext: longContext,
      cancelToken: cancelToken,
    );
    var inputTokens = 0;
    final totals = <String, Map<String, dynamic>>{};
    final rows = <Map<String, dynamic>>[];
    for (final (i, r) in results.indexed) {
      final d = r.decision;
      if (d == null) {
        rows.add({'id': ids[i], 'error': '${r.error}'});
        continue;
      }
      inputTokens += d.inputTokens;
      final answers = <String, dynamic>{};
      for (final e in d.answers.entries) {
        final a = e.value;
        final sure = a.confidence ?? (a.choice == null ? null : a.probabilities[a.choice]);
        final uncertain = minConfidence != null && sure != null && sure < minConfidence!;
        final t = totals.putIfAbsent(e.key, () => {'type': a.type});
        if (a.probability != null) {
          final yes = a.isTrue(threshold);
          answers[e.key] = {'yes': yes, 'p': _round(a.probability!)};
          t[yes ? 'yes' : 'no'] = (t[yes ? 'yes' : 'no'] as int? ?? 0) + 1;
        } else if (a.choice != null) {
          answers[e.key] = {'choice': a.choice, if (sure != null) 'confidence': _round(sure), if (uncertain) 'uncertain': true};
          final counts = t.putIfAbsent('counts', () => <String, int>{}) as Map<String, int>;
          counts[a.choice!] = (counts[a.choice!] ?? 0) + 1;
        } else if (a.score != null) {
          answers[e.key] = {'score': _round(a.score!), if (a.confidence != null) 'confidence': _round(a.confidence!), if (uncertain) 'uncertain': true};
          t['sum'] = (t['sum'] as double? ?? 0) + a.score!;
          t['n'] = (t['n'] as int? ?? 0) + 1;
        }
        if (uncertain) t['uncertain'] = (t['uncertain'] as int? ?? 0) + 1;
      }
      rows.add({'id': ids[i], 'answers': answers});
    }
    for (final t in totals.values) {
      final n = t.remove('n') as int?;
      final sum = t.remove('sum') as double?;
      if (n != null && sum != null && n > 0) t['mean_score'] = _round(sum / n);
    }
    final failed = rows.where((r) => r.containsKey('error')).length;
    return {
      'model': used,
      'count': rows.length,
      if (failed > 0) 'failed': failed,
      'totals': totals,
      'results': rows,
      'usage': {'input_tokens': inputTokens},
    };
  }

  static double _round(num v) => (v * 1000).round() / 1000;

  Map<String, dynamic> _answerJson(JevAnswer a) {
    final uncertain = minConfidence != null && a.confidence != null && a.confidence! < minConfidence!;
    return {
      'type': a.type,
      if (a.probability != null) ...{'probability': a.probability, 'noul': a.probability, 'yes': a.isTrue(threshold)},
      if (a.choice != null) 'choice': a.choice,
      if (a.score != null) 'score': a.score,
      if (a.confidence != null) 'confidence': a.confidence,
      if (uncertain) 'uncertain': true,
      if (a.probabilities.isNotEmpty) 'probabilities': a.probabilities,
      if (a.legend.isNotEmpty) 'legend': a.legend,
      if (a.box != null) 'box': a.box,
    };
  }

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'jev_decide',
          label: 'Deciding with Jev',
          description:
              'Asks several TypeSafe Jev questions about one state (noul/boolean, choice, score, box). Prefer this when you need more than one answer.',
          parameters: parameters,
          execute: (i) => run(i, cancelToken: ToolContext.current?.cancelToken),
        ),
        Tool(
          name: 'jev_batch',
          label: 'Deciding a batch with Jev',
          description: 'Asks the same Jev questions about many items in one call (up to $maxBatchItems): classify, label or '
              'score a list of messages, reviews or rows. Returns compact answers per item plus totals. Use this instead '
              'of calling a Jev tool once per item.',
          parameters: batchParameters,
          execute: (i) => runBatch(i, cancelToken: ToolContext.current?.cancelToken),
        ),
        Tool(
          name: 'jev_noul',
          label: 'Jev yes/no',
          description: 'One Jev yes/no (noul) question about one item (text, JSON or pictures). Returns probability of true '
              'and yes at the configured threshold.',
          parameters: Schema.object({
            'state': Schema.string(description: 'The content to judge: text, or JSON (sent as JSON).'),
            'instructions': Schema.string(description: 'The yes/no question.'),
            'if_true': Schema.string(description: 'What a yes means.'),
            'if_false': Schema.string(description: 'What a no means.'),
            'images': imagesParameter,
          }, required: [
            'state',
            'instructions'
          ]),
          execute: (i) => _one(
            i,
            (state, instructions, model, pictures) => client.noul(
              state,
              instructions,
              ifTrue: i['if_true'] as String?,
              ifFalse: i['if_false'] as String?,
              model: model,
              images: pictures,
              longContext: longContext,
              cancelToken: ToolContext.current?.cancelToken,
            ),
          ),
        ),
        Tool(
          name: 'jev_choice',
          label: 'Jev choice',
          description: 'One Jev multiple-choice question about one item (text, JSON or pictures). options is a map of '
              'option name → description.',
          parameters: Schema.object({
            'state': Schema.string(description: 'The content to judge: text, or JSON (sent as JSON).'),
            'instructions': Schema.string(),
            'options': Schema({
              'type': 'object',
              'additionalProperties': {'type': 'string'},
              'description': 'option → description'
            }),
            'images': imagesParameter,
          }, required: [
            'state',
            'instructions',
            'options'
          ]),
          execute: (i) {
            final opts = i['options'] ?? i['criteria'] ?? i['choices'];
            final question = JevQuestion.fromJson({'type': 'choice', 'instructions': i['instructions'], 'criteria': opts});
            return _one(
              i,
              (state, instructions, model, pictures) => client.choice(
                state,
                instructions,
                Map<String, Object?>.from(question.criteria as Map),
                model: model,
                images: pictures,
                longContext: longContext,
                cancelToken: ToolContext.current?.cancelToken,
              ),
            );
          },
        ),
        Tool(
          name: 'jev_score',
          label: 'Jev score',
          description: 'One Jev rubric score for one item (text, JSON or pictures). levels is 2–10 descriptions, lowest first.',
          parameters: Schema.object({
            'state': Schema.string(description: 'The content to judge: text, or JSON (sent as JSON).'),
            'instructions': Schema.string(),
            'levels': Schema.array(Schema.string(), description: 'Rubric levels, lowest first.'),
            'images': imagesParameter,
          }, required: [
            'state',
            'instructions',
            'levels'
          ]),
          execute: (i) {
            final question = JevQuestion.fromJson({'type': 'score', 'instructions': i['instructions'], 'criteria': i['levels'] ?? i['criteria']});
            return _one(
              i,
              (state, instructions, model, pictures) => client.score(
                state,
                instructions,
                List<Object?>.from(question.criteria as List),
                model: model,
                images: pictures,
                longContext: longContext,
                cancelToken: ToolContext.current?.cancelToken,
              ),
            );
          },
        ),
        Tool(
          name: 'jev_box',
          label: 'Jev box',
          description: 'Locates something in a picture: the box as fractions of width and height from the top-left.',
          parameters: Schema.object({
            'state': Schema.string(description: 'The picture\'s placeholder, or JSON that includes it.'),
            'instructions': Schema.string(description: 'What to find, and in which picture.'),
            'images': imagesParameter,
          }, required: [
            'instructions'
          ]),
          execute: (i) => _one(
            i,
            (state, instructions, model, pictures) {
              if (pictures.isEmpty) throw ArgumentError('Give the picture in images, e.g. {"img1": "photo.jpg"}.');
              final s = state is String && state.trim().isEmpty ? pictures.keys.first : state;
              return client.box(
                s,
                instructions,
                model: model,
                images: pictures,
                longContext: longContext,
                cancelToken: ToolContext.current?.cancelToken,
              );
            },
          ),
        ),
        Tool(
          name: 'jev_models',
          label: 'Listing Jev models',
          description: 'Lists Jev / System One model ids this key may use.',
          execute: (_) async => {
            'models': [for (final m in await client.listModels(cancelToken: ToolContext.current?.cancelToken)) m.id],
          },
        ),
      ];
}
