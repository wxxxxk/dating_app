import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/features/fortune/fortune_hub_controller.dart';
import 'package:dating_app/models/fortune/birth_profile.dart';
import 'package:dating_app/models/fortune_model.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/fortune/fortune_data_source.dart';

/// Firebase 없이 호출 횟수·요청 context·응답 시점을 직접 제어하는 가짜.
class FakeFortuneDataSource implements FortuneDataSource {
  final List<String> dailyUids = [];
  final List<DateTime?> dailyNows = [];
  final List<String> historyUids = [];
  final List<DateTime?> historyNows = [];
  final List<int> historyDays = [];

  /// null이면 즉시 완료. 값이 있으면 테스트가 직접 완료시킨다.
  Completer<DailyFortune>? nextDailyCompleter;
  Completer<List<FortuneHistoryEntry>>? nextHistoryCompleter;

  /// true면 **모든** 호출을 붙잡아둔다. 여러 요청을 동시에 in-flight로 두고
  /// 완료 순서를 뒤집어보기 위한 장치다.
  bool holdDaily = false;
  bool holdHistory = false;
  final List<Completer<DailyFortune>> pendingDaily = [];
  final List<Completer<List<FortuneHistoryEntry>>> pendingHistory = [];

  DailyFortune dailyResult = const DailyFortune(
    loveScore: 4,
    mood: '설렘',
    message: '메시지',
    advice: '조언',
  );
  Object? dailyError;

  List<FortuneHistoryEntry> Function(DateTime? now, int days)? historyBuilder;
  Object? historyError;

  int get dailyCallCount => dailyUids.length;
  int get historyCallCount => historyUids.length;

  @override
  Future<DailyFortune> getDailyFortune({
    required String uid,
    DateTime? now,
  }) async {
    dailyUids.add(uid);
    dailyNows.add(now);
    final completer = nextDailyCompleter;
    if (completer != null) {
      nextDailyCompleter = null;
      return completer.future;
    }
    if (holdDaily) {
      final held = Completer<DailyFortune>();
      pendingDaily.add(held);
      return held.future;
    }
    if (dailyError != null) throw dailyError!;
    return dailyResult;
  }

  @override
  Future<List<FortuneHistoryEntry>> getFortuneHistory({
    required String uid,
    int days = 7,
    DateTime? now,
  }) async {
    historyUids.add(uid);
    historyNows.add(now);
    historyDays.add(days);
    final completer = nextHistoryCompleter;
    if (completer != null) {
      nextHistoryCompleter = null;
      return completer.future;
    }
    if (holdHistory) {
      final held = Completer<List<FortuneHistoryEntry>>();
      pendingHistory.add(held);
      return held.future;
    }
    if (historyError != null) throw historyError!;
    return (historyBuilder ?? defaultHistory)(now, days);
  }
}

/// 오늘부터 과거로 [days]개. day 0의 fortune 유무를 [dayZeroFilled]로 조절한다.
List<FortuneHistoryEntry> historyFor(
  DateTime now,
  int days, {
  bool dayZeroFilled = true,
}) {
  final kst = now.toUtc().add(const Duration(hours: 9));
  final today = DateTime.utc(kst.year, kst.month, kst.day);
  return List.generate(days, (index) {
    final date = today.subtract(Duration(days: index));
    final key =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final filled = index == 0 ? dayZeroFilled : index.isEven;
    return FortuneHistoryEntry(
      dateKey: key,
      date: date,
      fortune: filled
          ? DailyFortune(
              loveScore: 3,
              mood: '기록 $index',
              message: 'm',
              advice: 'a',
            )
          : null,
    );
  });
}

List<FortuneHistoryEntry> defaultHistory(DateTime? now, int days) =>
    historyFor(now ?? DateTime.now(), days);

UserProfile profileFor(String uid, {BirthProfile? birthProfile}) => UserProfile(
  uid: uid,
  displayName: '테스터',
  birthDate: DateTime(1994, 5, 12),
  gender: 'female',
  bio: '소개',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  birthProfile:
      birthProfile ?? const BirthProfile.unknownTime(),
);

