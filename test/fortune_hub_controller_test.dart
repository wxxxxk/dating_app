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
}

final DateTime _staleDate = DateTime.utc(2020, 1, 1);

String _kstKey(DateTime instant) {
  final kst = instant.toUtc().add(const Duration(hours: 9));
  return '${kst.year.toString().padLeft(4, '0')}-'
      '${kst.month.toString().padLeft(2, '0')}-'
      '${kst.day.toString().padLeft(2, '0')}';
}
