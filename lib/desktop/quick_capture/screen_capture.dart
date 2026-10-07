import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart' as ffi;

/// F2 QuickCapture (phase 1): capture the entire virtual screen via GDI
/// BitBlt. Zero new pub dependencies — user32/gdi32 through dart:ffi, PNG
/// encoding through dart:ui. Windows only.

final class _BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight; // negative = top-down row order
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression; // 0 = BI_RGB
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

abstract final class ScreenCapture {
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');

  static final int Function(int) _getSystemMetrics = _user32
      .lookup<NativeFunction<Int32 Function(Int32)>>('GetSystemMetrics')
      .asFunction();
  static final Pointer<Void> Function(int) _getDC = _user32
      .lookup<NativeFunction<Pointer<Void> Function(IntPtr)>>('GetDC')
      .asFunction();
  static final int Function(int, Pointer<Void>) _releaseDC = _user32
      .lookup<NativeFunction<Int32 Function(IntPtr, Pointer<Void>)>>(
          'ReleaseDC')
      .asFunction();
  static final Pointer<Void> Function(Pointer<Void>) _createCompatibleDC =
      _gdi32
          .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>(
              'CreateCompatibleDC')
          .asFunction();
  static final Pointer<Void> Function(Pointer<Void>, int, int)
      _createCompatibleBitmap = _gdi32
          .lookup<
              NativeFunction<
                  Pointer<Void> Function(
                      Pointer<Void>, Int32, Int32)>>('CreateCompatibleBitmap')
          .asFunction();
  static final Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
      _selectObject = _gdi32
          .lookup<
              NativeFunction<
                  Pointer<Void> Function(
                      Pointer<Void>, Pointer<Void>)>>('SelectObject')
          .asFunction();
  static final int Function(Pointer<Void>) _deleteObject = _gdi32
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>('DeleteObject')
      .asFunction();
  static final int Function(Pointer<Void>) _deleteDC = _gdi32
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>('DeleteDC')
      .asFunction();
  static final int Function(Pointer<Void>, int, int, int, int, Pointer<Void>,
          int, int, int)
      _bitBlt = _gdi32
          .lookup<
              NativeFunction<
                  Int32 Function(
                      Pointer<Void>,
                      Int32,
                      Int32,
                      Int32,
                      Int32,
                      Pointer<Void>,
                      Int32,
                      Int32,
                      Uint32)>>('BitBlt')
          .asFunction();
  static final int Function(Pointer<Void>, Pointer<Void>, int, int,
          Pointer<Uint8>, Pointer<_BitmapInfoHeader>, int)
      _getDIBits = _gdi32
          .lookup<
              NativeFunction<
                  Int32 Function(
                      Pointer<Void>,
                      Pointer<Void>,
                      Uint32,
                      Uint32,
                      Pointer<Uint8>,
                      Pointer<_BitmapInfoHeader>,
                      Uint32)>>('GetDIBits')
          .asFunction();

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  // GetSystemMetrics indices for the full virtual screen (all monitors).
  static const int _smXVirtual = 76;
  static const int _smYVirtual = 77;
  static const int _smCxVirtual = 78;
  static const int _smCyVirtual = 79;
  static const int _srcCopy = 0x00CC0020;
  static const int _dibRgbColors = 0;

  /// Captures the full virtual screen and returns PNG bytes, or null on
  /// any failure. Called *before* the Kelivo window is raised so the shot
  /// shows exactly what was on screen at hotkey time.
  static Future<Uint8List?> capturePng() async {
    if (!isSupported) return null;
    final x = _getSystemMetrics(_smXVirtual);
    final y = _getSystemMetrics(_smYVirtual);
    final w = _getSystemMetrics(_smCxVirtual);
    final h = _getSystemMetrics(_smCyVirtual);
    if (w <= 0 || h <= 0) return null;

    final screenDc = _getDC(0);
    if (screenDc.address == 0) return null;
    Pointer<Void>? memDc;
    Pointer<Void>? bmp;
    Uint8List? pixels;
    try {
      memDc = _createCompatibleDC(screenDc);
      bmp = _createCompatibleBitmap(screenDc, w, h);
      if (memDc.address == 0 || bmp.address == 0) return null;
      final oldBmp = _selectObject(memDc, bmp);
      final blitOk =
          _bitBlt(memDc, 0, 0, w, h, screenDc, x, y, _srcCopy) != 0;
      if (blitOk) {
        final bmi = ffi.malloc<_BitmapInfoHeader>();
        final buf = ffi.malloc<Uint8>(w * h * 4);
        try {
          bmi.ref
            ..biSize = 40
            ..biWidth = w
            ..biHeight = -h // top-down
            ..biPlanes = 1
            ..biBitCount = 32
            ..biCompression = 0 // BI_RGB
            ..biSizeImage = w * h * 4
            ..biXPelsPerMeter = 0
            ..biYPelsPerMeter = 0
            ..biClrUsed = 0
            ..biClrImportant = 0;
          final lines = _getDIBits(memDc, bmp, 0, h, buf, bmi, _dibRgbColors);
          if (lines == h) {
            pixels = Uint8List.fromList(buf.asTypedList(w * h * 4));
          }
        } finally {
          ffi.malloc.free(buf);
          ffi.malloc.free(bmi);
        }
      }
      _selectObject(memDc, oldBmp);
    } finally {
      if (bmp != null && bmp.address != 0) _deleteObject(bmp);
      if (memDc != null && memDc.address != 0) _deleteDC(memDc);
      _releaseDC(0, screenDc);
    }
    if (pixels == null) return null;

    // GDI returns BGRA with a meaningless alpha channel: swap B<->R and
    // force full opacity so rgba8888 decoding does not yield a transparent
    // image.
    for (var i = 0; i < pixels.length; i += 4) {
      final b = pixels[i];
      pixels[i] = pixels[i + 2];
      pixels[i + 2] = b;
      pixels[i + 3] = 255;
    }

    // decodeImageFromPixels is callback-based; wrap it in a completer.
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888,
        completer.complete);
    final uiImage = await completer.future;
    try {
      final data = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      uiImage.dispose();
    }
  }
}
