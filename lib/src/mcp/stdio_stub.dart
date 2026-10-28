import '../core/cancel.dart';
import 'mcp.dart';

/// Stdio MCP servers need `dart:io` (desktop / mobile, not web).
class StdioMcpSession extends McpJsonRpcSession {
  StdioMcpSession(McpServer server) {
    throw McpException('Stdio MCP ("${server.id}") is not available on this platform. Use an HTTP or SSE server.');
  }

  @override
  Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic>? params, CancelToken? cancelToken]) =>
      throw UnsupportedError('stdio');

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {}
}
