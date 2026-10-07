import 'dart:convert';

import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:uuid/uuid.dart';

import '../../../core/models/scheduled_task.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/scheduled_tasks_service.dart';
import '../../../utils/utf16_safe_cut.dart';
import 'local_tools_service.dart';

/// Owner write tools (C3 phase 2): a conservative control-plane surface over
/// app settings, device-local scheduled tasks and the Learning Gateway.
/// Everything here mutates user-visible state, so every tool in this family
/// is listed in [LocalToolNames.requiresUserApproval].
///
/// The write surface is deliberately tiny:
/// - settings: a fixed whitelist; most keys are read-only, six are writable;
/// - tasks: only list/create/delete on the existing desktop scheduler (no
///   arbitrary schedule tweaks, no runNow);
/// - learning: a pass-through shell that forwards to an already-configured
///   Learning Gateway MCP server (none is spawned here).
class OwnerControlTools {
  const OwnerControlTools._();

  static String _ownerUnavailable() => jsonEncode({
    'error': 'owner_context_unavailable',
    'message': 'Owner data sources are not wired for this call site.',
  });

  static String _error(String code, String message) =>
      jsonEncode({'error': code, 'message': message});

  static int? _intArg(Object? value) =>
      value is int ? value : int.tryParse('$value');

  // ---------------------------------------------------------------------------
  // Settings family

  /// Keys the tools may read. Writeable keys are a strict subset of this.
  static const Set<String> readableSettingKeys = {
    'app_locale',
    'compress_max_chars',
    'compress_prompt',
    'current_assistant',
    'current_model',
    'search_enabled',
    'suggestion_prompt',
    'theme_mode',
    'theme_palette_id',
    'title_generation_enabled',
    'title_prompt',
    'translate_target_lang',
  };

  /// Keys the tools may write. Kept intentionally small and non-destructive:
  /// appearance, locale and the text prompts of the generation pipeline.
  /// Provider configs, API keys and the active model are never writable.
  static const Set<String> writeableSettingKeys = {
    'app_locale',
    'compress_prompt',
    'suggestion_prompt',
    'theme_mode',
    'title_prompt',
    'translate_target_lang',
  };

  static const int _maxPromptLength = 8000;

  static Future<String> handleSettingsGet(
    Map<String, dynamic> args,
    OwnerToolContext? ownerContext,
  ) async {
    final settings = ownerContext?.settings;
    if (settings == null) return _ownerUnavailable();
    final requested = <String>[
      if (args['keys'] is List)
        for (final key in (args['keys'] as List)) '$key',
    ];
    final keys =
        (requested.isEmpty
              ? readableSettingKeys.toList()
              : requested.where(readableSettingKeys.contains).toList())
          ..sort();
    final rejected = [
      for (final key in requested)
        if (!readableSettingKeys.contains(key)) key,
    ];
    return jsonEncode({
      if (rejected.isNotEmpty) 'rejected_keys': rejected,
      'settings': {
        for (final key in keys)
          key: _readSetting(settings, ownerContext?.assistantProvider, key),
      },
    });
  }

  static Object? _readSetting(
    SettingsProvider settings,
    AssistantProvider? assistantProvider,
    String key,
  ) {
    switch (key) {
      case 'app_locale':
        return settings.isFollowingSystemLocale
            ? 'system'
            : settings.appLocale.toString();
      case 'compress_max_chars':
        return settings.compressMaxChars;
      case 'compress_prompt':
        return settings.compressPrompt;
      case 'current_assistant':
        final assistant = assistantProvider?.currentAssistant;
        return assistant == null
            ? null
            : {'id': assistant.id, 'name': assistant.name};
      case 'current_model':
        return {
          'provider': settings.currentModelProvider,
          'model_id': settings.currentModelId,
        };
      case 'search_enabled':
        return settings.searchEnabled;
      case 'suggestion_prompt':
        return settings.suggestionPrompt;
      case 'theme_mode':
        return settings.themeMode.name;
      case 'theme_palette_id':
        return settings.themePaletteId;
      case 'title_generation_enabled':
        return settings.isTitleGenerationEnabled;
      case 'title_prompt':
        return settings.titlePrompt;
      case 'translate_target_lang':
        return settings.translateTargetLang;
    }
    return null;
  }

