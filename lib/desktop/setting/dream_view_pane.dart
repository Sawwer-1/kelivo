import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/memory_entry.dart';
import '../../core/providers/assistant_provider.dart';
import '../../core/providers/memory_provider_v2.dart';
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';

/// H integration (Dream mechanism over the existing stores): a read-only
/// page for the (user × assistant) relationship profile. The kernel is fully
/// reused — the entries come from the memory tier (V1) and the promoted
/// lessons from the learning gateway ride the learned_policy injection;
/// human review lives in the memory management page and the gateway's
/// review flow. Nothing new is persisted here.
class DreamViewPane extends StatefulWidget {
  const DreamViewPane({super.key});

  @override
  State<DreamViewPane> createState() => _DreamViewPaneState();
}

class _DreamViewPaneState extends State<DreamViewPane> {
  String? _assistantId;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final assistants = context.read<AssistantProvider>().assistants;
      final current = context.read<AssistantProvider>().currentAssistant;
      setState(() {
        _assistantId = current?.id ??
            (assistants.isNotEmpty ? assistants.first.id : null);
      });
      _refresh();
    });
  }

  void _refresh() {
    final id = _assistantId;
    if (id == null) return;
    context
        .read<MemoryProviderV2>()
        .refresh(assistantId: id, loadAll: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final assistantProvider = context.watch<AssistantProvider>();
    final memory = context.watch<MemoryProviderV2>();
    final assistants = assistantProvider.assistants;
    final activeAssistantId = _assistantId;
    final visible = activeAssistantId == null
        ? const <MemoryEntry>[]
        : memory.visibleFor(activeAssistantId);
    final archived = activeAssistantId == null
        ? const <MemoryEntry>[]
        : memory
            .archivedFor(activeAssistantId)
            .where((e) => _showArchived)
            .toList(growable: false);
    final profileFields = memory.profileFields;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settingsPageDreamView,
            style: TextStyle(
              fontSize: 18,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.dreamViewDescription,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(l10n.dreamViewSelectAssistant,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: activeAssistantId,
                items: [
                  for (final a in assistants)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (value) {
                  if (value == null || value == _assistantId) return;
                  setState(() => _assistantId = value);
                  _refresh();
                },
              ),
              const Spacer(),
              IconButton(
                tooltip: l10n.sshHostsSave,
                onPressed: _refresh,
                icon: const Icon(lucide.Lucide.RotateCcw, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                _sectionTitle(l10n.dreamViewProfileFields),
                if (profileFields.isEmpty)
                  _empty(l10n.dreamViewEmpty)
                else ...[
                  for (final field in profileFields)
                    ListTile(
                      dense: true,
                      leading: const Icon(lucide.Lucide.User, size: 17),
                      title: Text(field.key,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(field.value,
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                ],
                const SizedBox(height: 8),
                _sectionTitle(l10n.dreamViewMemoriesActive),
                if (visible.isEmpty) _empty(l10n.dreamViewEmpty) else ...[
                  for (final entry in visible)
                    ListTile(
                      dense: true,
                      leading: const Icon(lucide.Lucide.Layers, size: 17),
                      title: Text(
                        '[${MemoryEntry.typeToString(entry.type)}] '
                        '${entry.content}',
                        style: const TextStyle(fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        l10n.dreamViewEntryMeta(
                          entry.scope == MemoryScope.global
                              ? l10n.dreamViewScopeGlobal
                              : l10n.dreamViewScopeAssistant,
                          entry.updatedAt.toIso8601String().substring(0, 10),
                        ),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.dreamViewShowArchived,
                      style: const TextStyle(fontSize: 13)),
                  value: _showArchived,
                  onChanged: (v) => setState(() => _showArchived = v),
                ),
                if (_showArchived) ...[
                  _sectionTitle(l10n.dreamViewMemoriesArchived),
                  if (archived.isEmpty)
                    _empty(l10n.dreamViewEmpty)
                  else
                    for (final entry in archived)
                      ListTile(
                        dense: true,
                        leading: const Icon(lucide.Lucide.Database, size: 17),
                        title: Text(entry.content,
                            style: const TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic)),
                      ),
                ],
                const SizedBox(height: 8),
                Text(
                  l10n.dreamViewLessonsNote,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: AppFontWeights.semibold,
          ),
        ),
      );

  Widget _empty(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.5),
          ),
        ),
      );
}
