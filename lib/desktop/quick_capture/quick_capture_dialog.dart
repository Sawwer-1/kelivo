import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';

/// The outcome of a QuickCapture dialog: the (possibly empty) question the
/// user typed and the PNG file (full screen, or cropped by drag-select).
/// Empty text is legal — a screenshot-only message is valid chat input.
class QuickCaptureResult {
  const QuickCaptureResult({required this.text, required this.imageFile});

  final String text;
  final File imageFile;
}

/// F2 QuickCapture dialog: full-screen preview + question field + drag-to-
/// crop. Shows inside the Kelivo window (a floating overlay is phase 3).
abstract final class QuickCaptureDialog {
  /// Shows the dialog and, on confirm, persists the final PNG (cropped if
  /// the user selected a region) to a temp file. Returns null on cancel.
  static Future<QuickCaptureResult?> show(
    BuildContext context,
    Uint8List png,
  ) async {
    if (!context.mounted) return null;
    final result = await showDialog<(Uint8List, String)>(
      context: context,
      builder: (_) => _QuickCaptureBody(png: png),
    );
    if (result == null) return null;
    try {
      final dir = Directory(
        [
          Directory.systemTemp.path,
          'kelivo_quick_capture',
        ].join(Platform.pathSeparator),
      );
      await dir.create(recursive: true);
      final stamp = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'qc_'
          '${stamp.year}${two(stamp.month)}${two(stamp.day)}'
          '_${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}'
          '.png';
      final file = File([dir.path, name].join(Platform.pathSeparator));
      await file.writeAsBytes(result.$1, flush: true);
      if (!context.mounted) return null;
      return QuickCaptureResult(text: result.$2, imageFile: file);
    } catch (_) {
      return null;
    }
  }
}

class _QuickCaptureBody extends StatefulWidget {
  const _QuickCaptureBody({required this.png});

  final Uint8List png;

  @override
  State<_QuickCaptureBody> createState() => _QuickCaptureBodyState();
}

class _QuickCaptureBodyState extends State<_QuickCaptureBody> {
  Uint8List _png = Uint8List(0);
  ui.Image? _decoded;
  Rect? _selection; // in the preview area's local coordinates
  Rect? _previewArea; // LayoutBuilder area, captured for crop mapping
  bool _busy = false;

  late final TextEditingController _promptCtrl;

  @override
  void initState() {
    super.initState();
    _png = widget.png;
    _promptCtrl = TextEditingController();
    _decode();
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
    _decoded?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(_png);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _decoded = frame.image);
    } else {
      frame.image.dispose();
    }
  }

  /// Maps the preview-area selection back to image pixels (the preview is
  /// BoxFit.contain, so letterboxing on both axes must be compensated) and
  /// re-encodes the cropped region as the new PNG.
  Future<void> _crop() async {
    final image = _decoded;
    final selection = _selection;
    final area = _previewArea;
    if (image == null || selection == null || area == null || _busy) return;
    setState(() => _busy = true);
    try {
      final scale = math.min(area.width / image.width,
          area.height / image.height);
      final dx = (area.width - image.width * scale) / 2;
      final dy = (area.height - image.height * scale) / 2;
      double mapX(double x) =>
          ((x - dx) / scale).clamp(0.0, image.width.toDouble());
      double mapY(double y) =>
          ((y - dy) / scale).clamp(0.0, image.height.toDouble());
      final left = mapX(selection.left);
      final top = mapY(selection.top);
      final right = mapX(selection.right);
      final bottom = mapY(selection.bottom);
      final cropW = (right - left).round();
      final cropH = (bottom - top).round();
      if (cropW < 2 || cropH < 2) {
        setState(() => _selection = null); // stray click, ignore
        return;
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(left, top, right - left, bottom - top),
        Rect.fromLTWH(0, 0, cropW.toDouble(), cropH.toDouble()),
        Paint(),
      );
      final cropped = await recorder.endRecording().toImage(cropW, cropH);
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      final newPng = data?.buffer.asUint8List();
      cropped.dispose();
      if (newPng == null) return;
      final old = _decoded;
      setState(() {
        _png = newPng;
        _decoded = null;
        _selection = null;
      });
      old?.dispose();
      await _decode();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.quickCaptureDialogTitle),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _decoded == null
                    ? const Center(child: CircularProgressIndicator())
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final area = Offset.zero & constraints.biggest;
                          return Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: (details) => setState(() {
                                  _previewArea = area;
                                  _selection = Rect.fromPoints(
                                    _clampToArea(details.localPosition, area),
                                    _clampToArea(
                                        details.localPosition, area),
                                  );
                                }),
                                onPanUpdate: (details) => setState(() {
                                  if (_selection == null) return;
                                  _selection = Rect.fromPoints(
                                    _selection!.topLeft,
                                    _clampToArea(
                                        details.localPosition, area),
                                  );
                                }),
                                onPanEnd: (_) => setState(() {
                                  final sel = _selection;
                                  if (sel != null &&
                                      sel.width < 6 &&
                                      sel.height < 6) {
                                    _selection = null; // stray click
                                  }
                                }),
                                child: Image.memory(
                                  _png,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                ),
                              ),
                              if (_selection != null)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _SelectionPainter(
                                        selection: _selection!,
                                      ),
                                    ),
                                  ),
                                ),
                              if (_selection != null &&
                                  (_selection!.width >= 6 ||
                                      _selection!.height >= 6))
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: FilledButton.tonalIcon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          Colors.black.withValues(alpha: 0.65),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: _busy ? null : _crop,
                                    icon: const Icon(lucide.Lucide.Crop,
                                        size: 14),
                                    label: Text(
                                      l10n.quickCaptureCrop,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.quickCaptureCropHint,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 8),
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
          onPressed: _busy ? null : _submit,
          child: Text(l10n.quickCaptureSend),
        ),
      ],
    );
  }

  Offset _clampToArea(Offset offset, Rect area) => Offset(
        offset.dx.clamp(area.left, area.right),
        offset.dy.clamp(area.top, area.bottom),
      );

  void _submit() {
    Navigator.of(context).pop((_png, _promptCtrl.text.trim()));
  }
}

/// Dimmed overlay with a bright window for the selected region (draws the
/// four dim rectangles around the selection instead of blend tricks, so the
/// dialog underneath stays visible).
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({required this.selection});

  final Rect selection;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = const Color(0x66000000);
    // Four dim rectangles around the selection keep the preview inside it
    // fully visible — predictable over a dialog, no blend-mode tricks.
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, selection.top), dim);
    canvas.drawRect(
        Rect.fromLTRB(0, selection.bottom, size.width, size.height), dim);
    canvas.drawRect(
        Rect.fromLTRB(0, selection.top, selection.left, selection.bottom),
        dim);
    canvas.drawRect(
        Rect.fromLTRB(selection.right, selection.top, size.width,
            selection.bottom),
        dim);
    canvas.drawRect(
      selection,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter old) =>
      old.selection != selection;
}
