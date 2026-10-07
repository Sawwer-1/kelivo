import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../core/services/ssh/ssh_hosts_store.dart';
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';

/// G2 phase 2: manage saved SSH host profiles (Settings → SSH hosts).
/// Passwords and key passphrases are sealed at rest by [SshHostsStore].
class SshHostsPane extends StatefulWidget {
  const SshHostsPane({super.key});

  @override
  State<SshHostsPane> createState() => _SshHostsPaneState();
}

class _SshHostsPaneState extends State<SshHostsPane> {
  @override
  void initState() {
    super.initState();
    SshHostsStore.instance.addListener(_onChanged);
    // Warm the lazy cache; the store notifies listeners when loaded.
    SshHostsStore.instance.byName('');
  }

  @override
  void dispose() {
    SshHostsStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _edit(SshHostProfile? existing) async {
    final saved = await showDialog<SshHostProfile>(
      context: context,
      builder: (_) => _SshHostEditDialog(existing: existing),
    );
    if (saved == null) return;
    await SshHostsStore.instance.upsert(saved);
  }

  Future<void> _delete(SshHostProfile profile) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.sshHostsDelete),
        content: Text(
          l10n.sshHostsDeleteConfirm(profile.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.quickCaptureCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.sshHostsDelete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await SshHostsStore.instance.remove(profile.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hosts = SshHostsStore.instance.hosts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.settingsPageSshHosts,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.sshHostsAdd,
                onPressed: () => _edit(null),
                icon: const Icon(lucide.Lucide.Plus, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.sshHostsDescription,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurface.withValues(
                    alpha: 0.6,
                  ),
            ),
          ),
          const SizedBox(height: 12),
          if (hosts.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  l10n.sshHostsEmpty,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: hosts.length,
                itemBuilder: (context, index) {
                  final host = hosts[index];
                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withValues(alpha: 0.4),
                      ),
                    ),
                    child: ListTile(
                      leading: const Icon(lucide.Lucide.Terminal, size: 20),
                      title: Text(
                        host.name,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        l10n.sshHostsSubtitle(
                          host.host,
                          host.port,
                          host.username,
                          host.useKeyAuth
                              ? l10n.sshHostsAuthKey
                              : l10n.sshHostsAuthPassword,
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: l10n.sshHostsEdit,
                            icon: const Icon(lucide.Lucide.Edit, size: 17),
                            onPressed: () => _edit(host),
                          ),
                          IconButton(
                            tooltip: l10n.sshHostsDelete,
                            icon: const Icon(lucide.Lucide.Trash2, size: 17),
                            onPressed: () => _delete(host),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SshHostEditDialog extends StatefulWidget {
  const _SshHostEditDialog({this.existing});

  final SshHostProfile? existing;

  @override
  State<_SshHostEditDialog> createState() => _SshHostEditDialogState();
}

class _SshHostEditDialogState extends State<_SshHostEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _keyPathCtrl;
  late final TextEditingController _keyPassphraseCtrl;
  late bool _useKeyAuth;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _hostCtrl = TextEditingController(text: e?.host ?? '');
    _portCtrl = TextEditingController(
        text: e == null ? '22' : e.port.toString());
    _usernameCtrl = TextEditingController(text: e?.username ?? '');
    _passwordCtrl = TextEditingController(text: e?.password ?? '');
    _keyPathCtrl = TextEditingController(text: e?.keyPath ?? '');
    _keyPassphraseCtrl =
        TextEditingController(text: e?.keyPassphrase ?? '');
    _useKeyAuth = e?.useKeyAuth ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _keyPathCtrl.dispose();
    _keyPassphraseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? l10n.sshHostsAdd
            : l10n.sshHostsEdit,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: l10n.sshHostsName,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.sshHostsHost,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: InputDecoration(
                      labelText: l10n.sshHostsPort,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _usernameCtrl,
              decoration: InputDecoration(
                labelText: l10n.sshHostsUsername,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.sshHostsAuthKey,
                  style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(l10n.sshHostsAuthKeyHint,
                  style: const TextStyle(fontSize: 11.5)),
              value: _useKeyAuth,
              onChanged: (v) => setState(() => _useKeyAuth = v),
            ),
            if (_useKeyAuth) ...[
              TextField(
                controller: _keyPathCtrl,
                decoration: InputDecoration(
                  labelText: l10n.sshHostsKeyPath,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _keyPassphraseCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.sshHostsKeyPassphrase,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ] else
              TextField(
                controller: _passwordCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.sshHostsPasswordField,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.quickCaptureCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.sshHostsSave),
        ),
      ],
    );
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;
    final name = _nameCtrl.text.trim();
    final host = _hostCtrl.text.trim();
    final username = _usernameCtrl.text.trim();
    if (name.isEmpty || host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(l10n.sshHostsMissingFields)),
      );
      return;
    }
    Navigator.of(context).pop(
      SshHostProfile(
        name: name,
        host: host,
        port: int.tryParse(_portCtrl.text.trim()) ?? 22,
        username: username,
        useKeyAuth: _useKeyAuth,
        password: _passwordCtrl.text,
        keyPath: _keyPathCtrl.text.trim(),
        keyPassphrase: _keyPassphraseCtrl.text,
      ),
    );
  }
}
