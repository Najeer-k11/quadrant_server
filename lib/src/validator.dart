import 'dart:convert';

import 'middleware.dart';
import 'request.dart';
import 'response.dart';

// ─── Field definitions ────────────────────────────────────────

/// Base class for all field validators.
abstract class Field {
  const Field._();

  /// Creates a string field validator.
  static StringField string() => const StringField._();

  /// Creates an integer field validator.
  static IntField int_() => const IntField._();

  /// Creates a double/number field validator.
  static DoubleField double_() => const DoubleField._();

  /// Creates a boolean field validator.
  static BoolField bool_() => const BoolField._();

  /// Creates a list field validator.
  static ListField list() => const ListField._();

  /// Validates [raw] (the raw value from the body/params/query).
  /// Returns `null` on success, or an error message string on failure.
  String? validate(String fieldName, dynamic raw);

  /// Coerces [raw] into the field's expected type.
  dynamic coerce(dynamic raw) => raw;
}

/// String field with optional constraints.
class StringField extends Field {
  final bool _isRequired;
  final int? _minLength;
  final int? _maxLength;
  final RegExp? _pattern;
  final bool _isEmail;
  final List<String>? _oneOf;

  const StringField._({
    bool required = false,
    int? minLength,
    int? maxLength,
    RegExp? pattern,
    bool isEmail = false,
    List<String>? oneOf,
  })  : _isRequired = required,
        _minLength = minLength,
        _maxLength = maxLength,
        _pattern = pattern,
        _isEmail = isEmail,
        _oneOf = oneOf,
        super._();

  /// Marks this field as required.
  StringField required() => StringField._(
      required: true,
      minLength: _minLength,
      maxLength: _maxLength,
      pattern: _pattern,
      isEmail: _isEmail,
      oneOf: _oneOf);

  /// Minimum string length.
  StringField minLength(int n) => StringField._(
      required: _isRequired,
      minLength: n,
      maxLength: _maxLength,
      pattern: _pattern,
      isEmail: _isEmail,
      oneOf: _oneOf);

  /// Maximum string length.
  StringField maxLength(int n) => StringField._(
      required: _isRequired,
      minLength: _minLength,
      maxLength: n,
      pattern: _pattern,
      isEmail: _isEmail,
      oneOf: _oneOf);

  /// Validates against a regular expression.
  StringField matches(RegExp pattern) => StringField._(
      required: _isRequired,
      minLength: _minLength,
      maxLength: _maxLength,
      pattern: pattern,
      isEmail: _isEmail,
      oneOf: _oneOf);

  /// Validates as an email address (simple RFC-5321 check).
  StringField email() => StringField._(
      required: _isRequired,
      minLength: _minLength,
      maxLength: _maxLength,
      pattern: _pattern,
      isEmail: true,
      oneOf: _oneOf);

  /// Validates that the value is one of the given options.
  StringField oneOf(List<String> options) => StringField._(
      required: _isRequired,
      minLength: _minLength,
      maxLength: _maxLength,
      pattern: _pattern,
      isEmail: _isEmail,
      oneOf: options);

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null || (raw is String && raw.isEmpty)) {
      return _isRequired ? '$fieldName is required' : null;
    }
    final s = raw.toString();
    if (_minLength != null && s.length < _minLength!) {
      return '$fieldName must be at least $_minLength characters';
    }
    if (_maxLength != null && s.length > _maxLength!) {
      return '$fieldName must be at most $_maxLength characters';
    }
    if (_isEmail && !_emailRegex.hasMatch(s)) {
      return '$fieldName must be a valid email address';
    }
    if (_pattern != null && !_pattern!.hasMatch(s)) {
      return '$fieldName has an invalid format';
    }
    if (_oneOf != null && !_oneOf!.contains(s)) {
      return '$fieldName must be one of: ${_oneOf!.join(', ')}';
    }
    return null;
  }
}

/// Integer field with optional range constraints.
class IntField extends Field {
  final bool _isRequired;
  final int? _min;
  final int? _max;

  const IntField._({bool required = false, int? min, int? max})
      : _isRequired = required,
        _min = min,
        _max = max,
        super._();

  IntField required() => IntField._(required: true, min: _min, max: _max);
  IntField min(int n) => IntField._(required: _isRequired, min: n, max: _max);
  IntField max(int n) => IntField._(required: _isRequired, min: _min, max: n);

  @override
  int? coerce(dynamic raw) {
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null) return _isRequired ? '$fieldName is required' : null;
    final v = coerce(raw);
    if (v == null) return '$fieldName must be an integer';
    if (_min != null && v < _min!) return '$fieldName must be ≥ $_min';
    if (_max != null && v > _max!) return '$fieldName must be ≤ $_max';
    return null;
  }
}

