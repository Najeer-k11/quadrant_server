import '../middleware.dart';
import '../request.dart';

/// Security headers middleware ("helmet").
///
/// Adds 8 standard HTTP security response headers that harden the browser's
/// security model with minimal configuration.
///
/// All parameters accept a `String` value to override the default, or `null`
/// to omit that header entirely.
///
/// ```dart
/// // All defaults:
/// helmet()
///
/// // Override one header:
/// helmet(frameOptions: 'DENY')
///
/// // Disable a header:
/// helmet(xssProtection: null)
///
/// // HTTPS-only mode (enables HSTS):
/// helmet(hsts: 'max-age=31536000; includeSubDomains; preload')
/// ```
///
/// ### Default headers set
///
/// | Header | Default |
/// |--------|---------|
/// | `X-Content-Type-Options` | `nosniff` |
/// | `X-Frame-Options` | `SAMEORIGIN` |
/// | `X-XSS-Protection` | `0` (disabled — use CSP instead) |
/// | `Referrer-Policy` | `strict-origin-when-cross-origin` |
/// | `Permissions-Policy` | `geolocation=(), camera=(), microphone=()` |
/// | `Strict-Transport-Security` | `max-age=15552000; includeSubDomains` |
/// | `Cross-Origin-Opener-Policy` | `same-origin` |
/// | `Cross-Origin-Resource-Policy` | `same-origin` |
Middleware helmet({
  String? contentTypeOptions = 'nosniff',
  String? frameOptions = 'SAMEORIGIN',
  /// Set to `'0'` (the default) to disable the legacy XSS auditor.
  /// Modern best practice is to rely on CSP instead.
  String? xssProtection = '0',
  String? referrerPolicy = 'strict-origin-when-cross-origin',
  String? permissionsPolicy =
      'geolocation=(), camera=(), microphone=()',
  /// HTTP Strict Transport Security. Set to `null` on HTTP-only servers.
  String? hsts = 'max-age=15552000; includeSubDomains',
  String? crossOriginOpenerPolicy = 'same-origin',
  String? crossOriginResourcePolicy = 'same-origin',
}) {
  final securityHeaders = <String, String>{
    if (contentTypeOptions != null)
      'x-content-type-options': contentTypeOptions,
    if (frameOptions != null) 'x-frame-options': frameOptions,
    if (xssProtection != null) 'x-xss-protection': xssProtection,
    if (referrerPolicy != null) 'referrer-policy': referrerPolicy,
    if (permissionsPolicy != null) 'permissions-policy': permissionsPolicy,
    if (hsts != null) 'strict-transport-security': hsts,
    if (crossOriginOpenerPolicy != null)
      'cross-origin-opener-policy': crossOriginOpenerPolicy,
    if (crossOriginResourcePolicy != null)
      'cross-origin-resource-policy': crossOriginResourcePolicy,
  };

  return (Request req, Next next) async {
    final response = await next();

    // Merge security headers — existing response headers take precedence
    // so handlers can override a specific header if truly needed.
    final merged = <String, String>{...securityHeaders, ...response.headers};

    return response.copyWith(headers: merged);
  };
}
