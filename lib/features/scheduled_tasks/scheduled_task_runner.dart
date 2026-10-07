import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../core/database/generation_run.dart';
import '../../core/models/chat_input_data.dart';
import '../../core/models/conversation.dart';
import '../../core/models/workspace_binding.dart';
import '../../core/models/scheduled_task.dart';
import '../../core/providers/assistant_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/mcp_provider.dart';
import '../../core/providers/workspace_provider.dart';
import '../../core/providers/world_book_provider.dart';
import '../../core/services/chat/chat_service.dart';
import '../../core/services/scheduled_tasks_service.dart';
import '../home/controllers/chat_actions.dart';
import '../home/controllers/home_view_model.dart';
import '../home/services/ask_user_interaction_service.dart';
import '../home/services/tool_approval_service.dart';

Future<Map<String, Object?>> runScheduledTask(
  BuildContext context,
  HomeViewModel viewModel,
  ScheduledTask task,
  ScheduledRunCancellation cancellation,
  Future<void> Function(String) onConversation,
) async {
  final assistants = context.read<AssistantProvider>();
  final settings = context.read<SettingsProvider>();
  final mcp = context.read<McpProvider>();
  final workspaces = context.read<WorkspaceProvider>();
  final books = context.read<WorldBookProvider>();
  final chat = context.read<ChatService>();
  final approvals = context.read<ToolApprovalService>();
  final questions = context.read<AskUserInteractionService>();
  await Future.wait([
    settings.loaded,
    mcp.loaded,
    assistants.loaded,
    workspaces.loaded,
    books.initialize(),
    chat.init(),
  ]);
  await mcp.workspaceRuntime?.initialization;
  await mcp.workspaceRuntime?.refresh();
  cancellation.check();
  final assistant = assistants.getById(task.assistantId);
  if (assistant == null) throw StateError('assistant_missing');
  Conversation? targetConversation;
  if (task.mode != ScheduledTaskMode.newChat) {
    targetConversation = chat.getConversation(task.conversationId ?? '');
    if (targetConversation == null ||
        chat.isTemporaryConversation(targetConversation.id) ||
        targetConversation.assistantId != assistant.id) {
      throw StateError('conversation_missing');
    }
  }
  final workspaceId = targetConversation == null
      ? assistant.defaultWorkspaceId
      : WorkspaceBinding.fromExtras(targetConversation.extras).workspaceId;
  if (workspaceId != null) {
    if (workspaces.byId(workspaceId) == null) {
      throw StateError('workspace_missing');
    }
    if (mcp.workspaceRuntime?.lastStatus?.ready != true) {
      throw StateError('workspace_unavailable');
    }
  }
  final modelOverride = task.modelProvider != null && task.modelId != null
      ? (providerKey: task.modelProvider!, modelId: task.modelId!)
      : null;
  if (modelOverride != null) {
    final config = settings.getProviderConfig(modelOverride.providerKey);
    if (!config.enabled || !config.models.contains(modelOverride.modelId)) {
      throw StateError('model_missing');
    }
  }
  for (final id in assistant.mcpServerIds) {
    cancellation.check();
    final server = mcp.getById(id);
    if (server == null || !server.enabled) continue;
    await mcp.connect(id);
    cancellation.check();
    // connect() starts tool discovery without waiting for the cached snapshot.
    final toolsReady = mcp.isConnected(id) && await mcp.refreshTools(id);
    cancellation.check();
    if (!toolsReady) {
      throw StateError('mcp_unavailable: ${server.name}');
    }
  }
  cancellation.check();
  if (targetConversation != null &&
      chat.getConversation(targetConversation.id)?.assistantId !=
          assistant.id) {
    throw StateError('conversation_missing');
  }
  final conversation =
      targetConversation ??
      await chat.createConversation(
        title: task.name,
        assistantId: assistant.id,
        activate: false,
      );
  await onConversation(conversation.id);
  cancellation.check();
  void onStarted(String messageId) {
    cancellation.onCancel = () => ChatActions.cancelActiveGenerationFor(
      conversation.id,
      expectedMessageId: messageId,
    );
    if (cancellation.cancelled) unawaited(cancellation.cancel());
  }

  final repository = chat.chatRepositoryOrNull!;

  /// Sends one scheduled message and waits for its generation run to reach a
  /// terminal state, enforcing approvals/timeout/cancellation. Returns the
  /// result map plus the assistant's final text (workflow step chaining).
  Future<(Map<String, Object?>, String)> runStep(
    String inputText, {
    ({String providerKey, String modelId})? modelOverride,
  }) async {
    final result = await viewModel.sendScheduledMessage(
      input: ChatInputData(text: inputText),
      conversation: conversation,
      assistant: assistant,
      modelOverride: modelOverride,
      onGenerationStarted: onStarted,
      scheduledNotify: task.notify,
      scheduledPreview: task.showPreview,
    );
    if (cancellation.cancelled) await cancellation.cancel();
    cancellation.check();
    if (!result.success) {
      throw StateError(result.errorMessage ?? 'generation_failed');
    }
    final runId = result.generationRunId;
    if (runId == null) throw StateError('generation_run_missing');
    final deadline = DateTime.now().add(const Duration(minutes: 9));
    while (true) {
      cancellation.check();
      final run = await repository.getGenerationRun(runId);
      if (run == null) throw StateError('generation_run_missing');
      if (run.state.isTerminal) {
        final message = await repository.getMessage(
          result.assistantMessage!.id,
        );
        final text = message?.content ?? '';
        return (
          {
            'conversationId': conversation.id,
            'status': run.state == GenerationRunState.completed
                ? 'completed'
                : 'failed',
            'preview': text.characters.take(200).toString(),
            if (run.errorCode != null) 'error': run.errorCode,
          },
          text,
        );
      }
      // Preserve tool approval rules. Unattended runs cannot answer for the
      // user.
      if (approvals.pendingRequests.any(
            (r) => r.conversationId == conversation.id,
          ) ||
          questions.pendingRequests.values.any(
            (r) => r.conversationId == conversation.id,
          )) {
        throw StateError('user_interaction_required');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('execution_timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  // ---------------------------------------------------------------------------
  // Execution plan:
  // - regenerate: original path (message re-run), steps ignored.
  // - no steps: single prompt (legacy behavior, unchanged).
  // - steps: sequential chain — each step sends its prompt combined with the
  //   selected input source (previous assistant output or fixed text); any
  //   failure stops the chain with the failing step recorded on the run.
  final steps = task.mode == ScheduledTaskMode.regenerate
      ? const <ScheduledTaskStep>[]
      : task.steps;
  var runResult = <String, Object?>{};
  if (task.mode == ScheduledTaskMode.regenerate) {
    final message = await chat.chatRepositoryOrNull?.getMessage(
      task.messageId ?? '',
    );
    cancellation.check();
    if (message == null ||
        message.conversationId != conversation.id ||
        message.role != 'user') {
      throw StateError('message_missing');
    }
    final result = await viewModel.regenerateScheduledMessage(
      message: message,
      conversation: conversation,
      assistant: assistant,
      modelOverride: modelOverride,
      onGenerationStarted: onStarted,
      scheduledNotify: task.notify,
      scheduledPreview: task.showPreview,
    );
    if (cancellation.cancelled) await cancellation.cancel();
    cancellation.check();
    if (!result.success) {
      throw StateError(result.errorMessage ?? 'generation_failed');
    }
    final runId = result.generationRunId;
    if (runId == null) throw StateError('generation_run_missing');
    final deadline = DateTime.now().add(const Duration(minutes: 9));
    while (true) {
      cancellation.check();
      final run = await repository.getGenerationRun(runId);
      if (run == null) throw StateError('generation_run_missing');
      if (run.state.isTerminal) {
        final msg = await repository.getMessage(result.assistantMessage!.id);
        final text = msg?.content ?? '';
        if (run.state != GenerationRunState.completed) {
          throw StateError(run.errorCode ?? 'generation_failed');
        }
        return {
          'conversationId': conversation.id,
          'status': 'completed',
          'preview': text.characters.take(200).toString(),
        };
      }
      if (approvals.pendingRequests.any(
            (r) => r.conversationId == conversation.id,
          ) ||
          questions.pendingRequests.values.any(
            (r) => r.conversationId == conversation.id,
          )) {
        throw StateError('user_interaction_required');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('execution_timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  var previousOutput = '';
  for (var i = 0; i < math.max(steps.length, 1); i++) {
    cancellation.check();
    String inputText;
    ({String providerKey, String modelId})? stepOverride;
    if (steps.isEmpty) {
      inputText = task.prompt;
      stepOverride = modelOverride;
    } else {
      final step = steps[i];
      final sourcePayload = i == 0
          ? (step.source == ScheduledTaskStepSource.fixedText
                ? step.fixedText
                : '')
          : (step.source == ScheduledTaskStepSource.fixedText
                ? step.fixedText
                : previousOutput);
      inputText = sourcePayload.isEmpty
          ? step.prompt
          : '$sourcePayload\n\n${step.prompt}';
      if (step.modelProvider != null && step.modelId != null) {
        final config = settings.getProviderConfig(step.modelProvider!);
        if (!config.enabled || !config.models.contains(step.modelId)) {
          throw StateError('model_missing');
        }
        stepOverride = (
          providerKey: step.modelProvider!,
          modelId: step.modelId!,
        );
      } else {
        stepOverride = modelOverride;
      }
    }
    final (stepResult, assistantText) = await runStep(
      inputText,
      modelOverride: stepOverride,
    );
    if (stepResult['status'] != 'completed') {
      runResult = {
        ...stepResult,
        if (steps.isNotEmpty) 'failed_step': i + 1,
      };
      throw StateError(
        steps.isEmpty
            ? stepResult['error']?.toString() ?? 'generation_failed'
            : 'workflow_step_failed:${i + 1} '
                '${stepResult['error'] ?? ''}'.trim(),
      );
    }
    previousOutput = assistantText;
    runResult = {...stepResult, if (steps.isNotEmpty) 'steps_run': i + 1};
  }
  return runResult;
}
