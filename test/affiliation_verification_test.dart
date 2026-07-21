import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/affiliation_verification_request.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/verification/affiliation_verification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3-3 — 소속 인증 모델·경로/payload 계약 테스트.
final _t = DateTime(2026, 7, 21, 12);

Map<String, dynamic> _doc({
  String type = 'work',
  String status = 'pending',
  String proofType = 'employee_id',
  Object? reviewedAt,
  Object? rejectionReason,
}) {
  return {
    'uid': 'userA',
    'type': type,
    'institutionName': 'CVR Lab',
    'affiliationDetail': '개발팀',
    'proofType': proofType,
    'status': status,
    'storagePath': 'affiliationVerification/userA/$type/up1.jpg',
    'submittedAt': Timestamp.fromDate(_t),
    'updatedAt': Timestamp.fromDate(_t),
    'reviewedAt': reviewedAt,
    'rejectionReason': rejectionReason,
    'schemaVersion': 1,
  };
}

void main() {
  group('모델 파싱', () {
    test('1~2. work/school pending 요청을 파싱한다', () {
      final work = AffiliationVerificationRequest.fromMap('work', _doc());
      expect(work, isNotNull);
      expect(work!.type, AffiliationVerificationType.work);
      expect(work.isPending, isTrue);
      expect(work.institutionName, 'CVR Lab');
      expect(work.affiliationDetail, '개발팀');
      expect(work.proofType, 'employee_id');

      final school = AffiliationVerificationRequest.fromMap(
        'school',
        _doc(type: 'school', proofType: 'student_id'),
      );
      expect(school!.type, AffiliationVerificationType.school);
      expect(school.isPending, isTrue);
    });

    test('3~4. approved/rejected 요청을 파싱한다', () {
      final approved = AffiliationVerificationRequest.fromMap(
        'work',
        _doc(status: 'approved', reviewedAt: Timestamp.fromDate(_t)),
      );
      expect(approved!.isApproved, isTrue);
      expect(approved.reviewedAt, _t);
      expect(approved.rejectionLabel, isNull);

      final rejected = AffiliationVerificationRequest.fromMap(
        'school',
        _doc(
          type: 'school',
          proofType: 'student_id',
          status: 'rejected',
          reviewedAt: Timestamp.fromDate(_t),
          rejectionReason: 'institution_not_visible',
        ),
      );
      expect(rejected!.isRejected, isTrue);
      expect(rejected.rejectionLabel, '기관명이 충분히 보이지 않아요.');
    });

    test('5. malformed Timestamp는 crash 없이 null로 처리한다', () {
      final parsed = AffiliationVerificationRequest.fromMap('work', {
        'uid': 'userA',
        'type': 'work',
        'institutionName': 42,
        'affiliationDetail': null,
        'proofType': 7,
        'status': 'pending',
        'storagePath': 99,
        'submittedAt': 'not-a-timestamp',
        'updatedAt': 12345,
        'reviewedAt': {'a': 1},
        'rejectionReason': 7,
        // unknown field는 무시한다
        'downloadUrl': 'https://example.test/a.jpg',
      });
      expect(parsed, isNotNull);
      expect(parsed!.institutionName, '');
      expect(parsed.affiliationDetail, '');
      expect(parsed.proofType, '');
      expect(parsed.storagePath, '');
      expect(parsed.submittedAt, isNull);
      expect(parsed.reviewedAt, isNull);
      expect(parsed.rejectionReason, isNull);
    });

    test('6. 알 수 없는/불일치 type은 파싱에 실패한다', () {
      expect(AffiliationVerificationRequest.fromMap('company', _doc()), isNull);
      // 문서 id와 body type이 어긋나면 신뢰하지 않는다.
      expect(
        AffiliationVerificationRequest.fromMap('school', _doc(type: 'work')),
        isNull,
      );
      expect(AffiliationVerificationRequest.fromMap('work', null), isNull);
      // uid 누락도 거부
      final noUid = _doc()..remove('uid');
      expect(AffiliationVerificationRequest.fromMap('work', noUid), isNull);
    });

    test('7. 알 수 없는 status는 null로 폴백한다', () {
      expect(
        AffiliationVerificationRequest.fromMap('work', _doc(status: 'exploded')),
        isNull,
      );
    });

    test('8. 반려 label과 증빙/종류 라벨', () {
      expect(
        affiliationRejectionReasonLabel('sensitive_info_visible'),
        '민감한 번호나 QR 코드를 가린 뒤 다시 제출해주세요.',
      );
      // 알 수 없는 key(관리자 자유 입력 등)는 other 문구로 처리한다.
      expect(affiliationRejectionReasonLabel('admin_free_text'), '인증 자료를 다시 준비해주세요.');
      expect(affiliationRejectionReasonLabel(null), '인증 자료를 다시 준비해주세요.');
      expect(affiliationRejectionReasonLabels.keys.toSet(), {
        'document_not_clear',
        'institution_not_visible',
        'affiliation_not_confirmed',
        'sensitive_info_visible',
        'expired_document',
        'other',
      });

      expect(
        affiliationVerificationTypeLabel(AffiliationVerificationType.work),
        '직장 인증',
      );
      expect(
        affiliationVerificationTypeLabel(AffiliationVerificationType.school),
        '학교 인증',
      );
      expect(affiliationProofTypeLabel('employee_id'), '사원증');
      expect(affiliationProofTypeLabel('enrollment_certificate'), '재학 증명 자료');
      expect(affiliationProofTypeLabel('unknown'), '증빙 자료');
    });

    test('type별 허용 증빙 조합', () {
      expect(
        isAffiliationProofTypeAllowed(
          AffiliationVerificationType.work,
          'employee_id',
        ),
        isTrue,
      );
      expect(
        isAffiliationProofTypeAllowed(
          AffiliationVerificationType.work,
          'student_id',
        ),
        isFalse,
      );
      expect(
        isAffiliationProofTypeAllowed(
          AffiliationVerificationType.school,
          'employee_id',
        ),
        isFalse,
      );
      expect(
        isAffiliationProofTypeAllowed(
          AffiliationVerificationType.school,
          'enrollment_certificate',
        ),
        isTrue,
      );
    });
  });

  group('9~10. verification map 확장', () {
    test('9. 기존 3-key 문서는 그대로 동작한다', () {
      final legacy = VerificationStatus.fromMap({
        'email': true,
        'phone': true,
        'photo': true,
      });
      expect(legacy.email, isTrue);
      expect(legacy.phone, isTrue);
      expect(legacy.photo, isTrue);
      // 10. work/school 누락은 false
      expect(legacy.work, isFalse);
      expect(legacy.school, isFalse);
      expect(legacy.hasAny, isTrue);
    });

    test('work/school 파싱·직렬화·copyWith', () {
      final parsed = VerificationStatus.fromMap({
        'email': false,
        'phone': false,
        'photo': false,
        'work': true,
        'school': 'yes',
      });
      expect(parsed.work, isTrue);
      // bool이 아닌 값은 false로 본다.
      expect(parsed.school, isFalse);
      expect(parsed.hasAny, isTrue);

      expect(const VerificationStatus().toFirestore(), {
        'email': false,
        'phone': false,
        'photo': false,
        'work': false,
        'school': false,
      });
      expect(const VerificationStatus().hasAny, isFalse);

      final updated = const VerificationStatus().copyWith(school: true);
      expect(updated.school, isTrue);
      expect(updated.work, isFalse);
      expect(updated.email, isFalse);
    });
  });

  group('서비스 계약', () {
    test('1~2, 10. work/school Storage 경로', () {
      expect(
        AffiliationVerificationService.buildStoragePath(
          uid: 'userA',
          type: AffiliationVerificationType.work,
          uploadId: 'up1',
          extension: 'jpg',
        ),
        'affiliationVerification/userA/work/up1.jpg',
      );
      expect(
        AffiliationVerificationService.buildStoragePath(
          uid: 'userA',
          type: AffiliationVerificationType.school,
          uploadId: 'up1',
          extension: 'png',
        ),
        'affiliationVerification/userA/school/up1.png',
      );
      // storage.rules 정규식(단일 세그먼트 파일명)과 어긋나지 않아야 한다.
      final path = AffiliationVerificationService.buildStoragePath(
        uid: 'userA',
        type: AffiliationVerificationType.work,
        uploadId: 'up1',
        extension: 'heic',
      );
      expect(path.split('/').length, 4);
      // 파일명에 기관명 등 개인정보가 들어가지 않는다.
      expect(path.contains('CVR'), isFalse);
    });

    test('7~9. 입력 검증: 기관명/상세/조합', () {
      ({String institutionName, String affiliationDetail}) run({
        AffiliationVerificationType type = AffiliationVerificationType.work,
        String name = 'CVR Lab',
        String detail = '개발팀',
        String proof = 'employee_id',
      }) {
        return AffiliationVerificationService.normalizeInput(
          type: type,
          institutionName: name,
          affiliationDetail: detail,
          proofType: proof,
        );
      }

      // 8. 기관명 2~80자
      expect(() => run(name: 'A'), throwsA(isA<AffiliationVerificationError>()));
      expect(() => run(name: '  '), throwsA(isA<AffiliationVerificationError>()));
      expect(
        () => run(name: 'ㄱ' * 81),
        throwsA(isA<AffiliationVerificationError>()),
      );
      expect(run(name: '  CVR Lab  ').institutionName, 'CVR Lab');

      // 9. 상세 소속 0~80자(비워도 됨)
      expect(run(detail: '').affiliationDetail, '');
      expect(run(detail: '  개발팀  ').affiliationDetail, '개발팀');
      expect(
        () => run(detail: 'ㄱ' * 81),
        throwsA(isA<AffiliationVerificationError>()),
      );

      // 7. type/proofType 불일치
      expect(
        () => run(proof: 'student_id'),
        throwsA(isA<AffiliationVerificationError>()),
      );
      expect(
        () => run(
          type: AffiliationVerificationType.school,
          proof: 'employee_id',
        ),
        throwsA(isA<AffiliationVerificationError>()),
      );
      expect(
        run(
          type: AffiliationVerificationType.school,
          proof: 'student_id',
        ).institutionName,
        'CVR Lab',
      );
    });

    test('11. 요청 문서에 공개 URL을 저장하지 않는다', () {
      final doc = AffiliationVerificationService.buildRequestDoc(
        uid: 'userA',
        type: AffiliationVerificationType.school,
        institutionName: '서울과학기술대학교',
        affiliationDetail: '전자IT미디어공학과',
        proofType: 'student_id',
        storagePath: 'affiliationVerification/userA/school/up1.jpg',
        timestamp: 'ts',
      );

      expect(doc.keys.toSet(), {
        'uid',
        'type',
        'institutionName',
        'affiliationDetail',
        'proofType',
        'status',
        'storagePath',
        'submittedAt',
        'updatedAt',
        'reviewedAt',
        'rejectionReason',
        'schemaVersion',
      });
      expect(doc['status'], 'pending');
      expect(doc['reviewedAt'], isNull);
      expect(doc['rejectionReason'], isNull);
      expect(doc['schemaVersion'], 1);
      for (final forbidden in ['downloadUrl', 'url', 'photoUrl', 'bytes']) {
        expect(doc.containsKey(forbidden), isFalse, reason: '$forbidden 미저장');
      }
      expect(doc.values.join(' '), isNot(contains('https://')));
    });

    test('12~15. 제출 가능 여부: 없음/rejected만 허용', () {
      AffiliationVerificationRequest req(AffiliationVerificationStatus status) {
        return AffiliationVerificationRequest(
          uid: 'userA',
          type: AffiliationVerificationType.work,
          institutionName: 'CVR Lab',
          affiliationDetail: '',
          proofType: 'employee_id',
          status: status,
          storagePath: 'affiliationVerification/userA/work/up1.jpg',
          submittedAt: _t,
          updatedAt: _t,
          reviewedAt: null,
          rejectionReason: null,
        );
      }

      expect(AffiliationVerificationService.canSubmit(null), isTrue);
      expect(
        AffiliationVerificationService.canSubmit(
          req(AffiliationVerificationStatus.rejected),
        ),
        isTrue,
      );
      expect(
        AffiliationVerificationService.canSubmit(
          req(AffiliationVerificationStatus.pending),
        ),
        isFalse,
      );
      expect(
        AffiliationVerificationService.canSubmit(
          req(AffiliationVerificationStatus.approved),
        ),
        isFalse,
      );
    });

    test('5. 최대 파일 크기와 허용 확장자는 사진 인증과 동일하다', () {
      expect(AffiliationVerificationService.maxProofBytes, 5 * 1024 * 1024);
      expect(AffiliationVerificationService.allowedExtensions, {
        'jpg',
        'jpeg',
        'png',
        'heic',
        'heif',
      });
    });
  });
}