  static Future<String> handleSettingsSet(
    Map<String, dynamic> args,
    OwnerToolContext? ownerContext,
  ) async {
    final settings = ownerContext?.settings;
    if (settings == null) return _ownerUnavailable();
    final key = '${args['key'] ?? ''}'.trim();
    if (key.isEmpty) return _error('missing_argument', 'key is required.');
    if (!writeableSettingKeys.contains(key)) {
      return _error(
        readableSettingKeys.contains(key) ? 'key_read_only' : 'key_not_allowed',
        readableSettingKeys.contains(key)
            ? "Setting '$key' can be read but not modified by tools."
            : "Setting '$key' is not in the writable whitelist.",
      );
    }
    final value = args['value'];
    if (value == null) {
      // A bare `'$value'` would smuggle a null through as the string "null"
      // and pass the non-empty checks below — reject it explicitly.
      return _error('missing_argument', 'value is required.');
    }
    switch (key) {
      case 'app_locale':
        final tag = '$value'.trim();
        if (tag.isEmpty) {
          return _error('invalid_value', 'app_locale cannot be empty.');
        }
        if (tag.toLowerCase() == 'system') {
          await settings.setAppLocaleFollowSystem();
          return _settingsChanged(key, null, 'system');
        }
        final parts = tag.split(RegExp(r'[-_]'));
        final language = parts.first.toLowerCase();
        if (language.length != 2) {
          return _error(
            'invalid_value',
            "app_locale must be 'system' or a locale tag like en_US / zh_CN.",
          );
        }
        final country = parts.length > 1 ? parts[1].toUpperCase() : null;
        await settings.setAppLocale(Locale(language, country));
        return _settingsChanged(
          key,
          null,
          Locale(language, country).toString(),
        );
      case 'compress_prompt':
      case 'suggestion_prompt':
      case 'title_prompt':
        final text = '$value';
        if (text.trim().isEmpty) {
          return _error('invalid_value', "'$key' must be a non-empty string.");
        }
        if (text.length > _maxPromptLength) {
          return _error(
            'invalid_value',
            "'$key' must be at most $_maxPromptLength characters.",
          );
        }
        final old = switch (key) {
          'compress_prompt' => settings.compressPrompt,
          'suggestion_prompt' => settings.suggestionPrompt,
          _ => settings.titlePrompt,
        };
        switch (key) {
          case 'compress_prompt':
            await settings.setCompressPrompt(text);
          case 'suggestion_prompt':
            await settings.setSuggestionPrompt(text);
          default:
            await settings.setTitlePrompt(text);
        }
        return _settingsChanged(key, old, text);
      case 'theme_mode':
        final name = '$value'.trim();
        final mode = ThemeMode.values
            .where((candidate) => candidate.name == name)
            .firstOrNull;
        if (mode == null) {
          return _error(
            'invalid_value',
            'theme_mode must be one of: system, light, dark.',
          );
        }
        final old = settings.themeMode.name;
        await settings.setThemeMode(mode);
        return _settingsChanged(key, old, mode.name);
      case 'translate_target_lang':
        final code = '$value'.trim();
        if (code.isEmpty || code.length > 32) {
          return _error(
            'invalid_value',
            'translate_target_lang must be a language code of 1-32 chars.',
          );
        }
        final old = settings.translateTargetLang;
        await settings.setTranslateTargetLang(code);
        return _settingsChanged(key, old, code);
    }
    return _error('key_not_allowed', "Setting '$key' is not writable.");
  }

