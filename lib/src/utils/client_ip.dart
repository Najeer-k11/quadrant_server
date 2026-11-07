import 'dart:io';

/// Reads the client IP from an `X-Forwarded-For` value, given the number of
/// proxies in front of the server.
///
/// Each proxy appends the address it received the request from, so counting
/// [trustedProxyHops] entries from the right gives one that your own proxy
/// added. Anything further left comes from the client and could be forged.
///
/// Returns null if the header has too few entries.
String? forwardedClientIp(String forwardedFor, int trustedProxyHops) {
  final entries = forwardedFor.split(',');
  if (entries.length < trustedProxyHops) return null;
  return entries[entries.length - trustedProxyHops].trim();
}

/// The key that identifies one client for rate limiting, given its IP.
///
/// A single IPv6 client usually controls a whole /64, so counting per address
/// would let it pick a new address for every request. IPv6 addresses are
/// grouped by /64, and IPv4-mapped ones count as the IPv4 address they carry.
/// Anything that is not an IPv6 address is returned unchanged.
String clientRateLimitKey(String ip) {
  if (!ip.contains(':')) return ip; // Skips parsing for the common IPv4 case.

  final parsed = InternetAddress.tryParse(ip);
  if (parsed == null || parsed.type != InternetAddressType.IPv6) return ip;

  final raw = parsed.rawAddress;
  final isIpv4Mapped = raw[10] == 0xff &&
      raw[11] == 0xff &&
      raw.take(10).every((byte) => byte == 0);
  if (isIpv4Mapped) return raw.skip(12).join('.');

  final network = [
    for (var i = 0; i < 8; i += 2)
      ((raw[i] << 8) | raw[i + 1]).toRadixString(16),
  ].join(':');
  return '$network::/64';
}
