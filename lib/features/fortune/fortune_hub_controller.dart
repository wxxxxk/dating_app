import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/utils/kst_date.dart';
import '../../models/fortune_model.dart';
import '../../models/user_profile.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_data_source.dart';

/// 오늘의 운세 카드가 가질 수 있는 상태.
///
/// bool `_loading` + String `_error` 조합으로는 "요청 제한"과 "출생정보 미완성",
/// "네트워크 불가"를 구분할 수 없었고, loading 중에도 어제 결과가 그대로 남아
/// 있었다. 그 조합 자체를 없앤다.
enum DailyFortuneStatus {
  idle,
  loading,
  ready,
  rateLimited,
  unavailable,
  needsBirthProfile,
  error,
}

/// 최근 기록 목록의 상태. 일부 날짜 fortune이 null인 것은 정상 [ready]다.
enum FortuneHistoryStatus { idle, loading, ready, error }

/// `users/{uid}` 조회. 화면이 FirestoreService를 감아서 넣는다.
typedef FortuneProfileLoader = Future<UserProfile?> Function(String uid);

/// 오늘의 운세와 최근 기록을 하나의 KST 날짜·계정 context 위에서 관리한다.
///
/// 핵심 규칙:
/// - 표시되는 운세는 **항상 현재 KST 날짜, 현재 로그인 계정**의 것이다.
///   날짜나 계정이 바뀌는 순간 이전 결과는 한 프레임도 남지 않고 제거된다.
/// - 늦게 도착한 이전 요청(계정 전환·retry·날짜 변경 이후)은 상태를 덮어쓰지
///   못한다. daily/history 각각 독립적인 요청 세대를 가진다.
/// - daily 실패가 history를 무효화하지 않고, 그 반대도 마찬가지다.
/// - BuildContext·Navigator·SnackBar를 모르며, 사용자 문구도 만들지 않는다.
class FortuneHubController extends ChangeNotifier {
  FortuneHubController({
    required FortuneDataSource fortuneService,
    required FortuneProfileLoader loadProfile,
    String? initialUid,
    DateTime Function()? nowProvider,
    int historyDays = 7,
  }) : _fortune = fortuneService,
       _loadProfile = loadProfile,
       _activeUid = initialUid,
       _now = nowProvider ?? DateTime.now,
       _historyDays = historyDays;

  // ignore_for_file: prefer_initializing_formals

  final FortuneDataSource _fortune;
  final FortuneProfileLoader _loadProfile;
  final DateTime Function() _now;
  final int _historyDays;

  DailyFortuneStatus _dailyStatus = DailyFortuneStatus.idle;
  FortuneHistoryStatus _historyStatus = FortuneHistoryStatus.idle;

  DailyFortune? _dailyFortune;
  List<FortuneHistoryEntry> _history = const [];

  UserProfile? _profile;
  ZodiacInfo? _zodiac;
  SajuInfo? _saju;

  /// 프로필은 날짜가 아니라 계정에 묶인다. 같은 계정이면 자정이 지나도
  /// 다시 읽지 않는다(불필요한 Firestore 읽기 방지).
  String? _profileUid;

  String? _activeUid;
  String? _loadedDailyDateKey;
  String? _loadedHistoryDateKey;

  /// 이 controller가 **지금 담당하는** KST 날짜.
  ///
  /// 완료된 결과(`_loadedXDateKey`)가 아니라 요청 context다. 초기 요청이 아직
  /// 끝나지 않아 loaded key가 둘 다 null인 상태에서 자정을 넘기면, loaded key만
  /// 보는 판정으로는 날짜 변경을 감지하지 못해 controller가 loading에서 멈춘다.
  String? _contextDateKey;

  int _dailyGeneration = 0;
  int _historyGeneration = 0;

  /// 진행 중인 요청의 identity. 세대가 다른 옛 요청의 정리 코드가 새 요청의
  /// in-flight 상태를 꺼버리지 않도록, bool이 아니라 generation으로 들고 있다.
  int? _activeDailyGeneration;
  String? _activeDailyDateKey;
  int? _activeHistoryGeneration;
  String? _activeHistoryDateKey;

