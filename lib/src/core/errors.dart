/// Base class of every error this package throws.
class AiException implements Exception {
  const AiException(this.message, {this.provider, this.statusCode, this.body});

  /// A sentence a person can read.
  final String message;

  /// Which provider answered, e.g. `gateway`, `google`.
  final String? provider;

  /// The HTTP status, when the error came from an HTTP response.
  final int? statusCode;

  /// The raw response body, for debugging.
  final String? body;

  /// True for 401 and 403 answers: the key is missing, wrong or not allowed.
  bool get isAuthError => statusCode == 401 || statusCode == 403;

  /// True for 429 answers.
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => message;
}

/// No API key (or server address) was set for the provider a model needs.
class MissingApiKeyException extends AiException {
  const MissingApiKeyException(String provider, String name) : super('Add a $name API key to use this model.', provider: provider);
}

/// The request was cancelled with a [CancelToken].
class AiCancelledException extends AiException {
  const AiCancelledException() : super('Cancelled.');
}

/// The provider or model can't do what was asked (e.g. tools on Addis AI).
class UnsupportedFeatureException extends AiException {
  const UnsupportedFeatureException(super.message, {super.provider});
}

/// A model id the registry can't resolve, e.g. `nope:model`.
class UnknownModelException extends AiException {
  const UnknownModelException(super.message);
}

/// The model answered, but not with valid JSON for [generateObject].
class ObjectParseException extends AiException {
  const ObjectParseException(super.message, {this.text});
  final String? text;
}
