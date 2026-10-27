import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../agents/toolkit.dart';
import '../catalog/model_info.dart';
import '../core/cancel.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../core/media.dart';
import '../core/tools.dart';
import '../providers/openai_compatible.dart';

/// R2 credentials for its S3-compatible API (R2 → Manage API tokens).
class R2Credentials {
  const R2Credentials({required this.accountId, required this.accessKeyId, required this.secretAccessKey});
  final String accountId;
  final String accessKeyId;
  final String secretAccessKey;

  bool get complete => accountId.isNotEmpty && accessKeyId.isNotEmpty && secretAccessKey.isNotEmpty;
  String get host => '$accountId.r2.cloudflarestorage.com';
}

/// Cloudflare's REST API (v4) with an API token, R2 storage through the S3
/// API (SigV4), and Browser Rendering.
class CloudflareClient {
  CloudflareClient({this.token, this.accountId = '', this.r2, http.Client? httpClient})
      : _net = AiHttp(provider: 'Cloudflare', client: httpClient),
        _http = httpClient;

  static const api = 'https://api.cloudflare.com/client/v4';

  String? token;

  /// The account for Workers, KV, R2 and Browser Rendering; found from the
  /// token when empty.
  String accountId;
  R2Credentials? r2;
  final AiHttp _net;
  final http.Client? _http;

