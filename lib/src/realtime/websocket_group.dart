import 'dart:async';
import 'dart:convert';

import '../cluster/cluster_link.dart';
import 'websocket_context.dart';

/// Named groups with members in this isolate, to deliver messages from others.
/// A group leaves when it has no members, so finished rooms are not kept.
final Map<String, Set<WebSocketGroup>> _namedGroups = {};

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
///
/// ### In a `QuadrantCluster`
///
/// Give the group a [name]. Groups with the same name on different isolates
/// act as one: [broadcast], [broadcastJson] and [closeAll] reach all of their
/// members. [length], [isEmpty] and [members] still only cover this isolate.
///
/// ```dart
/// WebSocketGroup _room(String id) =>
///     rooms.putIfAbsent(id, () => WebSocketGroup(name: 'room:$id'));
/// ```
///
/// A group without a name throws when a member is added in a cluster, because
/// it would silently miss clients on other isolates. Use
/// [WebSocketGroup.local] if that is what you want.
class WebSocketGroup {
  /// Identifies this group across the isolates of a cluster.
  final String? name;

  final bool _local;
  final Set<WebSocketContext> _members = {};

  WebSocketGroup({this.name}) : _local = false;

  /// A group that only ever covers this isolate, even in a cluster.
  WebSocketGroup.local()
      : name = null,
        _local = true;

  // ─── Membership ───────────────────────────────────────────────

  /// Adds [ctx] to the group. It leaves the group by itself once its
  /// connection closes, so a closed connection is never kept in memory.
  void add(WebSocketContext ctx) {
    final link = currentClusterLink;
    if (link != null && name == null && !_local) {
      throw StateError(
        'A WebSocketGroup in a QuadrantCluster needs a name, or it would miss '
        'clients on other isolates. Use WebSocketGroup(name: ...), or '
        'WebSocketGroup.local() to stay on this isolate.',
      );
    }
    _members.add(ctx);
    final groupName = name;
    if (groupName != null && link != null) {
      link
        ..onGroupData = _deliverData
        ..onGroupClose = _deliverClose;
      (_namedGroups[groupName] ??= {}).add(this);
    }
    unawaited(ctx.socket.done
        .whenComplete(() => remove(ctx))
        .catchError((_) {}));
  }

  /// Removes [ctx] from the group.
  void remove(WebSocketContext ctx) {
    _members.remove(ctx);
    if (_members.isEmpty) _unregister();
  }

  void _unregister() {
    final groups = _namedGroups[name];
    if (groups == null) return;
    groups.remove(this);
    if (groups.isEmpty) _namedGroups.remove(name);
  }

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
    _sendLocally(data, exclude: exclude);
    final groupName = name;
    if (groupName != null) currentClusterLink?.sendToGroup(groupName, data);
  }

  /// JSON-encodes [data] and broadcasts it to every member.
  ///
  /// Pass [exclude] to skip one context (e.g. the sender).
  void broadcastJson(dynamic data, {WebSocketContext? exclude}) {
    broadcast(jsonEncode(data), exclude: exclude);
  }

  void _sendLocally(Object data, {WebSocketContext? exclude}) {
    for (final member in List.of(_members)) {
      if (member == exclude) continue;
      if (member.isOpen) {
        member.send(data);
      } else {
        // Lazily clean up stale closed connections.
        remove(member);
      }
    }
  }

  /// Closes every connection in the group with an optional [code] and [reason].
  Future<void> closeAll([int? code, String? reason]) async {
    final groupName = name;
    if (groupName != null) {
      currentClusterLink?.closeGroup(groupName, code, reason);
    }
    await _closeLocally(code, reason);
  }

  Future<void> _closeLocally(int? code, String? reason) async {
    final snapshot = List.of(_members);
    _members.clear();
    _unregister();
    for (final member in snapshot) {
      await member.close(code, reason);
    }
  }
}

void _deliverData(String name, Object data) {
  for (final group in List.of(_namedGroups[name] ?? const <WebSocketGroup>{})) {
    group._sendLocally(data);
  }
}

void _deliverClose(String name, int? code, String? reason) {
  for (final group in List.of(_namedGroups[name] ?? const <WebSocketGroup>{})) {
    unawaited(group._closeLocally(code, reason));
  }
}
