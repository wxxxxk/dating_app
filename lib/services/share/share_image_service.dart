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
    // paint 완료 여부를 RenderObject.debugNeedsPaint로 분기하지 않는다.
    // Flutter SDK 문서(rendering/object.dart)에 "In release builds, this
    // throws"라고 명시된 debug 전용 getter라, release APK에서 읽는 순간
    // 100% LateInitializationError(내부 `late bool result` 미할당)를 던진다.
    // 실기기 공유 실패의 실제 원인이 이것이었다. 대신 프레임을 두 번 확실히
    // 대기하고 짧은 여유 시간을 더해, 실기기 프레임 페이싱 지연에도 paint가
    // 끝난 뒤 캡처하도록 안전하게 처리한다.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await Future.delayed(const Duration(milliseconds: 16));

    final context = repaintKey.currentContext;
    if (context == null) {
      debugPrint(
        '[ShareImage] 실패 단계=context-null (repaintKey.currentContext == null)',
      );
      throw StateError('공유 카드 렌더 객체를 찾지 못했습니다.');
    }

    // repaintKey.currentContext는 위 null 체크로 이미 "현재 트리에 붙어있음"이
    // 보장된 상태라 BuildContext 자체의 use_build_context_synchronously 위험이
    // 없다(State.context를 async gap 너머로 들고 쓰는 패턴이 아님).
    // ignore: use_build_context_synchronously
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      debugPrint(
        '[ShareImage] 실패 단계=render-object-cast '
        'actualType=${renderObject.runtimeType}',
      );
      throw StateError('공유 카드 렌더 객체를 찾지 못했습니다.');
    }

    debugPrint('[ShareImage] renderObject 확보');

    final ui.Image image;
    try {
      image = await renderObject.toImage(pixelRatio: pixelRatio);
    } catch (e, st) {
      debugPrint('[ShareImage] 실패 단계=toImage type=${e.runtimeType} message=$e');
      debugPrint('$st');
      rethrow;
    }

    final ByteData? byteData;
    try {
      byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    } catch (e, st) {
      debugPrint(
        '[ShareImage] 실패 단계=toByteData type=${e.runtimeType} message=$e',
      );
      debugPrint('$st');
      image.dispose();
      rethrow;
    }
    image.dispose();

    if (byteData == null) {
      debugPrint('[ShareImage] 실패 단계=toByteData-null (byteData == null)');
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
      debugPrint('[ShareImage] 캡처용 위젯을 Overlay에 삽입하고 첫 프레임 대기 완료');
      return await capturePng(repaintKey, pixelRatio: pixelRatio);
    } catch (e, st) {
      debugPrint(
        '[ShareImage] 실패 단계=captureWidgetPng type=${e.runtimeType} message=$e',
      );
      debugPrint('$st');
      rethrow;
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
    final Uint8List bytes;
    try {
      bytes = await captureWidgetPng(context, child: child);
    } catch (e, st) {
      debugPrint('[ShareImage] 실패 단계=capture type=${e.runtimeType} message=$e');
      debugPrint('$st');
      rethrow;
    }

    final File file;
    try {
      final tempDir = await Directory.systemTemp.createTemp(
        'dating_app_share_',
      );
      final safeFileName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      file = File('${tempDir.path}/$safeFileName');
      await file.writeAsBytes(bytes, flush: true);
      debugPrint('[ShareImage] 임시 공유 파일 생성 완료 bytes=${bytes.length}');
    } catch (e, st) {
      debugPrint(
        '[ShareImage] 실패 단계=file-write type=${e.runtimeType} message=$e',
      );
      debugPrint('$st');
      rethrow;
    }

    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          title: title,
          text: text,
          files: [XFile(file.path, mimeType: 'image/png', name: fileName)],
          sharePositionOrigin: sharePositionOrigin,
          downloadFallbackEnabled: true,
        ),
      );
      debugPrint('[ShareImage] 공유 결과 status=${result.status}');
      return result;
    } catch (e, st) {
      debugPrint(
        '[ShareImage] 실패 단계=share_plus type=${e.runtimeType} message=$e',
      );
      debugPrint('$st');
      rethrow;
    }
  }
}
