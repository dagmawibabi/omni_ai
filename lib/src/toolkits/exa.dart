import 'package:http/http.dart' as http;

import '../agents/toolkit.dart';
import '../core/cancel.dart';
import '../core/http.dart';
import '../core/tools.dart';

/// One result from Exa.
class ExaResult {
  const ExaResult({required this.url, this.title, this.publishedDate, this.author, this.text, this.highlights = const [], this.summary});

  factory ExaResult.fromJson(Map j) => ExaResult(
        url: '${j['url']}',
        title: j['title'] as String?,
        publishedDate: j['publishedDate'] as String?,
        author: j['author'] as String?,
        text: j['text'] as String?,
        highlights: [for (final h in (j['highlights'] as List? ?? const [])) '$h'],
        summary: j['summary'] as String?,
      );

  final String url;
  final String? title;
  final String? publishedDate;
  final String? author;
  final String? text;
  final List<String> highlights;
  final String? summary;

  Map<String, dynamic> toJson({int maxText = 4000}) => {
        'url': url,
        if (title != null) 'title': title,
        if (publishedDate != null) 'published': publishedDate,
        if (author != null && author!.isNotEmpty) 'author': author,
        if (highlights.isNotEmpty) 'highlights': highlights,
        if (summary != null) 'summary': summary,
        if (text != null) 'text': text!.length > maxText ? '${text!.substring(0, maxText)}…' : text,
      };
}

/// Exa's web search API: search, page contents, similar pages and cited
/// answers. Get a key at https://dashboard.exa.ai/api-keys.
class ExaClient {
  ExaClient({this.apiKey, http.Client? httpClient}) : _net = AiHttp(provider: 'Exa', client: httpClient);

  static const base = 'https://api.exa.ai';
  String? apiKey;
  final AiHttp _net;

  Map<String, String> get _headers => {'x-api-key': apiKey?.trim() ?? ''};

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, CancelToken? token) async => Map<String, dynamic>.from(
      _net.json(await _net.post(Uri.parse('$base$path'), headers: _headers, json: body, cancelToken: token)) as Map);

  /// Searches the web. [type] is `auto`, `fast`, `neural` or `keyword`;
  /// [category] narrows to `news`, `research paper`, `company`, `github`,
  /// `pdf`, `tweet`, `personal site` or `financial report`.
  Future<List<ExaResult>> search(
    String query, {
    int numResults = 5,
    String type = 'auto',
    String? category,
    List<String>? includeDomains,
    List<String>? excludeDomains,
    DateTime? startPublished,
    DateTime? endPublished,
    bool text = false,
    bool highlights = true,
    bool summary = false,
    CancelToken? cancelToken,
  }) async {
    final j = await _post(
        '/search',
        {
          'query': query,
          'numResults': numResults.clamp(1, 25),
          'type': type,
          if (category != null) 'category': category,
          if (includeDomains != null && includeDomains.isNotEmpty) 'includeDomains': includeDomains,
          if (excludeDomains != null && excludeDomains.isNotEmpty) 'excludeDomains': excludeDomains,
          if (startPublished != null) 'startPublishedDate': startPublished.toUtc().toIso8601String(),
          if (endPublished != null) 'endPublishedDate': endPublished.toUtc().toIso8601String(),
          'contents': {
            if (text) 'text': {'maxCharacters': 6000},
            if (highlights) 'highlights': {'maxCharacters': 1000},
            if (summary) 'summary': true,
          },
        },
        cancelToken);
    return [for (final r in (j['results'] as List? ?? const []).whereType<Map>()) ExaResult.fromJson(r)];
  }

  /// The clean text of pages.
  Future<List<ExaResult>> contents(List<String> urls, {int maxCharacters = 8000, CancelToken? cancelToken}) async {
    final j = await _post(
        '/contents',
        {
          'urls': urls,
          'text': {'maxCharacters': maxCharacters},
        },
        cancelToken);
    return [for (final r in (j['results'] as List? ?? const []).whereType<Map>()) ExaResult.fromJson(r)];
  }

  /// Pages like [url].
  Future<List<ExaResult>> findSimilar(String url, {int numResults = 5, CancelToken? cancelToken}) async {
    final j = await _post(
        '/findSimilar',
        {
          'url': url,
          'numResults': numResults.clamp(1, 25),
          'contents': {
            'highlights': {'maxCharacters': 800},
          },
        },
        cancelToken);
    return [for (final r in (j['results'] as List? ?? const []).whereType<Map>()) ExaResult.fromJson(r)];
  }

  /// A short answer with the sources it came from.
  Future<({String answer, List<ExaResult> citations})> answer(String query, {CancelToken? cancelToken}) async {
    final j = await _post('/answer', {'query': query, 'text': false}, cancelToken);
    return (
      answer: '${j['answer'] ?? ''}',
      citations: [for (final r in (j['citations'] as List? ?? const []).whereType<Map>()) ExaResult.fromJson(r)],
    );
  }
}

