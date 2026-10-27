/// Tokens (and, when the provider says, dollars) a call used.
class Usage {
  const Usage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.reasoningTokens = 0,
    this.cachedInputTokens = 0,
    this.cost,
  });

  /// Reads OpenAI, Gemini and Addis usage objects alike.
  factory Usage.fromJson(Object? j) {
    if (j is! Map) return const Usage();
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
    final promptDetails = j['prompt_tokens_details'];
    final completionDetails = j['completion_tokens_details'];
    return Usage(
      inputTokens:
          n(j['prompt_tokens'] ?? j['input_tokens'] ?? j['promptTokenCount'] ?? j['prompt_token_count'] ?? j['total_input_tokens']),
      outputTokens: n(j['completion_tokens'] ??
          j['output_tokens'] ??
          j['candidatesTokenCount'] ??
          j['candidates_token_count'] ??
          j['total_output_tokens']),
      reasoningTokens: n((completionDetails is Map ? completionDetails['reasoning_tokens'] : null) ??
          j['thoughtsTokenCount'] ??
          j['total_thought_tokens']),
      cachedInputTokens: n((promptDetails is Map ? promptDetails['cached_tokens'] : null) ??
          j['cache_read_input_tokens'] ??
          j['cachedContentTokenCount'] ??
          j['total_cached_tokens']),
      cost: j['cost'] is num ? (j['cost'] as num).toDouble() : double.tryParse('${j['cost'] ?? ''}'),
    );
  }

  final int inputTokens;
  final int outputTokens;
  final int reasoningTokens;
  final int cachedInputTokens;

  /// USD, when the provider reports it (OpenRouter, Vercel AI Gateway).
  final double? cost;

  int get totalTokens => inputTokens + outputTokens;

  Usage operator +(Usage o) => Usage(
        inputTokens: inputTokens + o.inputTokens,
        outputTokens: outputTokens + o.outputTokens,
        reasoningTokens: reasoningTokens + o.reasoningTokens,
        cachedInputTokens: cachedInputTokens + o.cachedInputTokens,
        cost: cost == null && o.cost == null ? null : (cost ?? 0) + (o.cost ?? 0),
      );

  Map<String, dynamic> toJson() => {
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'reasoningTokens': reasoningTokens,
        'cachedInputTokens': cachedInputTokens,
        if (cost != null) 'cost': cost,
      };

  @override
  String toString() => 'Usage(in: $inputTokens, out: $outputTokens${cost == null ? '' : ', \$$cost'})';
}

/// Why a model stopped.
enum FinishReason {
  stop,
  length,
  toolCalls,
  contentFilter,
  error,
  other,
  unknown;

  static FinishReason parse(String? s) => switch (s?.toLowerCase()) {
        null => unknown,
        'stop' || 'end_turn' || 'stop_sequence' || 'finish_reason_stop' || 'completed' => stop,
        'length' || 'max_tokens' || 'incomplete' => length,
        'tool_calls' || 'function_call' || 'tool_use' || 'requires_action' => toolCalls,
        'content_filter' || 'safety' || 'recitation' || 'blocklist' || 'prohibited_content' || 'spii' => contentFilter,
        'error' || 'failed' => error,
        _ => other,
      };
}

/// How hard a reasoning model should think.
enum ReasoningEffort { none, minimal, low, medium, high, xhigh }
