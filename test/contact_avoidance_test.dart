import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/contact_avoidance_settings.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:dating_app/services/privacy/contact_phone_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3-4 — 전화번호 정규화·digest·모델/파서 계약 테스트.
void main() {
  group('1~8. 전화번호 정규화', () {
    test('1~4. 국내/국제 표기를 E.164로 정규화한다', () {
      const expected = '+821012345678';
      for (final raw in [
        '010-1234-5678',
        '010 1234 5678',
        '01012345678',
        '+82 10 1234 5678',
        '+821012345678',
        '82-10-1234-5678',
        '(010) 1234-5678',
      ]) {
        expect(normalizeContactPhoneNumber(raw), expected, reason: raw);
      }
      // 국번이 다른 번호도 동일 규칙
      expect(normalizeContactPhoneNumber('011-123-4567'), '+82111234567');
    });

    test('5~7. 짧은 번호·긴 번호·문자 포함 번호는 제외한다', () {
      for (final raw in [
        '1234',
        '114',
        '',
        '   ',
        '내선 123',
        '전화번호 없음',
        '010-1234-5678#101',
        '+8210123456789012345',
        '00000000000000000000',
        '+',
        '0',
      ]) {
        expect(normalizeContactPhoneNumber(raw), isNull, reason: raw);
      }
    });

    test('8. 표기가 달라도 같은 번호는 하나로 합쳐진다', () {
      final digests = contactPhoneDigests([
        '010-1234-5678',
        '010 1234 5678',
        '+821012345678',
        '01012345678',
        '010-9999-8888',
        '1234', // 제외됨
      ]);
      expect(digests.length, 2);
    });
  });

  group('9~10. digest', () {
    test('9. SHA-256 lowercase hex 64자리다', () {
      final digest = contactPhoneDigest('+821012345678');
      expect(digest.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(digest), isTrue);
      // 결정적이어야 서버 대조가 가능하다.
      expect(contactPhoneDigest('+821012345678'), digest);
      expect(contactPhoneDigest('+821012345679'), isNot(digest));
      expect(isValidContactDigest(digest), isTrue);
      expect(isValidContactDigest(digest.toUpperCase()), isFalse);
      expect(isValidContactDigest('abc'), isFalse);
    });

    test('10. 결과에 원문 번호나 이름이 남지 않는다', () {
      final digests = contactPhoneDigests(['010-1234-5678']);
      final joined = digests.join(' ');
      expect(joined.contains('010'), isFalse);
      expect(joined.contains('1234'), isFalse);
      expect(joined.contains('+82'), isFalse);
      expect(digests.every(isValidContactDigest), isTrue);
    });
  });

  group('10~12. 모델/파서', () {
    test('settings parser는 malformed 문서를 안전한 비활성으로 읽는다', () {
      final ok = ContactAvoidanceSettings.fromMap({
        'enabled': true,
        'contactCount': 120,
        'hiddenCount': 3,
        'syncedAt': Timestamp.fromDate(DateTime(2026, 7, 21, 12)),
        // unknown field는 무시한다
        'contactHashes': ['x'],
      });
      expect(ok.enabled, isTrue);
      expect(ok.contactCount, 120);
      expect(ok.hiddenCount, 3);
      expect(ok.syncedAt, DateTime(2026, 7, 21, 12));

      final broken = ContactAvoidanceSettings.fromMap({
        'enabled': 'yes',
        'contactCount': '120',
        'hiddenCount': null,
        'syncedAt': 'not-a-timestamp',
      });
      expect(broken.enabled, isFalse);
      expect(broken.contactCount, 0);
      expect(broken.hiddenCount, 0);
      expect(broken.syncedAt, isNull);

      expect(ContactAvoidanceSettings.fromMap(null).enabled, isFalse);
    });

    test('sync 결과 parser는 개수만 읽는다', () {
      final result = ContactAvoidanceSyncResult.fromMap({
        'enabled': true,
        'contactCount': 10,
        'hiddenCount': 2,
        // 서버가 실수로 넣더라도 모델에는 담기지 않는다
        'matchedUids': ['x'],
      });
      expect(result.enabled, isTrue);
      expect(result.contactCount, 10);
      expect(result.hiddenCount, 2);

      final empty = ContactAvoidanceSyncResult.fromMap(null);
      expect(empty.enabled, isFalse);
      expect(empty.contactCount, 0);
      expect(empty.hiddenCount, 0);
    });

    test('11~12. pair 문서에서 상대 uid만 뽑고 malformed는 건너뛴다', () {
      final uids = ContactAvoidanceService.avoidedUidsFromDocs('me', [
        {
          'participants': ['me', 'friendA'],
        },
        {
          'participants': ['friendB', 'me'],
        },
        // malformed: participants 누락/타입 오류/빈 값/자기 자신만
        {'participants': 'friendC'},
        {'participants': null},
        {},
        {
          'participants': ['me'],
        },
        {
          'participants': [42, '', 'friendD'],
        },
      ]);

      expect(uids, {'friendA', 'friendB', 'friendD'});
      expect(uids.contains('me'), isFalse);
    });

    test('6. 최대 동기화 개수는 2000이다', () {
      expect(ContactAvoidanceService.maxContactDigests, 2000);
    });
  });
}