  bool _disposed = false;
  bool _initialLoadStarted = false;

  /// day 0 보정을 이미 끝낸 날짜. 무한 재조회를 막는 유일한 장치다.
  String? _dayZeroSyncedDateKey;

  /// 출생정보가 바뀌어, 새 daily가 나온 뒤 최근 기록을 다시 읽어야 하는 날짜.
  ///
  /// 같은 KST 날짜라도 출생정보가 바뀌면 서버 `inputFingerprint`가 달라져
  /// dailyFortune 문서가 새로 쓰인다. daily만 다시 읽으면 오늘 카드는 새
  /// 출생정보 기반인데 최근 기록 day 0은 이전 값으로 남는다.
  ///
  /// daily와 **동시에** 읽으면 안 된다 — history가 daily의 Firestore write보다
  /// 먼저 끝나면 또 이전 문서를 읽는다. daily 성공 뒤에 순차로 읽는다.
  String? _refreshHistoryAfterDailyDateKey;

  DailyFortuneStatus get dailyStatus => _dailyStatus;
  FortuneHistoryStatus get historyStatus => _historyStatus;
  DailyFortune? get dailyFortune => _dailyFortune;
  List<FortuneHistoryEntry> get history => _history;
  UserProfile? get profile => _profile;
  ZodiacInfo? get zodiac => _zodiac;
  SajuInfo? get saju => _saju;
  String? get activeUid => _activeUid;
  String? get loadedDailyDateKey => _loadedDailyDateKey;
  String? get loadedHistoryDateKey => _loadedHistoryDateKey;
  String? get contextDateKey => _contextDateKey;
  int get dailyGeneration => _dailyGeneration;
  int get historyGeneration => _historyGeneration;

  /// 테스트·진단용. 진행 중인 요청이 있는지와 그 요청이 어느 날짜 것인지.
  bool get isDailyInFlight => _dailyInFlight;
  bool get isHistoryInFlight => _historyInFlight;
  String? get inFlightDailyDateKey => _activeDailyDateKey;
  String? get inFlightHistoryDateKey => _activeHistoryDateKey;

  /// 지금 이 순간의 KST 달력 날짜 key. 기기 시간대와 무관하다.
  String get currentDateKey => KstCalendarDate.fromInstant(_now()).dateKey;

  /// 화면 최초 진입. 중복 호출해도 요청은 한 번만 나간다.
  Future<void> loadInitial() async {
    if (_disposed || _initialLoadStarted) return;
    _initialLoadStarted = true;
    await refreshForCurrentContext();
  }

  /// 현재 계정·날짜 기준으로 아직 못 읽은 것만 읽는다.
  ///
  /// 같은 날짜에서 반복 호출해도 추가 요청이 나가지 않는다 — foreground 복귀가
  /// 매번 generateDailyFortune을 부르지 않도록 하는 지점이다.
  Future<void> refreshForCurrentContext() async {
    if (_disposed) return;
    final uid = _activeUid;
    if (uid == null) return;

    final dateKey = currentDateKey;
    _contextDateKey = dateKey;

    // "이미 읽었다"와 "이 날짜로 요청 중이다"만 재요청을 막는다. 다른 날짜의
    // 요청이 진행 중인 것은 재요청을 막을 이유가 되지 않는다.
    if (_loadedDailyDateKey != dateKey && _activeDailyDateKey != dateKey) {
      unawaited(_loadDaily(uid: uid, dateKey: dateKey));
    }
    if (_loadedHistoryDateKey != dateKey && _activeHistoryDateKey != dateKey) {
      unawaited(_loadHistory(uid: uid, dateKey: dateKey));
    }
  }

  /// 앱이 foreground로 돌아왔을 때. 날짜가 그대로면 아무 요청도 하지 않는다.
  Future<void> handleResume() async {
    if (_disposed) return;
    final dateKey = currentDateKey;
    if (_hasStaleDateContext(dateKey)) {
      _log('date_context_changed current_date_key=$dateKey');
      invalidateForDateChange();
    }
    await refreshForCurrentContext();
  }