  static String errorText(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['errors'] is List && (j['errors'] as List).isNotEmpty) {
        return (j['errors'] as List)
            .map((e) => e is Map ? '${e['message']}${e['code'] == null ? '' : ' (${e['code']})'}' : '$e')
            .join('; ');
      }
    } catch (_) {}
    return AiHttp.errorText(body);
  }

  /// Calls the API and returns `result`.
  Future<dynamic> call(String method, String path, {Object? body, Map<String, String>? query, String? rawBody, String? contentType}) async {
    final t = token?.trim() ?? '';
    if (t.isEmpty) throw const MissingApiKeyException('cloudflare', 'Cloudflare');
    final uri = Uri.parse('$api$path').replace(queryParameters: query == null || query.isEmpty ? null : query);
    final req = http.Request(method, uri)..headers['Authorization'] = 'Bearer $t';
    if (rawBody != null) {
      req.headers['Content-Type'] = contentType ?? 'text/plain';
      req.body = rawBody;
    } else if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final c = _http ?? http.Client();
    final http.Response r;
    try {
      r = await http.Response.fromStream(await c.send(req).timeout(const Duration(seconds: 90)));
    } catch (e) {
      throw AiException('Could not reach Cloudflare: $e', provider: 'cloudflare');
    } finally {
      if (_http == null) c.close();
    }
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw AiException(errorText(text), provider: 'cloudflare', statusCode: r.statusCode, body: text);
    }
    if (!(r.headers['content-type'] ?? '').contains('json')) return text;
    final j = jsonDecode(text);
    if (j is Map && j['success'] == false) throw AiException(errorText(text), provider: 'cloudflare', statusCode: r.statusCode);
    return j is Map && j.containsKey('result') ? j['result'] : j;
  }

  /// The account id, looked up from the token if not set.
  Future<String> account() async {
    if (accountId.isNotEmpty) return accountId;
    final list = await call('GET', '/accounts', query: {'per_page': '5'});
    if (list is! List || list.isEmpty) throw const AiException('This token sees no account. Set the account ID.', provider: 'cloudflare');
    return accountId = '${(list.first as Map)['id']}';
  }

  /// Null when the token works.
  Future<String?> verify() async {
    try {
      await call('GET', '/user/tokens/verify');
      return null;
    } catch (_) {
      try {
        await call('GET', '/accounts', query: {'per_page': '1'});
        return null;
      } catch (e) {
        return '$e';
      }
    }
  }

  /// A zone id from an id or a domain name.
  Future<String> zoneId(String zone) async {
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(zone)) return zone;
    final list = await call('GET', '/zones', query: {'name': zone});
    if (list is! List || list.isEmpty) throw AiException('No zone named $zone on this account.', provider: 'cloudflare');
    return '${(list.first as Map)['id']}';
  }

  /// A page as Markdown, rendered in a real browser (Browser Rendering).
  Future<String> markdown(String url) async {
    final r = await call('POST', '/accounts/${await account()}/browser-rendering/markdown', body: {'url': url});
    return r is String ? r : '${r is Map ? (r['markdown'] ?? r['content'] ?? jsonEncode(r)) : r}';
  }

  /// A screenshot of a page (PNG).
  Future<Uint8List> screenshot(String url) async {
    final t = token?.trim() ?? '';
    final r = await _net.post(Uri.parse('$api/accounts/${await account()}/browser-rendering/screenshot'),
        headers: {'Authorization': 'Bearer $t'}, json: {'url': url}, timeout: const Duration(seconds: 90));
    _net.ensureOk(r);
    return r.bodyBytes;
  }

  // ------------------------------------------------------------------ R2

  static List<String> _tags(String xml, String tag) => [for (final m in RegExp('<$tag>([\\s\\S]*?)</$tag>').allMatches(xml)) m[1]!];
  static String? _tag(String xml, String tag) =>
      _tags(xml, tag).firstOrNull?.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"');
  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static List<int> _hmac(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).bytes;
  static String _encodeKey(String key) => key.split('/').map(Uri.encodeComponent).join('/');
  static String _canonicalQuery(Map<String, String> q) {
    final keys = q.keys.toList()..sort();
    return keys.map((k) => '${Uri.encodeComponent(k)}=${Uri.encodeComponent(q[k]!)}').join('&');
  }

  R2Credentials _r2() {
    final c = r2;
    if (c == null || !c.complete) {
      throw const AiException('R2 needs an access key: set the account ID, access key ID and secret.', provider: 'cloudflare');
    }
    return c;
  }

  List<int> _signingKey(R2Credentials c, String date) {
    var k = _hmac(utf8.encode('AWS4${c.secretAccessKey}'), date);
    k = _hmac(k, 'auto');
    k = _hmac(k, 's3');
    return _hmac(k, 'aws4_request');
  }

  /// A SigV4-signed request to R2.
  Future<http.Response> s3(String method, String bucket,
      {String key = '', Map<String, String> query = const {}, Uint8List? body, String? contentType}) async {
    final c = _r2();
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${now.year}${two(now.month)}${two(now.day)}';
    final stamp = '${date}T${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
    final payload = body ?? Uint8List(0);
    final payloadHash = _hex(sha256.convert(payload).bytes);
    final path = '/${Uri.encodeComponent(bucket)}${key.isEmpty ? '' : '/${_encodeKey(key)}'}';
    final q = _canonicalQuery(query);
    final headers = <String, String>{
      'host': c.host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': stamp,
      if (contentType != null) 'content-type': contentType,
    };
    final names = headers.keys.toList()..sort();
    final canonical = [method, path, q, ...names.map((n) => '$n:${headers[n]!.trim()}'), '', names.join(';'), payloadHash].join('\n');
    final scope = '$date/auto/s3/aws4_request';
    final toSign = ['AWS4-HMAC-SHA256', stamp, scope, _hex(sha256.convert(utf8.encode(canonical)).bytes)].join('\n');
    final signature = _hex(_hmac(_signingKey(c, date), toSign));
    final req = http.Request(method, Uri.parse('https://${c.host}$path${q.isEmpty ? '' : '?$q'}'))
      ..headers.addAll({...headers}..remove('host'))
      ..headers['Authorization'] =
          'AWS4-HMAC-SHA256 Credential=${c.accessKeyId}/$scope, SignedHeaders=${names.join(';')}, Signature=$signature';
    if (body != null) req.bodyBytes = body;
    final client = _http ?? http.Client();
    try {
      final r = await http.Response.fromStream(await client.send(req).timeout(const Duration(minutes: 2)));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw AiException('R2: ${_tag(r.body, 'Message') ?? _tag(r.body, 'Code') ?? 'HTTP ${r.statusCode}'}',
            provider: 'cloudflare', statusCode: r.statusCode);
      }
      return r;
    } on AiException {
      rethrow;
    } catch (e) {
      throw AiException('Could not reach R2: $e', provider: 'cloudflare');
    } finally {
      if (_http == null) client.close();
    }
  }

  /// Buckets on the account (through the REST API, so only the token is needed).
  Future<List<String>> buckets() async {
    final r = await call('GET', '/accounts/${await account()}/r2/buckets');
    final list = r is Map ? r['buckets'] : r;
    return [for (final b in (list as List? ?? const []).whereType<Map>()) '${b['name']}'];
  }

  /// Objects in [bucket] under [prefix]: one folder level (with `folders`)
  /// when [delimiter], or every object below it when not.
  Future<Map<String, dynamic>> listObjects(String bucket, {String prefix = '', bool delimiter = true, int max = 200, String? cursor}) async {
    final xml = (await s3('GET', bucket, query: {
      'list-type': '2',
      'max-keys': '${max.clamp(1, 1000)}',
      if (prefix.isNotEmpty) 'prefix': prefix,
      if (delimiter) 'delimiter': '/',
      if (cursor != null) 'continuation-token': cursor,
    }))
        .body;
    return {
      'bucket': bucket,
      'prefix': prefix,
      'folders': [for (final p in _tags(xml, 'CommonPrefixes')) _tag(p, 'Prefix')],
      'objects': [
        for (final o in _tags(xml, 'Contents'))
          {
            'key': _tag(o, 'Key'),
            'size': int.tryParse(_tag(o, 'Size') ?? ''),
            'modified': _tag(o, 'LastModified'),
            'etag': _tag(o, 'ETag')?.replaceAll('"', '').replaceAll('&quot;', ''),
          },
      ],
      if (_tag(xml, 'IsTruncated') == 'true') 'next_cursor': _tag(xml, 'NextContinuationToken'),
    };
  }

  Future<Uint8List> getObject(String bucket, String key) async => (await s3('GET', bucket, key: key)).bodyBytes;
  Future<void> putObject(String bucket, String key, Uint8List bytes, String contentType) =>
      s3('PUT', bucket, key: key, body: bytes, contentType: contentType);
  Future<void> deleteObject(String bucket, String key) => s3('DELETE', bucket, key: key);

  /// A presigned GET link that works for [expires].
  String presign(String bucket, String key, {Duration expires = const Duration(hours: 1)}) {
    final c = _r2();
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${now.year}${two(now.month)}${two(now.day)}';
    final stamp = '${date}T${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
    final scope = '$date/auto/s3/aws4_request';
    final path = '/${Uri.encodeComponent(bucket)}/${_encodeKey(key)}';
    final query = _canonicalQuery({
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': '${c.accessKeyId}/$scope',
      'X-Amz-Date': stamp,
      'X-Amz-Expires': '${expires.inSeconds.clamp(1, 604800)}',
      'X-Amz-SignedHeaders': 'host',
    });
    final canonical = ['GET', path, query, 'host:${c.host}', '', 'host', 'UNSIGNED-PAYLOAD'].join('\n');
    final toSign = ['AWS4-HMAC-SHA256', stamp, scope, _hex(sha256.convert(utf8.encode(canonical)).bytes)].join('\n');
    return 'https://${c.host}$path?$query&X-Amz-Signature=${_hex(_hmac(_signingKey(c, date), toSign))}';
  }
}

