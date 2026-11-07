import 'dart:convert';

import '../core/middleware.dart';
import '../core/request.dart';
import '../core/response.dart';

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

  /// Creates a list field validator. Use [ListField.of] to check its items.
  static ListField list() => const ListField._();

  /// Creates a nested object field validator.
  ///
  /// ```dart
  /// 'address': Field.object({
  ///   'city': Field.string().required(),
  /// }).required(),
  /// ```
  static ObjectField object(Map<String, Field> fields) => ObjectField._(fields);

  /// Validates [raw] (the raw value from the body/params/query).
  /// Returns `null` on success, or an error message string on failure.
  String? validate(String fieldName, dynamic raw);

  /// Coerces [raw] into the field's expected type.
  dynamic coerce(dynamic raw) => raw;

  /// Whether the field must be present.
  bool get isRequired;

  /// Adds every problem with [raw] to [errors], keyed by its path, such as
  /// `address.city` or `tags[2]`.
  void collectErrors(String name, dynamic raw, Map<String, String> errors) {
    final error = validate(name, raw);
    if (error != null) errors[name] = error;
  }

  /// Describes this field as a JSON Schema, for the generated API docs.
  Map<String, dynamic> toJsonSchema();
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
  bool get isRequired => _isRequired;

  @override
  Map<String, dynamic> toJsonSchema() => {
        'type': 'string',
        if (_minLength != null) 'minLength': _minLength,
        if (_maxLength != null) 'maxLength': _maxLength,
        if (_pattern != null) 'pattern': _pattern!.pattern,
        if (_isEmail) 'format': 'email',
        if (_oneOf != null) 'enum': _oneOf,
      };

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null || (raw is String && raw.isEmpty)) {
      return _isRequired ? '$fieldName is required' : null;
    }
    if (raw is! String) return '$fieldName must be a string';
    final s = raw;
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
  bool get isRequired => _isRequired;

  @override
  Map<String, dynamic> toJsonSchema() => {
        'type': 'integer',
        if (_min != null) 'minimum': _min,
        if (_max != null) 'maximum': _max,
      };

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
  bool get isRequired => _isRequired;

  @override
  Map<String, dynamic> toJsonSchema() => {
        'type': 'number',
        if (_min != null) 'minimum': _min,
        if (_max != null) 'maximum': _max,
      };

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
  bool get isRequired => _isRequired;

  @override
  Map<String, dynamic> toJsonSchema() => {'type': 'boolean'};

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
  final Field? _items;

  const ListField._(
      {bool required = false, int? minItems, int? maxItems, Field? items})
      : _isRequired = required,
        _minItems = minItems,
        _maxItems = maxItems,
        _items = items,
        super._();

  ListField required() => ListField._(
      required: true, minItems: _minItems, maxItems: _maxItems, items: _items);
  ListField minItems(int n) => ListField._(
      required: _isRequired, minItems: n, maxItems: _maxItems, items: _items);
  ListField maxItems(int n) => ListField._(
      required: _isRequired, minItems: _minItems, maxItems: n, items: _items);

  /// Validates every item against [item].
  ListField of(Field item) => ListField._(
      required: _isRequired,
      minItems: _minItems,
      maxItems: _maxItems,
      items: item);

  @override
  bool get isRequired => _isRequired;

  @override
  Map<String, dynamic> toJsonSchema() => {
        'type': 'array',
        if (_minItems != null) 'minItems': _minItems,
        if (_maxItems != null) 'maxItems': _maxItems,
        if (_items != null) 'items': _items!.toJsonSchema(),
      };

  @override
  dynamic coerce(dynamic raw) {
    final items = _items;
    if (items == null || raw is! List) return raw;
    return [for (final item in raw) items.coerce(item)];
  }

  @override
  void collectErrors(String name, dynamic raw, Map<String, String> errors) {
    final error = validate(name, raw);
    if (error != null) {
      errors[name] = error;
      return;
    }
    final items = _items;
    if (items == null || raw is! List) return;
    for (var i = 0; i < raw.length; i++) {
      items.collectErrors('$name[$i]', raw[i], errors);
    }
  }

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

