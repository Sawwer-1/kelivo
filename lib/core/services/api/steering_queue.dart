/// D1 Steering: mid-generation user instructions.
///
/// While a generation with tool rounds is running, the user can still type
/// into the composer. Their text lands here as a pending per-conversation
/// queue. The tool loop drains the queue after each round's tool results and
/// appends the texts as user messages before the next model call, so the
/// instruction takes effect inside the running task instead of waiting for
/// the whole generation to finish.
///
/// The queue is intentionally in-memory only: the text has not been persisted
/// as a chat message yet. The drain callback (owned by ChatActions) persists
/// and renders it exactly once — either at injection time, or, when the
/// generation ends before reaching another tool round, when the leftover text
/// is handed back to the queued-input flow which sends it through the normal
/// path. A crash therefore loses nothing that was visible to the user: either
/// the message was already persisted, or it never left the composer.
final class SteeringService {
  SteeringService._();

  static final SteeringService instance = SteeringService._();

  final Map<String, List<String>> _pending = <String, List<String>>{};

  /// Queue [text] as a steering instruction for [conversationId].
  void enqueue(String conversationId, String text) {
    final trimmed = text.trim();
    if (conversationId.isEmpty || trimmed.isEmpty) return;
    _pending.putIfAbsent(conversationId, () => <String>[]).add(trimmed);
  }

  /// Remove and return every pending steering text for [conversationId],
  /// oldest first. Returns an empty list when nothing is pending.
  List<String> drain(String conversationId) {
    final texts = _pending.remove(conversationId);
    if (texts == null || texts.isEmpty) return const <String>[];
    return List<String>.of(texts);
  }

  /// Whether [conversationId] has pending steering text.
  bool hasPending(String conversationId) =>
      (_pending[conversationId] ?? const <String>[]).isNotEmpty;

  /// Drop pending steering for [conversationId] without delivering it.
  void clear(String conversationId) => _pending.remove(conversationId);
}
