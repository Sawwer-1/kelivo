import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 桌宠 (desktop pet): a small always-on-top assistant window.
///
/// desktop_multi_window re-enters `main()` for every sub-window engine; the
/// pet branch is chosen by the `kind: "pet"` marker in the window arguments.
/// All window plumbing is defensive — a failure on any desktop platform must
/// degrade to "no pet", never to a broken app.

const String petEnabledPrefKey = 'pet_enabled_v1';
const String petWindowArgsPrefKey = 'pet_window_args_v1';
const String _petKindMarker = '"kind":"pet"';

/// Diagnostic trail for the pet lifecycle. stderr is lost when the app is
/// launched from Explorer, so failures land in a file under the logs dir.
void _petLog(String message) {
  try {
    final base = Platform.environment['APPDATA'];
    if (base == null) return;
    final dir = Directory([base, 'com.psyche', 'kelivo', 'logs']
        .join(Platform.pathSeparator));
    dir.createSync(recursive: true);
    File([dir.path, 'pet_diag.log'].join(Platform.pathSeparator))
        .writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// Cross-window command channel: sub-window (pet) invokes, main handles.
const WindowMethodChannel petMethodChannel = WindowMethodChannel(
  'kelivo/pet',
  mode: ChannelMode.unidirectional,
);

/// Returns true when this engine is a pet sub-window (and runs its UI);
/// false on the main engine or when multi-window is unavailable.
Future<bool> branchPetEngine() async {
  if (kIsWeb) return false;
  try {
    final controller = await WindowController.fromCurrentEngine();
    final args = controller.arguments;
    if (!args.contains(_petKindMarker)) return false;
    _petLog('pet engine branch: args=$args');
    await _runPetWindow(controller, args);
    return true;
  } catch (error, stackTrace) {
    _petLog('pet engine branch FAILED: $error\n$stackTrace');
    return false;
  }
}

Future<void> _runPetWindow(
  WindowController controller,
  String argumentsJson,
) async {
  Map<String, dynamic> args = const {};
  try {
    final decoded = jsonDecode(argumentsJson);
    if (decoded is Map) {
      args = decoded.map((k, v) => MapEntry(k.toString(), v));
    }
  } catch (_) {}

  final assistantId = (args['assistantId'] ?? '').toString();
  final name = (args['assistantName'] ?? '').toString();
  final avatar = args['avatar']?.toString();

  await windowManager.ensureInitialized();
  try {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(200, 236),
        minimumSize: Size(200, 236),
        maximumSize: Size(200, 236),
        alwaysOnTop: true,
        skipTaskbar: true,
        title: 'Kelivo Pet',
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.setAlignment(Alignment.bottomRight);
        await windowManager.show();
      },
    );
  } catch (_) {
    // Geometry best-effort; the card still renders windowed.
  }

  try {
    final self = await WindowController.fromCurrentEngine();
    await self.setWindowMethodHandler((call) async {
      if (call.method == 'pet.destroy') {
        await windowManager.destroy();
      }
      return null;
    });
  } catch (_) {}

  runApp(
    _PetApp(assistantId: assistantId, assistantName: name, avatar: avatar),
  );
}

class _PetApp extends StatelessWidget {
  const _PetApp({
    required this.assistantId,
    required this.assistantName,
    this.avatar,
  });

  final String assistantId;
  final String assistantName;
  final String? avatar;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: _PetCard(
        assistantId: assistantId,
        assistantName: assistantName,
        avatar: avatar,
      ),
    );
  }
}

class _PetCard extends StatefulWidget {
  const _PetCard({
    required this.assistantId,
    required this.assistantName,
    this.avatar,
  });

  final String assistantId;
  final String assistantName;
  final String? avatar;

  @override
  State<_PetCard> createState() => _PetCardState();
}

class _PetCardState extends State<_PetCard> {
  bool _busy = false;

  Future<void> _openMain() async {
    if (_busy) return;
    _busy = true;
    try {
      await petMethodChannel.invokeMethod<dynamic>('pet.open_main');
    } catch (_) {}
    _busy = false;
  }

  Future<void> _requestClose() async {
    try {
      await petMethodChannel.invokeMethod<dynamic>('pet.close_requested');
    } catch (_) {
      // Main window gone: nothing to close into; die silently.
    }
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onPanStart: (_) => windowManager.startDragging(),
        child: Container(
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 0),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.assistantName.isEmpty
                            ? 'Kelivo'
                            : widget.assistantName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                    _PetIconButton(icon: Icons.close, onTap: _requestClose),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: GestureDetector(
                    onTap: _openMain,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: cs.surfaceContainer,
                          border: Border.all(
                            color: cs.primary.withValues(alpha: 0.4),
                            width: 2,
                          ),
                        ),
                        child: ClipOval(
                          child: _PetAvatar(avatar: widget.avatar),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '点按打开 Kelivo',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetIconButton extends StatelessWidget {
  const _PetIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 14, color: cs.onSurface.withValues(alpha: 0.6)),
      ),
    );
  }
}

