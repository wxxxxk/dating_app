import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'image_metadata_sanitizer.dart';

/// 사진 한 장을 고르고 처리하는 계약.
///
/// 위젯이 구체 구현(native image_picker)에 직접 묶이면 위젯 테스트가
/// platform fake에 의존하게 된다. 화면은 이 인터페이스만 본다.
abstract interface class ProfilePhotoPicker {
  Future<ProcessedProfilePhoto?> pickFromGallery();
}

/// 프로필 사진 선택·처리의 **단일 계약**.
///
/// 처리 기준이 진입점마다 다르면 같은 사진도 등록 경로에 따라 화질이 달라진다.
/// 온보딩·프로필 편집이 모두 이 클래스를 쓴다.
///
/// 여기서 하는 일은 두 가지뿐이다:
/// 1. 원본에서 **한 번만** resize·encode (image_picker)
/// 2. 개인정보 metadata 제거 (무손실, 픽셀 재인코딩 없음)
///
/// 이후 StorageService는 다시 resize·compress하지 않는다.
class ProfilePhotoProcessor implements ProfilePhotoPicker {
  ProfilePhotoProcessor({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// 처리 규칙 버전. 기준이 바뀌면 올린다(진단 로그·테스트가 참조한다).
  static const int processingVersion = 3;

  /// 긴 변 최대 픽셀.
  ///
  /// 가로·세로 **양쪽**에 같은 값을 주면 image_picker가 비율을 유지한 채
  /// 이 정사각형 안에 맞춘다. 즉 방향과 무관하게 긴 변이 이 값이 된다.
  static const int maxLongEdge = 2048;

  /// JPEG 재인코딩 품질. 80은 손실이 눈에 보였다.
  static const int jpegQuality = 90;

  /// 공개 프로필에 올릴 수 있는 포맷.
  ///
  /// HEIC/HEIF는 제외한다 — 무손실로 GPS·EXIF를 벗겨낼 방법이 없고,
  /// NetworkImage 표시 호환성도 보장되지 않는다. picker가 리사이즈하면
  /// 보통 JPEG로 나오지만, 그렇지 않은 경우를 통과시키지 않는다.
  static const Set<DetectedImageFormat> supportedFormats = {
    DetectedImageFormat.jpeg,
    DetectedImageFormat.png,
    DetectedImageFormat.webp,
  };

  /// 갤러리에서 프로필 사진 한 장을 고르고 처리한다.
  ///
  /// 사용자가 취소하면 null. 그 밖의 실패는 [ProfilePhotoFailure]를 던진다 —
  /// 예전처럼 byteLength=0인 "정상" 객체를 돌려주지 않는다.
  @override
  Future<ProcessedProfilePhoto?> pickFromGallery() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: maxLongEdge.toDouble(),
      maxHeight: maxLongEdge.toDouble(),
      imageQuality: jpegQuality,
      // 촬영 metadata를 애초에 덜 들고 오게 한다. 다만 이것만 믿지 않고
      // 아래에서 실제 bytes를 다시 sanitize·검증한다.
      requestFullMetadata: false,
    );
    if (picked == null) return null;
    return processFile(File(picked.path));
  }

  /// 파일을 읽어 포맷을 판정하고 metadata를 제거한다.
  ///
  /// 경로 확장자나 XFile.mimeType을 신뢰하지 않는다. **magic bytes가 기준**이다.
  Future<ProcessedProfilePhoto> processFile(File file) async {
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const ProfilePhotoFailure(ProfilePhotoFailureKind.readFailed);
    }
    return processBytes(bytes, targetFile: file);
  }

  /// bytes 기준 처리. 테스트가 파일 없이 계약을 검증할 수 있게 분리했다.
  ///
  /// [targetFile]이 있으면 정리된 bytes를 그 파일에 다시 쓴다.
  Future<ProcessedProfilePhoto> processBytes(
    Uint8List bytes, {
    File? targetFile,
  }) async {
    if (bytes.isEmpty) {
      throw const ProfilePhotoFailure(ProfilePhotoFailureKind.readFailed);
    }

    final format = detectImageFormat(bytes);
    if (format == DetectedImageFormat.unknown) {
      throw const ProfilePhotoFailure(ProfilePhotoFailureKind.invalidImage);
    }
    if (!supportedFormats.contains(format)) {
      throw const ProfilePhotoFailure(
        ProfilePhotoFailureKind.unsupportedFormat,
      );
    }

    final sanitized = sanitizeImageMetadata(bytes);
    if (sanitized == null) {
      // 포맷은 알겠는데 안전하게 벗겨낼 수 없다 → 원본을 fallback으로 올리지 않는다.
      throw const ProfilePhotoFailure(
        ProfilePhotoFailureKind.metadataSanitizationFailed,
      );
    }
    if (!sanitized.sanitized) {
      throw const ProfilePhotoFailure(
        ProfilePhotoFailureKind.metadataSanitizationFailed,
      );
    }

    var file = targetFile;
    if (file != null) {
      try {
        await file.writeAsBytes(sanitized.bytes, flush: true);
      } catch (_) {
        throw const ProfilePhotoFailure(ProfilePhotoFailureKind.readFailed);
      }
    }

    return ProcessedProfilePhoto(
      file: file,
      bytes: sanitized.bytes,
      byteLength: sanitized.bytes.length,
      contentType: format.contentType!,
      extension: format.extension!,
      processingVersion: processingVersion,
      metadataSanitized: true,
      // image_picker 한 번 + 무손실 metadata 제거 → 압축 pass는 1이다.
      compressionPassCount: 1,
    );
  }
}

/// 처리 실패 분류. 화면이 안전한 문구를 고르는 데 쓴다.
enum ProfilePhotoFailureKind {
  readFailed,
  invalidImage,
  unsupportedFormat,
  metadataSanitizationFailed,
}

class ProfilePhotoFailure implements Exception {
  final ProfilePhotoFailureKind kind;
  const ProfilePhotoFailure(this.kind);

  /// 사용자에게 보여줄 수 있는 문구. 경로·원문 오류를 담지 않는다.
  String get userMessage => switch (kind) {
    ProfilePhotoFailureKind.unsupportedFormat =>
      '지원하지 않는 사진 형식이에요. 다른 사진을 선택해 주세요.',
    _ => '사진을 처리하지 못했어요. 다른 사진을 선택해 주세요.',
  };

  @override
  String toString() => 'ProfilePhotoFailure(${kind.name})';
}

/// 처리 완료된 프로필 사진. 여기서부터는 재압축 대상이 아니다.
///
/// [metadataSanitized]가 true인 결과만 Storage에 올라간다.
class ProcessedProfilePhoto {
  final File? file;
  final Uint8List bytes;
  final int byteLength;
  final String contentType;
  final String extension;
  final int processingVersion;
  final bool metadataSanitized;
  final int compressionPassCount;

  const ProcessedProfilePhoto({
    required this.file,
    required this.bytes,
    required this.byteLength,
    required this.contentType,
    required this.extension,
    required this.processingVersion,
    required this.metadataSanitized,
    required this.compressionPassCount,
  });

  /// 진단 로그용 요약. 파일명·경로·UID·URL을 담지 않는다.
  String get diagnosticSummary =>
      'outputBytes=$byteLength outputFormat=$contentType '
      'compressionPassCount=$compressionPassCount '
      'metadataSanitized=$metadataSanitized '
      'processingVersion=$processingVersion';

  void logDiagnostics() {
    if (kDebugMode) debugPrint('[ProfilePhoto] $diagnosticSummary');
  }
}
