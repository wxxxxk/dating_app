import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

/// 공유용 위젯을 PNG로 캡처하고 시스템 공유 시트를 띄우는 유틸리티.
///
/// RepaintBoundary는 실제로 layout/paint된 위젯만 캡처할 수 있으므로,
/// 공유 순간에만 루트 Overlay의 화면 밖 좌표에 캡처용 위젯을 붙인 뒤 제거한다.
class ShareImageService {
  ShareImageService._();

  static Future<Uint8List> capturePng(
    GlobalKey repaintKey, {
    double pixelRatio = 3.0,
  }) async {
    await WidgetsBinding.instance.endOfFrame;

    final context = repaintKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw StateError('공유 카드 렌더 객체를 찾지 못했습니다.');
    }

    if (renderObject.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
    }

    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    if (byteData == null) {
      throw StateError('공유 이미지를 PNG로 변환하지 못했습니다.');
    }

    final bytes = byteData.buffer.asUint8List();
    debugPrint(
      '[ShareImage] PNG 생성 완료 bytes=${bytes.length} '
      'pixelRatio=$pixelRatio',
    );
    return bytes;
  }

  static Future<Uint8List> captureWidgetPng(
    BuildContext context, {
    required Widget child,
    double pixelRatio = 3.0,
  }) async {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      throw StateError('공유 이미지를 렌더할 Overlay를 찾지 못했습니다.');
    }

    final repaintKey = GlobalKey();
    final entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              // 캡처용 위젯은 paint는 되지만 화면 안에는 절대 들어오지 않게 둔다.
              offset: const Offset(-10000, -10000),
              child: RepaintBoundary(
                key: repaintKey,
                child: Material(type: MaterialType.transparency, child: child),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    try {
      await WidgetsBinding.instance.endOfFrame;
      return capturePng(repaintKey, pixelRatio: pixelRatio);
    } finally {
      entry.remove();
    }
  }

  static Future<ShareResult> sharePng({
    required BuildContext context,
    required Widget child,
    required String fileName,
    required String title,
    required String text,
    required Rect sharePositionOrigin,
  }) async {
    final bytes = await captureWidgetPng(context, child: child);
    final tempDir = await Directory.systemTemp.createTemp('dating_app_share_');
    final safeFileName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${tempDir.path}/$safeFileName');
    await file.writeAsBytes(bytes, flush: true);
    debugPrint('[ShareImage] 임시 공유 파일 생성: ${file.path}');

    final result = await SharePlus.instance.share(
      ShareParams(
        title: title,
        text: text,
        files: [XFile(file.path, mimeType: 'image/png', name: fileName)],
        sharePositionOrigin: sharePositionOrigin,
        downloadFallbackEnabled: true,
      ),
    );
    debugPrint('[ShareImage] 공유 결과 status=${result.status} raw=${result.raw}');
    return result;
  }
}
