import 'dart:convert';

/// Pulls JSON out of a model's reply: plain, fenced in ```json, or with
/// words around it. Returns null when there is none.
Object? extractJson(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  try {
    return jsonDecode(t);
  } catch (_) {}
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) {
    try {
      return jsonDecode(fence.group(1)!.trim());
    } catch (_) {}
  }
  final start = t.indexOf(RegExp(r'[\[{]'));
  if (start < 0) return null;
  final open = t[start];
  final end = t.lastIndexOf(open == '{' ? '}' : ']');
  if (end <= start) return null;
  try {
    return jsonDecode(t.substring(start, end + 1));
  } catch (_) {
    return null;
  }
}

/// Parses JSON that is still streaming in, closing open strings, arrays and
/// objects. Returns null when nothing usable has arrived yet.
Object? parsePartialJson(String text) {
  var t = text.trim();
  if (t.startsWith('```')) {
    final nl = t.indexOf('\n');
    t = nl < 0 ? '' : t.substring(nl + 1);
  }
  final fenceEnd = t.indexOf('```');
  if (fenceEnd >= 0) t = t.substring(0, fenceEnd);
  final start = t.indexOf(RegExp(r'[\[{]'));
  if (start < 0) return null;
  t = t.substring(start);

  // Drop characters from the end until the closed-up text parses. Most
  // chunks need no trimming; a dangling key or half a literal needs a few.
  for (var cut = t.length; cut > 0; cut--) {
    final s = t.substring(0, cut);
    final closed = _close(s);
    if (closed == null) continue;
    try {
      return jsonDecode(closed);
    } catch (_) {
      if (t.length - cut > 64) return null;
    }
  }
  return null;
}

/// [s] with its open string, arrays and objects closed, or null when it
/// ends somewhere no closing can fix (after a comma or colon).
String? _close(String s) {
  final stack = <String>[];
  var inString = false;
  var escaped = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      stack.add('}');
    } else if (c == '[') {
      stack.add(']');
    } else if (c == '}' || c == ']') {
      if (stack.isEmpty) return null;
      stack.removeLast();
    }
  }
  var out = s;
  if (inString) {
    if (escaped) out = out.substring(0, out.length - 1);
    out += '"';
  }
  final tail = out.trimRight();
  if (tail.endsWith(',') || tail.endsWith(':')) return null;
  return out + stack.reversed.join();
}