/// Double/number field with optional range constraints.
class DoubleField extends Field {
  final bool _isRequired;
  final double? _min;
  final double? _max;

  const DoubleField._({bool required = false, double? min, double? max})
      : _isRequired = required,
        _min = min,
        _max = max,
        super._();

  DoubleField required() =>
      DoubleField._(required: true, min: _min, max: _max);
  DoubleField min(double n) =>
      DoubleField._(required: _isRequired, min: n, max: _max);
  DoubleField max(double n) =>
      DoubleField._(required: _isRequired, min: _min, max: n);

  @override
  double? coerce(dynamic raw) {
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null) return _isRequired ? '$fieldName is required' : null;
    final v = coerce(raw);
    if (v == null) return '$fieldName must be a number';
    if (_min != null && v < _min!) return '$fieldName must be ≥ $_min';
    if (_max != null && v > _max!) return '$fieldName must be ≤ $_max';
    return null;
  }
}

/// Boolean field.
class BoolField extends Field {
  final bool _isRequired;

  const BoolField._({bool required = false})
      : _isRequired = required,
        super._();

  BoolField required() => BoolField._(required: true);

  @override
  dynamic coerce(dynamic raw) {
    if (raw is bool) return raw;
    if (raw == 'true' || raw == '1' || raw == 'yes') return true;
    if (raw == 'false' || raw == '0' || raw == 'no') return false;
    return null;
  }

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null) return _isRequired ? '$fieldName is required' : null;
    if (coerce(raw) == null) return '$fieldName must be a boolean';
    return null;
  }
}

/// List field.
class ListField extends Field {
  final bool _isRequired;
  final int? _minItems;
  final int? _maxItems;

  const ListField._({bool required = false, int? minItems, int? maxItems})
      : _isRequired = required,
        _minItems = minItems,
        _maxItems = maxItems,
        super._();


  ListField required() =>
      ListField._(required: true, minItems: _minItems, maxItems: _maxItems);
  ListField minItems(int n) =>
      ListField._(required: _isRequired, minItems: n, maxItems: _maxItems);
  ListField maxItems(int n) =>
      ListField._(required: _isRequired, minItems: _minItems, maxItems: n);

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null) return _isRequired ? '$fieldName is required' : null;
    if (raw is! List) return '$fieldName must be a list';
    if (_minItems != null && raw.length < _minItems!) {
      return '$fieldName must have at least $_minItems item(s)';
    }
    if (_maxItems != null && raw.length > _maxItems!) {
      return '$fieldName must have at most $_maxItems item(s)';
    }
    return null;
  }
}

// ─── Schema and middleware ────────────────────────────────────

/// A schema that validates fields in the request body.
///
/// ```dart
/// final createUserSchema = BodySchema({
///   'email':    Field.string().email().required(),
///   'name':     Field.string().minLength(2).required(),
///   'age':      Field.int_().min(0).max(150),
///   'role':     Field.string().oneOf(['admin', 'user']).required(),
///   'active':   Field.bool_(),
/// });
/// ```
class BodySchema {
  final Map<String, Field> fields;
  const BodySchema(this.fields);
}

/// Validation middleware factory.
///
/// Validates the request body against [schema] before the handler runs.
/// Returns `422 Unprocessable Entity` with a map of field-level errors
/// if validation fails.
///
/// ```dart
/// Route.post(
///   path: '/users',
///   handler: createUser,
///   middlewares: [validate(createUserSchema)],
/// )
///
/// // On failure — 422:
/// // {"errors": {"email": "email is required", "role": "role must be one of: admin, user"}}
/// ```
Middleware validate(BodySchema schema) {
  return (Request req, Next next) async {
    final body = req.body;
    final data = body is Map ? body as Map<String, dynamic> : <String, dynamic>{};
    final errors = <String, String>{};

    for (final entry in schema.fields.entries) {
      final fieldName = entry.key;
      final field = entry.value;
      final raw = data[fieldName];
      final error = field.validate(fieldName, raw);
      if (error != null) errors[fieldName] = error;
    }

    if (errors.isNotEmpty) {
      return Response(
        statusCode: 422,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'errors': errors}),
      );
    }

    return next();
  };
}

// ─── Private helpers ──────────────────────────────────────────

final _emailRegex = RegExp(
  r'^[a-zA-Z0-9.!#$%&'
  r"'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}"
  r'[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$',
);