  static String _settingsChanged(String key, Object? old, String latest) =>
      jsonEncode({
        'ok': true,
        'key': key,
        'old_value': old,
        'new_value': latest,
      });

  // ---------------------------------------------------------------------------
  // Scheduled tasks family

  static Map<String, dynamic> _taskRow(ScheduledTask task) => {
    'id': task.id,
    'name': task.name,
    'prompt': task.prompt.length > 300
        ? '${truncateHeadUtf16Safe(task.prompt, 300)}…[truncated]'
        : task.prompt,
    'hour': task.hour,
    'minute': task.minute,
    'repeat': task.repeat.name,
    'weekdays': task.onceDate == null ? List<int>.from(task.weekdays) : null,
    'once_date': task.onceDate == null
        ? null
        : ScheduledTask.dateKey(task.onceDate),
    'enabled': task.enabled,
    'next_run_at': task.nextRunAt?.toIso8601String(),
    'mode': task.mode.name,
    'assistant_id': task.assistantId,
    'conversation_id': task.conversationId,
    'last_run': task.runs.isEmpty
        ? null
        : {
            'status': task.runs.first.status,
            'started_at': task.runs.first.startedAt?.toIso8601String(),
            'error': task.runs.first.error,
          },
  };

  static Future<String> handleTaskList(OwnerToolContext? ownerContext) async {
    if (!ScheduledTasksService.supported) {
      return _error(
        'scheduled_tasks_unavailable',
        'Scheduled tasks are not supported on this platform.',
      );
    }
    return jsonEncode({
      'tasks': [
        for (final task in ScheduledTasksService.instance.tasks) _taskRow(task),
      ],
    });
  }

