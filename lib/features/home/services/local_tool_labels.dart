import 'package:flutter/widgets.dart';

import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import 'local_tools_service.dart';

/// Ids of the local tools offered on this platform, in the order the assistant
/// "Local tools" tab lists them.
List<String> availableLocalToolIds() => [
  for (final id in LocalToolNames.all)
    if (LocalToolsService.isAvailableOnThisPlatform(id)) id,
];

IconData localToolIcon(String id) {
  switch (id) {
    case LocalToolNames.timeInfo:
      return Lucide.clock;
    case LocalToolNames.clipboard:
      return Lucide.Clipboard;
    case LocalToolNames.textToSpeech:
      return Lucide.Volume2;
    case LocalToolNames.askUser:
      return Lucide.MessageCircleQuestionMark;
    case LocalToolNames.calculate:
      return Lucide.Calculator;
    case LocalToolNames.screenTime:
      return Lucide.Smartphone;
    case LocalToolNames.calendarQuery:
      return Lucide.Calendar;
    case LocalToolNames.calendarCreate:
      return Lucide.CalendarPlus;
    case LocalToolNames.currentLocation:
      return Lucide.MapPin;
    case LocalToolNames.phoneControl:
      return Lucide.Smartphone;
    case LocalToolNames.weather:
      return Lucide.CloudSun;
    case LocalToolNames.healthSummary:
      return Lucide.HeartPulse;
    case LocalToolNames.remindersQuery:
      return Lucide.ListTodo;
    case LocalToolNames.remindersCreate:
      return Lucide.ListPlus;
    case LocalToolNames.remindersComplete:
      return Lucide.CheckCircle;
    case LocalToolNames.ownerListConversations:
      return Lucide.MessagesSquare;
    case LocalToolNames.ownerReadConversation:
      return Lucide.FileText;
    case LocalToolNames.ownerListAssistants:
      return Lucide.Bot;
    case LocalToolNames.ownerListProviders:
      return Lucide.Database;
    case LocalToolNames.ownerSettingsGet:
      return Lucide.Settings;
    case LocalToolNames.ownerSettingsSet:
      return Lucide.Settings2;
    case LocalToolNames.ownerTaskList:
      return Lucide.Calendar;
    case LocalToolNames.ownerTaskCreate:
      return Lucide.CalendarPlus;
    case LocalToolNames.ownerTaskDelete:
      return Lucide.Trash2;
    case LocalToolNames.ownerLearningCall:
      return Lucide.BookOpen;
    case LocalToolNames.ownerMcpList:
      return Lucide.Network;
    case LocalToolNames.ownerMcpToggle:
      return Lucide.Zap;
    case LocalToolNames.ownerMemoryList:
      return Lucide.Layers;
    case LocalToolNames.ownerMemoryWrite:
      return Lucide.SquarePen;
    case LocalToolNames.sshExec:
      return Lucide.Terminal;
    case LocalToolNames.sshUpload:
      return Lucide.Upload;
    case LocalToolNames.sshDownload:
      return Lucide.Download;
    case LocalToolNames.spawnSubtask:
      return Lucide.Bot;
    case LocalToolNames.ownerDreamView:
      return Lucide.Sparkles;
    default:
      return Lucide.Wrench;
  }
}

String localToolTitle(AppLocalizations l10n, String id) {
  switch (id) {
    case LocalToolNames.timeInfo:
      return l10n.assistantEditLocalToolTimeInfoTitle;
    case LocalToolNames.clipboard:
      return l10n.assistantEditLocalToolClipboardTitle;
    case LocalToolNames.textToSpeech:
      return l10n.assistantEditLocalToolTextToSpeechTitle;
    case LocalToolNames.askUser:
      return l10n.assistantEditLocalToolAskUserTitle;
    case LocalToolNames.calculate:
      return l10n.assistantEditLocalToolCalculateTitle;
    case LocalToolNames.screenTime:
      return l10n.assistantEditLocalToolScreenTimeTitle;
    case LocalToolNames.calendarQuery:
      return l10n.assistantEditLocalToolCalendarQueryTitle;
    case LocalToolNames.calendarCreate:
      return l10n.assistantEditLocalToolCalendarCreateTitle;
    case LocalToolNames.currentLocation:
      return l10n.assistantEditLocalToolLocationTitle;
    case LocalToolNames.phoneControl:
      return l10n.phoneControlTitle;
    case LocalToolNames.weather:
      return l10n.assistantEditLocalToolWeatherTitle;
    case LocalToolNames.healthSummary:
      return l10n.assistantEditLocalToolHealthTitle;
    case LocalToolNames.remindersQuery:
      return l10n.assistantEditLocalToolRemindersQueryTitle;
    case LocalToolNames.remindersCreate:
      return l10n.assistantEditLocalToolRemindersCreateTitle;
    case LocalToolNames.remindersComplete:
      return l10n.assistantEditLocalToolRemindersCompleteTitle;
    case LocalToolNames.ownerListConversations:
      return l10n.ownerToolListConversationsTitle;
    case LocalToolNames.ownerReadConversation:
      return l10n.ownerToolReadConversationTitle;
    case LocalToolNames.ownerListAssistants:
      return l10n.ownerToolListAssistantsTitle;
    case LocalToolNames.ownerListProviders:
      return l10n.ownerToolListProvidersTitle;
    case LocalToolNames.ownerSettingsGet:
      return l10n.ownerToolSettingsGetTitle;
    case LocalToolNames.ownerSettingsSet:
      return l10n.ownerToolSettingsSetTitle;
    case LocalToolNames.ownerTaskList:
      return l10n.ownerToolTaskListTitle;
    case LocalToolNames.ownerTaskCreate:
      return l10n.ownerToolTaskCreateTitle;
    case LocalToolNames.ownerTaskDelete:
      return l10n.ownerToolTaskDeleteTitle;
    case LocalToolNames.ownerLearningCall:
      return l10n.ownerToolLearningCallTitle;
    case LocalToolNames.ownerMcpList:
      return l10n.ownerToolMcpListTitle;
    case LocalToolNames.ownerMcpToggle:
      return l10n.ownerToolMcpToggleTitle;
    case LocalToolNames.ownerMemoryList:
      return l10n.ownerToolMemoryListTitle;
    case LocalToolNames.ownerMemoryWrite:
      return l10n.ownerToolMemoryWriteTitle;
    case LocalToolNames.sshExec:
      return l10n.assistantEditLocalToolSshExecTitle;
    case LocalToolNames.sshUpload:
      return l10n.assistantEditLocalToolSshUploadTitle;
    case LocalToolNames.sshDownload:
      return l10n.assistantEditLocalToolSshDownloadTitle;
    case LocalToolNames.spawnSubtask:
      return l10n.assistantEditLocalToolSpawnSubtaskTitle;
    case LocalToolNames.ownerDreamView:
      return l10n.ownerToolDreamViewTitle;
    default:
      return id;
  }
}
