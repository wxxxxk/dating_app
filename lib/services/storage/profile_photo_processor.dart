import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// 프로필 사진 선택·처리의 **단일 계약**.
///
/// 1-D 감사 결과, 사진 처리 기준이 진입점마다 달랐다:
/// - 온보딩 대표 사진: `imageQuality: 85, maxWidth: 1080`
/// - 온보딩 서브 사진: `imageQuality: 80, maxWidth: 1080`
/// - 프로필 편집 교체: `imageQuality: 85` (해상도 제한 없음)
///
/// `maxWidth`만 주면 **가로 사진의 짧은 변이 무너진다** — 4000×3000 원본이
/// 1080×810이 되어, 카드가 1080px 폭으로 그리는 순간 확대되며 흐려진다.
/// 세로 사진도 긴 변이 1440px에 그쳐 상세 화면에서 부족했다.
///
/// 그래서 처리를 한 곳으로 모으고, 가로·세로 모두 긴 변 기준으로 제한한다.
/// 이 모듈이 유일한 처리 지점이며, 이후 단계(StorageService)는 다시
/// resize·compress하지 않는다.
class ProfilePhotoProcessor {
  ProfilePhotoProcessor({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// 처리 규칙 버전. 기준이 바뀌면 올린다(진단 로그·테스트가 참조한다).
  static const int processingVersion = 2;

  /// 긴 변 최대 픽셀.
  ///
  /// 가로·세로 **양쪽**에 같은 값을 주면 image_picker가 비율을 유지한 채
  /// 이 정사각형 안에 맞춘다. 즉 방향과 무관하게 긴 변이 이 값이 된다.
  /// 4:3 가로 사진이면 2048×1536이 되어 짧은 변도 1080을 넉넉히 넘긴다.
  static const int maxLongEdge = 2048;

  /// JPEG 재인코딩 품질.
  ///
  /// 원본이 이미 JPEG면 decode→encode가 한 번 더 일어난다. 80은 그 손실이
  /// 눈에 보였다. 90은 파일 크기(약 0.6~1.5MB)와 품질의 균형점이다.
  static const int jpegQuality = 90;

  /// 갤러리에서 프로필 사진 한 장을 고르고 처리한다.
  ///
  /// 처리는 image_picker 한 번의 호출로 끝난다 — 별도 compressor를 거치지
  /// 않으므로 압축 pass는 항상 1이다. image_picker는 리사이즈 시 EXIF
  /// orientation을 픽셀에 반영해 저장하므로 세로 사진이 눕지 않는다.
  Future<ProcessedProfilePhoto?> pickFromGallery() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: maxLongEdge.toDouble(),
      maxHeight: maxLongEdge.toDouble(),
      imageQuality: jpegQuality,
    );
    if (picked == null) return null;
    return describe(File(picked.path));
  }

  /// 처리된 파일을 진단 가능한 결과로 감싼다.
  ///
  /// 파일을 다시 인코딩하지 않는다. 크기만 읽는다.
  static ProcessedProfilePhoto describe(File file) {
    var byteLength = 0;
    try {
      byteLength = file.lengthSync();
    } catch (_) {
      byteLength = 0;
    }
    return ProcessedProfilePhoto(
      file: file,
      byteLength: byteLength,
      contentType: 'image/jpeg',
      extension: 'jpg',
      processingVersion: processingVersion,
    );
  }
}

/// 처리 완료된 프로필 사진. 여기서부터는 재압축 대상이 아니다.
class ProcessedProfilePhoto {
  final File file;
  final int byteLength;
  final String contentType;
  final String extension;
  final int processingVersion;

  const ProcessedProfilePhoto({
    required this.file,
    required this.byteLength,
    required this.contentType,
    required this.extension,
    required this.processingVersion,
  });

  /// 진단 로그용 요약. 파일명·경로·UID를 담지 않는다.
  String get diagnosticSummary =>
      'outputBytes=$byteLength format=$contentType '
      'compressionPassCount=1 processingVersion=$processingVersion';

  void logDiagnostics() {
    if (kDebugMode) debugPrint('[ProfilePhoto] $diagnosticSummary');
  }
}
