import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/compress_context_options.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/logging/context_log_models.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/services/model_spec/model_spec_resolver.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../core/utils/token_estimator.dart';
import '../../../utils/utf16_safe_cut.dart';

/// Auto-compaction (E2): keeps long conversations within an assistant-level
/// context budget.
///
/// When the estimated request usage exceeds `Assistant.contextBudget`, the
/// older part of the history (everything up to a watermark) is summarized in
/// the background by the compress→summary→title→assistant model chain and
/// stored in `conversation.extras['compaction']`. Later assemblies replace
/// that summarized prefix with the stored summary instead of replaying every
/// message. Compaction reuses the manual "Compress Context" prompt
/// (`settings.compressPrompt`) and split-retry machinery.
///
/// Storage shape (extras['compaction']):
/// `{watermarkId, summary, updatedAt}` — `watermarkId` is the id of the last
/// message covered by `summary` in the version-collapsed history. A watermark
/// message that no longer exists (deleted, or cut off by a newer manual
/// truncation) disables injection until the next compaction refreshes it.
///
/// The feature is strictly opt-in (`contextBudget == null` disables it) and
/// never blocks the in-flight request: compaction runs fire-and-forget and
/// only affects subsequent turns. Summaries are a context-engineering artifact
/// only — they never enter the memory system.
class ContextCompactionService {
  ContextCompactionService._();

  static const String extrasKey = 'compaction';

  /// Fraction of [Assistant.contextBudget] kept as verbatim recent history;
  /// everything before that point is folded into the summary.
  static const double keepTokenFraction = 0.35;

  /// Conservative token charge per media/document attachment (exact counts
  /// need image dimensions we do not have at planning time).
  static const int _unknownMediaTokens = 1000;

  /// Never summarize below this many collapsed messages — the recent tail
  /// must keep at least two messages of live context.
  static const int _minKeptMessages = 2;

  static final Set<String> _running = <String>{};

  /// Read the stored compaction state from conversation extras.
  static ContextCompaction? readFrom(Map<String, dynamic>? extras) {
    if (extras == null) return null;
    return ContextCompaction.fromExtras(extras[extrasKey]);
  }

  /// Budget check after a request has been assembled. Best-effort and
  /// side-effect free apart from scheduling the background compaction.
  ///
  /// Runs on the real send path only ([prepareApiMessagesWithInjections]);
  /// context previews never reach it, so previewing cannot trigger a
  /// background summarize.
  static Future<void> maybeCompactAfterAssembly({
    required Conversation? conversation,
    required Assistant? assistant,
    required SettingsProvider settings,
    required ChatService chatService,
    required List<Map<String, dynamic>> apiMessages,
    required List<Map<String, dynamic>> toolDefs,
    required String locale,
  }) async {
    try {
      final budget = assistant?.contextBudget;
      if (conversation == null || budget == null || budget <= 0) return;
      if (chatService.isTemporaryConversation(conversation.id)) return;
      final usage = estimateUsage(apiMessages: apiMessages, toolDefs: toolDefs);
      if (usage <= budget) return;
      await _compactInBackground(
        conversationId: conversation.id,
        budget: budget,
        assistant: assistant,
        settings: settings,
        chatService: chatService,
        locale: locale,
      );
    } catch (e, st) {
      FlutterLogger.log(
        '[AutoCompact] budget check failed: $e\n$st',
        tag: 'AutoCompact',
      );
    }
  }

  /// Plan the history for one assembly: drop the summarized prefix and keep
  /// everything from the watermark onwards. Returns null when there is no
  /// usable injection (feature state missing, watermark gone, or fewer than
  /// [_minKeptMessages] messages would remain).
  static PlanInjection? planInjection({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required int truncateIndex,
    required String watermarkId,
  }) {
    if (watermarkId.isEmpty) return null;
    final base = (truncateIndex >= 0 && truncateIndex <= messages.length)
        ? messages.sublist(truncateIndex)
        : messages;
    ChatMessage? anchor;
    for (final m in base) {
      if (m.id == watermarkId) {
        anchor = m;
        break;
      }
    }
    // The watermark message vanished (deleted, or excluded by a newer manual
    // truncation): the stored summary may be stale, so stay on plain history.
    if (anchor == null) return null;
    final gid = anchor.groupId ?? anchor.id;
    final collapsed = collapseForCompaction(base, versionSelections);
    var wIdx = -1;
    for (var i = 0; i < collapsed.length; i++) {
      final m = collapsed[i];
      if ((m.groupId ?? m.id) == gid) {
        wIdx = i;
        break;
      }
    }
    if (wIdx < 0 || wIdx > collapsed.length - 1 - _minKeptMessages) {
      return null;
    }
    return PlanInjection(messages: collapsed.sublist(wIdx + 1));
  }

