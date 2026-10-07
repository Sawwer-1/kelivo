import 'dart:async';
import 'dart:io';

import '../../../../utils/mcp_structured_image.dart';
import '../../../../utils/utf16_safe_cut.dart';
import '../../../models/token_usage.dart';
import '../chat_api_helpers.dart';
import '../stream/stream_chunk.dart';
import '../stream/stream_chunk_emit.dart';
import '../stream/stream_chunk_ids.dart';

/// Hard cap on client-tool rounds per generation (AAA costguards lineage).
/// A model stuck issuing tool calls must not burn tokens forever: the loop
/// stops with a visible notice instead of running unbounded. Per call-site
/// override is possible, but the default applies to every provider path.
const int kDefaultMaxToolRounds = 256;

/// Tool result content above this size is truncated before it enters the
/// transcript; the full output is spilled to a local file so the model can
/// still page through it with file tools.
const int kToolOutputMaxChars = 32 * 1024;

StreamChunk _guardNotice(String text) {
  // A dedicated source id keeps the notice a separate text part that never
  // merges into model output.
  return TextDelta(id: StreamChunkIds('generation-guard').text(), text: text);
}

String _roundsExhaustedNotice(int maxRounds) =>
    '\n\n[Generation guard] Tool rounds exceeded the limit of $maxRounds; '
    'the loop was stopped. Wrap up now and answer with what you have.\n';

String? _spillToolOutput(EmitToolCall call, String content) {
  try {
    final dirPath = [
      Directory.systemTemp.path,
      'kelivo_tool_outputs',
    ].join(Platform.pathSeparator);
    Directory(dirPath).createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safeName = call.name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final safeId = call.id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final fileName = '${stamp}_${safeName}_$safeId.txt';
    final file = File([dirPath, fileName].join(Platform.pathSeparator));
    file.writeAsStringSync(content, flush: true);
    _cleanupOldSpillFiles(dirPath);
    return file.path;
  } catch (_) {
    return null;
  }
}

/// Opportunistic hygiene: spill files accumulate in the system temp dir and
/// nothing else ever removes them. Best-effort drop of anything older than
/// 7 days on each spill write (spills are rare — only past the 32KB cap).
void _cleanupOldSpillFiles(String dirPath) {
  try {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    for (final entity in Directory(dirPath).listSync()) {
      if (entity is! File || !entity.path.endsWith('.txt')) continue;
      if (entity.statSync().modified.isBefore(cutoff)) {
        entity.deleteSync();
      }
    }
  } catch (_) {
    // Cleanup must never break the spill path itself.
  }
}

typedef StreamRoundRunner =
    Stream<StreamChunk> Function(Stream<StreamChunk> Function() sendRound);

/// Tag the first usage of each HTTP round, including non-stream responses
/// whose usage is only available after parsing. Tagging happens outside the
/// retry runner so bookkeeping cannot disable retries of empty failed attempts.
/// Hosts reset [usageOf] for each request so it never returns an earlier round.
Stream<StreamChunk> _withRequestUsage(
  Stream<StreamChunk> source,
  TokenUsage? Function()? usageOf,
) async* {
  var startsRequest = true;
  await for (final chunk in source) {
    if (chunk is Usage) {
      yield Usage(chunk.usage, startsRequest: startsRequest);
      startsRequest = false;
    } else {
      yield chunk;
    }
  }
  final usage = usageOf?.call();
  if (usage != null || startsRequest) {
    // Missing usage must not count the preceding request again.
    yield Usage(usage ?? const TokenUsage(), startsRequest: startsRequest);
  }
}

final class ExecutedClientTool {
  const ExecutedClientTool({
    required this.call,
    required this.content,
    this.metadata,
  });

  final EmitToolCall call;

  /// Markdown / plain text sent back to the model and persisted as content.
  final String content;

  /// Result metadata (e.g. `mcpResult`). Merged with [call.metadata] on emit.
  final Map<String, dynamic>? metadata;
}

EmitToolResult _emitExecuted(ExecutedClientTool item) {
  return emitToolResult(
    id: item.call.id,
    name: item.call.name,
    arguments: item.call.arguments,
    content: item.content,
    metadata: mergeToolResultMetadata(item.call.metadata, item.metadata),
  );
}

/// Execute [calls] and yield [ToolCallResult]s (and optionally [ToolCall*]).
Stream<StreamChunk> executeClientTools({
  required List<EmitToolCall> calls,
  required ToolCallHandler onToolCall,
  bool emitCalls = false,
  TokenUsage? usage,
  int totalTokens = 0,
}) async* {
  if (calls.isEmpty) return;
  if (emitCalls) {
    yield* emitToolCalls(calls, usage: usage, totalTokens: totalTokens);
  }
  final executed = <ExecutedClientTool>[
    for (final call in calls) await _executeClientTool(call, onToolCall),
  ];
  yield* emitToolResults(
    [for (final item in executed) _emitExecuted(item)],
    usage: usage,
    totalTokens: totalTokens,
  );
}

