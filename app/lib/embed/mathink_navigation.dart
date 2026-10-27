import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Host paper geometry is stable, independent of the current ink bounds.
Rect mathInkPaperRect(Object? value) {
  if (value is! Map) return const Rect.fromLTWH(0, 0, 1000, 1414);
  final width = value['width'], height = value['height'];
  if (width is! num ||
      height is! num ||
      !width.isFinite ||
      !height.isFinite ||
      width < 1 ||
      height < 1 ||
      width > 20000 ||
      height > 20000) {
    throw const FormatException('INVALID_PAGE_GEOMETRY');
  }
  return Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
}

({Offset position, double zoom}) mathInkFitView(
  Rect paper,
  Size viewport, {
  required bool widthOnly,
}) {
  if (viewport.width <= 0 || viewport.height <= 0) {
    throw const FormatException('VIEWPORT_NOT_READY');
  }
  final zoom = widthOnly
      ? ((viewport.width - 48) / paper.width).clamp(.1, 10.0)
      : 1.0;
  return (
    position: Offset(
      paper.center.dx - viewport.width / (2 * zoom),
      paper.height * zoom < viewport.height - 48
          ? paper.center.dy - viewport.height / (2 * zoom)
          : -24 / zoom,
    ),
    zoom: zoom,
  );
}

/// A candidate is decided at pointer down and never promoted after a pinch or
/// a pan that only reaches an edge halfway through this same gesture.
class MathInkPageGesture {
  int? pointer;
  Offset? start;
  Duration? began;
  bool previous = false, next = false, cancelled = false;
  int generation = 0;

  bool get active => pointer != null && !cancelled;
  void cancel() {
    cancelled = true;
  }

  void reset() {
    pointer = null;
    start = null;
    began = null;
    previous = false;
    next = false;
    cancelled = false;
    generation++;
  }

  void down(
    PointerDownEvent event, {
    required Rect paper,
    required Size viewport,
    required Offset camera,
    required double zoom,
    required bool allowed,
    required int pointerCount,
  }) {
    if (pointerCount != 1 || event.kind != PointerDeviceKind.touch) {
      cancel();
      return;
    }
    reset();
    if (!allowed ||
        event.localPosition.dx < 24 ||
        event.localPosition.dx > viewport.width - 24) {
      return;
    }
    pointer = event.pointer;
    start = event.localPosition;
    began = event.timeStamp;
    final fits = paper.width * zoom <= viewport.width + 2;
    previous = fits || camera.dx <= paper.left + 2 / zoom;
    next =
        fits ||
        camera.dx >=
            max(paper.left, paper.right - viewport.width / zoom) - 2 / zoom;
  }

  String? up(PointerUpEvent event) {
    if (!active || event.pointer != pointer || start == null || began == null) {
      return null;
    }
    final delta = event.localPosition - start!;
    final milliseconds = max(1, (event.timeStamp - began!).inMilliseconds);
    if (delta.dx.abs() < 64 ||
        delta.dx.abs() < delta.dy.abs() * 1.6 ||
        milliseconds > 1200 ||
        delta.dx.abs() / milliseconds < .08) {
      return null;
    }
    if (delta.dx < 0 && next) return 'next';
    if (delta.dx > 0 && previous) return 'previous';
    return null;
  }
}