  static Future<String> handleTaskCreate(
    Map<String, dynamic> args,
    OwnerToolContext? ownerContext,
  ) async {
    if (!ScheduledTasksService.supported) {
      return _error(
        'scheduled_tasks_unavailable',
        'Scheduled tasks are not supported on this platform.',
      );
    }
    final name = '${args['name'] ?? ''}'.trim();
    if (name.isEmpty) return _error('missing_argument', 'name is required.');
    final prompt = '${args['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) {
      return _error('missing_argument', 'prompt is required.');
    }
    final hour = _intArg(args['hour']);
    final minute = _intArg(args['minute']);
    if (hour == null || hour < 0 || hour > 23) {
      return _error(
        'invalid_value',
        'hour must be an integer between 0 and 23.',
      );
    }
    if (minute == null || minute < 0 || minute > 59) {
      return _error(
        'invalid_value',
        'minute must be an integer between 0 and 59.',
      );
    }
    final modeName = '${args['mode'] ?? 'new_chat'}'.trim();
    final ScheduledTaskMode mode = switch (modeName) {
      'new_chat' => ScheduledTaskMode.newChat,
      'follow_up' => ScheduledTaskMode.followUp,
      _ => ScheduledTaskMode.newChat,
    };
    if (modeName != 'new_chat' && modeName != 'follow_up') {
      return _error('invalid_value', "mode must be 'new_chat' or 'follow_up'.");
    }
    final dateRaw = '${args['date'] ?? ''}'.trim();
    final weekdaysRaw = args['weekdays'];
    final DateTime? onceDate;
    final List<int> weekdays;
    if (dateRaw.isNotEmpty) {
      onceDate = DateTime.tryParse(dateRaw);
      if (onceDate == null || dateRaw.length != 10) {
        return _error(
          'invalid_value',
          'date must be a YYYY-MM-DD calendar day.',
        );
      }
      weekdays = const [1, 2, 3, 4, 5, 6, 7];
    } else if (weekdaysRaw is List && weekdaysRaw.isNotEmpty) {
      onceDate = null;
      final parsedWeekdays = <int>[];
      for (final day in weekdaysRaw) {
        final value = _intArg(day);
        if (value != null &&
            value >= 1 &&
            value <= 7 &&
            !parsedWeekdays.contains(value)) {
          parsedWeekdays.add(value);
        }
      }
      weekdays = parsedWeekdays;
      if (weekdays.isEmpty) {
        return _error(
          'invalid_value',
          'weekdays must contain integers 1 (Monday) through 7 (Sunday).',
        );
      }
    } else {
      return _error(
        'missing_argument',
        "Provide either 'date' (YYYY-MM-DD, one-time) or 'weekdays' "
            '(repeating days, 1=Monday..7=Sunday).',
      );
    }
    final conversationId = '${args['conversation_id'] ?? ''}'.trim();
    if (mode == ScheduledTaskMode.followUp && conversationId.isEmpty) {
      return _error(
        'missing_argument',
        'conversation_id is required for follow_up tasks.',
      );
    }
    if (mode == ScheduledTaskMode.followUp) {
      // Without this check a follow_up task would fire into a missing
      // conversation and silently never take effect.
      final chatService = ownerContext?.chatService;
      if (chatService != null &&
          chatService.getConversation(conversationId) == null) {
        return _error(
          'invalid_value',
          "conversation_id '$conversationId' does not exist.",
        );
      }
    }
    final assistantId = '${args['assistant_id'] ?? ''}'.trim().isNotEmpty
        ? '${args['assistant_id']}'.trim()
        : (ownerContext?.assistantProvider?.currentAssistant?.id ?? '');
    if (assistantId.isEmpty) {
      return _error(
        'missing_argument',
        'assistant_id is required (there is no current assistant).',
      );
    }
    // Same rationale: a task bound to a deleted/unknown assistant would
    // never produce a visible run. Skipped only when the provider itself is
    // unavailable (same tolerance as the currentAssistant fallback above).
    final assistantProvider = ownerContext?.assistantProvider;
    if (assistantProvider != null &&
        assistantProvider.getById(assistantId) == null) {
      return _error(
        'invalid_value',
        "assistant_id '$assistantId' does not exist.",
      );
    }
    final task = ScheduledTask(
      id: const Uuid().v4(),
      name: name,
      prompt: prompt,
      assistantId: assistantId,
      hour: hour,
      minute: minute,
      weekdays: weekdays,
      onceDate: onceDate,
      mode: mode,
      conversationId: mode == ScheduledTaskMode.followUp
          ? conversationId
          : null,
      notify: args['notify'] is bool ? args['notify'] as bool : true,
    );
    try {
      await ScheduledTasksService.instance.save(task);
    } on ArgumentError catch (error) {
      return _error(
        'invalid_task',
        'The schedule was rejected (${error.message}).',
      );
    } on StateError catch (error) {
      return _error(
        error.message,
        error.message == 'schedule_ended'
            ? 'The requested time has already passed (device local time) '
                  'or the schedule can never fire.'
            : 'The task could not be saved (${error.message}).',
      );
    }
    final saved = ScheduledTasksService.instance.tasks
        .where((candidate) => candidate.id == task.id)
        .firstOrNull;
    return jsonEncode({
      'ok': true,
      'task': saved == null ? null : _taskRow(saved),
    });
  }

  static Future<String> handleTaskDelete(
    Map<String, dynamic> args,
    OwnerToolContext? ownerContext,
  ) async {
    if (!ScheduledTasksService.supported) {
      return _error(
        'scheduled_tasks_unavailable',
        'Scheduled tasks are not supported on this platform.',
      );
    }
    final taskId = '${args['task_id'] ?? ''}'.trim();
    if (taskId.isEmpty) {
      return _error('missing_argument', 'task_id is required.');
    }
    final service = ScheduledTasksService.instance;
    if (!service.tasks.any((task) => task.id == taskId)) {
      return _error('not_found', 'Unknown task_id: $taskId');
    }
    try {
      await service.delete(taskId);
    } on StateError catch (error) {
      return _error(
        error.message,
        error.message == 'task_running'
            ? 'The task is currently running; try again later.'
            : 'The task could not be deleted (${error.message}).',
      );
    }
    return jsonEncode({'ok': true, 'deleted': taskId});
  }

  // ---------------------------------------------------------------------------
  // Learning gateway pass-through

  /// The eight Learning Gateway tools (tools/learning_gateway/). The shell
  /// never spawns the gateway; it forwards to an already-configured MCP
  /// server, so connection lifecycle stays with the existing MCP stack.
  static const Set<String> learningToolNames = {
    'learning_record',
    'learning_recall',
    'learning_review_queue',
    'learning_promote',
    'learning_archive',
    'learning_stats',
    'learning_export_worldbook',
    'learning_ingest_inbox',
  };

  static Future<String> handleLearningCall(
    Map<String, dynamic> args,
    OwnerToolContext? ownerContext,
  ) async {
    final provider = ownerContext?.mcpProvider;
    if (provider == null) return _ownerUnavailable();
    final tool = '${args['tool'] ?? ''}'.trim();
    if (!learningToolNames.contains(tool)) {
      final names = learningToolNames.toList()..sort();
      return _error(
        'invalid_tool',
        'tool must be one of: ${names.join(', ')}.',
      );
    }
    final rawArguments = args['arguments'];
    final callArguments = rawArguments is Map
        ? Map<String, dynamic>.from(rawArguments)
        : <String, dynamic>{};
    String? serverId;
    for (final server in provider.connectedServers) {
      if (!server.enabled) continue;
      if (server.tools.any(
        (candidate) => candidate.enabled && candidate.name == tool,
      )) {
        serverId = server.id;
        break;
      }
    }
    if (serverId == null) {
      return jsonEncode({
        'error': 'learning_gateway_not_configured',
        'message':
            'No connected MCP server exposes "$tool". Configure the '
            'Learning Gateway first (Settings -> MCP -> add a stdio server).',
        'config_hint': {
          'transport': 'stdio',
          'command': 'python',
          'args': ['<repo>/tools/learning_gateway/learning_gateway.py'],
        },
      });
    }
    final result = await provider.callTool(serverId, tool, callArguments);
    if (result == null) {
      return _error(
        'gateway_unavailable',
        'The MCP server exposing "$tool" did not respond.',
      );
    }
    final texts = [
      for (final part in result.content)
        if (part is mcp.TextContent) part.text,
    ];
    return jsonEncode({
      'ok': result.isError != true,
      'tool': tool,
      'result': texts.join('\n'),
    });
  }

  // ---------------------------------------------------------------------------
  // Tool definitions

  static const Map<String, dynamic> ownerSettingsGetDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.ownerSettingsGet,
      'description':
          "Read the user's app settings by key (whitelisted keys only: "
          'app_locale, compress_max_chars, compress_prompt, '
          'current_assistant, current_model, search_enabled, '
          'suggestion_prompt, theme_mode, theme_palette_id, '
          'title_generation_enabled, title_prompt, translate_target_lang). '
          'Read-only; every call requires user approval. Omit keys to read '
          'all whitelisted keys.',
      'parameters': {
        'type': 'object',
        'properties': {
          'keys': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Optional subset of whitelisted keys to read. Defaults to '
                'all whitelisted keys.',
          },
        },
        'additionalProperties': false,
      },
    },
  };

  static const Map<String, dynamic> ownerSettingsSetDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.ownerSettingsSet,
      'description':
          'Modify ONE whitelisted app setting per call. Writable keys: '
          'theme_mode (system|light|dark), app_locale ("system" or a locale '
          'tag like en_US / zh_CN), title_prompt, suggestion_prompt, '
          'compress_prompt (non-empty, max 8000 chars), translate_target_lang '
          '(language code). Every other key is rejected as read-only. '
          'Changes take effect immediately and every call requires user '
          'approval.',
      'parameters': {
        'type': 'object',
        'properties': {
          'key': {
            'type': 'string',
            'description': 'One of the writable keys listed above.',
          },
          'value': {
            'description':
                'New value for the key (string for all writable '
                'keys; theme_mode expects system/light/dark).',
          },
        },
        'required': ['key', 'value'],
        'additionalProperties': false,
      },
    },
  };

  static const Map<String, dynamic> ownerTaskListDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.ownerTaskList,
      'description':
          'List the device-local scheduled tasks (name, time, repeat rule, '
          'enabled flag, next run, last run status; prompts truncated). '
          'Read-only; every call requires user approval.',
      'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
    },
  };

  static const Map<String, dynamic> ownerTaskCreateDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.ownerTaskCreate,
      'description':
          "Create a device-local scheduled task that sends 'prompt' with the "
          'chosen assistant at the given local time. Provide either date '
          '(one-time, YYYY-MM-DD) or weekdays (repeating, 1=Monday..7=Sunday). '
          'Tasks fire only while Kelivo is running: occurrences missed while '
          'the app is closed are skipped, and a one-time time already in the '
          'past is rejected. Every call requires user approval.',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Short task name (max 200 chars).',
          },
          'prompt': {
            'type': 'string',
            'description':
                'Instruction sent as the user message when the task fires '
                '(max 32000 chars).',
          },
          'hour': {'type': 'integer', 'description': 'Local hour, 0-23.'},
          'minute': {'type': 'integer', 'description': 'Local minute, 0-59.'},
          'date': {
            'type': 'string',
            'description': 'One-time run day, YYYY-MM-DD (device local time).',
          },
          'weekdays': {
            'type': 'array',
            'items': {'type': 'integer'},
            'description':
                'Repeating days as integers 1 (Monday) through 7 (Sunday).',
          },
          'mode': {
            'type': 'string',
            'enum': ['new_chat', 'follow_up'],
            'description':
                "new_chat (default) starts a fresh conversation; follow_up "
                'continues conversation_id.',
          },
          'assistant_id': {
            'type': 'string',
            'description':
                'Assistant to run the task with. Defaults to the current '
                'assistant.',
          },
          'conversation_id': {
            'type': 'string',
            'description': 'Required when mode is follow_up.',
          },
          'notify': {
            'type': 'boolean',
            'description':
                'Send a notification when the task fires '
                '(default true).',
          },
        },
        'required': ['name', 'prompt', 'hour', 'minute'],
        'additionalProperties': false,
      },
    },
  };

  static const Map<String, dynamic> ownerTaskDeleteDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.ownerTaskDelete,
      'description':
          'Delete one scheduled task by id (from owner_task_list). Every '
          'call requires user approval.',
      'parameters': {
        'type': 'object',
        'properties': {
          'task_id': {'type': 'string', 'description': 'From owner_task_list.'},
        },
        'required': ['task_id'],
        'additionalProperties': false,
      },
    },
  };

  static const Map<String, dynamic> ownerLearningCallDefinition = {
    'type': 'function',
    'function': {
      'name': LocalToolNames.ownerLearningCall,
      'description':
          'Forward a call to the Learning Gateway (a long-term lesson '
          'memory with a human-review shadow period). tool must be one of: '
          'learning_record, learning_recall, learning_review_queue, '
          'learning_promote, learning_archive, learning_stats, '
          'learning_export_worldbook, learning_ingest_inbox. Returns '
          'learning_gateway_not_configured with setup hints when the gateway '
          'MCP server is not connected. Every call requires user approval.',
      'parameters': {
        'type': 'object',
        'properties': {
          'tool': {
            'type': 'string',
            'description': 'One of the eight learning_* gateway tools.',
          },
          'arguments': {
            'type': 'object',
            'description':
                'Arguments object forwarded to the gateway tool as-is '
                '(e.g. {type, content, tags} for learning_record).',
          },
        },
        'required': ['tool'],
        'additionalProperties': false,
      },
    },
  };
}