/// Cloudflare for agents: DNS, cache, Workers, KV, R2 storage, and reading
/// pages in a real browser. Changes need approval by default.
///
/// The token needs the permissions for what you use (Zone/DNS, Workers,
/// KV, R2, Browser Rendering). R2 object tools also need [r2] credentials.
class CloudflareToolkit extends Toolkit {
  CloudflareToolkit(
      {String? token,
      String accountId = '',
      R2Credentials? r2,
      this.defaultBucket,
      this.writeApproval = ApprovalPolicy.always,
      http.Client? httpClient})
      : client = CloudflareClient(token: token, accountId: accountId, r2: r2, httpClient: httpClient);

  final CloudflareClient client;

  /// The bucket R2 tools use when none is named.
  String? defaultBucket;

  /// Approval for tools that change things.
  final ApprovalPolicy writeApproval;

  String? get token => client.token;
  set token(String? v) => client.token = v;

  @override
  String get id => 'cloudflare';
  @override
  String get name => 'Cloudflare';
  @override
  String get apiKeyUrl => 'https://dash.cloudflare.com/profile/api-tokens';
  @override
  bool get isConfigured => token?.trim().isNotEmpty ?? false;
  @override
  Future<String?> verify() => client.verify();

  @override
  String get instructions => 'You can manage the user\'s Cloudflare account (DNS, cache, Workers, KV, R2 files) and read pages '
      'with browse_page. Say exactly what you will change before changing it.';

  static const _zone = {'type': 'string', 'description': 'Zone id or domain, e.g. example.com.'};
  Map<String, dynamic> _bucket() =>
      {'type': 'string', 'description': 'R2 bucket.${defaultBucket == null ? '' : ' Default: $defaultBucket.'}'};
  String _b(Map<String, dynamic> i) {
    final b = '${i['bucket'] ?? defaultBucket ?? ''}'.trim();
    if (b.isEmpty) throw const AiException('Name an R2 bucket.', provider: 'cloudflare');
    return b;
  }

