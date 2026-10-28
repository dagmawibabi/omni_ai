import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/provider.dart';
import 'model_info.dart';

/// Metadata about a model from https://models.dev: prices, limits,
/// modalities, release dates. Free, no key.
class ModelsDev {
  ModelsDev._(this._byProvider, this.providers);

  static const url = 'https://models.dev/api.json';

  /// Downloads the whole models.dev catalog (~1 MB).
  static Future<ModelsDev> fetch({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) throw Exception('models.dev answered ${r.statusCode}');
      return parse(utf8.decode(r.bodyBytes));
    } finally {
      if (client == null) c.close();
    }
  }

  static ModelsDev parse(String raw) {
    final all = jsonDecode(raw) as Map<String, dynamic>;
    final by = <String, Map<String, Map<String, dynamic>>>{};
    final providers = <String, Map<String, dynamic>>{};
    all.forEach((pid, p) {
      if (p is! Map) return;
      providers[pid] = {
        for (final e in p.entries)
          if (e.key != 'models') '${e.key}': e.value
      };
      final models = p['models'];
      if (models is! Map) return;
      by[pid] = {
        for (final e in models.entries)
          if (e.value is Map) '${e.key}': Map<String, dynamic>.from(e.value as Map)
      };
    });
    return ModelsDev._(by, providers);
  }

  final Map<String, Map<String, Map<String, dynamic>>> _byProvider;

  /// Provider entries: name, doc URL, env var names, API URL.
  final Map<String, Map<String, dynamic>> providers;

  /// The entry for [modelId] at [provider], or the same model at any
  /// provider (as `lab/model` or bare id).
  Map<String, dynamic>? lookup(String? provider, String modelId) {
    final bare = modelId.replaceAll(':free', '');
    if (provider != null) {
      final m = _byProvider[provider]?[bare];
      if (m != null) return m;
    }
    final slash = bare.indexOf('/');
    if (slash > 0) {
      final m = _byProvider[bare.substring(0, slash)]?[bare.substring(slash + 1)];
      if (m != null) return m;
    }
    for (final p in _byProvider.values) {
      final m = p[bare];
      if (m != null) return m;
    }
    return null;
  }

  /// Every model of a models.dev provider as [ModelInfo] under [asProvider].
  List<ModelInfo> modelsOf(String modelsDevProvider, {required String asProvider}) => [
        for (final e in (_byProvider[modelsDevProvider] ?? const <String, Map<String, dynamic>>{}).entries)
          enrich(ModelInfo(provider: asProvider, modelId: e.key, name: '${e.value['name'] ?? e.key}'), e.value),
      ];

  /// Fills gaps in [m] from a models.dev entry [d].
  static ModelInfo enrich(ModelInfo m, Map<String, dynamic>? d) {
    if (d == null) return m;
    final limit = d['limit'] as Map?;
    final cost = d['cost'] as Map?;
    final mods = d['modalities'] as Map?;
    List<String>? list(Object? v) => v is List ? [for (final x in v) '$x'] : null;
    final outMods = list(mods?['output']);
    var types = m.types;
    if (outMods != null && m.types.length == 1 && m.types.contains(ModelType.text) && !outMods.contains('text')) {
      types = {
        if (outMods.contains('image')) ModelType.image,
        if (outMods.contains('audio')) ModelType.speech,
        if (outMods.contains('video')) ModelType.video,
      };
      if (types.isEmpty) types = m.types;
    }
    return m.copyWith(
      name: m.name == m.modelId ? '${d['name'] ?? m.name}' : null,
      types: types,
      description: m.description.isEmpty ? d['description'] as String? : null,
      family: m.family ?? d['family'] as String?,
      contextWindow: m.contextWindow ?? (limit?['context'] as num?)?.toInt(),
      maxOutput: m.maxOutput ?? (limit?['output'] as num?)?.toInt(),
      inputPrice: m.inputPrice ?? (cost?['input'] as num?)?.toDouble(),
      outputPrice: m.outputPrice ?? (cost?['output'] as num?)?.toDouble(),
      cacheReadPrice: m.cacheReadPrice ?? (cost?['cache_read'] as num?)?.toDouble(),
      inputModalities: m.inputModalities.length <= 1 ? list(mods?['input']) : null,
      outputModalities: m.outputModalities.length <= 1 ? outMods : null,
      reasoning: m.reasoning || d['reasoning'] == true,
      toolCall: m.toolCall || d['tool_call'] == true,
      structuredOutput: m.structuredOutput || d['structured_output'] == true,
      openWeights: m.openWeights || d['open_weights'] == true,
      attachment: m.attachment || d['attachment'] == true,
      temperature: d['temperature'] is bool ? d['temperature'] as bool : null,
      releaseDate: m.releaseDate ?? d['release_date'] as String?,
      lastUpdated: m.lastUpdated ?? d['last_updated'] as String?,
      knowledge: m.knowledge ?? d['knowledge'] as String?,
    );
  }
}

