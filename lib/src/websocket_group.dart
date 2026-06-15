import 'websocket_context.dart';

/// A managed group of WebSocket connections that can broadcast messages
/// to all members or individual clients.
///
/// [WebSocketGroup] is the recommended way to implement chat rooms, presence
/// channels, pub/sub feeds, or any feature that needs to push messages to
/// multiple connected clients.
///
/// ```dart
/// final rooms = <String, WebSocketGroup>{};
///
/// WebSocketGroup _room(String id) =>
///     rooms.putIfAbsent(id, () => WebSocketGroup());
///
/// WebSocketRoute(
///   path: '/ws/chat/:roomId',
///   onStart: (ctx) async {
///     final room = _room(ctx.request.params['roomId']!);
///     room.add(ctx);
///     room.broadcast('** A user joined **', exclude: ctx);
///   },
///   onMessage: (ctx, data) async {
///     _room(ctx.request.params['roomId']!).broadcast(data, exclude: ctx);
///   },
///   onClose: (ctx, code, reason) async {
///     final id = ctx.request.params['roomId']!;
///     _room(id).remove(ctx);
///     _room(id).broadcast('** A user left **');
///     if (_room(id).isEmpty) rooms.remove(id);
///   },
/// )
/// ```
class WebSocketGroup {
  final Set<WebSocketContext> _members = {};

  // ─── Membership ───────────────────────────────────────────────

  /// Adds [ctx] to the group.
  void add(WebSocketContext ctx) => _members.add(ctx);

  /// Removes [ctx] from the group.
  void remove(WebSocketContext ctx) => _members.remove(ctx);

  /// Returns true if the group has no members.
  bool get isEmpty => _members.isEmpty;

  /// Returns true if the group has at least one member.
  bool get isNotEmpty => _members.isNotEmpty;

  /// Number of active connections in this group.
  int get length => _members.length;

  /// An unmodifiable view of the current members.
  Set<WebSocketContext> get members => Set.unmodifiable(_members);

  // ─── Sending ──────────────────────────────────────────────────

  /// Sends [data] to every member of the group.
  ///
  /// Pass [exclude] to skip one context (e.g. the sender).
  /// Skips any member whose connection is closed.
  void broadcast(Object data, {WebSocketContext? exclude}) {
    for (final member in List.of(_members)) {
      if (member == exclude) continue;
      if (member.isOpen) {
        member.send(data);
      } else {
        // Lazily clean up stale closed connections.
        _members.remove(member);
      }
    }
  }

  /// JSON-encodes [data] and broadcasts it to every member.
  ///
  /// Pass [exclude] to skip one context (e.g. the sender).
  void broadcastJson(dynamic data, {WebSocketContext? exclude}) {
    for (final member in List.of(_members)) {
      if (member == exclude) continue;
      if (member.isOpen) {
        member.sendJson(data);
      } else {
        _members.remove(member);
      }
    }
  }

  /// Closes every connection in the group with an optional [code] and [reason].
  Future<void> closeAll([int? code, String? reason]) async {
    final snapshot = List.of(_members);
    _members.clear();
    for (final member in snapshot) {
      await member.close(code, reason);
    }
  }
}
