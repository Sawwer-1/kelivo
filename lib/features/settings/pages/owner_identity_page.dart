import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';

/// Owner identity declaration (AAA furnace-2): user-authored, model
/// read-only. The declaration is injected into the system prompt as a fixed
/// block when [SettingsProvider.ownerIdentityEnabled] is on.
class OwnerIdentityContent extends StatefulWidget {
  const OwnerIdentityContent({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  State<OwnerIdentityContent> createState() => _OwnerIdentityContentState();
}

class _OwnerIdentityContentState extends State<OwnerIdentityContent> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _declarationCtrl;
  Timer? _nameDebounce;
  Timer? _declarationDebounce;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    _nameCtrl = TextEditingController(text: settings.ownerName);
    _declarationCtrl = TextEditingController(text: settings.ownerDeclaration);
  }

  @override
  void dispose() {
    _nameDebounce?.cancel();
    _declarationDebounce?.cancel();
    _nameCtrl.dispose();
    _declarationCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    return SingleChildScrollView(
      padding:
          widget.padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SwitchRow(
            title: l10n.ownerIdentityEnabledTitle,
            subtitle: l10n.ownerIdentityEnabledSubtitle,
            value: settings.ownerIdentityEnabled,
            onChanged: (v) =>
                context.read<SettingsProvider>().setOwnerIdentityEnabled(v),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.ownerIdentityNameTitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              hintText: l10n.ownerIdentityNameHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              _nameDebounce?.cancel();
              _nameDebounce = Timer(const Duration(milliseconds: 500), () {
                context.read<SettingsProvider>().setOwnerName(_nameCtrl.text);
              });
            },
          ),
          const SizedBox(height: 16),
          Text(
            l10n.ownerIdentityDeclarationTitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _declarationCtrl,
            minLines: 5,
            maxLines: 12,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: l10n.ownerIdentityDeclarationHint,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              _declarationDebounce?.cancel();
              _declarationDebounce = Timer(
                const Duration(milliseconds: 500),
                () => context
                    .read<SettingsProvider>()
                    .setOwnerDeclaration(_declarationCtrl.text),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            l10n.ownerIdentityHowItWorks,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 15, color: cs.onSurface),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IosSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