  /// Append the stored summary to the system message (creating one when the
  /// assembly has none yet). Mirrors MessageBuilderService._appendToSystemMessage
  /// tagging so context-usage accounting stays accurate.
  static void injectSummary(
    List<Map<String, dynamic>> apiMessages,
    String summary,
  ) {
    final payload = '[Earlier conversation summary]\n$summary';
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      apiMessages[0]['content'] =
          '${(apiMessages[0]['content'] ?? '') as String}\n\n$payload';
      ContextSegmentTags.append(
        apiMessages[0],
        source: ContextSource.systemPrompt,
        length: 2 + payload.length,
      );
    } else {
      final message = <String, dynamic>{'role': 'system', 'content': payload};
      ContextSegmentTags.append(
        message,
        source: ContextSource.systemPrompt,
        length: payload.length,
      );
      apiMessages.insert(0, message);
    }
  }

  /// E1 estimate of the total request usage: message contents (text parts),
  /// media/document attachments, tool call envelopes, and tool definitions.
  /// Attachments are charged a flat conservative amount because exact image
  /// token counts need dimensions unavailable at planning time.
  static int estimateUsage({
    required List<Map<String, dynamic>> apiMessages,
    required List<Map<String, dynamic>> toolDefs,
  }) {
    var total = estimateToolsTokens(toolDefs);
    for (final m in apiMessages) {
      final content = m['content'];
      if (content is String) {
        total += estimateTokens(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map && part['text'] is String) {
            total += estimateTokens(part['text'] as String);
          } else {
            total += _unknownMediaTokens;
          }
        }
      }
      for (final key in const [
        multimodalInternalMediaPathsKey,
        multimodalInternalDocumentPathsKey,
      ]) {
        final refs = m[key];
        if (refs is List) total += refs.length * _unknownMediaTokens;
      }
      final calls = m['tool_calls'];
      if (calls is List && calls.isNotEmpty) {
        total += estimateTokens(calls.toString());
      }
    }
    return total;
  }

  static Future<void> _compactInBackground({
    required String conversationId,
    required int budget,
    required Assistant? assistant,
    required SettingsProvider settings,
    required ChatService chatService,
    required String locale,
  }) async {
    if (!_running.add(conversationId)) return;
    try {
      await _runCompaction(
        conversationId: conversationId,
        budget: budget,
        assistant: assistant,
        settings: settings,
        chatService: chatService,
        locale: locale,
      );
    } finally {
      _running.remove(conversationId);
    }
  }

  static Future<void> _runCompaction({
    required String conversationId,
    required int budget,
    required Assistant? assistant,
    required SettingsProvider settings,
    required ChatService chatService,
    required String locale,
  }) async {
    final convo = chatService.getConversation(conversationId);
    if (convo == null) return;
    if (chatService.isTemporaryConversation(convo.id)) return;

    final msgs = await chatService.loadMessages(convo.id);
    if (msgs.any((m) => m.isStreaming)) return;
    final tIdx = convo.truncateIndex;
    final base = (tIdx >= 0 && tIdx <= msgs.length) ? msgs.sublist(tIdx) : msgs;
    final collapsed = collapseForCompaction(
      base,
      chatService.getVersionSelections(convo.id),
    );
    if (collapsed.length < _minKeptMessages + 2) return;

    final keepBudget = (budget * keepTokenFraction).round();
    final start = _keepRecentStart(collapsed, keepBudget);
    if (start == null) return;
    final summarizeRange = collapsed.sublist(0, start);
    if (summarizeRange.isEmpty) return;
    final watermarkId = summarizeRange.last.id;

    // Debounce: another run may have produced the same watermark already.
    final existing = readFrom(convo.extras);
    if (existing != null && existing.watermarkId == watermarkId) return;

    // Same model chain as the manual "Compress Context" action.
    final resolved = resolveCompressContextModel(
      compressProvider: settings.compressModelProvider,
      compressModelId: settings.compressModelId,
      summaryProvider: settings.summaryModelProvider,
      summaryModelId: settings.summaryModelId,
      titleProvider: settings.titleModelProvider,
      titleModelId: settings.titleModelId,
      assistantProvider: assistant?.chatModelProvider,
      assistantModelId: assistant?.chatModelId,
      currentProvider: settings.currentModelProvider,
      currentModelId: settings.currentModelId,
    );
    final provKey = resolved.providerKey;
    final mdlId = resolved.modelId;
    if (provKey == null || mdlId == null) return;
    final cfg = settings.getProviderConfig(provKey);
    final reasoning = settings.compressGenerationReasoningFor(assistant);

    final body = StringBuffer();
    final previous = existing?.summary.trim() ?? '';
    if (previous.isNotEmpty) {
      body
        ..writeln('Previous summary of even earlier context:')
        ..writeln(previous)
        ..writeln();
    }
    body.writeln('Conversation excerpt to summarize:');
    for (final m in summarizeRange) {
      final text = m.content.trim();
      if (text.isEmpty) continue;
      body
        ..writeln(m.role == 'assistant' ? '[assistant]' : '[user]')
        ..writeln(text)
        ..writeln();
    }
    final requestChars = compressRequestCharBudget(
      contextWindowTokens: ModelSpecResolver.instance
          .spec(cfg, mdlId)
          .contextWindow,
    );
    final content = truncateHeadUtf16Safe(body.toString(), requestChars);

    try {
      final summary = (await summarizeWithContextRetry(
        content,
        summarize: (text) async {
          final prompt = settings.compressPrompt
              .replaceAll('{content}', text)
              .replaceAll('{locale}', locale);
          return (await ChatApiService.generateText(
            conversationId: convo.id,
            config: cfg,
            modelId: mdlId,
            prompt: prompt,
            reasoning: reasoning,
            skipImageParsing: true,
          )).trim();
        },
      )).trim();
      if (summary.isEmpty) return;
      await chatService.updateConversationExtras(convo.id, (extras) {
        final current = ContextCompaction.fromExtras(extras[extrasKey]);
        // Debounce re-check under the latest extras.
        if (current != null && current.watermarkId == watermarkId) {
          return extras;
        }
        return <String, dynamic>{
          ...extras,
          extrasKey: {
            'watermarkId': watermarkId,
            'summary': summary,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
        };
      });
      FlutterLogger.log(
        '[AutoCompact] summarized ${summarizeRange.length} messages '
        '(watermark=$watermarkId) for $conversationId',
        tag: 'AutoCompact',
      );
    } catch (e, st) {
      // Keep the old state on failure; the next over-budget turn retries.
      FlutterLogger.log(
        '[AutoCompact] compaction failed: $e\n$st',
        tag: 'AutoCompact',
      );
    }
  }

  /// Index of the first kept (non-summarized) message: the earliest index
  /// whose suffix stays within [keepBudget] estimated tokens. Returns null
  /// when the whole collapsed history already fits the keep budget — in that
  /// case the overage comes from prompts/tools and summarizing would not
  /// recover meaningful tokens.
  static int? _keepRecentStart(List<ChatMessage> collapsed, int keepBudget) {
    if (keepBudget <= 0) return null;
    var acc = 0;
    var start = 0;
    var overflowed = false;
    for (var i = collapsed.length - 1; i >= 0; i--) {
      acc += estimateTokens(collapsed[i].content);
      if (acc > keepBudget) {
        start = i + 1;
        overflowed = true;
        break;
      }
      start = i;
    }
    if (!overflowed) return null;
    final maxStart = collapsed.length - _minKeptMessages;
    if (start > maxStart) start = maxStart;
    if (start < 1) return null;
    return start;
  }

  /// Version collapse identical to MessageBuilderService.buildApiMessages
  /// (group id → selected or newest version, original order preserved) so the
  /// planning view matches what is actually sent.
  static List<ChatMessage> collapseForCompaction(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup =
        <String, List<ChatMessage>>{};
    final List<String> order = <String>[];
    for (final m in items) {
      final gid = m.groupId ?? m.id;
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      ChatMessage? selected;
      if (sel != null) {
        for (final candidate in vers) {
          if (candidate.version == sel) {
            selected = candidate;
            break;
          }
        }
      }
      out.add(selected ?? vers.last);
    }
    return out;
  }
}

/// Stored compaction state for one conversation.
class ContextCompaction {
  const ContextCompaction({
    required this.watermarkId,
    required this.summary,
    required this.updatedAt,
  });

  /// Id of the last message covered by [summary].
  final String watermarkId;
  final String summary;
  final int updatedAt;

  static ContextCompaction? fromExtras(Object? raw) {
    if (raw is! Map) return null;
    final watermarkId = (raw['watermarkId'] ?? '').toString();
    final summary = (raw['summary'] ?? '').toString();
    if (watermarkId.isEmpty || summary.trim().isEmpty) return null;
    return ContextCompaction(
      watermarkId: watermarkId,
      summary: summary,
      updatedAt: raw['updatedAt'] is num
          ? (raw['updatedAt'] as num).toInt()
          : 0,
    );
  }
}

/// Result of [ContextCompactionService.planInjection].
class PlanInjection {
  const PlanInjection({required this.messages});

  /// Messages that must still be sent verbatim (everything after the
  /// watermark), already version-collapsed.
  final List<ChatMessage> messages;
}