/// Every model from the providers you use, enriched with models.dev, cached
/// on the device. Listen to it (it is a [ChangeNotifier]) to rebuild a
/// picker as it loads.
///
/// ```dart
/// await ai.catalog.load();
/// final chat = ai.catalog.ofType(ModelType.text);
/// ```
class ModelCatalog extends ChangeNotifier {
  ModelCatalog(this._providers, {this.maxAge = const Duration(days: 3), this.cacheKey = 'omni_ai.catalog.v1'});

  final List<AiProvider> Function() _providers;
  final Duration maxAge;
  final String cacheKey;

  List<ModelInfo> models = const [];
  bool loading = false;

  /// True while [load] or [refresh] is in flight.
  bool get isLoading => loading || _loading != null;

  /// Per-provider errors from the last refresh (e.g. a bad key).
  Map<String, String> errors = const {};
  DateTime? fetchedAt;
  ModelsDev? modelsDev;

  Future<void>? _loading;

  ModelInfo? byId(String id) => models.where((m) => m.id == id || m.modelId == id).firstOrNull;
  List<ModelInfo> ofType(ModelType type) => models.where((m) => m.supports(type)).toList();
  List<ModelInfo> ofProvider(String provider) => models.where((m) => m.provider == provider).toList();

  /// Models matching a search across id, name, lab and description.
  List<ModelInfo> search(String query, {ModelType? type, String? provider}) {
    final q = query.trim().toLowerCase();
    return models.where((m) {
      if (type != null && !m.supports(type)) return false;
      if (provider != null && m.provider != provider) return false;
      if (q.isEmpty) return true;
      return m.id.toLowerCase().contains(q) ||
          m.name.toLowerCase().contains(q) ||
          (m.lab ?? '').toLowerCase().contains(q) ||
          m.description.toLowerCase().contains(q);
    }).toList();
  }

  /// Loads the cache, then refreshes when it's older than [maxAge].
  Future<void> load({bool force = false}) => _loading ??= () async {
        try {
          if (models.isEmpty) await _readCache();
          final at = fetchedAt;
          if (force || models.isEmpty || at == null || DateTime.now().difference(at) > maxAge) await _refresh();
        } finally {
          _loading = null;
        }
      }();

  /// Fetches every configured provider's list again.
  Future<void> refresh() => load(force: true);

  Future<void> _refresh() async {
    loading = true;
    notifyListeners();
    final errs = <String, String>{};
    final providers = _providers().where((p) => p.isConfigured || !p.needsApiKey || p.id == 'gateway' || p.id == 'openrouter').toList();
    final devFuture = ModelsDev.fetch().then<ModelsDev?>((v) => v, onError: (Object e) {
      errs['models.dev'] = '$e';
      return null;
    });
    final lists = await Future.wait([
      for (final p in providers)
        p.listModels().timeout(const Duration(seconds: 60)).then<List<ModelInfo>>((v) => v, onError: (Object e) {
          errs[p.id] = '$e';
          return const <ModelInfo>[];
        }),
    ]);
    final dev = await devFuture;
    modelsDev = dev ?? modelsDev;
    final out = <ModelInfo>[];
    for (var i = 0; i < providers.length; i++) {
      final p = providers[i];
      for (final m in lists[i]) {
        out.add(dev == null ? m : ModelsDev.enrich(m, dev.lookup(p.modelsDevId, m.modelId)));
      }
    }
    out.sort((a, b) {
      final p = a.provider.compareTo(b.provider);
      if (p != 0) return p;
      final l = (a.lab ?? '').compareTo(b.lab ?? '');
      if (l != 0) return l;
      return (b.releaseDate ?? '').compareTo(a.releaseDate ?? '');
    });
    if (out.isNotEmpty) {
      models = out;
      fetchedAt = DateTime.now();
      unawaited(_writeCache());
    }
    errors = errs;
    loading = false;
    notifyListeners();
  }

  Future<void> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      models = [for (final m in j['models'] as List) ModelInfo.fromJson(Map<String, dynamic>.from(m as Map))];
      fetchedAt = DateTime.tryParse('${j['at']}');
      notifyListeners();
    } catch (e) {
      debugPrint('[omni_ai] catalog cache unreadable: $e');
    }
  }

  Future<void> _writeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          cacheKey,
          jsonEncode({
            'at': fetchedAt?.toIso8601String(),
            'models': [for (final m in models) m.toJson()]
          }));
    } catch (e) {
      debugPrint('[omni_ai] catalog cache not saved: $e');
    }
  }

  Future<void> clearCache() async {
    models = const [];
    fetchedAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(cacheKey);
    notifyListeners();
  }
}
