import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// The outcome of a QuickCapture dialog: the (possibly empty) question the
/// user typed and the PNG file the screenshot was persisted to. Empty text
/// is legal — a screenshot-only message is valid chat input.
class QuickCaptureResult {
  const QuickCaptureResult({required this.text, required this.imageFile});

  final String text;
  final File imageFile;
}

/// F2 QuickCapture (phase 1) dialog: full-screen preview + question field.
/// Shows inside the Kelivo window (a floating overlay is phase 2).
abstract final class QuickCaptureDialog {
  /// Persists [png] to a temp file, then shows the dialog. Returns null
  /// when the user cancels (or the dialog could not be shown).
  static Future<QuickCaptureResult?> show(
    BuildContext context,
    Uint8List png,
  ) async {
    final File file;
    try {
      final dir = Directory(
        [
          Directory.systemTemp.path,
          'kelivo_quick_capture',
        ].join(Platform.pathSeparator),
      );
      await dir.create(recursive: true);
      final stamp = DateTime.now();
      final name = 'qc_'
          '${stamp.year}${_two(stamp.month)}${_two(stamp.day)}'
          '_${_two(stamp.hour)}${_two(stamp.minute)}${_two(stamp.second)}'
          '.png';
      file = File([dir.path, name].join(Platform.pathSeparator));
      await file.writeAsBytes(png, flush: true);
    } catch (_) {
      return null;
    }
    if (!context.mounted) return null;
    return showDialog<QuickCaptureResult>(
      context: context,
      builder: (dialogContext) => _QuickCaptureBody(png: png, file: file),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class _QuickCaptureBody extends StatefulWidget {
  const _QuickCaptureBody({required this.png, required this.file});

  final Uint8List png;
  final File file;

  @override
  State<_QuickCaptureBody> createState() => _QuickCaptureBodyState();
}

class _QuickCaptureBodyState extends State<_QuickCaptureBody> {
  late final TextEditingController _promptCtrl;

  @override
  void initState() {
    super.initState();
    // Default prompt is filled in didChangeDependencies: reading
    // AppLocalizations (an InheritedWidget) inside initState throws.
    _promptCtrl = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_promptCtrl.text.isEmpty) {
      final l10n = AppLocalizations.of(context);
      _promptCtrl.text = l10n?.quickCaptureDefaultPrompt ?? '';
    }
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.quickCaptureDialogTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  widget.png,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptCtrl,
              decoration: InputDecoration(
                labelText: l10n.quickCapturePromptLabel,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
              autofocus: true,
              onSubmitted: (_) => _submit(),
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
          child: Text(l10n.quickCaptureSend),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(
      QuickCaptureResult(text: _promptCtrl.text.trim(), imageFile: widget.file),
    );
  }
}
