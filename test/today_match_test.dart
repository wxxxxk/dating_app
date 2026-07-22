import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/features/home/today_match.dart';
import 'package:dating_app/models/public_profile.dart';

// 1-B 회귀 테스트.
//
// 수정 전 동작:
// - 후보를 거리순 목록의 `.first`로 골라 항상 같은 사람이 나왔다
// - 점수가 `match ? 88 : 82` (+4) 상수였다
// - 날짜 개념이 없어 "오늘의" 추천이 아니었다

PublicProfile profile(
  String uid, {
  List<String> interests = const [],
  String? relationshipGoal,
}) => PublicProfile(
  uid: uid,
  displayName: 'user-$uid',
  interests: interests,
  relationshipGoal: relationshipGoal,
);

TodayMatchCandidate discovery(
  String uid, {
  List<String> interests = const [],
}) => TodayMatchCandidate(
  profile: profile(uid, interests: interests),
  source: TodayMatchSource.discovery,
);

TodayMatchCandidate matched(String uid, {String? reason}) =>
    TodayMatchCandidate(
      profile: profile(uid),
      source: TodayMatchSource.match,
      candidateReason: reason,
    );

void main() {
  group('KST date key', () {
    test('UTC 자정 직후는 이미 KST 다음 날이다', () {
      // 2026-07-22 00:30 UTC == 2026-07-22 09:30 KST
      expect(kstDateKey(DateTime.utc(2026, 7, 22, 0, 30)), '2026-07-22');
    });

    test('UTC 15:00은 KST로 다음 날이다 (경계)', () {
      // 2026-07-21 15:00 UTC == 2026-07-22 00:00 KST
      expect(kstDateKey(DateTime.utc(2026, 7, 21, 15, 0)), '2026-07-22');
      expect(kstDateKey(DateTime.utc(2026, 7, 21, 14, 59)), '2026-07-21');
    });

    test('로컬 시간대와 무관하게 같은 순간이면 같은 key다', () {
      final instant = DateTime.utc(2026, 3, 1, 20, 0);
      expect(kstDateKey(instant), kstDateKey(instant.toLocal()));
    });
  });

  group('후보 선정', () {
    test('7. 후보가 0명이면 null이다', () {
      expect(
        selectTodayCandidate(
          viewerUid: 'me',
          dateKey: '2026-07-22',
          candidates: const [],
        ),
        isNull,
      );
    });

    test('8. 후보가 1명이면 그 후보다', () {
      final selected = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: [discovery('a')],
      );
      expect(selected!.id, 'a');
    });

    test('9. 입력 순서를 바꿔도 같은 후보가 선택된다 (.first 의존 없음)', () {
      final forward = [discovery('a'), discovery('b'), discovery('c')];
      final reversed = forward.reversed.toList();
      final first = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: forward,
      );
      final second = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: reversed,
      );
      expect(first!.id, second!.id);
    });

    test('10. 같은 사용자 + 같은 날짜면 항상 같은 후보다', () {
      final candidates = [discovery('a'), discovery('b'), discovery('c')];
      final picks = List.generate(
        20,
        (_) => selectTodayCandidate(
          viewerUid: 'me',
          dateKey: '2026-07-22',
          candidates: candidates,
        )!.id,
      );
      expect(picks.toSet().length, 1);
    });

    test('11. 날짜가 바뀌면 재선정된다 (며칠 사이 후보가 달라진다)', () {
      final candidates = List.generate(6, (i) => discovery('u$i'));
      final picks = <String>{};
      for (var day = 1; day <= 20; day++) {
        picks.add(
          selectTodayCandidate(
            viewerUid: 'me',
            dateKey: '2026-07-${day.toString().padLeft(2, '0')}',
            candidates: candidates,
          )!.id,
        );
      }
      expect(picks.length, greaterThan(1), reason: '날짜가 달라도 항상 같으면 고정 버그다');
    });

    test('12. 사용자가 다르면 같은 날짜라도 선택이 공유되지 않는다', () {
      final candidates = List.generate(6, (i) => discovery('u$i'));
      final picks = <String>{};
      for (var i = 0; i < 20; i++) {
        picks.add(
          selectTodayCandidate(
            viewerUid: 'viewer$i',
            dateKey: '2026-07-22',
            candidates: candidates,
          )!.id,
        );
      }
      expect(picks.length, greaterThan(1));
    });

    test('이미 이어진 인연(match)이 새 후보(discovery)보다 우선한다', () {
      final selected = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: [discovery('a'), matched('b'), discovery('c')],
      );
      expect(selected!.source, TodayMatchSource.match);
      expect(selected.id, 'b');
    });

    test('같은 후보가 양쪽에 들어오면 match 쪽만 남는다', () {
      final selected = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: [
          discovery('a'),
          matched('a', reason: '이 후보 문구'),
        ],
      );
      expect(selected!.source, TodayMatchSource.match);
      expect(selected.candidateReason, '이 후보 문구');
    });

    test('후보가 여러 명이면 선택이 한쪽으로 쏠리지 않는다', () {
      final candidates = List.generate(4, (i) => discovery('u$i'));
      final counts = <String, int>{};
      for (var i = 0; i < 200; i++) {
        final id = selectTodayCandidate(
          viewerUid: 'viewer$i',
          dateKey: '2026-07-22',
          candidates: candidates,
        )!.id;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      expect(counts.keys.length, 4, reason: '네 후보 모두 한 번은 선택돼야 한다');
    });
  });

  group('결과 원자성과 문구 결합', () {
    test('21/22. 후보가 바뀌면 문구와 지문이 함께 바뀐다', () {
      final a = buildTodayMatchResult(
        candidate: discovery('a', interests: const ['등산']),
        dateKey: '2026-07-22',
      );
      final b = buildTodayMatchResult(
        candidate: discovery('b', interests: const ['영화']),
        dateKey: '2026-07-22',
      );
      expect(a.candidateId, 'a');
      expect(a.profile.uid, 'a');
      expect(b.candidateId, 'b');
      expect(a.reason, isNot(b.reason));
      expect(a.reasonFingerprint, isNot(b.reasonFingerprint));
    });

    test('23. AI 문구가 없으면 그 후보 자신의 정보로만 문구를 만든다', () {
      final result = buildTodayMatchResult(
        candidate: discovery('a', interests: const ['등산', '커피']),
        dateKey: '2026-07-22',
      );
      // 후보 자신의 관심사가 들어간다. 다른 후보/데모 문구가 아니다.
      // 관심사는 정렬해 첫 항목을 쓰므로 순서가 흔들려도 문구가 안정적이다.
      expect(result.reason, contains('등산'));

      final shuffled = buildTodayMatchResult(
        candidate: discovery('a', interests: const ['커피', '등산']),
        dateKey: '2026-07-22',
      );
      expect(shuffled.reason, result.reason);
    });

    test('AI 문구가 있으면 그 후보의 문구를 그대로 쓴다', () {
      final result = buildTodayMatchResult(
        candidate: matched('a', reason: '두 사람은 대화 속도가 비슷해요.'),
        dateKey: '2026-07-22',
      );
      expect(result.reason, '두 사람은 대화 속도가 비슷해요.');
    });

    test('24. 결과에 점수 필드가 없다 (근거 없는 % 표시 불가)', () {
      final result = buildTodayMatchResult(
        candidate: discovery('a'),
        dateKey: '2026-07-22',
      );
      // 점수 소스가 앱에 없으므로 숫자 자체를 두지 않는다.
      expect(result.toString(), isNot(contains('score')));
      final fields = result.runtimeType.toString();
      expect(fields, 'TodayMatchResult');
      // 문구에 상수 퍼센트가 들어가지 않는다.
      expect(RegExp(r'\d+\s*%').hasMatch(result.reason), isFalse);
    });

    test('25. 문구에 내부 코드·UID·생년월일이 들어가지 않는다', () {
      final result = buildTodayMatchResult(
        candidate: discovery('uid-secret-123', interests: const ['등산']),
        dateKey: '2026-07-22',
      );
      expect(result.reason.contains('uid-secret-123'), isFalse);
      expect(RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(result.reason), isFalse);
      expect(result.reason.contains('discovery'), isFalse);
      expect(result.reason.contains('TodayMatchSource'), isFalse);
    });
  });

  group('캐시 재사용 조건', () {
    TodayMatchResult resultFor(String uid) => buildTodayMatchResult(
      candidate: discovery(uid, interests: const ['등산']),
      dateKey: '2026-07-22',
    );

    test('같은 날짜 + 후보가 아직 자격 있으면 재사용한다', () {
      final result = resultFor('a');
      expect(
        result.isReusableFor(
          dateKey: '2026-07-22',
          eligibleCandidateIds: {'a', 'b'},
        ),
        isTrue,
      );
    });

    test('20. 날짜가 지나면 재사용하지 않는다', () {
      final result = resultFor('a');
      expect(
        result.isReusableFor(
          dateKey: '2026-07-23',
          eligibleCandidateIds: {'a'},
        ),
        isFalse,
      );
    });

    test('18. 후보가 자격을 잃으면(차단·비활성) 재사용하지 않는다', () {
      final result = resultFor('a');
      expect(
        result.isReusableFor(
          dateKey: '2026-07-22',
          eligibleCandidateIds: {'b', 'c'},
        ),
        isFalse,
      );
    });

    test('후보가 하나도 없으면 재사용하지 않는다', () {
      final result = resultFor('a');
      expect(
        result.isReusableFor(
          dateKey: '2026-07-22',
          eligibleCandidateIds: const {},
        ),
        isFalse,
      );
    });

    test('15. algorithm version이 바뀌면 재사용하지 않는다', () {
      final stale = TodayMatchResult(
        profile: profile('a'),
        candidateId: 'a',
        reason: '문구',
        dateKey: '2026-07-22',
        source: TodayMatchSource.discovery,
        reasonFingerprint: buildReasonFingerprint('a', '문구'),
        algorithmVersion: kTodayMatchAlgorithmVersion - 1,
      );
      expect(
        stale.isReusableFor(dateKey: '2026-07-22', eligibleCandidateIds: {'a'}),
        isFalse,
      );
    });

    test('16/21. 문구가 다른 후보 것으로 바뀌면 지문이 어긋나 재사용하지 않는다', () {
      final tampered = TodayMatchResult(
        profile: profile('a'),
        candidateId: 'a',
        reason: 'B 후보의 문구',
        dateKey: '2026-07-22',
        // 지문은 여전히 원래 문구 기준 → 불일치
        reasonFingerprint: buildReasonFingerprint('a', 'A 후보의 문구'),
        source: TodayMatchSource.discovery,
      );
      expect(
        tampered.isReusableFor(
          dateKey: '2026-07-22',
          eligibleCandidateIds: {'a'},
        ),
        isFalse,
      );
    });
  });
}
