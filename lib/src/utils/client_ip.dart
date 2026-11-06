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