  /// 로그인 계정이 바뀌었을 때(로그아웃이면 [uid]는 null).
  Future<void> updateAccount(String? uid) async {
    if (_disposed) return;
    if (_activeUid == uid) return;

    _log('account_context_changed signed_in=${uid != null}');
    // 진행 중인 이전 계정 요청을 먼저 무효화한다. 그래야 A의 응답이
    // B의 화면에 한 프레임도 나타나지 않는다.
    _invalidateInFlightRequests();

    _activeUid = uid;
    _contextDateKey = uid == null ? null : currentDateKey;
    _profile = null;
    _profileUid = null;
    _zodiac = null;
    _saju = null;
    _dailyFortune = null;
    _history = const [];
    _loadedDailyDateKey = null;
    _loadedHistoryDateKey = null;
    _dayZeroSyncedDateKey = null;
    _refreshHistoryAfterDailyDateKey = null;
    _dailyStatus = DailyFortuneStatus.idle;
    _historyStatus = FortuneHistoryStatus.idle;
    notifyListeners();

    if (uid == null) return;
    _initialLoadStarted = true;
    await refreshForCurrentContext();
  }

  /// 진행 중인 요청을 전부 무효화한다.
  ///
  /// 네트워크 요청을 물리적으로 취소하지는 않는다. 세대를 올리고 in-flight
  /// identity를 비워, 늦게 도착한 응답이 새 요청의 상태를 건드리지 못하게 한다.
  void _invalidateInFlightRequests() {
    _dailyGeneration += 1;
    _historyGeneration += 1;
    _activeDailyGeneration = null;
    _activeDailyDateKey = null;
    _activeHistoryGeneration = null;
    _activeHistoryDateKey = null;
  }

  /// KST 날짜가 넘어갔다. 어제 결과를 즉시 버린다.
  ///
  /// 어제 요청이 아직 끝나지 않았어도 기다리지 않는다 — 그대로 두면 어제
  /// 요청의 in-flight 상태가 오늘 요청 시작을 막아 loading에서 멈춘다.
  void invalidateForDateChange() {
    if (_disposed) return;
    _invalidateInFlightRequests();
    _contextDateKey = _activeUid == null ? null : currentDateKey;
    _dailyFortune = null;
    _history = const [];
    _loadedDailyDateKey = null;
    _loadedHistoryDateKey = null;
    _dayZeroSyncedDateKey = null;
    // 이전 날짜의 출생정보 갱신 예약을 다음 날짜로 넘기지 않는다.
    _refreshHistoryAfterDailyDateKey = null;
    _dailyStatus = _activeUid == null
        ? DailyFortuneStatus.idle
        : DailyFortuneStatus.loading;
    _historyStatus = _activeUid == null
        ? FortuneHistoryStatus.idle
        : FortuneHistoryStatus.loading;
    notifyListeners();
  }

  Future<void> retryDaily() async {
    if (_disposed) return;
    final uid = _activeUid;
    if (uid == null) return;
    _dailyGeneration += 1; // 진행 중이던 요청 결과는 버린다.
    _loadedDailyDateKey = null;
    await _loadDaily(uid: uid, dateKey: currentDateKey);
  }

  Future<void> retryHistory() async {
    if (_disposed) return;
    final uid = _activeUid;
    if (uid == null) return;
    _historyGeneration += 1;
    _loadedHistoryDateKey = null;
    await _loadHistory(uid: uid, dateKey: currentDateKey);
  }