/// After-round client-tool loop: execute → append → send follow-up → repeat.
///
/// The host owns protocol-specific HTTP and transcript shape. This runner
/// owns execute + [ToolCallResult] emit + the loop.
///
/// Two entries stay on purpose. [runProviderToolRounds] owns the first HTTP
/// round via [sendRound] (Claude / Gemini). OpenAI's first round is consumed
/// by the caller (`await for` SSE or one-shot JSON); only later rounds enter
/// [runClientToolFollowUps]. Unifying stream/non-stream return types does not
/// change who drives the first request, so these cannot merge.
Stream<StreamChunk> runClientToolFollowUps({
  required List<EmitToolCall> initialCalls,
  required ToolCallHandler onToolCall,
  required FutureOr<void> Function(List<ExecutedClientTool> executed) append,
  required Stream<StreamChunk> Function() sendFollowUp,
  required List<EmitToolCall> Function() takeCallsAfterRound,
  required Stream<StreamChunk> Function() finish,
  StreamRoundRunner? retryRound,
  bool emitCalls = false,
  TokenUsage? Function()? usageOf,
  int maxRounds = kDefaultMaxToolRounds,
}) async* {
  var calls = List<EmitToolCall>.from(initialCalls);
  var rounds = 0;
  while (calls.isNotEmpty) {
    rounds++;
    if (rounds > maxRounds) {
      yield _guardNotice(_roundsExhaustedNotice(maxRounds));
      break;
    }
    final usage = usageOf?.call();
    final totalTokens = usage?.totalTokens ?? 0;
    final executed = <ExecutedClientTool>[];
    // Do not clear [emitCalls] after the first round. OpenAI non-stream
    // follow-ups have no decoder emitting ToolCall*, so later rounds would
    // otherwise land as ToolCallResult-only cards with empty name/args.
    if (emitCalls) {
      yield* emitToolCalls(calls, usage: usage, totalTokens: totalTokens);
    }
    for (final call in calls) {
      executed.add(await _executeClientTool(call, onToolCall));
    }
    yield* emitToolResults(
      [for (final item in executed) _emitExecuted(item)],
      usage: usage,
      totalTokens: totalTokens,
    );
    await append(executed);
    yield* _withRequestUsage(
      retryRound?.call(sendFollowUp) ?? sendFollowUp(),
      usageOf,
    );
    calls = takeCallsAfterRound();
  }
  yield* finish();
}

/// In-round loop used by Claude / Gemini: send (and maybe execute mid-stream),
/// then append and repeat until [takeCalls] and [continueWithoutCalls] are both
/// empty/false.
Stream<StreamChunk> runProviderToolRounds({
  required Stream<StreamChunk> Function() sendRound,
  required List<EmitToolCall> Function() takeCalls,
  required FutureOr<void> Function(List<ExecutedClientTool> executed) append,
  required bool Function() continueWithoutCalls,
  required Stream<StreamChunk> Function() finish,
  ToolCallHandler? onToolCall,
  bool emitCalls = false,
  bool executeAfterRound = true,
  StreamRoundRunner? retryRound,
  TokenUsage? Function()? usageOf,
  int maxRounds = kDefaultMaxToolRounds,
}) async* {
  var rounds = 0;
  while (true) {
    rounds++;
    if (rounds > maxRounds) {
      yield _guardNotice(_roundsExhaustedNotice(maxRounds));
      yield* finish();
      return;
    }
    yield* _withRequestUsage(
      retryRound?.call(sendRound) ?? sendRound(),
      usageOf,
    );
    final calls = takeCalls();
    if (calls.isEmpty && !continueWithoutCalls()) {
      yield* finish();
      return;
    }
    final executed = <ExecutedClientTool>[];
    if (executeAfterRound && calls.isNotEmpty && onToolCall != null) {
      final usage = usageOf?.call();
      final totalTokens = usage?.totalTokens ?? 0;
      if (emitCalls) {
        yield* emitToolCalls(calls, usage: usage, totalTokens: totalTokens);
      }
      for (final call in calls) {
        executed.add(await _executeClientTool(call, onToolCall));
      }
      yield* emitToolResults(
        [for (final item in executed) _emitExecuted(item)],
        usage: usage,
        totalTokens: totalTokens,
      );
    }
    await append(executed);
  }
}

Future<ExecutedClientTool> _executeClientTool(
  EmitToolCall call,
  ToolCallHandler onToolCall,
) async {
  final raw = await onToolCall(call.name, call.arguments, toolCallId: call.id);
  final parsed = ClientToolResult.fromHandler(raw);
  var content = parsed.content;
  if (content.length > kToolOutputMaxChars) {
    final spillPath = _spillToolOutput(call, content);
    content =
        '${truncateHeadUtf16Safe(content, kToolOutputMaxChars)}\n\n'
        '[tool output truncated: showing first $kToolOutputMaxChars of '
        '${content.length} characters'
        '${spillPath == null ? '' : '; full output saved to $spillPath'}]';
  }
  return ExecutedClientTool(
    call: call,
    content: content,
    metadata: parsed.metadata,
  );
}
