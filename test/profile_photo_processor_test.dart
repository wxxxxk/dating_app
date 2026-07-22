import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/services/storage/profile_photo_processor.dart';

// 1-D 회귀 테스트.
//
// 수정 전 상태:
// - 온보딩 대표: imageQuality 85, maxWidth 1080
// - 온보딩 서브: imageQuality 80, maxWidth 1080
// - 프로필 편집: imageQuality 85, 해상도 제한 없음
//
// maxWidth만 걸면 가로 사진의 짧은 변이 무너진다(4000x3000 → 1080x810).
// 카드가 1080px 폭으로 그리는 순간 확대되어 흐려졌다.

String _read(String relativePath) => File(relativePath).readAsStringSync();

void main() {
  group('처리 기준 계약', () {
    test('1/2. 긴 변 제한이 가로·세로 양쪽에 적용된다', () {
      // maxWidth/maxHeight를 같은 값으로 주면 image_picker가 비율을 유지한 채
      // 정사각형 안에 맞춘다 → 방향과 무관하게 긴 변이 제한된다.
      final source = _read('lib/services/storage/profile_photo_processor.dart');
      expect(source.contains('maxWidth: maxLongEdge.toDouble()'), isTrue);
      expect(source.contains('maxHeight: maxLongEdge.toDouble()'), isTrue);
    });

    test('긴 변 기준이 권장 범위(1600~2048) 안이다', () {
      expect(ProfilePhotoProcessor.maxLongEdge, greaterThanOrEqualTo(1600));
      expect(ProfilePhotoProcessor.maxLongEdge, lessThanOrEqualTo(2048));
    });

    test('4:3 가로 사진도 짧은 변 1080을 넘긴다', () {
      // 긴 변이 maxLongEdge일 때 4:3이면 짧은 변은 그 3/4이다.
      final shortEdge = (ProfilePhotoProcessor.maxLongEdge * 3) ~/ 4;
      expect(shortEdge, greaterThanOrEqualTo(1080));
    });

    test('16:9 가로 사진의 짧은 변도 1080 이상이다', () {
      final shortEdge = (ProfilePhotoProcessor.maxLongEdge * 9) ~/ 16;
      expect(shortEdge, greaterThanOrEqualTo(1080));
    });

    test('6/7. JPEG 품질이 권장 범위(88~92) 안이다', () {
      expect(ProfilePhotoProcessor.jpegQuality, greaterThanOrEqualTo(88));
      expect(ProfilePhotoProcessor.jpegQuality, lessThanOrEqualTo(92));
      // 과도한 저용량 압축(80 이하)으로 되돌아가지 않게 고정한다.
      expect(ProfilePhotoProcessor.jpegQuality, greaterThan(85));
    });

    test('3. upscale하지 않는다 (제한은 상한일 뿐이다)', () {
      final source = _read('lib/services/storage/profile_photo_processor.dart');
      // 최소 크기를 강제하거나 확대하는 코드가 없다.
      expect(source.contains('minWidth'), isFalse);
      expect(source.contains('upscale'), isFalse);
    });

    test('9. 출력 contentType과 확장자가 일치한다', () {
      final file = File('pubspec.yaml'); // 존재하는 아무 파일
      final processed = ProfilePhotoProcessor.describe(file);
      expect(processed.contentType, 'image/jpeg');
      expect(processed.extension, 'jpg');
    });

    test('없는 파일도 예외 없이 describe된다', () {
      final processed = ProfilePhotoProcessor.describe(
        File('does-not-exist-${DateTime.now().microsecondsSinceEpoch}.jpg'),
      );
      expect(processed.byteLength, 0);
    });

    test('processingVersion이 기록된다', () {
      final processed = ProfilePhotoProcessor.describe(File('pubspec.yaml'));
      expect(
        processed.processingVersion,
        ProfilePhotoProcessor.processingVersion,
      );
      expect(ProfilePhotoProcessor.processingVersion, greaterThanOrEqualTo(2));
    });
  });

  group('10/11/12. 단일 처리 파이프라인', () {
    final processorSource = _read(
      'lib/services/storage/profile_photo_processor.dart',
    );
    final onboardingSource = _read(
      'lib/features/onboarding/photo_upload_step.dart',
    );
    final editSource = _read('lib/features/profile/profile_edit_screen.dart');
    final storageSource = _read('lib/services/storage/storage_service.dart');

    test('10. 압축은 pickImage 한 번뿐이다 (2차 압축 경로 없음)', () {
      // 저장소 전체에 별도 compressor가 없어야 한다.
      for (final source in [
        processorSource,
        onboardingSource,
        editSource,
        storageSource,
      ]) {
        expect(source.contains('FlutterImageCompress'), isFalse);
        expect(source.contains('compressWithFile'), isFalse);
        expect(source.contains('encodeJpg'), isFalse);
        expect(source.contains('copyResize'), isFalse);
      }
      // processor 안에서 pickImage는 정확히 한 번 호출된다.
      expect('pickImage('.allMatches(processorSource).length, 1);
    });

    test('11. 온보딩과 프로필 편집이 같은 processor를 쓴다', () {
      expect(onboardingSource.contains('ProfilePhotoProcessor()'), isTrue);
      expect(editSource.contains('ProfilePhotoProcessor()'), isTrue);
      // 화면이 직접 pickImage 옵션을 정하지 않는다.
      expect(onboardingSource.contains('imageQuality:'), isFalse);
      expect(editSource.contains('imageQuality:'), isFalse);
      expect(onboardingSource.contains('maxWidth: 1080'), isFalse);
    });

    test('StorageService는 다시 resize·compress하지 않는다', () {
      expect(storageSource.contains('imageQuality'), isFalse);
      // 주석이 아니라 실제 호출이 없어야 한다.
      expect(storageSource.contains('copyResize('), isFalse);
      expect(storageSource.contains('ResizeImage('), isFalse);
      expect(storageSource.contains('pickImage('), isFalse);
      // 처리된 contentType을 그대로 받는다.
      expect(storageSource.contains('String contentType'), isTrue);
    });

    test('12. 기존 remote URL은 processor를 거치지 않는다', () {
      // processor는 로컬 File만 다룬다. http URL을 내려받는 경로가 없다.
      expect(processorSource.contains('http://'), isFalse);
      expect(processorSource.contains('https://'), isFalse);
      expect(processorSource.contains('HttpClient'), isFalse);
      expect(processorSource.contains('NetworkAssetBundle'), isFalse);
    });
  });

  group('26/27. Storage object path와 캐시 무효화', () {
    final storageSource = _read('lib/services/storage/storage_service.dart');
    final editSource = _read('lib/features/profile/profile_edit_screen.dart');

    test('26/27. 업로드마다 timestamp가 들어간 새 경로를 만든다', () {
      expect(
        storageSource.contains(
          "'main_\${DateTime.now().millisecondsSinceEpoch}.jpg'",
        ),
        isTrue,
      );
      expect(
        storageSource.contains(
          'sub_\${i}_\${DateTime.now().millisecondsSinceEpoch}',
        ),
        isTrue,
      );
      // 프로필 편집 교체도 새 경로를 만든다(고정 경로 덮어쓰기 없음).
      expect(
        editSource.contains('DateTime.now().millisecondsSinceEpoch'),
        isTrue,
      );
    });

    test('사용자 제공 파일명을 경로에 쓰지 않는다', () {
      expect(storageSource.contains('picked.name'), isFalse);
      expect(storageSource.contains('basename'), isFalse);
      expect(editSource.contains('picked.name'), isFalse);
    });

    test('immutable object에 맞는 cacheControl을 붙인다', () {
      expect(storageSource.contains('immutable'), isTrue);
      expect(storageSource.contains('cacheControl'), isTrue);
      expect(storageSource.contains('contentType: contentType'), isTrue);
    });
  });

  group('13. 진단 로그 비식별화', () {
    final processorSource = _read(
      'lib/services/storage/profile_photo_processor.dart',
    );

    test('로그에 UID·경로·파일명·URL이 없다', () {
      final processed = ProfilePhotoProcessor.describe(File('pubspec.yaml'));
      final summary = processed.diagnosticSummary;
      expect(summary.contains('pubspec'), isFalse);
      // contentType(image/jpeg) 외에 경로 구분자가 없어야 한다.
      expect(summary.replaceAll('image/jpeg', '').contains('/'), isFalse);
      expect(summary.contains('http'), isFalse);
      // 허용된 수치만 담는다.
      expect(summary.contains('outputBytes='), isTrue);
      expect(summary.contains('compressionPassCount=1'), isTrue);
      expect(summary.contains('processingVersion='), isTrue);
    });

    test('로그는 debug 모드에서만 남는다', () {
      expect(processorSource.contains('if (kDebugMode) debugPrint'), isTrue);
    });
  });

  group('14/15/28. 재업로드 방지 계약', () {
    final editSource = _read('lib/features/profile/profile_edit_screen.dart');

    test('14/15/28. 대표 사진 변경·순서 변경은 업로드를 호출하지 않는다', () {
      // 업로드는 사진을 새로 고른 경로에서만 일어난다.
      final uploadIdx = editSource.indexOf('uploadProfilePhoto(');
      expect(uploadIdx, greaterThan(0));
      final pickIdx = editSource.indexOf('_pickAndUploadPhoto');
      expect(pickIdx, greaterThan(0));
      // 대표 설정 경로에는 업로드 호출이 없다.
      final setMainIdx = editSource.indexOf("case 'main':");
      if (setMainIdx > 0) {
        final slice = editSource.substring(setMainIdx, setMainIdx + 400);
        expect(slice.contains('uploadProfilePhoto('), isFalse);
      }
    });
  });
}