  /// 출생시간 보완을 마친 직후.
  ///
  /// 단순 daily retry가 아니라 **같은 계정·같은 날짜의 계산 입력 변경**이다.
  /// 이전 출생정보로 만든 오늘 운세와 최근 기록 day 0을 먼저 지우고, 새 daily가
  /// 생성된 뒤에 최근 기록을 다시 읽는다. 과거 1~6일 기록은 그대로 둔다.
  Future<void> refreshAfterBirthProfileCompleted() async {
    if (_disposed) return;
    final uid = _activeUid;
    if (uid == null) return;
    final dateKey = currentDateKey;

    _log('birth_profile_changed date_key=$dateKey');
    // 진행 중이던 daily/history 응답은 모두 이전 출생정보 기준이다.
    _invalidateInFlightRequests();
    _contextDateKey = dateKey;
    _profile = null;
    _profileUid = null;
    _zodiac = null;
    _saju = null;
    _dailyFortune = null;
    _loadedDailyDateKey = null;
    _dayZeroSyncedDateKey = null;
    _clearHistoryDayZeroFortune(dateKey);
    _refreshHistoryAfterDailyDateKey = dateKey;
    _dailyStatus = DailyFortuneStatus.loading;
    notifyListeners();

    await _loadDaily(uid: uid, dateKey: dateKey);
  }

  /// 오늘 항목의 운세만 비우고 과거 기록은 유지한다.
  /// 이전 출생정보 기반 day 0을 한 프레임도 남기지 않기 위한 동기 처리다.
  void _clearHistoryDayZeroFortune(String dateKey) {
    if (_history.isEmpty) return;
    final dayZero = _history.first;
    if (dayZero.dateKey != dateKey || dayZero.fortune == null) return;
    _history = List.unmodifiable([
      FortuneHistoryEntry(dateKey: dayZero.dateKey, date: dayZero.date),
      ..._history.skip(1),
    ]);
  }

  /// 출생정보 변경 후 예약된 history 갱신을 소비한다. 날짜당 한 번만 실행된다.
  bool _consumeBirthProfileHistoryRefresh(String uid, String dateKey) {
    if (_refreshHistoryAfterDailyDateKey != dateKey) return false;
    _refreshHistoryAfterDailyDateKey = null;
    // 이 재조회가 day 0 대조를 겸한다. 뒤이어 또 보정이 돌지 않게 한다.
    _dayZeroSyncedDateKey = dateKey;
    _loadedHistoryDateKey = null;
    _log('history_refresh_after_birth_change date_key=$dateKey');
    unawaited(_loadHistory(uid: uid, dateKey: dateKey));
    return true;
  }

  bool get _dailyInFlight => _activeDailyGeneration != null;
  bool get _historyInFlight => _activeHistoryGeneration != null;

