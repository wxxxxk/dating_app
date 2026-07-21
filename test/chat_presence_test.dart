import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/chat_presence.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2-2 — 채팅방 presence 모델/문구 판정 테스트.
///
/// 화면에서 보이는 판정(online/typing/마지막 접속 문구)은 모두 순수 함수라
/// Firebase 없이 검증한다.

final _now = DateTime(2026, 7, 21, 15, 0);

ChatPresence _presence({
  bool isOnline = true,
  bool isTyping = false,
  Duration? ago,
}) {
  return ChatPresence(
    uid: 'userB',
    isOnline: isOnline,
    isTyping: isTyping,
    lastActiveAt: ago == null ? null : _now.subtract(ago),
  );
}

void main() {
  group('1~2. fromMap 파싱', () {
    test('1. 정상 문서를 파싱한다', () {
      final parsed = ChatPresence.fromMap('userB', {
        'uid': 'userB',
        'isOnline': true,
        'isTyping': true,
        'lastActiveAt': Timestamp.fromDate(_now),
        'updatedAt': Timestamp.fromDate(_now),
      });

      expect(parsed, isNotNull);
      expect(parsed!.uid, 'userB');
      expect(parsed.isOnline, isTrue);
      expect(parsed.isTyping, isTrue);
      expect(parsed.lastActiveAt, _now);
    });

    test('2. malformed 값은 crash 없이 안전한 offline 값으로 보정된다', () {
      final parsed = ChatPresence.fromMap('userB', {
        'uid': 42,
        'isOnline': 'yes',
        'isTyping': 1,
        // Timestamp가 아닌 값 → lastActiveAt null
        'lastActiveAt': 'not-a-timestamp',
        // unknown field는 무시한다
        'someUnknownField': {'a': 1},
      });

      expect(parsed, isNotNull);
      expect(parsed!.isOnline, isFalse);
      expect(parsed.isTyping, isFalse);
      expect(parsed.lastActiveAt, isNull);
      expect(parsed.isFresh(now: _now), isFalse);
      expect(ChatPresence.fromMap('userB', null), isNull);
    });
  });

  group('3~5. fresh / stale 판정', () {
    test('3. 최근 heartbeat면 online으로 판정한다', () {
      final p = _presence(ago: const Duration(seconds: 20));
      expect(p.isFresh(now: _now), isTrue);
      expect(p.isActuallyOnline(now: _now), isTrue);
    });

    test('4. 90초를 넘으면 isOnline true여도 offline으로 판정한다', () {
      final p = _presence(ago: const Duration(seconds: 91));
      expect(p.isFresh(now: _now), isFalse);
      expect(p.isActuallyOnline(now: _now), isFalse);
    });

    test('5. typing은 online + fresh일 때만 true다', () {
      expect(
        _presence(
          isTyping: true,
          ago: const Duration(seconds: 10),
        ).isActuallyTyping(now: _now),
        isTrue,
      );
      // stale
      expect(
        _presence(
          isTyping: true,
          ago: const Duration(seconds: 120),
        ).isActuallyTyping(now: _now),
        isFalse,
      );
      // isOnline false
      expect(
        _presence(
          isOnline: false,
          isTyping: true,
          ago: const Duration(seconds: 10),
        ).isActuallyTyping(now: _now),
        isFalse,
      );
    });

    test('클라이언트 시각 오차로 lastActiveAt이 미래여도 fresh로 본다', () {
      final p = ChatPresence(
        uid: 'userB',
        isOnline: true,
        isTyping: false,
        lastActiveAt: _now.add(const Duration(seconds: 5)),
      );
      expect(p.isActuallyOnline(now: _now), isTrue);
    });
  });

  group('6~10. 상태 문구', () {
    String label(ChatPresence? p) => chatPresenceLabel(presence: p, now: _now);

    test('6. online이면 "온라인"', () {
      expect(label(_presence(ago: const Duration(seconds: 5))), '온라인');
    });

    test('7. typing이면 "입력 중..."', () {
      expect(
        label(_presence(isTyping: true, ago: const Duration(seconds: 5))),
        '입력 중...',
      );
    });

    test('8. offline이고 1분 이내면 "방금 전 접속"', () {
      expect(
        label(_presence(isOnline: false, ago: const Duration(seconds: 30))),
        '방금 전 접속',
      );
    });

    test('9. 1~59분이면 "N분 전 접속"', () {
      expect(
        label(_presence(isOnline: false, ago: const Duration(minutes: 7))),
        '7분 전 접속',
      );
      expect(
        label(_presence(isOnline: false, ago: const Duration(minutes: 59))),
        '59분 전 접속',
      );
    });

    test('10. stale online은 offline 문구로 내려간다', () {
      // isOnline true지만 heartbeat 만료(2분) → "2분 전 접속"
      expect(label(_presence(ago: const Duration(minutes: 2))), '2분 전 접속');
      // 같은 날 1시간 이상 전
      expect(
        label(_presence(isOnline: false, ago: const Duration(hours: 3))),
        '오늘 접속',
      );
      // 어제 이전
      expect(
        label(_presence(isOnline: false, ago: const Duration(days: 2))),
        '최근 접속',
      );
      // presence 문서 없음 / lastActiveAt 없음
      expect(label(null), '최근 접속');
      expect(label(_presence(isOnline: false)), '최근 접속');
    });
  });
}
