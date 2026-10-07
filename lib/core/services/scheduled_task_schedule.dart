import '../models/scheduled_task.dart';

/// The first occurrence strictly after [after], in the device's local time.
/// Calendar arithmetic avoids drifting by an hour across daylight saving days.
DateTime? nextScheduledTaskRun(ScheduledTask task, DateTime after) {
  if (task.hour < 0 ||
      task.hour > 23 ||
      task.minute < 0 ||
      task.minute > 59 ||
      task.weekdays.isEmpty ||
      task.weekdays.any((day) => day < 1 || day > 7)) {
    throw ArgumentError('invalid_schedule');
  }
  DateTime date(DateTime value) => DateTime(value.year, value.month, value.day);
  final start = task.startDate == null ? null : date(task.startDate!);
  final end = task.endDate == null ? null : date(task.endDate!);
  if (start != null && end != null && start.isAfter(end)) {
    throw ArgumentError('invalid_date_range');
  }
  DateTime occurrence(DateTime day) =>
      DateTime(day.year, day.month, day.day, task.hour, task.minute);
  if (task.onceDate != null) {
    final day = date(task.onceDate!);
    if (start != null && day.isBefore(start) ||
        end != null && day.isAfter(end)) {
      return null;
    }
    final candidate = occurrence(day);
    return candidate.isAfter(after) ? candidate : null;
  }
  final today = date(after.toLocal());
  final first = start != null && start.isAfter(today) ? start : today;
  for (var offset = 0; offset <= 7; offset++) {
    final day = DateTime(first.year, first.month, first.day + offset);
    if (end != null && day.isAfter(end)) return null;
    if (!task.weekdays.contains(day.weekday)) continue;
    final candidate = occurrence(day);
    if (candidate.isAfter(after)) return candidate;
  }
  throw StateError('invalid_schedule');
}

void validateScheduledTask(ScheduledTask task) {
  if (task.id.isEmpty ||
      task.id.length > 128 ||
      task.name.trim().isEmpty ||
      task.name.trim().length > 200 ||
      task.assistantId.trim().isEmpty ||
      task.prompt.trim().length > 32000 ||
      task.mode != ScheduledTaskMode.regenerate && task.prompt.trim().isEmpty ||
      task.mode != ScheduledTaskMode.newChat &&
          (task.conversationId ?? '').trim().isEmpty ||
      task.mode == ScheduledTaskMode.regenerate &&
          (task.messageId ?? '').trim().isEmpty ||
      (task.modelProvider == null) != (task.modelId == null) ||
      task.modelId != null &&
          ((task.modelId!.trim().isEmpty) ||
              task.modelProvider!.trim().isEmpty)) {
    throw ArgumentError('invalid_task');
  }
  // G5 workflow steps: bounded count, non-empty prompts, the first step
  // cannot consume a previous output (there is none), fixed-text steps must
  // carry text, and per-step model overrides must stay paired.
  if (task.steps.length > 10) {
    throw ArgumentError('invalid_task');
  }
  for (var i = 0; i < task.steps.length; i++) {
    final step = task.steps[i];
    if (step.prompt.trim().isEmpty || step.prompt.trim().length > 16000) {
      throw ArgumentError('invalid_task');
    }
    if (i == 0 && step.source == ScheduledTaskStepSource.previousOutput) {
      throw ArgumentError('invalid_task');
    }
    if (step.source == ScheduledTaskStepSource.fixedText &&
        step.fixedText.trim().isEmpty) {
      throw ArgumentError('invalid_task');
    }
    if ((step.modelProvider == null) != (step.modelId == null)) {
      throw ArgumentError('invalid_task');
    }
  }
  if (task.preparationWindowMinutes < 1 ||
      task.preparationWindowMinutes > 1440 ||
      task.maxPrepareAttempts < 1 ||
      task.maxPrepareAttempts > 5 ||
      task.preparationCooldownMinutes < 1 ||
      task.preparationCooldownMinutes > 1440) {
    throw ArgumentError('invalid_preparation_options');
  }
}
