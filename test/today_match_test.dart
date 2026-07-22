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
        viewerEligibilityFingerprint: 'viewer-fp',
      );
      final b = buildTodayMatchResult(
        candidate: discovery('b', interests: const ['영화']),
        dateKey: '2026-07-22',
        viewerEligibilityFingerprint: 'viewer-fp',
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
        viewerEligibilityFingerprint: 'viewer-fp',
      );
      // 후보 자신의 관심사가 들어간다. 다른 후보/데모 문구가 아니다.
      // 관심사는 정렬해 첫 항목을 쓰므로 순서가 흔들려도 문구가 안정적이다.
      expect(result.reason, contains('등산'));

      final shuffled = buildTodayMatchResult(
        candidate: discovery('a', interests: const ['커피', '등산']),
        dateKey: '2026-07-22',
        viewerEligibilityFingerprint: 'viewer-fp',
      );
      expect(shuffled.reason, result.reason);
    });

    test('AI 문구가 있으면 그 후보의 문구를 그대로 쓴다', () {
      final result = buildTodayMatchResult(
        candidate: matched('a', reason: '두 사람은 대화 속도가 비슷해요.'),
        dateKey: '2026-07-22',
        viewerEligibilityFingerprint: 'viewer-fp',
      );
      expect(result.reason, '두 사람은 대화 속도가 비슷해요.');
    });

    test('24. 결과에 점수 필드가 없다 (근거 없는 % 표시 불가)', () {
      final result = buildTodayMatchResult(
        candidate: discovery('a'),
        dateKey: '2026-07-22',
        viewerEligibilityFingerprint: 'viewer-fp',
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
        viewerEligibilityFingerprint: 'viewer-fp',
      );
      expect(result.reason.contains('uid-secret-123'), isFalse);
      expect(RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(result.reason), isFalse);
      expect(result.reason.contains('discovery'), isFalse);
      expect(result.reason.contains('TodayMatchSource'), isFalse);
    });
  });

  group('차단 안전성 (fail-closed)', () {
    Future<List<TodayMatchCandidate>> collect({
      required Future<Set<String>> Function(String) loadBlocked,
      Future<List<TodayMatchCandidate>> Function(Set<String>)? loadMatches,
      Future<List<PublicProfile>> Function(Set<String>)? loadDiscovery,
      List<String>? log,
    }) {
      return collectTodayMatchCandidates(
        viewerUid: 'me',
        loadBlockedUids: loadBlocked,
        loadMatchCandidates: loadMatches ?? (_) async => const [],
        loadDiscoveryProfiles: loadDiscovery ?? (_) async => const [],
        onLog: log?.add,
      );
    }

    test(
      '1/2. 차단 조회 실패면 BlockLookupFailure를 던지고 discovery를 호출하지 않는다',
      () async {
        var discoveryCalls = 0;
        final log = <String>[];
        await expectLater(
          collect(
            loadBlocked: (_) async => throw StateError('permission-denied'),
            loadDiscovery: (_) async {
              discoveryCalls += 1;
              return const [];
            },
            log: log,
          ),
          throwsA(isA<BlockLookupFailure>()),
        );
        expect(discoveryCalls, 0, reason: '차단 확인 없이 추천을 계속하면 안 된다');
        expect(log, contains('block_relationship_lookup_failed'));
      },
    );

    test('3. 차단한 discovery 후보가 제외된다', () async {
      final candidates = await collect(
        loadBlocked: (_) async => {'blocked'},
        loadDiscovery: (_) async => [profile('blocked'), profile('ok')],
      );
      expect(candidates.map((c) => c.id), ['ok']);
    });

    test('4. 차단한 match 후보가 제외된다 (매치 스트림에 남아 있어도)', () async {
      final candidates = await collect(
        loadBlocked: (_) async => {'blocked'},
        loadMatches: (_) async => [matched('blocked'), matched('ok')],
      );
      expect(candidates.map((c) => c.id), ['ok']);
    });

    test('5. 나를 차단한 상대도 같은 집합으로 제외된다', () async {
      // getBlockedRelationshipUids는 양방향(내가 차단 + 나를 차단)을 함께 준다.
      final candidates = await collect(
        loadBlocked: (_) async => {'blocked-me'},
        loadMatches: (_) async => [matched('blocked-me')],
        loadDiscovery: (_) async => [profile('blocked-me'), profile('ok')],
      );
      expect(candidates.map((c) => c.id), ['ok']);
    });

    test('8. 차단 조회 성공 + match 실패면 discovery로 계속 진행한다', () async {
      final log = <String>[];
      final candidates = await collect(
        loadBlocked: (_) async => const {},
        loadMatches: (_) async => throw StateError('stream failed'),
        loadDiscovery: (_) async => [profile('ok')],
        log: log,
      );
      expect(candidates.map((c) => c.id), ['ok']);
      expect(log, contains('match_list_failed'));
    });

    test('9. discovery 실패는 CandidateLookupFailure다 (후보 0명이 아니다)', () async {
      final log = <String>[];
      await expectLater(
        collect(
          loadBlocked: (_) async => const {},
          loadDiscovery: (_) async => throw StateError('offline'),
          log: log,
        ),
        throwsA(isA<CandidateLookupFailure>()),
      );
      expect(log, contains('discovery_lookup_failed'));
    });

    test('차단 집합이 discovery 조회에 그대로 전달된다', () async {
      Set<String>? received;
      await collect(
        loadBlocked: (_) async => {'b1', 'b2'},
        loadDiscovery: (blocked) async {
          received = blocked;
          return const [];
        },
      );
      expect(received, {'b1', 'b2'});
    });
  });

  group('캐시 재사용 조건', () {
    const viewerFp = 'viewer-fp';

    TodayMatchResult resultFor(TodayMatchCandidate candidate) =>
        buildTodayMatchResult(
          candidate: candidate,
          dateKey: '2026-07-22',
          viewerEligibilityFingerprint: viewerFp,
        );

    bool reusable(
      TodayMatchResult result, {
      String dateKey = '2026-07-22',
      Map<String, String>? fingerprints,
      Set<String> blocked = const {},
      String viewer = viewerFp,
    }) => result.isReusableFor(
      dateKey: dateKey,
      eligibleCandidateFingerprints:
          fingerprints ??
          {result.candidateId: result.candidateProfileFingerprint},
      blockedUids: blocked,
      viewerEligibilityFingerprint: viewer,
    );

    test('14. 공개 필드가 그대로면 재사용한다', () {
      final result = resultFor(discovery('a', interests: const ['등산']));
      expect(reusable(result), isTrue);
    });

    test('20. 날짜가 지나면 재사용하지 않는다', () {
      final result = resultFor(discovery('a'));
      expect(reusable(result, dateKey: '2026-07-23'), isFalse);
    });

    test('6/18. 후보가 차단되면 재사용하지 않는다', () {
      final result = resultFor(discovery('a'));
      expect(reusable(result, blocked: {'a'}), isFalse);
    });

    test('후보가 eligible 목록에서 사라지면 재사용하지 않는다', () {
      final result = resultFor(discovery('a'));
      expect(reusable(result, fingerprints: const {}), isFalse);
    });

    test('10. 사진이 바뀌면 무효화된다', () {
      final before = PublicProfile(uid: 'a', photoUrls: const ['p1.jpg']);
      final after = PublicProfile(uid: 'a', photoUrls: const ['p2.jpg']);
      final result = resultFor(
        TodayMatchCandidate(
          profile: before,
          source: TodayMatchSource.discovery,
        ),
      );
      expect(
        reusable(
          result,
          fingerprints: {'a': buildCandidateProfileFingerprint(after)},
        ),
        isFalse,
      );
    });

    test('사진 순서만 바뀌어도(대표 사진 교체) 무효화된다', () {
      final before = PublicProfile(
        uid: 'a',
        photoUrls: const ['p1.jpg', 'p2.jpg'],
      );
      final after = PublicProfile(
        uid: 'a',
        photoUrls: const ['p2.jpg', 'p1.jpg'],
      );
      expect(
        buildCandidateProfileFingerprint(before),
        isNot(buildCandidateProfileFingerprint(after)),
      );
    });

    test('11. bio가 바뀌면 무효화된다', () {
      final before = PublicProfile(uid: 'a', bio: '안녕하세요');
      final after = PublicProfile(uid: 'a', bio: '반갑습니다');
      final result = resultFor(
        TodayMatchCandidate(
          profile: before,
          source: TodayMatchSource.discovery,
        ),
      );
      expect(
        reusable(
          result,
          fingerprints: {'a': buildCandidateProfileFingerprint(after)},
        ),
        isFalse,
      );
    });

    test('12. interests가 바뀌면 무효화된다', () {
      final result = resultFor(discovery('a', interests: const ['등산']));
      expect(
        reusable(
          result,
          fingerprints: {
            'a': buildCandidateProfileFingerprint(
              profile('a', interests: const ['등산', '영화']),
            ),
          },
        ),
        isFalse,
      );
    });

    test('13. relationshipGoal이 바뀌면 무효화된다', () {
      final result = resultFor(
        TodayMatchCandidate(
          profile: profile('a', relationshipGoal: 'serious'),
          source: TodayMatchSource.discovery,
        ),
      );
      expect(
        reusable(
          result,
          fingerprints: {
            'a': buildCandidateProfileFingerprint(
              profile('a', relationshipGoal: 'casual'),
            ),
          },
        ),
        isFalse,
      );
    });

    test('profileUpdatedAt이 바뀌면 무효화된다', () {
      final before = PublicProfile(
        uid: 'a',
        profileUpdatedAt: DateTime.utc(2026, 7, 1),
      );
      final after = PublicProfile(
        uid: 'a',
        profileUpdatedAt: DateTime.utc(2026, 7, 22),
      );
      expect(
        buildCandidateProfileFingerprint(before),
        isNot(buildCandidateProfileFingerprint(after)),
      );
    });

    test('17. discoveryFilter가 바뀌면 무효화된다', () {
      final result = resultFor(discovery('a'));
      expect(reusable(result, viewer: 'different-filter-fp'), isFalse);
    });

    test('15. algorithm version이 바뀌면 재사용하지 않는다', () {
      final stale = TodayMatchResult(
        profile: profile('a'),
        candidateId: 'a',
        reason: '문구',
        dateKey: '2026-07-22',
        source: TodayMatchSource.discovery,
        reasonFingerprint: buildReasonFingerprint('a', '문구'),
        candidateProfileFingerprint: buildCandidateProfileFingerprint(
          profile('a'),
        ),
        viewerEligibilityFingerprint: viewerFp,
        algorithmVersion: kTodayMatchAlgorithmVersion - 1,
      );
      expect(reusable(stale), isFalse);
    });

    test('16/21. 문구가 다른 후보 것으로 바뀌면 지문이 어긋나 재사용하지 않는다', () {
      final tampered = TodayMatchResult(
        profile: profile('a'),
        candidateId: 'a',
        reason: 'B 후보의 문구',
        dateKey: '2026-07-22',
        reasonFingerprint: buildReasonFingerprint('a', 'A 후보의 문구'),
        candidateProfileFingerprint: buildCandidateProfileFingerprint(
          profile('a'),
        ),
        viewerEligibilityFingerprint: viewerFp,
        source: TodayMatchSource.discovery,
      );
      expect(reusable(tampered), isFalse);
    });
  });

  group('viewer eligibility fingerprint', () {
    String fp({
      String uid = 'me',
      int ageMin = 20,
      int ageMax = 40,
      double? maxDistanceKm = 30,
      String gender = 'all',
      String? relationshipGoal,
      bool hasLocation = true,
    }) => buildViewerEligibilityFingerprint(
      viewerUid: uid,
      ageMin: ageMin,
      ageMax: ageMax,
      maxDistanceKm: maxDistanceKm,
      gender: gender,
      relationshipGoal: relationshipGoal,
      hasLocation: hasLocation,
    );

    test('같은 조건이면 같은 값이다', () {
      expect(fp(), fp());
    });

    test('17. 나이·거리·성별·목표·위치사용이 바뀌면 값이 달라진다', () {
      expect(fp(ageMin: 25), isNot(fp()));
      expect(fp(ageMax: 45), isNot(fp()));
      expect(fp(maxDistanceKm: 50), isNot(fp()));
      expect(fp(maxDistanceKm: null), isNot(fp()));
      expect(fp(gender: 'female'), isNot(fp()));
      expect(fp(relationshipGoal: 'serious'), isNot(fp()));
      expect(fp(hasLocation: false), isNot(fp()));
    });

    test('19. 계정이 다르면 값이 달라진다 (이전 캐시 재사용 불가)', () {
      expect(fp(uid: 'other'), isNot(fp()));
    });
  });

  group('지문 비노출', () {
    test('16. 지문이 UI 문구에 들어가지 않는다', () {
      final result = buildTodayMatchResult(
        candidate: discovery('a', interests: const ['등산']),
        dateKey: '2026-07-22',
        viewerEligibilityFingerprint: 'viewer-fp',
      );
      expect(
        result.reason.contains(result.candidateProfileFingerprint),
        isFalse,
      );
      expect(
        result.reason.contains(result.viewerEligibilityFingerprint),
        isFalse,
      );
      expect(result.reason.contains(result.reasonFingerprint), isFalse);
    });
  });

  group('날짜 계약 (4장 정정)', () {
    test('20/22. 같은 dateKey면 입력 순서가 달라도 결과가 같다', () {
      final candidates = List.generate(5, (i) => discovery('u$i'));
      final a = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: candidates,
      )!;
      final b = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: candidates.reversed.toList(),
      )!;
      expect(a.id, b.id);
    });

    test('21. 다음 날 같은 후보가 나와도 계약 위반이 아니다 (재계산 여부만 본다)', () {
      final candidates = [discovery('a'), discovery('b')];
      final today = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: candidates,
      )!;
      final tomorrow = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-23',
        candidates: candidates,
      )!;
      // 같을 수도 다를 수도 있다. 중요한 건 새 날짜로 계산됐다는 것이다.
      expect(tomorrow.id, isIn(['a', 'b']));
      // 날짜가 바뀌면 캐시는 반드시 무효화된다.
      final result = buildTodayMatchResult(
        candidate: today,
        dateKey: '2026-07-22',
        viewerEligibilityFingerprint: 'v',
      );
      expect(
        result.isReusableFor(
          dateKey: '2026-07-23',
          eligibleCandidateFingerprints: {
            result.candidateId: result.candidateProfileFingerprint,
          },
          blockedUids: const {},
          viewerEligibilityFingerprint: 'v',
        ),
        isFalse,
      );
    });

    test('후보 집합이 달라지면 새 집합으로 재계산된다', () {
      final small = [discovery('a')];
      final large = [discovery('a'), discovery('b'), discovery('c')];
      final fromSmall = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: small,
      )!;
      final fromLarge = selectTodayCandidate(
        viewerUid: 'me',
        dateKey: '2026-07-22',
        candidates: large,
      )!;
      expect(fromSmall.id, 'a');
      expect(fromLarge.id, isIn(['a', 'b', 'c']));
    });
  });
}
