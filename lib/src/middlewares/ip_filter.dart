import 'dart:io';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// IP allow/deny filter middleware.
///
/// Restricts access based on the client's remote IP address. Supports both
/// exact IP addresses and CIDR notation for subnet ranges.
///
/// **Provide exactly one of [allow] or [deny]** (not both):
///
/// ```dart
/// // Allow only specific IPs / subnets:
/// ipFilter(allow: ['127.0.0.1', '::1', '192.168.1.0/24'])
///
/// // Deny specific IPs / subnets:
/// ipFilter(deny: ['1.2.3.4', '10.0.0.0/8'])
///
/// // Custom rejection response:
/// ipFilter(
///   deny: ['1.2.3.4'],
///   onDeny: (req) => Response.forbidden('Your IP has been blocked.'),
/// )
/// ```
///
/// [allow] — if set, only IPs matching an entry are allowed; all others → 403.
/// [deny] — if set, IPs matching an entry are blocked → 403; all others pass.
/// [onDeny] — optional factory for the rejection response.
Middleware ipFilter({
  List<String> allow = const [],
  List<String> deny = const [],
  Response Function(Request req)? onDeny,
}) {
  assert(allow.isEmpty || deny.isEmpty,
      'ipFilter: provide either [allow] or [deny], not both.');

  final allowRules = allow.map(_CidrRule.parse).toList();
  final denyRules = deny.map(_CidrRule.parse).toList();

  return (Request req, Next next) async {
    final remote = req.raw.connectionInfo?.remoteAddress;
    if (remote == null) return next(); // no IP info — pass through

    final ip = remote;

    // Allow-list mode: reject if IP does not match any rule.
    if (allowRules.isNotEmpty) {
      final allowed = allowRules.any((r) => r.matches(ip));
      if (!allowed) {
        return onDeny?.call(req) ??
            Response(
              statusCode: 403,
              headers: {'content-type': 'application/json'},
              body: '{"error":"Forbidden","ip":"${ip.address}"}',
            );
      }
    }

    // Deny-list mode: reject if IP matches any rule.
    if (denyRules.isNotEmpty) {
      final blocked = denyRules.any((r) => r.matches(ip));
      if (blocked) {
        return onDeny?.call(req) ??
            Response(
              statusCode: 403,
              headers: {'content-type': 'application/json'},
              body: '{"error":"Forbidden","ip":"${ip.address}"}',
            );
      }
    }

    return next();
  };
}

// ─── CIDR Rule ───────────────────────────────────────────────

/// Internal representation of an IP or CIDR rule.
class _CidrRule {
  final InternetAddress network;
  final int prefixLength; // -1 means exact match (no CIDR)
  final int _maskBits;    // pre-computed mask for IPv4

  _CidrRule._(this.network, this.prefixLength, this._maskBits);

  factory _CidrRule.parse(String rule) {
    final slash = rule.indexOf('/');
    if (slash == -1) {
      // Exact IP match.
      return _CidrRule._(InternetAddress(rule), -1, 0);
    }
    final ip = rule.substring(0, slash);
    final prefix = int.parse(rule.substring(slash + 1));
    final addr = InternetAddress(ip);
    int mask = 0;
    if (addr.type == InternetAddressType.IPv4 && prefix >= 0 && prefix <= 32) {
      mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    }
    return _CidrRule._(addr, prefix, mask);
  }

  bool matches(InternetAddress ip) {
    if (prefixLength == -1) {
      // Exact match.
      return ip.address == network.address;
    }

    if (ip.type != network.type) return false;

    if (ip.type == InternetAddressType.IPv4) {
      final ipInt = _ipv4ToInt(ip.rawAddress);
      final netInt = _ipv4ToInt(network.rawAddress);
      return (ipInt & _maskBits) == (netInt & _maskBits);
    }

    // IPv6 CIDR — compare bit by bit up to prefixLength.
    final ipBytes = ip.rawAddress;
    final netBytes = network.rawAddress;
    var bitsLeft = prefixLength;
    for (var i = 0; i < 16 && bitsLeft > 0; i++) {
      final bits = bitsLeft >= 8 ? 8 : bitsLeft;
      final mask = (0xFF << (8 - bits)) & 0xFF;
      if ((ipBytes[i] & mask) != (netBytes[i] & mask)) return false;
      bitsLeft -= bits;
    }
    return true;
  }

  static int _ipv4ToInt(List<int> bytes) =>
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
}