  Future<void> _loadDaily({required String uid, required String dateKey}) async {
    final generation = ++_dailyGeneration;
    _activeDailyGeneration = generation;
    _activeDailyDateKey = dateKey;
    _dailyFortune = null;
    _dailyStatus = DailyFortuneStatus.loading;
    notifyListeners();
    _log('request_started area=daily generation=$generation date_key=$dateKey');

    try {
      // 프로필은 계정 단위 캐시. 같은 계정이면 날짜가 바뀌어도 재조회하지 않는다.
      var profile = _profileUid == uid ? _profile : null;
      if (profile == null) {
        profile = await _loadProfile(uid);
        if (!_isDailyCurrent(generation, uid, dateKey)) return;
        if (profile == null) {
          _finishDaily(DailyFortuneStatus.error, generation);
          return;
        }
        _profile = profile;
        _profileUid = uid;
      }

      if (profile.birthProfile.needsCompletion) {
        _zodiac = null;
        _saju = null;
        // 출생정보를 채우기 전까지는 확정된 결론이다. foreground 복귀마다
        // 다시 판정하며 loading을 깜빡이지 않도록 날짜 context를 기록한다.
        _loadedDailyDateKey = dateKey;
        _finishDaily(DailyFortuneStatus.needsBirthProfile, generation);
        return;
      }

      // 요청에 쓴 날짜와 응답 판정에 쓸 날짜를 같은 instant에서 뽑는다.
      final requestInstant = _instantForDateKey(dateKey);
      final fortune = await _fortune.getDailyFortune(
        uid: uid,
        now: requestInstant,
      );

      if (!_isDailyCurrent(generation, uid, dateKey)) return;

      _zodiac = FortuneCalculator.getZodiacSign(profile.birthDate);
      _saju = FortuneCalculator.getSaju(profile.birthDate);
      _dailyFortune = fortune;
      _loadedDailyDateKey = dateKey;
      _finishDaily(DailyFortuneStatus.ready, generation);
      _log('request_succeeded area=daily generation=$generation');
      // 출생정보 변경 갱신이 예약돼 있으면 그쪽이 history를 담당한다.
      if (!_consumeBirthProfileHistoryRefresh(uid, dateKey)) {
        _maybeSyncHistoryDayZero();
      }
    } on FortuneFailure catch (failure) {
      if (!_isDailyCurrent(generation, uid, dateKey)) return;
      final status = dailyStatusForFailureCode(failure.code);
      _log('error_category=${failure.code} area=daily');
      if (status == null) {
        // unauthenticated: 인증 게이트가 처리할 몫이다. 결과만 비운다.
        _dailyFortune = null;
        _finishDaily(DailyFortuneStatus.idle, generation);
        return;
      }
      _finishDaily(status, generation);
    } catch (error) {
      if (!_isDailyCurrent(generation, uid, dateKey)) return;
      _log('error_category=unknown area=daily');
      _finishDaily(DailyFortuneStatus.error, generation);
    } finally {
      // stale 경로로 return했더라도 반드시 지난다. 단, 이 요청이 여전히
      // 현재 요청일 때만 비운다 — 옛 요청이 새 요청의 in-flight를 끄면
      // 그 자리에서 중복 요청이 시작된다.
      if (_activeDailyGeneration == generation) {
        _activeDailyGeneration = null;
        _activeDailyDateKey = null;
      }
    }
  }

  Future<void> _loadHistory({
    required String uid,
    required String dateKey,
  }) async {
    final generation = ++_historyGeneration;
    _activeHistoryGeneration = generation;
    _activeHistoryDateKey = dateKey;
    _history = const [];
    _historyStatus = FortuneHistoryStatus.loading;
    notifyListeners();
    _log(
      'request_started area=history generation=$generation date_key=$dateKey',
    );

    try {
      final entries = await _fortune.getFortuneHistory(
        uid: uid,
        days: _historyDays,
        now: _instantForDateKey(dateKey),
      );
      if (!_isHistoryCurrent(generation, uid, dateKey)) return;
      _history = List.unmodifiable(entries);
      _loadedHistoryDateKey = dateKey;
      _historyStatus = FortuneHistoryStatus.ready;
      _log(
        'request_succeeded area=history generation=$generation '
        'day_count=${entries.length}',
      );
      notifyListeners();
      // day 0 보정은 이 요청이 in-flight에서 빠진 뒤에 판단해야 한다.
      // 그래야 보정 재조회가 자기 자신에게 막히지 않는다.
      _releaseHistoryRequest(generation);
      _maybeSyncHistoryDayZero();
    } on FortuneFailure catch (failure) {
      if (!_isHistoryCurrent(generation, uid, dateKey)) return;
      _log('error_category=${failure.code} area=history');
      _finishHistoryError(dateKey);
    } catch (error) {
      if (!_isHistoryCurrent(generation, uid, dateKey)) return;
      _log('error_category=unknown area=history');
      _finishHistoryError(dateKey);
    } finally {
      _releaseHistoryRequest(generation);
    }
  }

  void _releaseHistoryRequest(int generation) {
    if (_activeHistoryGeneration == generation) {
      _activeHistoryGeneration = null;
      _activeHistoryDateKey = null;
    }
  }

