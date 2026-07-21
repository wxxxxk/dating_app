import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/photo_verification_request.dart';
import 'package:dating_app/services/verification/photo_verification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3-2 — 사진 인증 모델·경로/payload 계약 테스트.
///
/// 실제 Storage/Firestore write 경로는 Rules 테스트가 검증하고, 여기서는
/// 파싱 방어와 "공개 URL 미저장" 계약을 Firebase 없이 확인한다.
final _t = DateTime(2026, 7, 21, 12);

Map<String, dynamic> _doc({
  String status = 'pending',
  Object? reviewedAt,
  Object? rejectionReason,
}) {
  return {
    'uid': 'userA',
    'status': status,
    'storagePath': 'photoVerification/userA/1721_abc.jpg',
    'submittedAt': Timestamp.fromDate(_t),
    'updatedAt': Timestamp.fromDate(_t),
    'reviewedAt': reviewedAt,
    'rejectionReason': rejectionReason,
    'schemaVersion': 1,
  };
}

void main() {
  group('모델 파싱', () {
    test('1. pending 요청을 파싱한다', () {
      final parsed = PhotoVerificationRequest.fromMap('userA', _doc());
      expect(parsed, isNotNull);
      expect(parsed!.isPending, isTrue);
      expect(parsed.isApproved, isFalse);
      expect(parsed.isRejected, isFalse);
      expect(parsed.submittedAt, _t);
      expect(parsed.reviewedAt, isNull);
      expect(parsed.rejectionLabel, isNull);
    });

    test('2. approved 요청을 파싱한다', () {
      final parsed = PhotoVerificationRequest.fromMap(
        'userA',
        _doc(status: 'approved', reviewedAt: Timestamp.fromDate(_t)),
      );
      expect(parsed!.isApproved, isTrue);
      expect(parsed.reviewedAt, _t);
      expect(parsed.rejectionLabel, isNull);
    });

    test('3. rejected 요청은 사용자 문구로 사유를 표시한다', () {
      final parsed = PhotoVerificationRequest.fromMap(
        'userA',
        _doc(
          status: 'rejected',
          reviewedAt: Timestamp.fromDate(_t),
          rejectionReason: 'face_covered',
        ),
      );
      expect(parsed!.isRejected, isTrue);
      expect(parsed.rejectionReason, 'face_covered');
      expect(parsed.rejectionLabel, '마스크나 물건으로 얼굴이 가려져 있어요.');
    });

    test('4. malformed Timestamp는 crash 없이 null로 처리한다', () {
      final parsed = PhotoVerificationRequest.fromMap('userA', {
        'uid': 42,
        'status': 'pending',
        'storagePath': 99,
        'submittedAt': 'not-a-timestamp',
        'updatedAt': 12345,
        'reviewedAt': {'a': 1},
        'rejectionReason': 7,
        // unknown field는 무시한다
        'downloadUrl': 'https://example.test/x.jpg',
      });
      expect(parsed, isNotNull);
      expect(parsed!.submittedAt, isNull);
      expect(parsed.updatedAt, isNull);
      expect(parsed.reviewedAt, isNull);
      expect(parsed.rejectionReason, isNull);
      expect(parsed.storagePath, '');
    });

    test('5. 알 수 없는 status/문서는 null로 폴백한다', () {
      expect(
        PhotoVerificationRequest.fromMap('userA', _doc(status: 'exploded')),
        isNull,
      );
      expect(PhotoVerificationRequest.fromMap('userA', null), isNull);
      expect(PhotoVerificationRequest.fromMap('', _doc()), isNull);
    });

    test('6. 알 수 없는 반려 key는 안전한 기본 문구로 대체한다', () {
      final parsed = PhotoVerificationRequest.fromMap(
        'userA',
        _doc(status: 'rejected', rejectionReason: 'admin_free_text_leak'),
      );
      expect(parsed!.rejectionLabel, '사진을 다시 촬영해주세요.');
      expect(photoRejectionReasonLabel(null), '사진을 다시 촬영해주세요.');
      // 서버 allowlist와 동일한 key 집합을 쓴다.
      expect(photoRejectionReasonLabels.keys.toSet(), {
        'face_not_clear',
        'photo_mismatch',
        'face_covered',
        'image_quality',
        'other',
      });
    });
  });

  group('서비스 계약', () {
    test('4. Storage 경로는 photoVerification/{uid}/{uploadId}.{ext}다', () {
      expect(
        PhotoVerificationService.buildStoragePath(
          uid: 'userA',
          uploadId: 'up1',
          extension: 'jpg',
        ),
        'photoVerification/userA/up1.jpg',
      );
      // storage.rules의 정규식(단일 세그먼트 파일명)과 어긋나지 않아야 한다.
      final path = PhotoVerificationService.buildStoragePath(
        uid: 'userA',
        uploadId: PhotoVerificationService.generateUploadId(),
        extension: 'png',
      );
      expect(path.split('/').length, 3);
      expect(RegExp(r'^photoVerification/userA/[^/]+\.png$').hasMatch(path), isTrue);
    });

    test('uploadId는 호출마다 달라진다', () {
      final ids = List.generate(
        50,
        (_) => PhotoVerificationService.generateUploadId(),
      );
      expect(ids.toSet().length, 50);
    });

    test('확장자 추출은 대소문자를 정규화하고 기본값을 준다', () {
      expect(PhotoVerificationService.extensionOf('a/b/c.JPG'), 'jpg');
      expect(PhotoVerificationService.extensionOf('image.HEIC'), 'heic');
      expect(PhotoVerificationService.extensionOf('noext'), 'jpg');
      expect(
        PhotoVerificationService.allowedExtensions,
        {'jpg', 'jpeg', 'png', 'heic', 'heif'},
      );
    });

    test('5. 요청 문서에 공개 URL을 저장하지 않는다', () {
      final doc = PhotoVerificationService.buildRequestDoc(
        uid: 'userA',
        storagePath: 'photoVerification/userA/up1.jpg',
        timestamp: 'ts',
      );

      expect(doc, {
        'uid': 'userA',
        'status': 'pending',
        'storagePath': 'photoVerification/userA/up1.jpg',
        'submittedAt': 'ts',
        'updatedAt': 'ts',
        'reviewedAt': null,
        'rejectionReason': null,
        'schemaVersion': 1,
      });
      for (final forbidden in [
        'downloadUrl',
        'url',
        'photoUrl',
        'bytes',
        'imageData',
      ]) {
        expect(doc.containsKey(forbidden), isFalse, reason: '$forbidden 미저장');
      }
      expect(doc.values.join(' '), isNot(contains('https://')));
    });

    test('6~9. 제출 가능 여부: 없음/rejected만 허용', () {
      PhotoVerificationRequest req(PhotoVerificationStatus status) {
        return PhotoVerificationRequest(
          uid: 'userA',
          status: status,
          storagePath: 'photoVerification/userA/up1.jpg',
          submittedAt: _t,
          updatedAt: _t,
          reviewedAt: null,
          rejectionReason: null,
        );
      }

      expect(PhotoVerificationService.canSubmit(null), isTrue);
      expect(
        PhotoVerificationService.canSubmit(
          req(PhotoVerificationStatus.rejected),
        ),
        isTrue,
      );
      expect(
        PhotoVerificationService.canSubmit(
          req(PhotoVerificationStatus.pending),
        ),
        isFalse,
      );
      expect(
        PhotoVerificationService.canSubmit(
          req(PhotoVerificationStatus.approved),
        ),
        isFalse,
      );
    });

    test('2. 최대 파일 크기는 5MB다', () {
      expect(PhotoVerificationService.maxPhotoBytes, 5 * 1024 * 1024);
    });
  });
}