class _PetAvatar extends StatelessWidget {
  const _PetAvatar({this.avatar});

  final String? avatar;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final source = avatar?.trim() ?? '';
    if (source.isEmpty) {
      return Icon(Icons.smart_toy_outlined, size: 44, color: cs.primary);
    }
    if (source.startsWith('data:image')) {
      final comma = source.indexOf(',');
      if (comma > 0) {
        return _fromBase64(source.substring(comma + 1), cs);
      }
    }
    if (source.startsWith('http')) {
      return Image.network(
        source,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.smart_toy_outlined, size: 44, color: cs.primary),
      );
    }
    final file = File(source);
    if (file.existsSync()) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.smart_toy_outlined, size: 44, color: cs.primary),
      );
    }
    return _fromBase64(source, cs);
  }

  Widget _fromBase64(String data, ColorScheme cs) {
    try {
      final cleaned = data.replaceAll(RegExp(r'\s'), '');
      return Image.memory(
        base64Decode(cleaned),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.smart_toy_outlined, size: 44, color: cs.primary),
      );
    } catch (_) {
      return Icon(Icons.smart_toy_outlined, size: 44, color: cs.primary);
    }
  }
}

// ---------------------------------------------------------------------------
// Main-window side

/// Owns the pet sub-window from the main engine: spawn, close, restore.
final class PetWindowManager {
  PetWindowManager._();

  static final PetWindowManager instance = PetWindowManager._();

  WindowController? _controller;
  bool _handlerInstalled = false;

  Future<void> ensureMainHandler() async {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    try {
      await petMethodChannel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'pet.open_main':
            await windowManager.show();
            await windowManager.focus();
            return null;
          case 'pet.close_requested':
            await close();
            return null;
        }
        return null;
      });
    } catch (_) {
      _handlerInstalled = false;
    }
  }

  /// Spawns the pet window for [assistant] and persists the intent so the
  /// next launch restores it.
  Future<void> spawn({
    required String assistantId,
    required String assistantName,
    String? avatar,
  }) async {
    await ensureMainHandler();
    final args = jsonEncode({
      'kind': 'pet',
      'assistantId': assistantId,
      'assistantName': assistantName,
      'avatar': avatar,
    });
    await close(closePref: false);
    try {
      _controller = await WindowController.create(
        WindowConfiguration(arguments: args, hiddenAtLaunch: false),
      );
      _petLog('spawn: created ${_controller?.windowId}');
    } catch (error, stackTrace) {
      _petLog('spawn FAILED: $error\n$stackTrace');
      _controller = null;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(petEnabledPrefKey, true);
    await prefs.setString(petWindowArgsPrefKey, args);
  }

  /// Closes the pet window. [closePref] clears the restore intent; the ✕
  /// inside the pet window must clear it, while a respawn keeps it.
  ///
  /// desktop_multi_window 0.3.1 exposes only window_show/window_hide
  /// natively, so destruction goes through the pet engine itself via its
  /// window method handler.
  Future<void> close({bool closePref = true}) async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        await controller.invokeMethod<dynamic>('pet.destroy');
      } catch (_) {}
    } else {
      // After a restart the main engine holds no controller; find pet
      // windows by their arguments and ask each to destroy itself.
      try {
        for (final window in await WindowController.getAll()) {
          if (window.arguments.contains(_petKindMarker)) {
            await window.invokeMethod<dynamic>('pet.destroy');
          }
        }
      } catch (_) {}
    }
    if (closePref) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(petEnabledPrefKey, false);
      await prefs.remove(petWindowArgsPrefKey);
    }
  }

  /// Restores the pet on app start when the user left it enabled.
  Future<void> restoreIfEnabled() async {
    _petLog('restore: enter');
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(petEnabledPrefKey) ?? false)) {
        _petLog('restore: disabled, skip');
        return;
      }
      final args = prefs.getString(petWindowArgsPrefKey);
      if (args == null || !args.contains(_petKindMarker)) {
        _petLog('restore: no args, skip');
        return;
      }
      await ensureMainHandler();
      // Closing stale windows must never block the respawn.
      try {
        await close(closePref: false);
      } catch (error) {
        _petLog('restore: stale close failed: $error');
      }
      _controller = await WindowController.create(
        WindowConfiguration(arguments: args, hiddenAtLaunch: false),
      );
      _petLog('restore: created ${_controller?.windowId}');
    } catch (error, stackTrace) {
      _petLog('restore: FAILED: $error\n$stackTrace');
      _controller = null;
    }
  }

  /// Mirrors the pref without touching windows (settings UI reads this).
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(petEnabledPrefKey) ?? false;
    } catch (_) {
      return false;
    }
  }
}
