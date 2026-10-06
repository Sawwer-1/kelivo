import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/key_vault/key_vault.dart';
import '../../../icons/lucide_adapter.dart' as lucide;
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/section_card.dart';

import 'package:Kelivo/theme/app_font_weights.dart';

/// G7: built-in self-diagnostics. Checks provider reachability, MCP server
/// status, DPAPI vault health, tool-audit writability, the learning gateway
/// directory, adb availability and the promoted-snapshot freshness.

enum DoctorStatus { idle, running, ok, warn, fail }

class DoctorCheckResult {
  const DoctorCheckResult({
    required this.status,
    required this.detail,
    this.elapsed = Duration.zero,
  });

  final DoctorStatus status;
  final String detail;
  final Duration elapsed;
}

enum DoctorCheckId { providers, mcp, vault, audit, learning, adb, snapshot }

/// Shared diagnostics body used by the desktop pane and the mobile page.
class DoctorContent extends StatefulWidget {
  const DoctorContent({super.key, this.padding = const EdgeInsets.all(16)});

  final EdgeInsetsGeometry padding;

  @override
  State<DoctorContent> createState() => _DoctorContentState();
}

class _DoctorContentState extends State<DoctorContent> {
  final Map<DoctorCheckId, DoctorCheckResult?> _results = {
    for (final id in DoctorCheckId.values) id: null,
  };
  bool _runningAll = false;
  DateTime? _lastRunAll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(runAll());
    });
  }

  SettingsProvider get _settings => context.read<SettingsProvider>();
  McpProvider get _mcp => context.read<McpProvider>();

  Future<void> runAll() async {
    if (_runningAll) return;
    _runningAll = true;
    if (mounted) {
      setState(() {
        for (final id in DoctorCheckId.values) {
          _results[id] = DoctorCheckResult(
            status: DoctorStatus.running,
            detail: '',
          );
        }
      });
    }
    for (final id in DoctorCheckId.values) {
      await runOne(id);
    }
    _runningAll = false;
    if (mounted) {
      setState(() {
        _lastRunAll = DateTime.now();
      });
    }
  }

  Future<void> runOne(DoctorCheckId id) async {
    if (mounted) {
      setState(() {
        _results[id] = DoctorCheckResult(
          status: DoctorStatus.running,
          detail: '',
        );
      });
    }
    final sw = Stopwatch()..start();
    DoctorCheckResult result;
    try {
      switch (id) {
        case DoctorCheckId.providers:
          result = await _checkProviders();
        case DoctorCheckId.mcp:
          result = _checkMcp();
        case DoctorCheckId.vault:
          result = await _checkVault();
        case DoctorCheckId.audit:
          result = await _checkAudit();
        case DoctorCheckId.learning:
          result = await _checkLearning();
        case DoctorCheckId.adb:
          result = await _checkAdb();
        case DoctorCheckId.snapshot:
          result = await _checkSnapshot();
      }
    } catch (e) {
      result = DoctorCheckResult(status: DoctorStatus.fail, detail: '$e');
    }
    result = DoctorCheckResult(
      status: result.status,
      detail: result.detail,
      elapsed: sw.elapsed,
    );
    if (mounted) {
      setState(() {
        _results[id] = result;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Checks

  Future<DoctorCheckResult> _checkProviders() async {
    final configs = _settings.providerConfigs.values
        .where((c) => c.enabled)
        .toList(growable: false);
    if (configs.isEmpty) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'No enabled providers.',
      );
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 6),
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    var reachable = 0;
    final failed = <String>[];
    for (final c in configs) {
      final base = c.baseUrl.trim();
      if (base.isEmpty) {
        failed.add(c.name);
        continue;
      }
      try {
        await dio.getUri<dynamic>(Uri.parse(base));
        reachable++;
      } catch (_) {
        failed.add(c.name);
      }
    }
    final ok = reachable == configs.length;
    final detail = failed.isEmpty
        ? '$reachable/${configs.length} reachable'
        : '$reachable/${configs.length} reachable; unreachable: '
              '${failed.join(', ')}';
    return DoctorCheckResult(
      status: ok ? DoctorStatus.ok : DoctorStatus.warn,
      detail: detail,
    );
  }

  DoctorCheckResult _checkMcp() {
    final servers = _mcp.servers.where((s) => s.enabled).toList();
    if (servers.isEmpty) {
      return const DoctorCheckResult(
        status: DoctorStatus.ok,
        detail: 'No MCP servers configured.',
      );
    }
    var connected = 0;
    final problems = <String>[];
    for (final s in servers) {
      switch (_mcp.statusFor(s.id)) {
        case McpStatus.connected:
          connected++;
        case McpStatus.error:
          problems.add('${s.name}: error');
        default:
          problems.add('${s.name}: ${_mcp.statusFor(s.id).name}');
      }
    }
    final detail = problems.isEmpty
        ? '$connected/${servers.length} connected'
        : '$connected/${servers.length} connected; ${problems.join(', ')}';
    return DoctorCheckResult(
      status: connected == servers.length
          ? DoctorStatus.ok
          : (connected == 0 ? DoctorStatus.fail : DoctorStatus.warn),
      detail: detail,
    );
  }

  Future<DoctorCheckResult> _checkVault() async {
    final vault = KeyVault.instance;
    if (!vault.isSupported) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'Vault not supported on this platform.',
      );
    }
    final probe = 'kelivo-doctor-${DateTime.now().microsecondsSinceEpoch}';
    String roundtrip;
    try {
      final sealed = vault.encryptString(probe);
      if (!vault.isEncrypted(sealed)) {
        return const DoctorCheckResult(
          status: DoctorStatus.fail,
          detail: 'Ciphertext missing vault tag.',
        );
      }
      final opened = vault.decryptOrOriginal(sealed);
      roundtrip = opened.decrypted && opened.value == probe ? 'ok' : 'mismatch';
    } catch (e) {
      return DoctorCheckResult(status: DoctorStatus.fail, detail: '$e');
    }
    if (roundtrip != 'ok') {
      return const DoctorCheckResult(
        status: DoctorStatus.fail,
        detail: 'Seal/unseal round-trip mismatch.',
      );
    }
    // Count plaintext (unsealed) API keys among enabled providers.
    var plaintext = 0;
    for (final c in _settings.providerConfigs.values) {
      final key = c.apiKey.trim();
      if (c.enabled &&
          key.isNotEmpty &&
          !c.isOAuth &&
          !vault.isEncrypted(key)) {
        plaintext++;
      }
    }
    return DoctorCheckResult(
      status: plaintext == 0 ? DoctorStatus.ok : DoctorStatus.warn,
      detail: plaintext == 0
          ? 'DPAPI round-trip ok; all keys sealed'
          : 'DPAPI round-trip ok; $plaintext plaintext key(s)',
    );
  }

  Future<DoctorCheckResult> _checkAudit() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(
        [base.path, 'tool_audit'].join(Platform.pathSeparator),
      );
      await dir.create(recursive: true);
      final probe = File('${dir.path}${Platform.pathSeparator}doctor_probe');
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return DoctorCheckResult(status: DoctorStatus.ok, detail: dir.path);
    } catch (e) {
      return DoctorCheckResult(status: DoctorStatus.fail, detail: '$e');
    }
  }

  String? get _learningDirPath {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return '$appData\\kelivo_learning';
    }
    return null;
  }

  Future<DoctorCheckResult> _checkLearning() async {
    final root = _learningDirPath;
    if (root == null) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'Learning gateway is desktop (Windows) only.',
      );
    }
    final dir = Directory(root);
    if (!dir.existsSync()) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: '$root not found (gateway not installed or never run).',
      );
    }
    final inbox = Directory('$root\\inbox');
    var pending = 0;
    var writable = false;
    try {
      await inbox.create(recursive: true);
      final probe = File('${inbox.path}\\doctor_probe');
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      writable = true;
      pending = inbox
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .length;
    } catch (_) {}
    if (!writable) {
      return DoctorCheckResult(
        status: DoctorStatus.fail,
        detail: '$root exists but the inbox is not writable.',
      );
    }
    return DoctorCheckResult(
      status: DoctorStatus.ok,
      detail: pending == 0
          ? 'Inbox writable; 0 pending'
          : 'Inbox writable; $pending pending file(s)',
    );
  }

  Future<DoctorCheckResult> _checkAdb() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'adb check is desktop only.',
      );
    }
    try {
      final run = await Process.run('adb', const [
        'devices',
      ]).timeout(const Duration(seconds: 8));
      if (run.exitCode != 0) {
        return DoctorCheckResult(
          status: DoctorStatus.warn,
          detail: 'adb exited with ${run.exitCode}.',
        );
      }
      final devices = run.stdout
          .toString()
          .split('\n')
          .where((l) => l.trim().endsWith('\tdevice'))
          .length;
      return DoctorCheckResult(
        status: DoctorStatus.ok,
        detail: devices == 0 ? 'adb ok; 0 devices' : 'adb ok; $devices online',
      );
    } on ProcessException {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'adb not found (not installed or not in PATH).',
      );
    } on TimeoutException {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'adb timed out after 8s.',
      );
    }
  }

  Future<DoctorCheckResult> _checkSnapshot() async {
    final root = _learningDirPath;
    if (root == null) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'Learning gateway is desktop (Windows) only.',
      );
    }
    final file = File('$root\\promoted_snapshot.json');
    if (!file.existsSync()) {
      return const DoctorCheckResult(
        status: DoctorStatus.warn,
        detail: 'Not generated yet (written on first promoted lesson).',
      );
    }
    final age = DateTime.now().difference(await file.lastModified());
    final hours = age.inHours;
    final detail = hours < 1
        ? 'Updated ${age.inMinutes.clamp(0, 59)} min ago'
        : hours < 48
        ? 'Updated $hours h ago'
        : 'Updated ${age.inDays} d ago';
    return DoctorCheckResult(
      status: age.inDays <= 1 ? DoctorStatus.ok : DoctorStatus.warn,
      detail: detail,
    );
  }

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: widget.padding,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _runningAll ? null : () => runAll(),
                    icon: _runningAll
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(lucide.Lucide.RefreshCw, size: 16),
                    label: Text(l10n.doctorRunAll),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SectionCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                radius: 16,
                children: [
                  for (var i = 0; i < DoctorCheckId.values.length; i++) ...[
                    _row(context, DoctorCheckId.values[i]),
                    if (i != DoctorCheckId.values.length - 1)
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        color: cs.onSurface.withValues(alpha: 0.06),
                      ),
                  ],
                ],
              ),
              if (_lastRunAll != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${l10n.doctorLastRun}: '
                  '${_lastRunAll!.toLocal().toString().substring(0, 19)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, DoctorCheckId id) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final result = _results[id];
    final (icon, label) = switch (id) {
      DoctorCheckId.providers => (
        lucide.Lucide.Boxes,
        l10n.doctorCheckProviders,
      ),
      DoctorCheckId.mcp => (lucide.Lucide.Terminal, l10n.doctorCheckMcp),
      DoctorCheckId.vault => (lucide.Lucide.Lock, l10n.doctorCheckVault),
      DoctorCheckId.audit => (lucide.Lucide.FileText, l10n.doctorCheckAudit),
      DoctorCheckId.learning => (lucide.Lucide.Brain, l10n.doctorCheckLearning),
      DoctorCheckId.adb => (lucide.Lucide.Smartphone, l10n.doctorCheckAdb),
      DoctorCheckId.snapshot => (
        lucide.Lucide.FileClock,
        l10n.doctorCheckSnapshot,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
                if (result != null && result.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    result.detail,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _statusChip(context, result),
          const SizedBox(width: 4),
          _SmallIconBtn(onTap: _runningAll ? null : () => runOne(id)),
        ],
      ),
    );
  }

  Widget _statusChip(BuildContext context, DoctorCheckResult? result) {
    final l10n = AppLocalizations.of(context)!;
    final (color, text) = switch (result?.status) {
      DoctorStatus.ok => (const Color(0xFF34C759), l10n.doctorStatusOk),
      DoctorStatus.warn => (const Color(0xFFFF9500), l10n.doctorStatusWarn),
      DoctorStatus.fail => (const Color(0xFFFF3B30), l10n.doctorStatusFail),
      DoctorStatus.running => (
        const Color(0xFF8E8E93),
        l10n.doctorStatusRunning,
      ),
      DoctorStatus.idle ||
      null => (const Color(0xFF8E8E93), l10n.doctorStatusIdle),
    };
    final running = result?.status == DoctorStatus.running;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: running
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: AppFontWeights.medium,
                color: color,
              ),
            ),
    );
  }
}

class _SmallIconBtn extends StatelessWidget {
  const _SmallIconBtn({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          lucide.Lucide.RefreshCw,
          size: 15,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

/// Mobile settings page wrapper.
class DoctorPage extends StatelessWidget {
  const DoctorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.doctorPageTitle)),
      body: const DoctorContent(),
    );
  }
}