  Map<String, dynamic> _obj(Map<String, dynamic> props, List<String> required) =>
      {'type': 'object', 'properties': props, 'required': required};

  @override
  Future<List<Tool>> tools() async => [
        Tool(
          name: 'browse_page',
          label: 'Reading a page',
          description: 'Opens a URL in a real browser (JavaScript runs) and returns the page as Markdown.',
          parametersJson: _obj({
            'url': {'type': 'string'}
          }, [
            'url'
          ]),
          execute: (i) async {
            final md = await client.markdown('${i['url']}');
            return {'url': i['url'], 'markdown': md.length > 20000 ? '${md.substring(0, 20000)}…' : md};
          },
        ),
        Tool(
          name: 'screenshot_page',
          label: 'Taking a screenshot',
          description: 'Takes a screenshot of a URL; the image is shown to the user.',
          parametersJson: _obj({
            'url': {'type': 'string'}
          }, [
            'url'
          ]),
          execute: (i) async => ToolOutput({'url': i['url'], 'screenshot': 'shown to the user'},
              files: [GeneratedFile(await client.screenshot('${i['url']}'), mediaType: 'image/png')]),
        ),
        Tool(
          name: 'cloudflare_zones',
          label: 'Listing domains',
          description: 'Lists the domains (zones) on the account.',
          execute: (_) async => {
            'zones': [
              for (final z in (await client.call('GET', '/zones', query: {'per_page': '50'}) as List).whereType<Map>())
                {'id': z['id'], 'name': z['name'], 'status': z['status'], 'plan': (z['plan'] as Map?)?['name']},
            ],
          },
        ),
        Tool(
          name: 'cloudflare_dns_records',
          label: 'Reading DNS',
          description: 'Lists DNS records of a zone, optionally of one type or name.',
          parametersJson: _obj({
            'zone': _zone,
            'type': {'type': 'string'},
            'name': {'type': 'string'}
          }, [
            'zone'
          ]),
          execute: (i) async {
            final z = await client.zoneId('${i['zone']}');
            final list = await client.call('GET', '/zones/$z/dns_records', query: {
              'per_page': '100',
              if (i['type'] != null) 'type': '${i['type']}'.toUpperCase(),
              if (i['name'] != null) 'name': '${i['name']}',
            });
            return {
              'records': [
                for (final r in (list as List).whereType<Map>())
                  {'id': r['id'], 'type': r['type'], 'name': r['name'], 'content': r['content'], 'proxied': r['proxied'], 'ttl': r['ttl']},
              ],
            };
          },
        ),
        Tool(
          name: 'cloudflare_set_dns_record',
          label: 'Changing DNS',
          approval: writeApproval,
          description: 'Creates a DNS record, or updates one when record_id is given.',
          parametersJson: _obj({
            'zone': _zone,
            'record_id': {'type': 'string'},
            'type': {'type': 'string', 'description': 'A, AAAA, CNAME, TXT, MX…'},
            'name': {'type': 'string'},
            'content': {'type': 'string'},
            'proxied': {'type': 'boolean'},
            'ttl': {'type': 'integer', 'description': '1 = automatic.'},
          }, [
            'zone',
            'type',
            'name',
            'content'
          ]),
          execute: (i) async {
            final z = await client.zoneId('${i['zone']}');
            final body = {
              'type': '${i['type']}'.toUpperCase(),
              'name': i['name'],
              'content': i['content'],
              if (i['proxied'] != null) 'proxied': i['proxied'],
              'ttl': i['ttl'] ?? 1,
            };
            final id = i['record_id'];
            final r = id == null
                ? await client.call('POST', '/zones/$z/dns_records', body: body)
                : await client.call('PATCH', '/zones/$z/dns_records/$id', body: body);
            return {'saved': true, 'record': r};
          },
        ),
        Tool(
          name: 'cloudflare_delete_dns_record',
          label: 'Deleting a DNS record',
          approval: writeApproval,
          description: 'Deletes a DNS record.',
          parametersJson: _obj({
            'zone': _zone,
            'record_id': {'type': 'string'}
          }, [
            'zone',
            'record_id'
          ]),
          execute: (i) async {
            final z = await client.zoneId('${i['zone']}');
            await client.call('DELETE', '/zones/$z/dns_records/${i['record_id']}');
            return {'deleted': i['record_id']};
          },
        ),
        Tool(
          name: 'cloudflare_purge_cache',
          label: 'Purging the cache',
          approval: writeApproval,
          description: 'Purges a zone\'s cache: everything, or only some URLs.',
          parametersJson: _obj({
            'zone': _zone,
            'urls': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          }, [
            'zone'
          ]),
          execute: (i) async {
            final z = await client.zoneId('${i['zone']}');
            final urls = [for (final u in (i['urls'] as List? ?? const [])) '$u'];
            await client.call('POST', '/zones/$z/purge_cache', body: urls.isEmpty ? {'purge_everything': true} : {'files': urls});
            return {'purged': urls.isEmpty ? 'everything' : urls};
          },
        ),
        Tool(
          name: 'cloudflare_workers',
          label: 'Listing Workers',
          description: 'Lists Workers scripts on the account.',
          execute: (_) async => {
            'workers': [
              for (final w in (await client.call('GET', '/accounts/${await client.account()}/workers/scripts') as List).whereType<Map>())
                {'name': w['id'], 'modified': w['modified_on']},
            ],
          },
        ),
        Tool(
          name: 'cloudflare_kv',
          label: 'Reading KV',
          description: 'Lists KV namespaces (no namespace), lists keys in one (namespace), or reads a value (namespace + key).',
          parametersJson: _obj({
            'namespace': {'type': 'string', 'description': 'Namespace id.'},
            'key': {'type': 'string'},
            'prefix': {'type': 'string'}
          }, []),
          execute: (i) async {
            final a = await client.account();
            final ns = i['namespace'];
            if (ns == null) {
              return {
                'namespaces': [
                  for (final n in (await client.call('GET', '/accounts/$a/storage/kv/namespaces') as List).whereType<Map>())
                    {'id': n['id'], 'title': n['title']},
                ],
              };
            }
            if (i['key'] == null) {
              final keys = await client
                  .call('GET', '/accounts/$a/storage/kv/namespaces/$ns/keys', query: {if (i['prefix'] != null) 'prefix': '${i['prefix']}'});
              return {
                'keys': [for (final k in (keys as List).whereType<Map>()) k['name']],
              };
            }
            final v = await client.call('GET', '/accounts/$a/storage/kv/namespaces/$ns/values/${Uri.encodeComponent('${i['key']}')}');
            return {'key': i['key'], 'value': v is String ? v : jsonEncode(v)};
          },
        ),
        Tool(
          name: 'cloudflare_kv_put',
          label: 'Writing KV',
          approval: writeApproval,
          description: 'Writes a value to a KV namespace.',
          parametersJson: _obj({
            'namespace': {'type': 'string'},
            'key': {'type': 'string'},
            'value': {'type': 'string'}
          }, [
            'namespace',
            'key',
            'value'
          ]),
          execute: (i) async {
            await client.call('PUT',
                '/accounts/${await client.account()}/storage/kv/namespaces/${i['namespace']}/values/${Uri.encodeComponent('${i['key']}')}',
                rawBody: '${i['value']}');
            return {'written': i['key']};
          },
        ),
        Tool(
          name: 'r2_buckets',
          label: 'Listing buckets',
          description: 'Lists R2 storage buckets.',
          execute: (_) async => {'buckets': await client.buckets()},
        ),
        Tool(
          name: 'r2_list',
          label: 'Listing files',
          description: 'Lists files and folders in an R2 bucket, one folder level at a time.',
          parametersJson: _obj({
            'bucket': _bucket(),
            'prefix': {'type': 'string', 'description': 'Folder, e.g. "reports/".'}
          }, []),
          execute: (i) => client.listObjects(_b(i), prefix: '${i['prefix'] ?? ''}'),
        ),
        Tool(
          name: 'r2_read',
          label: 'Reading a file',
          description: 'Reads a file from R2. Text comes back as text; images are shown to the user.',
          parametersJson: _obj({
            'bucket': _bucket(),
            'key': {'type': 'string'}
          }, [
            'key'
          ]),
          execute: (i) async {
            final bytes = await client.getObject(_b(i), '${i['key']}');
            final type = sniffMediaType(bytes, fallback: 'text/plain');
            if (type.startsWith('image/')) {
              return ToolOutput({'key': i['key'], 'image': 'shown to the user'}, files: [GeneratedFile(bytes, mediaType: type)]);
            }
            if (type != 'text/plain') return {'key': i['key'], 'media_type': type, 'bytes': bytes.length};
            final text = utf8.decode(bytes, allowMalformed: true);
            return {'key': i['key'], 'text': text.length > 20000 ? '${text.substring(0, 20000)}…' : text};
          },
        ),
        Tool(
          name: 'r2_write',
          label: 'Saving a file',
          approval: writeApproval,
          description: 'Saves text as a file in R2.',
          parametersJson: _obj({
            'bucket': _bucket(),
            'key': {'type': 'string'},
            'content': {'type': 'string'},
            'content_type': {'type': 'string'}
          }, [
            'key',
            'content'
          ]),
          execute: (i) async {
            await client.putObject(_b(i), '${i['key']}', Uint8List.fromList(utf8.encode('${i['content']}')),
                '${i['content_type'] ?? 'text/plain; charset=utf-8'}');
            return {'saved': i['key']};
          },
        ),
        Tool(
          name: 'r2_share_link',
          label: 'Making a link',
          description: 'A temporary download link for an R2 file.',
          parametersJson: _obj({
            'bucket': _bucket(),
            'key': {'type': 'string'},
            'hours': {'type': 'integer', 'description': '1-168, default 24.'}
          }, [
            'key'
          ]),
          execute: (i) async =>
              {'url': client.presign(_b(i), '${i['key']}', expires: Duration(hours: ((i['hours'] as num?) ?? 24).toInt().clamp(1, 168)))},
        ),
        Tool(
          name: 'r2_delete',
          label: 'Deleting a file',
          approval: writeApproval,
          description: 'Deletes a file from R2.',
          parametersJson: _obj({
            'bucket': _bucket(),
            'key': {'type': 'string'}
          }, [
            'key'
          ]),
          execute: (i) async {
            await client.deleteObject(_b(i), '${i['key']}');
            return {'deleted': i['key']};
          },
        ),
        Tool(
          name: 'cloudflare_api',
          label: 'Calling Cloudflare',
          description: 'Any Cloudflare API v4 call, for things the other tools don\'t cover. Path like '
              '/zones/{id}/settings. {account_id} in the path is filled in.',
          approval: ApprovalPolicy.when((i) => '${i['method'] ?? 'GET'}'.toUpperCase() != 'GET' ? writeApproval.requires(i) : false),
          parametersJson: _obj({
            'method': {
              'type': 'string',
              'enum': ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
            },
            'path': {'type': 'string'},
            'body': {'type': 'object'},
          }, [
            'path'
          ]),
          execute: (i) async {
            var path = '${i['path']}';
            if (path.contains('{account_id}')) path = path.replaceAll('{account_id}', await client.account());
            return {'result': await client.call('${i['method'] ?? 'GET'}'.toUpperCase(), path, body: i['body'])};
          },
        ),
      ];
}