  /// 오늘 운세를 방금 만들었으면 최근 기록의 day 0이 비어 있을 수 있다.
  /// 그 경우에만 history를 **한 번** 다시 읽는다. history는 callable을
  /// 부르지 않으므로 daily를 되부르는 순환이 생기지 않는다.
  void _maybeSyncHistoryDayZero() {
    if (_disposed) return;
    if (_dailyStatus != DailyFortuneStatus.ready) return;
    if (_historyStatus != FortuneHistoryStatus.ready) return;

    final uid = _activeUid;
    if (uid == null) return;
    final dateKey = currentDateKey;
    if (_loadedDailyDateKey != dateKey) return;
    if (_loadedHistoryDateKey != dateKey) return;
    if (_dayZeroSyncedDateKey == dateKey) return;

    _dayZeroSyncedDateKey = dateKey;

    final dayZero = _history.isEmpty ? null : _history.first;
    final needsSync =
        dayZero == null ||
        dayZero.dateKey != dateKey ||
        dayZero.fortune == null;
    if (!needsSync) return;

    _loadedHistoryDateKey = null;
    unawaited(_loadHistory(uid: uid, dateKey: dateKey));
  }

  void _finishDaily(DailyFortuneStatus status, int generation) {
    if (generation != _dailyGeneration) return;
    if (status != DailyFortuneStatus.ready) _dailyFortune = null;
    _dailyStatus = status;
    notifyListeners();
  }

  void _finishHistoryError(String dateKey) {
    _history = const [];
    _historyStatus = FortuneHistoryStatus.error;
    // 보정 재조회가 실패했다면 "이 날짜는 확인 끝"으로 굳히지 않는다.
    // 사용자가 retryHistory로 복구하면 day 0을 다시 대조할 수 있어야 한다.
    if (_dayZeroSyncedDateKey == dateKey) _dayZeroSyncedDateKey = null;
    notifyListeners();
  }

  /// 이 daily 요청이 아직 유효한가: 최신 세대 + 같은 계정 + 같은 KST 날짜.
  bool _isDailyCurrent(int generation, String uid, String dateKey) {
    if (_disposed) return false;
    if (generation != _dailyGeneration) {
      _log('stale_response_ignored area=daily generation=$generation');
      return false;
    }
    if (_activeUid != uid || currentDateKey != dateKey) {
      _log('stale_response_ignored area=daily reason=context');
      return false;
    }
    return true;
  }

  bool _isHistoryCurrent(int generation, String uid, String dateKey) {
    if (_disposed) return false;
    if (generation != _historyGeneration) {
      _log('stale_response_ignored area=history generation=$generation');
      return false;
    }
    if (_activeUid != uid || currentDateKey != dateKey) {
      _log('stale_response_ignored area=history reason=context');
      return false;
    }
    return true;
  }

  /// 완료된 결과뿐 아니라 **진행 중인 요청과 controller context**까지 본다.
  /// 초기 요청이 아직 끝나지 않은 채로 자정을 넘긴 경우가 여기서 걸린다.
  bool _hasStaleDateContext(String dateKey) {
    for (final candidate in [
      _contextDateKey,
      _loadedDailyDateKey,
      _loadedHistoryDateKey,
      _activeDailyDateKey,
      _activeHistoryDateKey,
    ]) {
      if (candidate != null && candidate != dateKey) return true;
    }
    return false;
  }

  /// 서비스가 다시 KST 날짜를 계산해도 [dateKey]와 같은 값이 나오는 instant.
  /// 달력 날짜(정오 KST = 03:00 UTC)를 쓰면 경계에서 흔들리지 않는다.
  static DateTime _instantForDateKey(String dateKey) {
    final parts = dateKey.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final day = int.parse(parts[2]);
    return DateTime.utc(year, month, day, 3);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[FortuneHub] $message');
  }
}

/// 서버 실패 코드를 화면 상태로 축약한다.
///
/// null을 돌려주면 "표시할 오류가 아니다"(unauthenticated — 인증 게이트 몫).
DailyFortuneStatus? dailyStatusForFailureCode(String code) {
  switch (code) {
    case 'failed-precondition':
      return DailyFortuneStatus.needsBirthProfile;
    case 'resource-exhausted':
      return DailyFortuneStatus.rateLimited;
    case 'unavailable':
    case 'deadline-exceeded':
      return DailyFortuneStatus.unavailable;
    case 'unauthenticated':
      return null;
    default:
      return DailyFortuneStatus.error;
  }
}
