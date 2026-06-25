import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/theme/app_colors.dart';

/// Loads the custom map marker bitmaps once (person + car from assets, plus a
/// drawn "typing" bubble). Falls back to drawn shapes if an asset is missing.
class MapMarkers {
  MapMarkers._();

  static BitmapDescriptor? car;
  static BitmapDescriptor? person;
  static BitmapDescriptor? bubble;
  static BitmapDescriptor? flag;
  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    car = await _asset('assets/markers/car.png', 46) ?? await _drawnCar();
    person =
        await _asset('assets/markers/person.png', 42) ?? await _drawnPerson();
    bubble = await _drawnBubble();
    flag = await _asset('assets/markers/flag.png', 42) ?? await _drawnFlag();
  }

  static Future<BitmapDescriptor?> _asset(String path, double size) async {
    try {
      return await BitmapDescriptor.asset(
        ImageConfiguration(size: Size(size, size)),
        path,
      );
    } catch (_) {
      return null;
    }
  }

  // --- Drawn fallbacks (used until/if PNGs are missing) ---
  static Future<BitmapDescriptor> _fromCanvas(
    double size,
    void Function(Canvas, double) paint,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paint(canvas, size);
    final img =
        await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(data!.buffer.asUint8List());
  }

  static Future<BitmapDescriptor> _drawnCar() => _fromCanvas(88, (canvas, s) {
        final c = Offset(s / 2, s / 2);
        canvas.drawCircle(c, 20, Paint()..color = Colors.white);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: c, width: 22, height: 34),
              const Radius.circular(7)),
          Paint()..color = AppColors.green,
        );
      });

  static Future<BitmapDescriptor> _drawnPerson() =>
      _fromCanvas(88, (canvas, s) {
        final c = Offset(s / 2, s / 2);
        canvas.drawCircle(c, 22, Paint()..color = AppColors.green);
        canvas.drawCircle(c, 22,
            Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = Colors.white);
        canvas.drawCircle(Offset(c.dx, c.dy - 5), 5, Paint()..color = Colors.white);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(c.dx, c.dy + 6), width: 16, height: 12),
              const Radius.circular(6)),
          Paint()..color = Colors.white,
        );
      });

  /// Destination pin — a dark disc with a white flag, visually distinct from
  /// the green pickup person marker.
  static Future<BitmapDescriptor> _drawnFlag() => _fromCanvas(88, (canvas, s) {
        final c = Offset(s / 2, s / 2);
        canvas.drawCircle(c, 22, Paint()..color = AppColors.dark);
        canvas.drawCircle(
            c,
            22,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4
              ..color = Colors.white);
        // Pole
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(c.dx - 8, c.dy - 11, 3, 22),
              const Radius.circular(1.5)),
          Paint()..color = Colors.white,
        );
        // Pennant
        final pennant = Path()
          ..moveTo(c.dx - 5, c.dy - 11)
          ..lineTo(c.dx + 10, c.dy - 7)
          ..lineTo(c.dx - 5, c.dy - 3)
          ..close();
        canvas.drawPath(pennant, Paint()..color = Colors.white);
      });

  static Future<BitmapDescriptor> _drawnBubble() => _fromCanvas(96, (canvas, s) {
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(8, 6, s - 16, 38),
          const Radius.circular(14),
        );
        canvas.drawRRect(r, Paint()..color = Colors.white);
        // little tail
        final tail = Path()
          ..moveTo(s / 2 - 7, 42)
          ..lineTo(s / 2 + 7, 42)
          ..lineTo(s / 2, 56)
          ..close();
        canvas.drawPath(tail, Paint()..color = Colors.white);
        // three dots
        for (var i = 0; i < 3; i++) {
          canvas.drawCircle(
            Offset(s / 2 - 12 + i * 12, 25),
            4,
            Paint()..color = AppColors.green,
          );
        }
      });
}