/// Cloudflare Workers AI: open models on Cloudflare's network, through its
/// OpenAI-compatible endpoint. Model ids like `@cf/meta/llama-3.3-70b-instruct-fp8-fast`.
class CloudflareWorkersAiProvider extends OpenAICompatibleProvider {
  CloudflareWorkersAiProvider({String? token, required this.accountId, super.httpClient})
      : super(
          id: 'workersai',
          name: 'Cloudflare Workers AI',
          apiKey: token,
          baseUrl: 'https://api.cloudflare.com/client/v4/accounts/$accountId/ai/v1',
          supportedTypes: const {ModelType.text, ModelType.embedding},
        );

  @override
  String get apiKeyUrl => 'https://dash.cloudflare.com/profile/api-tokens';
  @override
  String get docsUrl => 'https://developers.cloudflare.com/workers-ai/';
  @override
  String get modelsDevId => 'cloudflare-workers-ai';

  final String accountId;

  /// Text-generation and embedding models from the Workers AI catalog.
  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancelToken}) async {
    final j = net.json(await net.get(
      Uri.parse('${CloudflareClient.api}/accounts/$accountId/ai/models/search?per_page=200'),
      headers: authHeaders(),
      cancelToken: cancelToken,
    ));
    final list = j is Map ? j['result'] : j;
    return [
      for (final m in (list as List? ?? const []).whereType<Map>())
        if (const {'Text Generation', 'Text Embeddings'}.contains((m['task'] as Map?)?['name']))
          ModelInfo(
            provider: id,
            modelId: '${m['name']}',
            name: '${m['name']}'.split('/').last,
            lab: '${m['name']}'.split('/').elementAtOrNull(1),
            description: '${m['description'] ?? ''}',
            types: (m['task'] as Map?)?['name'] == 'Text Embeddings' ? const {ModelType.embedding} : const {ModelType.text},
            openWeights: true,
          ),
    ];
  }
}