/// Nested object field.
class ObjectField extends Field {
  final bool _isRequired;
  final Map<String, Field> _fields;

  const ObjectField._(this._fields, {bool required = false})
      : _isRequired = required,
        super._();

  ObjectField required() => ObjectField._(_fields, required: true);

  @override
  bool get isRequired => _isRequired;

  @override
  Map<String, dynamic> toJsonSchema() => _objectSchema(_fields);

  /// Keeps only the declared fields, each coerced.
  @override
  dynamic coerce(dynamic raw) =>
      raw is Map<String, dynamic> ? _coerceFields(_fields, raw) : raw;

  @override
  void collectErrors(String name, dynamic raw, Map<String, String> errors) {
    final error = validate(name, raw);
    if (error != null) {
      errors[name] = error;
      return;
    }
    if (raw is! Map<String, dynamic>) return;
    _fields.forEach((key, field) {
      field.collectErrors('$name.$key', raw[key], errors);
    });
  }

  @override
  String? validate(String fieldName, dynamic raw) {
    if (raw == null) return _isRequired ? '$fieldName is required' : null;
    if (raw is! Map<String, dynamic>) return '$fieldName must be an object';
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

  /// Describes this schema as a JSON Schema, for the generated API docs.
  Map<String, dynamic> toJsonSchema() => _objectSchema(fields);
}

/// Validation middleware factory.
///
/// Validates the request body against [schema] before the handler runs.
/// Returns `422 Unprocessable Entity` with a map of field-level errors
/// if validation fails.
///
/// On success, `req.context[contextKey]` (default `'validated'`) holds the
/// declared fields only, coerced to their types: `"42"` becomes `42` for an
/// [IntField]. `req.body` is left as it was received.
///
/// ```dart
/// Route.post(
///   path: '/users',
///   handler: (req) async {
///     final user = req.context['validated'] as Map<String, dynamic>;
///     final age = user['age'] as int?;
///     ...
///   },
///   middlewares: [validate(createUserSchema)],
/// )
///
/// // On failure — 422:
/// // {"errors": {"email": "email is required", "address.city": "address.city is required"}}
/// ```
///
/// On a route's own `middlewares`, the schema also appears in the API docs at
/// `/quadrant_docs`.
Middleware validate(BodySchema schema, {String contextKey = 'validated'}) {
  Future<Response> middleware(Request req, Next next) async {
    final body = req.body;
    final data = body is Map ? body as Map<String, dynamic> : <String, dynamic>{};
    final errors = <String, String>{};

    schema.fields.forEach((name, field) {
      field.collectErrors(name, data[name], errors);
    });

    if (errors.isNotEmpty) {
      return Response(
        statusCode: 422,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'errors': errors}),
      );
    }

    req.setContext(contextKey, _coerceFields(schema.fields, data));
    return next();
  }

  _schemas[middleware] = schema;
  return middleware;
}

final _schemas = Expando<BodySchema>('quadrant_validate_schema');

/// The schema of a [validate] middleware, or null for any other middleware.
///
/// This is an **internal** API — not part of the public surface.
BodySchema? schemaOf(Middleware middleware) => _schemas[middleware];

// ─── Private helpers ──────────────────────────────────────────

Map<String, dynamic> _coerceFields(
  Map<String, Field> fields,
  Map<String, dynamic> data,
) =>
    {
      for (final entry in fields.entries)
        if (data.containsKey(entry.key))
          entry.key: entry.value.coerce(data[entry.key]),
    };

Map<String, dynamic> _objectSchema(Map<String, Field> fields) {
  final required = [
    for (final entry in fields.entries)
      if (entry.value.isRequired) entry.key,
  ];
  return {
    'type': 'object',
    if (required.isNotEmpty) 'required': required,
    'properties': {
      for (final entry in fields.entries)
        entry.key: entry.value.toJsonSchema(),
    },
  };
}

final _emailRegex = RegExp(
  r'^[a-zA-Z0-9.!#$%&'
  r"'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}"
  r'[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$',
);