void main() {
  // KST 2026-07-22 12:00 (UTC 03:00)
  final day1Noon = DateTime.utc(2026, 7, 22, 3);
  // KST 2026-07-23 00:30 (UTC 2026-07-22 15:30) — 다음 KST 날짜
  final day2Past = DateTime.utc(2026, 7, 22, 15, 30);

  late FakeFortuneDataSource fake;
  late DateTime now;
  late List<String> profileRequests;

  FortuneHubController build({
    String? uid = 'user-a',
    Future<UserProfile?> Function(String uid)? loadProfile,
  }) {
    return FortuneHubController(
      fortuneService: fake,
      loadProfile:
          loadProfile ??
          (requestedUid) async {
            profileRequests.add(requestedUid);
            return profileFor(requestedUid);
          },
      initialUid: uid,
      nowProvider: () => now,
    );
  }

  setUp(() {
    fake = FakeFortuneDataSource();
    now = day1Noon;
    profileRequests = [];
  });

  group('초기 상태', () {
    test('1. UID가 null이면 어떤 서비스도 호출하지 않는다', () async {
      final controller = build(uid: null);
      await controller.loadInitial();
      await pumpEventQueue();

      expect(fake.dailyCallCount, 0);
      expect(fake.historyCallCount, 0);
      expect(controller.dailyStatus, DailyFortuneStatus.idle);
      expect(controller.historyStatus, FortuneHistoryStatus.idle);
      expect(controller.dailyFortune, isNull);
      expect(controller.history, isEmpty);
      controller.dispose();
    });

    test('2. UID가 있으면 daily/history를 각각 한 번씩만 읽는다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(fake.dailyCallCount, 1);
      expect(fake.historyCallCount, 1);
      expect(fake.historyDays.single, 7);
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      controller.dispose();
    });

    test('3. loadInitial을 여러 번 불러도 요청이 중복되지 않는다', () async {
      final controller = build();
      await Future.wait([
        controller.loadInitial(),
        controller.loadInitial(),
        controller.loadInitial(),
      ]);
      await pumpEventQueue();

      expect(fake.dailyCallCount, 1);
      expect(fake.historyCallCount, 1);
      controller.dispose();
    });
  });

  group('날짜와 lifecycle', () {
    test('4/5/6. 같은 날짜 resume은 무호출, 다음 날짜 resume은 daily/history 각 1회', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      await controller.handleResume();
      await pumpEventQueue();
      expect(fake.dailyCallCount, 1, reason: '같은 KST 날짜 → 추가 호출 없음');
      expect(fake.historyCallCount, 1);

      now = day2Past; // KST 날짜가 넘어갔다
      await controller.handleResume();
      await pumpEventQueue();
      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2);
      expect(controller.loadedDailyDateKey, '2026-07-23');
      controller.dispose();
    });

    test('7/8. 날짜 변경을 감지하면 어제 daily/history를 즉시 제거한다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();
      expect(controller.dailyFortune, isNotNull);
      expect(controller.history, isNotEmpty);

      // 새 응답이 오기 전 상태를 보려고 daily/history를 모두 붙잡아둔다.
      fake.nextDailyCompleter = Completer<DailyFortune>();
      fake.nextHistoryCompleter = Completer<List<FortuneHistoryEntry>>();
      now = day2Past;
      unawaited(controller.handleResume());

      expect(controller.dailyFortune, isNull, reason: '어제 운세가 남으면 안 된다');
      expect(controller.history, isEmpty);
      expect(controller.dailyStatus, DailyFortuneStatus.loading);
      expect(controller.historyStatus, FortuneHistoryStatus.loading);
      controller.dispose();
    });

    test('9. 같은 날짜 resume을 반복해도 추가 호출이 없다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      for (var i = 0; i < 5; i++) {
        await controller.handleResume();
        await pumpEventQueue();
      }
      expect(fake.dailyCallCount, 1);
      expect(fake.historyCallCount, 1);
      controller.dispose();
    });
  });

  group('계정 변경', () {
    test('10/13. 계정 전환 시 이전 계정 결과가 즉시 사라지고 새 계정만 반영된다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();
      expect(controller.dailyFortune, isNotNull);

      fake.nextDailyCompleter = Completer<DailyFortune>();
      unawaited(controller.updateAccount('user-b'));
      expect(controller.dailyFortune, isNull, reason: 'A 결과가 B 화면에 남으면 안 된다');
      expect(controller.history, isEmpty);
      expect(controller.activeUid, 'user-b');

      fake.nextDailyCompleter!.complete(fake.dailyResult);
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(fake.dailyUids.last, 'user-b');
      expect(fake.historyUids.last, 'user-b');
      controller.dispose();
    });

    test('11. A 요청 중 B로 전환하면 A 응답은 무시된다', () async {
      final aDaily = Completer<DailyFortune>();
      fake.nextDailyCompleter = aDaily;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      final bDaily = Completer<DailyFortune>();
      fake.nextDailyCompleter = bDaily;
      unawaited(controller.updateAccount('user-b'));
      await pumpEventQueue();

      aDaily.complete(
        const DailyFortune(loveScore: 1, mood: 'A', message: 'A', advice: 'A'),
      );
      await pumpEventQueue();
      expect(controller.dailyFortune, isNull, reason: 'A 응답이 반영되면 안 된다');
      expect(controller.dailyStatus, DailyFortuneStatus.loading);

      bDaily.complete(
        const DailyFortune(loveScore: 5, mood: 'B', message: 'B', advice: 'B'),
      );
      await pumpEventQueue();
      expect(controller.dailyFortune?.mood, 'B');
      controller.dispose();
    });

    test('12. 로그아웃하면 결과가 제거되고 추가 호출이 없다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();
      final callsBefore = fake.dailyCallCount + fake.historyCallCount;

      await controller.updateAccount(null);
      await pumpEventQueue();

      expect(controller.dailyFortune, isNull);
      expect(controller.history, isEmpty);
      expect(controller.dailyStatus, DailyFortuneStatus.idle);
      expect(controller.historyStatus, FortuneHistoryStatus.idle);
      expect(fake.dailyCallCount + fake.historyCallCount, callsBefore);
      controller.dispose();
    });
  });

  group('늦게 도착한 응답', () {
    test('14. retry 이전 daily 응답은 무시된다', () async {
      final first = Completer<DailyFortune>();
      fake.nextDailyCompleter = first;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      final second = Completer<DailyFortune>();
      fake.nextDailyCompleter = second;
      unawaited(controller.retryDaily());
      await pumpEventQueue();

      first.complete(
        const DailyFortune(loveScore: 1, mood: '옛', message: 'x', advice: 'x'),
      );
      await pumpEventQueue();
      expect(controller.dailyFortune, isNull);

      second.complete(
        const DailyFortune(loveScore: 5, mood: '새', message: 'n', advice: 'n'),
      );
      await pumpEventQueue();
      expect(controller.dailyFortune?.mood, '새');
      controller.dispose();
    });

    test('15. retry 이전 history 응답은 무시된다', () async {
      final first = Completer<List<FortuneHistoryEntry>>();
      fake.nextHistoryCompleter = first;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      final second = Completer<List<FortuneHistoryEntry>>();
      fake.nextHistoryCompleter = second;
      unawaited(controller.retryHistory());
      await pumpEventQueue();

      first.complete([FortuneHistoryEntry(dateKey: 'stale', date: _staleDate)]);
      await pumpEventQueue();
      expect(controller.history, isEmpty);

      second.complete(historyFor(day1Noon, 7));
      await pumpEventQueue();
      expect(controller.history.length, 7);
      expect(controller.history.first.dateKey, '2026-07-22');
      controller.dispose();
    });

    test('16. 어제 daily가 오늘 daily보다 늦게 도착하면 무시된다', () async {
      final yesterday = Completer<DailyFortune>();
      fake.nextDailyCompleter = yesterday;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      now = day2Past;
      final today = Completer<DailyFortune>();
      fake.nextDailyCompleter = today;
      unawaited(controller.handleResume());
      await pumpEventQueue();

      yesterday.complete(
        const DailyFortune(loveScore: 1, mood: '어제', message: 'y', advice: 'y'),
      );
      await pumpEventQueue();
      expect(controller.dailyFortune, isNull);

      today.complete(
        const DailyFortune(loveScore: 5, mood: '오늘', message: 't', advice: 't'),
      );
      await pumpEventQueue();
      expect(controller.dailyFortune?.mood, '오늘');
      expect(controller.loadedDailyDateKey, '2026-07-23');
      controller.dispose();
    });

    test('17/18. dispose 이후 daily/history 응답은 반영되지 않는다', () async {
      final daily = Completer<DailyFortune>();
      final history = Completer<List<FortuneHistoryEntry>>();
      fake.nextDailyCompleter = daily;
      fake.nextHistoryCompleter = history;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      controller.dispose();
      daily.complete(fake.dailyResult);
      history.complete(historyFor(day1Noon, 7));
      // dispose된 ChangeNotifier에 notifyListeners를 부르면 예외가 난다.
      // 아무 예외 없이 지나가야 한다.
      await pumpEventQueue();
      expect(controller.dailyFortune, isNull);
      expect(controller.history, isEmpty);
    });
  });

  group('오류 분류', () {
    Future<DailyFortuneStatus> statusForCode(String code) async {
      fake.dailyError = FortuneFailure(code);
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();
      final status = controller.dailyStatus;
      controller.dispose();
      return status;
    }

    test('19. resource-exhausted → rateLimited', () async {
      expect(
        await statusForCode('resource-exhausted'),
        DailyFortuneStatus.rateLimited,
      );
    });

    test('20/21. unavailable·deadline-exceeded → unavailable', () async {
      expect(
        await statusForCode('unavailable'),
        DailyFortuneStatus.unavailable,
      );
      fake = FakeFortuneDataSource();
      expect(
        await statusForCode('deadline-exceeded'),
        DailyFortuneStatus.unavailable,
      );
    });

    test('22. failed-precondition → needsBirthProfile', () async {
      expect(
        await statusForCode('failed-precondition'),
        DailyFortuneStatus.needsBirthProfile,
      );
    });

    test('23. internal/unknown → error', () async {
      expect(await statusForCode('internal'), DailyFortuneStatus.error);
      fake = FakeFortuneDataSource();
      expect(await statusForCode('unknown'), DailyFortuneStatus.error);
    });

    test('23-b. unauthenticated는 결과를 비우고 idle로 남는다', () async {
      fake.dailyError = const FortuneFailure('unauthenticated');
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(controller.dailyStatus, DailyFortuneStatus.idle);
      expect(controller.dailyFortune, isNull);
      controller.dispose();
    });

    test('24/25. history 오류는 error이고 raw 예외 문자열을 남기지 않는다', () async {
      fake.historyError = StateError('permission-denied at users/uid-1234');
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(controller.historyStatus, FortuneHistoryStatus.error);
      expect(controller.history, isEmpty);
      // 상태에는 enum만 있고 raw 문자열을 담을 필드 자체가 없다.
      expect(controller.dailyStatus, DailyFortuneStatus.ready, reason: 'daily는 독립');
      controller.dispose();
    });

    test('26. retry하면 ready로 복구된다', () async {
      fake.dailyError = const FortuneFailure('unavailable');
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.unavailable);

      fake.dailyError = null;
      await controller.retryDaily();
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.dailyFortune, isNotNull);
      controller.dispose();
    });

    test('26-b. 프로필의 출생정보가 미완성이면 needsBirthProfile이고 callable을 부르지 않는다', () async {
      final controller = build(
        loadProfile: (uid) async => profileFor(
          uid,
          birthProfile: const BirthProfile.legacyMissing(),
        ),
      );
      await controller.loadInitial();
      await pumpEventQueue();

      expect(controller.dailyStatus, DailyFortuneStatus.needsBirthProfile);
      expect(fake.dailyCallCount, 0);
      controller.dispose();
    });
  });

  group('today와 history day 0 결합', () {
    test('27. history day 0의 dateKey가 현재 KST 날짜다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(controller.history.first.dateKey, '2026-07-22');
      expect(controller.history.length, 7);
      expect(
        controller.history.map((e) => e.dateKey).toSet().length,
        7,
        reason: '중복 없음',
      );
      controller.dispose();
    });

    test('28. daily 성공 후 day 0이 비어 있으면 history를 한 번만 다시 읽는다', () async {
      var served = 0;
      fake.historyBuilder = (nowValue, days) {
        served += 1;
        return historyFor(
          nowValue ?? day1Noon,
          days,
          dayZeroFilled: served > 1, // 첫 응답만 비어 있다
        );
      };
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(fake.historyCallCount, 2, reason: '보정 재조회 1회');
      expect(controller.history.first.fortune, isNotNull);
      expect(fake.dailyCallCount, 1, reason: 'history 갱신이 daily를 되부르지 않는다');
      controller.dispose();
    });

    test('29. day 0이 이미 채워져 있으면 추가 history 읽기가 없다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(fake.historyCallCount, 1);
      controller.dispose();
    });

    test('30/31. 일부 날짜가 null이어도 ready이고 daily를 다시 부르지 않는다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.history.any((e) => e.fortune == null), isTrue);
      expect(fake.dailyCallCount, 1);
      controller.dispose();
    });

    test('31-b. daily/history 요청이 같은 KST 날짜 instant를 쓴다', () async {
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(fake.dailyNows.single, isNotNull);
      expect(
        _kstKey(fake.dailyNows.single!),
        _kstKey(fake.historyNows.single!),
      );
      expect(_kstKey(fake.dailyNows.single!), '2026-07-22');
      controller.dispose();
    });
  });

  // 1-E-3 회귀: 초기 daily/history가 **둘 다 아직 완료되지 않은 채** 자정을
  // 넘기면, loaded key가 둘 다 null이라 날짜 변경이 감지되지 않고 두 in-flight
  // flag가 새 요청을 막아 controller가 loading에서 영구 정지했다.
  group('자정 전환 중 in-flight 교착', () {
    const yesterdayFortune = DailyFortune(
      loveScore: 1,
      mood: '어제',
      message: 'y',
      advice: 'y',
    );
    const todayFortune = DailyFortune(
      loveScore: 5,
      mood: '오늘',
      message: 't',
      advice: 't',
    );

    test('45. 두 요청이 모두 in-flight여도 새 날짜 요청이 즉시 시작된다', () async {
      fake
        ..holdDaily = true
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      expect(fake.dailyCallCount, 1);
      expect(fake.historyCallCount, 1);
      expect(controller.loadedDailyDateKey, isNull);
      expect(controller.loadedHistoryDateKey, isNull);
      expect(controller.isDailyInFlight, isTrue);
      expect(controller.isHistoryInFlight, isTrue);

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();

      // 어제 응답이 아직 오지 않았는데도 새 날짜 요청이 나가야 한다.
      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2);
      expect(controller.dailyStatus, DailyFortuneStatus.loading);
      expect(controller.historyStatus, FortuneHistoryStatus.loading);
      expect(controller.contextDateKey, '2026-07-23');
      expect(controller.inFlightDailyDateKey, '2026-07-23');
      expect(controller.inFlightHistoryDateKey, '2026-07-23');

      // 어제 응답이 뒤늦게 도착 — 반영되지 않는다.
      fake.pendingDaily[0].complete(yesterdayFortune);
      fake.pendingHistory[0].complete(historyFor(day1Noon, 7));
      await pumpEventQueue();
      expect(controller.dailyFortune, isNull);
      expect(controller.history, isEmpty);
      expect(controller.dailyStatus, DailyFortuneStatus.loading);
      expect(controller.historyStatus, FortuneHistoryStatus.loading);

      // 오늘 응답
      fake.pendingDaily[1].complete(todayFortune);
      fake.pendingHistory[1].complete(historyFor(day2Past, 7));
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.dailyFortune?.mood, '오늘');
      expect(controller.loadedDailyDateKey, '2026-07-23');
      expect(controller.loadedHistoryDateKey, '2026-07-23');
      expect(controller.history.first.dateKey, '2026-07-23');

      // 이후 같은 날짜 resume은 추가 호출을 만들지 않는다.
      await controller.handleResume();
      await pumpEventQueue();
      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2);
      controller.dispose();
    });

    test('16/17. 어제 요청의 정리 코드가 오늘 요청의 in-flight를 끄지 않는다', () async {
      fake
        ..holdDaily = true
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();

      // 어제 요청을 성공/실패 양쪽으로 끝내본다.
      fake.pendingDaily[0].complete(yesterdayFortune);
      fake.pendingHistory[0].completeError(const FortuneFailure('unavailable'));
      await pumpEventQueue();

      expect(controller.isDailyInFlight, isTrue, reason: '오늘 daily는 여전히 진행 중');
      expect(controller.isHistoryInFlight, isTrue);
      expect(controller.inFlightDailyDateKey, '2026-07-23');
      expect(controller.inFlightHistoryDateKey, '2026-07-23');
      // 20. stale 오류가 현재 상태를 덮어쓰지 않는다.
      expect(controller.historyStatus, FortuneHistoryStatus.loading);
      expect(fake.dailyCallCount, 2, reason: '중복 재요청 없음');
      expect(fake.historyCallCount, 2);
      controller.dispose();
    });

    test('18/19. 진행 중이면 중복 요청이 없고, 완료 후 retry가 동작한다', () async {
      fake
        ..holdDaily = true
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      await controller.refreshForCurrentContext();
      await controller.refreshForCurrentContext();
      await pumpEventQueue();
      expect(fake.dailyCallCount, 1, reason: '같은 날짜 요청이 진행 중이면 중복 금지');
      expect(fake.historyCallCount, 1);

      fake.pendingDaily[0].complete(todayFortune);
      fake.pendingHistory[0].complete(historyFor(day1Noon, 7));
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.isDailyInFlight, isFalse);
      expect(controller.isHistoryInFlight, isFalse);

      fake
        ..holdDaily = false
        ..holdHistory = false;
      await controller.retryDaily();
      await controller.retryHistory();
      await pumpEventQueue();
      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2);
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      controller.dispose();
    });

    test('20. stale 요청이 오류로 끝나도 현재 ready 상태를 덮어쓰지 않는다', () async {
      fake.holdDaily = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();

      fake.pendingDaily[1].complete(todayFortune);
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);

      fake.pendingDaily[0].completeError(const FortuneFailure('internal'));
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.dailyFortune?.mood, '오늘');
      controller.dispose();
    });

    test('21. daily만 in-flight인 상태에서 날짜가 바뀌어도 복구된다', () async {
      fake.holdDaily = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.isDailyInFlight, isTrue);

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();
      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2);
      expect(controller.history.first.dateKey, '2026-07-23');

      fake.pendingDaily[1].complete(todayFortune);
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.loadedDailyDateKey, '2026-07-23');
      controller.dispose();
    });

    test('22. history만 in-flight인 상태에서 날짜가 바뀌어도 복구된다', () async {
      fake.holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.isHistoryInFlight, isTrue);

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();
      expect(fake.historyCallCount, 2);
      expect(controller.loadedDailyDateKey, '2026-07-23');

      fake.pendingHistory[1].complete(historyFor(day2Past, 7));
      await pumpEventQueue();
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.loadedHistoryDateKey, '2026-07-23');
      controller.dispose();
    });

    test('23. profile loader 단계에서 날짜가 바뀌어도 교착되지 않는다', () async {
      final profileGate = Completer<UserProfile?>();
      final controller = build(loadProfile: (uid) => profileGate.future);
      unawaited(controller.loadInitial());
      await pumpEventQueue();
      expect(fake.dailyCallCount, 0, reason: '아직 프로필 대기 중');
      expect(controller.isDailyInFlight, isTrue);

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();
      expect(controller.contextDateKey, '2026-07-23');
      expect(controller.inFlightDailyDateKey, '2026-07-23');

      profileGate.complete(profileFor('user-a'));
      await pumpEventQueue();
      // 어제 요청은 버려지고, 오늘 요청만 결과를 만든다.
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.loadedDailyDateKey, '2026-07-23');
      expect(fake.dailyCallCount, 1);
      expect(_kstKey(fake.dailyNows.single!), '2026-07-23');
      controller.dispose();
    });

    test('24. 날짜 변경 직후 계정을 전환해도 새 계정 결과만 남는다', () async {
      fake
        ..holdDaily = true
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();

      unawaited(controller.updateAccount('user-b'));
      await pumpEventQueue();
      expect(controller.activeUid, 'user-b');
      expect(controller.contextDateKey, '2026-07-23');
      expect(fake.dailyUids.last, 'user-b');

      // user-a의 어제·오늘 응답이 모두 늦게 도착해도 반영되지 않는다.
      for (final pending in fake.pendingDaily.take(2)) {
        pending.complete(yesterdayFortune);
      }
      await pumpEventQueue();
      expect(controller.dailyFortune, isNull);

      fake.pendingDaily.last.complete(todayFortune);
      fake.pendingHistory.last.complete(historyFor(day2Past, 7));
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.dailyFortune?.mood, '오늘');
      controller.dispose();
    });

    test('25. 계정 전환 직후 날짜가 바뀌어도 새 계정·새 날짜로 복구된다', () async {
      fake
        ..holdDaily = true
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      unawaited(controller.updateAccount('user-b'));
      await pumpEventQueue();
      expect(controller.contextDateKey, '2026-07-22');

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();
      expect(controller.contextDateKey, '2026-07-23');
      expect(controller.inFlightDailyDateKey, '2026-07-23');
      expect(fake.dailyUids.last, 'user-b');

      fake.pendingDaily.last.complete(todayFortune);
      fake.pendingHistory.last.complete(historyFor(day2Past, 7));
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.loadedDailyDateKey, '2026-07-23');
      controller.dispose();
    });

    test('26. dispose 이후의 모든 늦은 완료를 무시한다', () async {
      fake
        ..holdDaily = true
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();

      now = day2Past;
      unawaited(controller.handleResume());
      await pumpEventQueue();

      controller.dispose();
      fake.pendingDaily[0].complete(yesterdayFortune);
      fake.pendingDaily[1].complete(todayFortune);
      fake.pendingHistory[0].complete(historyFor(day1Noon, 7));
      fake.pendingHistory[1].completeError(const FortuneFailure('internal'));
      await pumpEventQueue();

      expect(controller.dailyFortune, isNull);
      expect(controller.history, isEmpty);
    });
  });

  // 1-E-4 회귀: 같은 KST 날짜에 출생정보가 바뀌면 서버 inputFingerprint가 달라져
  // dailyFortune 문서가 새로 쓰인다. daily만 다시 읽으면 오늘 카드는 새 출생정보
  // 기반인데 최근 기록 day 0은 이전 출생정보 기반으로 남았다.
  group('출생정보 변경 후 재결합', () {
    const oldFortune = DailyFortune(
      loveScore: 2,
      mood: '시간 모름',
      message: 'old',
      advice: 'old',
    );
    const newFortune = DailyFortune(
      loveScore: 5,
      mood: '시간 반영',
      message: 'new',
      advice: 'new',
    );

    /// unknown-time 상태로 daily/history가 모두 ready인 controller.
    Future<FortuneHubController> readyController() async {
      fake.dailyResult = oldFortune;
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.ready);
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.history.first.fortune, isNotNull);
      expect(fake.dailyCallCount, 1);
      expect(fake.historyCallCount, 1, reason: 'day 0이 채워져 보정 재조회 없음');
      return controller;
    }

    test('48. 호출 즉시 이전 daily와 day 0이 사라지고 과거 기록은 남는다', () async {
      final controller = await readyController();
      final pastBefore = controller.history.skip(1).toList();

      fake.holdDaily = true;
      unawaited(controller.refreshAfterBirthProfileCompleted());

      expect(controller.dailyFortune, isNull);
      expect(controller.dailyStatus, DailyFortuneStatus.loading);
      expect(controller.history.first.fortune, isNull, reason: '이전 day 0 즉시 제거');
      expect(controller.history.first.dateKey, '2026-07-22');
      expect(controller.history.length, 7);
      for (var i = 0; i < pastBefore.length; i++) {
        expect(controller.history[i + 1].dateKey, pastBefore[i].dateKey);
        expect(controller.history[i + 1].fortune, pastBefore[i].fortune);
      }
      controller.dispose();
    });

    test('49. daily가 먼저 나가고, 완료 전에는 history를 읽지 않는다', () async {
      final controller = await readyController();

      fake.holdDaily = true;
      unawaited(controller.refreshAfterBirthProfileCompleted());
      await pumpEventQueue();

      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 1, reason: 'daily write 전에 history를 읽으면 안 된다');
      controller.dispose();
    });

    test('50. daily 성공 후 history를 정확히 1회 재조회해 day 0을 교체한다', () async {
      final controller = await readyController();

      fake.dailyResult = newFortune;
      await controller.refreshAfterBirthProfileCompleted();
      await pumpEventQueue();

      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2, reason: 'history 재조회는 정확히 1회');
      expect(controller.dailyFortune?.mood, '시간 반영');
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.history.first.dateKey, '2026-07-22');
      expect(controller.history.first.fortune, isNotNull);
      expect(controller.history.length, 7);
      controller.dispose();
    });

    test('51. 기존 dayZeroSyncedDateKey가 재조회를 막지 않는다', () async {
      final controller = await readyController();
      // day 0이 이미 채워져 있어 guard가 오늘 날짜로 굳어 있는 상태다.
      await controller.handleResume();
      await pumpEventQueue();
      expect(fake.historyCallCount, 1);

      await controller.refreshAfterBirthProfileCompleted();
      await pumpEventQueue();
      expect(fake.historyCallCount, 2);
      controller.dispose();
    });

    test('52. 재조회 완료 후 추가 중복 read가 없다', () async {
      final controller = await readyController();
      await controller.refreshAfterBirthProfileCompleted();
      await pumpEventQueue();
      expect(fake.historyCallCount, 2);

      await controller.handleResume();
      await controller.refreshForCurrentContext();
      await pumpEventQueue();
      expect(fake.dailyCallCount, 2);
      expect(fake.historyCallCount, 2);
      controller.dispose();
    });

    test('53. daily 실패 시 이전 daily·day 0을 복원하지 않는다', () async {
      final controller = await readyController();

      fake.dailyError = const FortuneFailure('unavailable');
      await controller.refreshAfterBirthProfileCompleted();
      await pumpEventQueue();

      expect(controller.dailyStatus, DailyFortuneStatus.unavailable);
      expect(controller.dailyFortune, isNull);
      expect(controller.history.first.fortune, isNull, reason: '이전 day 0 복원 금지');
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(fake.historyCallCount, 1, reason: 'daily 실패 시 history를 읽지 않는다');
      controller.dispose();
    });

    test('54. daily 실패 후 retryDaily가 성공하면 history를 갱신한다', () async {
      final controller = await readyController();
      fake.dailyError = const FortuneFailure('unavailable');
      await controller.refreshAfterBirthProfileCompleted();
      await pumpEventQueue();
      expect(controller.dailyStatus, DailyFortuneStatus.unavailable);

      fake
        ..dailyError = null
        ..dailyResult = newFortune;
      await controller.retryDaily();
      await pumpEventQueue();

      expect(controller.dailyFortune?.mood, '시간 반영');
      expect(fake.historyCallCount, 2, reason: 'retry 성공 시 예약된 갱신이 실행된다');
      expect(controller.history.first.fortune, isNotNull);
      controller.dispose();
    });

    test('55. 갱신 중 날짜가 바뀌면 이전 날짜 history refresh를 버린다', () async {
      final controller = await readyController();

      fake.holdDaily = true;
      unawaited(controller.refreshAfterBirthProfileCompleted());
      await pumpEventQueue();
      final historyCallsBefore = fake.historyCallCount;

      now = day2Past;
      fake.holdDaily = false;
      await controller.handleResume();
      await pumpEventQueue();

      expect(controller.loadedDailyDateKey, '2026-07-23');
      expect(controller.loadedHistoryDateKey, '2026-07-23');
      // 어제 daily가 늦게 도착해도 어제 날짜 history를 다시 읽지 않는다.
      final callsAfterRollover = fake.historyCallCount;
      fake.pendingDaily.first.complete(newFortune);
      await pumpEventQueue();
      expect(fake.historyCallCount, callsAfterRollover);
      expect(callsAfterRollover, greaterThan(historyCallsBefore));
      expect(controller.history.first.dateKey, '2026-07-23');
      controller.dispose();
    });

    test('56. 갱신 중 계정이 바뀌면 이전 계정 refresh를 버린다', () async {
      final controller = await readyController();

      fake.holdDaily = true;
      unawaited(controller.refreshAfterBirthProfileCompleted());
      await pumpEventQueue();

      fake.holdDaily = false;
      await controller.updateAccount('user-b');
      await pumpEventQueue();
      final callsAfterSwitch = fake.historyCallCount;

      // user-a의 daily가 뒤늦게 도착해도 history를 다시 읽지 않는다.
      fake.pendingDaily.first.complete(newFortune);
      await pumpEventQueue();
      expect(fake.historyCallCount, callsAfterSwitch);
      expect(fake.historyUids.last, 'user-b');
      controller.dispose();
    });

    test('57. 진행 중이던 이전 history 응답이 늦게 와도 day 0을 덮어쓰지 않는다', () async {
      fake
        ..dailyResult = oldFortune
        ..holdHistory = true;
      final controller = build();
      unawaited(controller.loadInitial());
      await pumpEventQueue();
      expect(controller.isHistoryInFlight, isTrue);

      // history가 아직 진행 중인 시점에 출생정보가 바뀐다.
      fake
        ..holdHistory = false
        ..dailyResult = newFortune;
      await controller.refreshAfterBirthProfileCompleted();
      await pumpEventQueue();
      expect(controller.history.first.fortune?.mood, '기록 0');

      // 이전 출생정보 기준으로 시작됐던 history 응답이 뒤늦게 도착.
      fake.pendingHistory.first.complete([
        FortuneHistoryEntry(dateKey: 'stale-day-zero', date: _staleDate),
      ]);
      await pumpEventQueue();
      expect(controller.history.first.dateKey, '2026-07-22');
      expect(controller.history.length, 7);
      controller.dispose();
    });

    test('58. dispose 이후 늦은 응답을 무시한다', () async {
      final controller = await readyController();
      fake
        ..holdDaily = true
        ..holdHistory = true;
      unawaited(controller.refreshAfterBirthProfileCompleted());
      await pumpEventQueue();

      controller.dispose();
      fake.pendingDaily.first.complete(newFortune);
      await pumpEventQueue();

      expect(controller.dailyFortune, isNull);
      expect(fake.historyCallCount, 1, reason: 'dispose 후에는 재조회하지 않는다');
    });
  });

  group('day 0 sync guard', () {
    test('46. 보정 재조회가 실패하면 retry 후 day 0을 다시 대조한다', () async {
      var served = 0;
      fake.historyBuilder = (nowValue, days) {
        served += 1;
        if (served == 2) throw const FortuneFailure('unavailable');
        // 3번째 응답(수동 retry)부터 day 0이 채워진다.
        return historyFor(nowValue ?? day1Noon, days, dayZeroFilled: served > 2);
      };
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      // 1회차 ready(day 0 비어있음) → 보정 재조회 2회차가 실패했다.
      expect(fake.historyCallCount, 2);
      expect(controller.historyStatus, FortuneHistoryStatus.error);

      await controller.retryHistory();
      await pumpEventQueue();
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      expect(controller.history.first.fortune, isNotNull);
      controller.dispose();
    });

    test('47. day 0이 계속 비어 있어도 자동 재조회는 날짜당 1회로 멈춘다', () async {
      fake.historyBuilder = (nowValue, days) =>
          historyFor(nowValue ?? day1Noon, days, dayZeroFilled: false);
      final controller = build();
      await controller.loadInitial();
      await pumpEventQueue();

      expect(fake.historyCallCount, 2, reason: '초기 1회 + 보정 1회에서 멈춘다');
      expect(controller.historyStatus, FortuneHistoryStatus.ready);
      controller.dispose();
    });
  });
}

final DateTime _staleDate = DateTime.utc(2020, 1, 1);

String _kstKey(DateTime instant) {
  final kst = instant.toUtc().add(const Duration(hours: 9));
  return '${kst.year.toString().padLeft(4, '0')}-'
      '${kst.month.toString().padLeft(2, '0')}-'
      '${kst.day.toString().padLeft(2, '0')}';
}