/// Web search, page reading and cited answers for agents, powered by Exa.
class ExaToolkit extends Toolkit {
  ExaToolkit({String? apiKey, http.Client? httpClient}) : client = ExaClient(apiKey: apiKey, httpClient: httpClient);

  final ExaClient client;

  String? get apiKey => client.apiKey;
  set apiKey(String? v) => client.apiKey = v;

  @override
  String get id => 'exa';
  @override
  String get name => 'Exa web search';
  @override
  String get apiKeyUrl => 'https://dashboard.exa.ai/api-keys';
  @override
  bool get isConfigured => apiKey?.trim().isNotEmpty ?? false;

  @override
  String get instructions =>
      'For current events, facts you are unsure of, or anything the user asks you to look up, use web_search, then read '
      'promising pages with read_pages. Cite the URLs you used.';

  @override
  Future<String?> verify() async {
    try {
      requireKey(this, apiKey);
      await client.search('test', numResults: 1, highlights: false, type: 'fast');
      return null;
    } catch (e) {
      return '$e';
    }
  }

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'web_search',
          label: 'Searching the web',
          description: 'Searches the web and returns titles, URLs, dates and the most relevant passages. Use for current or '
              'factual questions. Narrow with category or domains when it helps.',
          parameters: Schema.object({
            'query': Schema.string(description: 'What to find, as a natural description or keywords.'),
            'num_results': Schema.integer(minimum: 1, maximum: 15),
            'category': Schema.enumOf(['news', 'research paper', 'company', 'github', 'pdf', 'tweet', 'personal site', 'financial report']),
            'include_domains': Schema.array(Schema.string(), description: 'Only these sites, e.g. ["arxiv.org"].'),
            'published_after': Schema.string(description: 'ISO date, e.g. 2026-01-01.'),
          }, required: [
            'query'
          ]),
          execute: (i) async {
            requireKey(this, apiKey);
            final results = await client.search(
              '${i['query']}',
              numResults: (i['num_results'] as num?)?.toInt() ?? 5,
              category: i['category'] as String?,
              includeDomains: [for (final d in (i['include_domains'] as List? ?? const [])) '$d'],
              startPublished: DateTime.tryParse('${i['published_after'] ?? ''}'),
            );
            return {
              'query': i['query'],
              'results': [for (final r in results) r.toJson()],
            };
          },
        ),
        Tool(
          name: 'read_pages',
          label: 'Reading pages',
          description: 'Returns the clean text of up to 5 web pages.',
          parameters: Schema.object({'urls': Schema.array(Schema.string())}),
          execute: (i) async {
            requireKey(this, apiKey);
            final urls = [for (final u in (i['urls'] as List? ?? const [])) '$u'].take(5).toList();
            final pages = await client.contents(urls);
            return {
              'pages': [for (final p in pages) p.toJson(maxText: 8000)],
            };
          },
        ),
        Tool(
          name: 'find_similar_pages',
          label: 'Finding similar pages',
          description: 'Finds pages similar to a URL (competitors, related papers, alternatives).',
          parameters: Schema.object({'url': Schema.string(), 'num_results': Schema.integer(minimum: 1, maximum: 10)}, required: ['url']),
          execute: (i) async {
            requireKey(this, apiKey);
            final r = await client.findSimilar('${i['url']}', numResults: (i['num_results'] as num?)?.toInt() ?? 5);
            return {
              'results': [for (final x in r) x.toJson()],
            };
          },
        ),
        Tool(
          name: 'web_answer',
          label: 'Looking up an answer',
          description: 'A direct answer to a factual question, researched on the web, with citations.',
          parameters: Schema.object({'question': Schema.string()}),
          execute: (i) async {
            requireKey(this, apiKey);
            final r = await client.answer('${i['question']}');
            return {
              'answer': r.answer,
              'citations': [for (final c in r.citations) c.toJson(maxText: 500)],
            };
          },
        ),
      ];
}
