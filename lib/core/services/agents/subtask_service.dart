import 'dart:async';
import 'dart:convert';

import '../../../features/home/services/local_tools_service.dart';
import '../../../utils/utf16_safe_cut.dart';

/// G6 Sub-agent: lets a model delegate a self-contained task to a fresh
/// conversation of any assistant.
///
/// The executor is attached once per app start by HomePageController (the
/// only place with a HomeViewModel). Tool calls made inside a subtask keep
/// the standard approval flow — a subtask never inherits pre-approved
/// permissions; while an approval/question is pending the waiter reports
/// `user_interaction_required` instead of answering for the user.
class SubtaskService {
  SubtaskService._();
  static final SubtaskService instance = SubtaskService._();

  Future<Map<String, Object?>> Function({
    required String prompt,
    required String assistantId,
    String? title,
    required bool wait,
  })? _executor;

  /// Whether an executor is attached (app UI is up and the chat stack is
  /// initialized). Tool calls before that are rejected with
  /// `subtask_unavailable` instead of crashing.
  bool get supported => _executor != null;

  void attach(
    Future<Map<String, Object?>> Function({
      required String prompt,
      required String assistantId,
      String? title,
      required bool wait,
    })
    executor,
  ) {
    _executor = executor;
  }

  Future<Map<String, Object?>> run({
    required String prompt,
    required String assistantId,
    String? title,
    required bool wait,
  }) async {
    final executor = _executor;
    if (executor == null) {
      return {
        'error': 'subtask_unavailable',
        'message':
            'The chat stack is not ready yet; retry after the app finishes '
            'loading.',
      };
    }
    return executor(
      prompt: prompt,
      assistantId: assistantId,
      title: title,
      wait: wait,
    );
  }

  // ---------------------------------------------------------------------------
  // Tool surface
  // ---------------------------------------------------------------------------

  static Map<String, Object?> _jsonError(String code, String message) => {
    'error': code,
    'message': message,
  };

  static Future<String> handleSpawnSubtask(Map<String, dynamic> args) async {
    final prompt = '${args['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) {
      return jsonEncode(_jsonError('missing_argument', 'prompt is required.'));
    }
    if (prompt.length > 32000) {
      return jsonEncode(
        _jsonError('invalid_value', 'prompt exceeds 32000 characters.'),
      );
    }
    final assistantId = '${args['assistant_id'] ?? ''}'.trim();
    final title = '${args['title'] ?? ''}'.trim();
    final wait = args['wait'] is bool ? args['wait'] as bool : false;
    try {
      final result = await instance.run(
        prompt: prompt,
        assistantId: assistantId,
        title: title.isEmpty ? null : title,
        wait: wait,
      );
      return jsonEncode(result);
    } catch (error) {
      return jsonEncode(_jsonError('subtask_failed', '$error'));
    }
  }

  static const Map<String, dynamic> spawnSubtaskDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.spawnSubtask,
      'description':
          'Delegate a self-contained task to a fresh conversation of an '
          'assistant (sub-agent). The subtask runs its own chat with tool '
          'access subject to the same user approvals as any other '
          'conversation — it never inherits pre-approved permissions. With '
          'wait=false the call returns as soon as the task is queued and the '
          'caller can point the user to conversation_id; with wait=true the '
          'call blocks (up to 5 minutes) and returns the sub-agent reply. '
          'Every call requires user approval.',
      'parameters': {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description':
                'Complete, self-contained instruction for the sub-agent '
                '(max 32000 chars). Include every fact it needs — it cannot '
                'see this conversation.',
          },
          'assistant_id': {
            'type': 'string',
            'description':
                'Assistant to run the subtask with (use owner_assistants '
                'first to pick one). Defaults to the current assistant.',
          },
          'title': {
            'type': 'string',
            'description': 'Optional conversation title (max 200 chars).',
          },
          'wait': {
            'type': 'boolean',
            'description':
                'true: block until the subtask finishes and return its reply '
                '(recommended for short tasks). false (default): queue it '
                'and return immediately.',
          },
        },
        'required': ['prompt'],
      },
    },
  };
}

/// Truncates a subtask reply for in-conversation return (kept next to the
/// service so both wait branches stay consistent).
String truncateSubtaskReply(String text) => text.length > 8000
    ? '${truncateHeadUtf16Safe(text, 8000)}…[truncated]'
    : text;
