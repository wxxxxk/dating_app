import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/services/storage/image_metadata_sanitizer.dart';
import 'package:dating_app/services/storage/profile_photo_processor.dart';
import 'package:dating_app/services/storage/storage_service.dart';

// 1-D 최종 보정 회귀 테스트.
//
// 수정 전: describe()가 파일 내용과 무관하게 항상 image/jpeg / jpg를 반환했다.
// PNG·텍스트 파일도 JPEG로 위장돼 업로드될 수 있었고, GPS·EXIF가 실제로
// 제거됐는지 아무도 확인하지 않았다.
//
// 저장소에 binary를 추가하지 않고 fixture bytes를 코드로 만든다.

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// 최소 JPEG: SOI + APP segment들 + DQT + SOS + payload + EOI
Uint8List jpegFixture({
  bool withExif = false,
  bool withGps = false,
  bool withXmp = false,
  bool withComment = false,
  List<int> payload = const [0x11, 0x22, 0x33, 0x44],
}) {
  final out = <int>[0xFF, 0xD8];

  void app(int marker, List<int> body) {
    final length = body.length + 2;
    out.addAll([0xFF, marker, (length >> 8) & 0xFF, length & 0xFF]);
    out.addAll(body);
  }

  // APP0(JFIF) — 개인정보가 아니라 유지 대상
  app(0xE0, [...ascii.encode('JFIF'), 0x00, 0x01, 0x01, 0x00]);

  if (withExif || withGps) {
    final exif = <int>[...ascii.encode('Exif'), 0x00, 0x00];
    if (withGps) exif.addAll(ascii.encode('GPSLatitude37.5665'));
    app(0xE1, exif);
  }
  if (withXmp) {
    app(0xE1, ascii.encode('http://ns.adobe.com/xap/1.0/<x:xmpmeta/>'));
  }
  if (withComment) {
    app(0xFE, ascii.encode('Canon EOS R5 serial 12345'));
  }

  app(0xDB, [0x00, ...List.filled(64, 0x10)]); // DQT — 유지돼야 함

  out.addAll([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
  out.addAll(payload);
  out.addAll([0xFF, 0xD9]);
  return _bytes(out);
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i += 1) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 최소 PNG: signature + IHDR + (선택)metadata + IDAT + IEND
Uint8List pngFixture({bool withExif = false, bool withText = false}) {
  final out = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  void chunk(String type, List<int> data) {
    final length = data.length;
    out.addAll([
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
    final typed = [...ascii.encode(type), ...data];
    out.addAll(typed);
    final crc = _crc32(typed);
    out.addAll([
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
  }

  chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  if (withExif) chunk('eXIf', ascii.encode('GPSLatitude37.5665'));
  if (withText) chunk('tEXt', ascii.encode('ArtistHong'));
  chunk('IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]);
  chunk('IEND', const []);
  return _bytes(out);
}

/// 최소 WebP: RIFF + WEBP + VP8X + (선택)EXIF/XMP + VP8
Uint8List webpFixture({bool withExif = false, bool withXmp = false}) {
  final body = <int>[...ascii.encode('WEBP')];

  void chunk(String fourcc, List<int> data) {
    body.addAll(ascii.encode(fourcc));
    final size = data.length;
    body.addAll([
      size & 0xFF,
      (size >> 8) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 24) & 0xFF,
    ]);
    body.addAll(data);
    if (size.isOdd) body.add(0);
  }

  // VP8X flags: bit3=EXIF, bit2=XMP
  final flags = (withExif ? 0x08 : 0) | (withXmp ? 0x04 : 0);
  chunk('VP8X', [flags, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  if (withExif) chunk('EXIF', ascii.encode('GPSLatitude37.5665'));
  if (withXmp) chunk('XMP ', ascii.encode('<x:xmpmeta/>'));
  chunk('VP8 ', [0x01, 0x02, 0x03, 0x04]);

  final out = <int>[...ascii.encode('RIFF')];
  final size = body.length;
  out.addAll([
    size & 0xFF,
    (size >> 8) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 24) & 0xFF,
  ]);
  out.addAll(body);
  return _bytes(out);
}

Uint8List heicFixture() => _bytes([
  0,
  0,
  0,
  0x18,
  ...ascii.encode('ftyp'),
  ...ascii.encode('heic'),
  0,
  0,
  0,
  0,
  ...ascii.encode('heicmif1'),
]);

String _text(Uint8List bytes) => ascii.decode(bytes, allowInvalid: true);

void main() {
  final processor = ProfilePhotoProcessor();

  group('1~7. 실제 bytes 기반 포맷 판정', () {
    test('1. JPEG signature → image/jpeg / jpg', () async {
      final result = await processor.processBytes(jpegFixture());
      expect(result.contentType, 'image/jpeg');
      expect(result.extension, 'jpg');
    });

    test('2. PNG signature → image/png / png', () async {
      final result = await processor.processBytes(pngFixture());
      expect(result.contentType, 'image/png');
      expect(result.extension, 'png');
    });

    test('3. WebP signature → image/webp / webp', () async {
      final result = await processor.processBytes(webpFixture());
      expect(result.contentType, 'image/webp');
      expect(result.extension, 'webp');
    });

    test('4. 일반 텍스트는 invalidImage로 거부한다', () async {
      await expectLater(
        processor.processBytes(
          _bytes(ascii.encode('hello world, this is not an image at all')),
        ),
        throwsA(
          isA<ProfilePhotoFailure>().having(
            (f) => f.kind,
            'kind',
            ProfilePhotoFailureKind.invalidImage,
          ),
        ),
      );
    });

    test('5. pubspec.yaml 내용은 이미지로 판정되지 않는다', () async {
      const yaml =
          'name: dating_app\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n';
      expect(
        detectImageFormat(_bytes(ascii.encode(yaml))),
        DetectedImageFormat.unknown,
      );
      await expectLater(
        processor.processBytes(_bytes(ascii.encode(yaml))),
        throwsA(isA<ProfilePhotoFailure>()),
      );
    });

    test('6. 잘린 JPEG은 거부한다', () async {
      final truncated = Uint8List.sublistView(jpegFixture(), 0, 6);
      await expectLater(
        processor.processBytes(truncated),
        throwsA(isA<ProfilePhotoFailure>()),
      );
    });

    test('7. 확장자와 bytes가 충돌하면 bytes를 우선한다', () async {
      // 이름이 .jpg여도 내용이 PNG면 PNG로 판정돼야 한다.
      final result = await processor.processBytes(pngFixture());
      expect(result.extension, 'png', reason: '경로 확장자를 신뢰하면 안 된다');
      expect(result.contentType, 'image/png');
    });

    test('HEIC은 unsupportedFormat으로 거부한다', () async {
      expect(detectImageFormat(heicFixture()), DetectedImageFormat.heic);
      await expectLater(
        processor.processBytes(heicFixture()),
        throwsA(
          isA<ProfilePhotoFailure>().having(
            (f) => f.kind,
            'kind',
            ProfilePhotoFailureKind.unsupportedFormat,
          ),
        ),
      );
    });

    test('빈 파일은 readFailed다', () async {
      await expectLater(
        processor.processBytes(Uint8List(0)),
        throwsA(
          isA<ProfilePhotoFailure>().having(
            (f) => f.kind,
            'kind',
            ProfilePhotoFailureKind.readFailed,
          ),
        ),
      );
    });
  });

  group('8~13. metadata 제거', () {
    test('8. JPEG EXIF APP1이 제거된다', () async {
      final source = jpegFixture(withExif: true);
      expect(hasPrivacyMetadata(source), isTrue);
      final result = await processor.processBytes(source);
      expect(hasPrivacyMetadata(result.bytes), isFalse);
      expect(result.metadataSanitized, isTrue);
    });

    test('9. JPEG GPS 좌표가 남지 않는다', () async {
      final source = jpegFixture(withGps: true);
      expect(_text(source).contains('GPSLatitude'), isTrue);
      final result = await processor.processBytes(source);
      expect(
        _text(result.bytes).contains('GPSLatitude'),
        isFalse,
        reason: 'GPS 좌표가 공개 프로필 사진에 남으면 안 된다',
      );
    });

    test('10. JPEG XMP와 카메라 comment가 제거된다', () async {
      final source = jpegFixture(withXmp: true, withComment: true);
      final result = await processor.processBytes(source);
      final text = _text(result.bytes);
      expect(text.contains('xmpmeta'), isFalse);
      expect(text.contains('Canon EOS R5'), isFalse);
      expect(text.contains('serial'), isFalse);
    });

    test('JFIF APP0는 유지된다 (표시 호환성, 개인정보 아님)', () async {
      final result = await processor.processBytes(jpegFixture(withExif: true));
      expect(_text(result.bytes).contains('JFIF'), isTrue);
    });

    test('11. PNG eXIf·tEXt가 제거된다', () async {
      final source = pngFixture(withExif: true, withText: true);
      expect(hasPrivacyMetadata(source), isTrue);
      final result = await processor.processBytes(source);
      final text = _text(result.bytes);
      expect(text.contains('eXIf'), isFalse);
      expect(text.contains('tEXt'), isFalse);
      expect(text.contains('GPSLatitude'), isFalse);
      expect(text.contains('Hong'), isFalse);
      expect(result.metadataSanitized, isTrue);
    });

    test('12. WebP EXIF·XMP chunk가 제거되고 VP8X flag가 내려간다', () async {
      final source = webpFixture(withExif: true, withXmp: true);
      expect(hasPrivacyMetadata(source), isTrue);
      final result = await processor.processBytes(source);
      final text = _text(result.bytes);
      expect(text.contains('GPSLatitude'), isFalse);
      expect(text.contains('xmpmeta'), isFalse);
      expect(hasPrivacyMetadata(result.bytes), isFalse);
      // VP8X payload 첫 바이트(flags)에서 EXIF/XMP 비트가 꺼졌는지.
      expect(result.bytes[12 + 8] & 0x0C, 0);
    });

    test('13. 픽셀 payload는 보존된다 (무손실 sanitization)', () async {
      const payload = [0xAB, 0xCD, 0xEF, 0x12];
      final result = await processor.processBytes(
        jpegFixture(withExif: true, withGps: true, payload: payload),
      );
      var found = false;
      for (var i = 0; i + 4 <= result.bytes.length; i += 1) {
        if (result.bytes[i] == payload[0] &&
            result.bytes[i + 1] == payload[1] &&
            result.bytes[i + 2] == payload[2] &&
            result.bytes[i + 3] == payload[3]) {
          found = true;
          break;
        }
      }
      expect(found, isTrue, reason: '픽셀 데이터를 재인코딩하면 안 된다');
      expect(result.bytes[result.bytes.length - 2], 0xFF);
      expect(result.bytes.last, 0xD9);
    });

    test('metadata가 없는 파일은 그대로 통과한다', () async {
      final source = jpegFixture();
      final result = await processor.processBytes(source);
      expect(result.metadataSanitized, isTrue);
      expect(result.byteLength, lessThanOrEqualTo(source.length));
    });
  });

  group('14/17~19. 업로드 계약', () {
    test('14/19. metadataSanitized=false면 업로드가 차단된다', () {
      final unsafe = ProcessedProfilePhoto(
        file: null,
        bytes: jpegFixture(),
        byteLength: 10,
        contentType: 'image/jpeg',
        extension: 'jpg',
        processingVersion: ProfilePhotoProcessor.processingVersion,
        metadataSanitized: false,
        compressionPassCount: 1,
      );
      // Storage 호출 전에 막힌다(Firebase 초기화 없이 검증 가능).
      expect(() => ensureUploadablePhoto(unsafe), throwsA(isA<StateError>()));

      final safe = ProcessedProfilePhoto(
        file: null,
        bytes: jpegFixture(),
        byteLength: 10,
        contentType: 'image/jpeg',
        extension: 'jpg',
        processingVersion: ProfilePhotoProcessor.processingVersion,
        metadataSanitized: true,
        compressionPassCount: 1,
      );
      expect(() => ensureUploadablePhoto(safe), returnsNormally);
    });

    test('17/18. object 이름이 실제 확장자를 쓴다', () {
      expect(
        buildProfilePhotoObjectName(role: 'main', extension: 'png'),
        endsWith('.png'),
      );
      expect(
        buildProfilePhotoObjectName(role: 'sub_1', extension: 'webp'),
        startsWith('sub_1_'),
      );
    });

    test('object 이름에 nonce가 있어 같은 밀리초에도 충돌하지 않는다', () {
      final names = <String>{};
      for (var i = 0; i < 200; i += 1) {
        names.add(buildProfilePhotoObjectName(role: 'main', extension: 'jpg'));
      }
      expect(names.length, 200);
    });

    test('object 이름에 사용자 파일명이 들어가지 않는다', () {
      final name = buildProfilePhotoObjectName(role: 'main', extension: 'jpg');
      expect(
        RegExp(r'^main_\d+_[a-z0-9]+\.jpg$').hasMatch(name),
        isTrue,
        reason: name,
      );
    });
  });

  group('20. 진단 로그 비식별화', () {
    test('허용된 수치만 담고 경로·URL·파일명이 없다', () async {
      final result = await processor.processBytes(jpegFixture());
      final summary = result.diagnosticSummary;
      expect(summary.contains('outputBytes='), isTrue);
      expect(summary.contains('outputFormat='), isTrue);
      expect(summary.contains('metadataSanitized=true'), isTrue);
      expect(summary.contains('compressionPassCount=1'), isTrue);
      expect(summary.contains('processingVersion='), isTrue);
      expect(summary.contains('http'), isFalse);
      expect(summary.contains('.jpg'), isFalse);
      expect(summary.replaceAll('image/jpeg', '').contains('/'), isFalse);
    });

    test('processingVersion이 올라갔다', () {
      expect(ProfilePhotoProcessor.processingVersion, greaterThanOrEqualTo(3));
    });
  });

  group('처리 기준 유지 (직전 작업 회귀 방지)', () {
    test('긴 변 2048, 품질 90이 유지된다', () {
      expect(ProfilePhotoProcessor.maxLongEdge, 2048);
      expect(ProfilePhotoProcessor.jpegQuality, 90);
    });

    test('4:3 가로 사진의 짧은 변이 1080을 넘는다', () {
      expect(
        (ProfilePhotoProcessor.maxLongEdge * 3) ~/ 4,
        greaterThanOrEqualTo(1080),
      );
    });

    test('지원 포맷에 HEIC이 없다', () {
      expect(
        ProfilePhotoProcessor.supportedFormats.contains(
          DetectedImageFormat.heic,
        ),
        isFalse,
      );
    });
  });
}
