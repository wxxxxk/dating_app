import 'package:cloud_firestore/cloud_firestore.dart';

import 'saju_birth_input.dart';
import 'saju_convention.dart';

/// 출생정보의 정밀도 상태 (Phase 5-2).
///
/// [legacyMissing]은 "시간을 모른다"와 **다르다**. 아직 물어본 적이 없다는 뜻이며,
/// 이 상태를 임의로 unknown으로 확정하거나 정오를 대입하지 않는다.
enum BirthProfileStatus {
  /// Phase 5-2 이전에 가입해 출생시간을 물어본 적이 없는 상태.
  legacyMissing,

  /// 사용자가 "시간을 몰라요"를 선택한 상태. 시주를 계산하지 않는다.
  dateOnly,

  /// 사용자가 태어난 시각을 입력한 상태.
  dateAndTime,
}

/// `users/{uid}` 비공개 문서의 출생정보.
///
/// 공개 프로필(`publicProfiles`)·커뮤니티 스냅샷 등 어떤 공개 모델에도 담지
/// 않는다. 사주 계산의 최종 권한은 서버에 있고, 이 모델은 입력 상태를 화면이
/// 판단하기 위한 것이다.
class BirthProfile {
  /// 현재 정식 지원하는 유일한 달력.
  static const String solarCalendar = 'solar';

  /// 현재 정식 지원하는 유일한 시간대.
  static const String seoulTimeZone = 'Asia/Seoul';

  /// 서버 `SAJU_CONVENTION_VERSION`과 맞춘 입력 스키마 버전.
  static const int currentInputVersion = 2;

  /// 자정으로부터의 분. 0~1439.
  static const int minMinutes = 0;
  static const int maxMinutes = 1439;

  /// 출생시간을 아는지. **null이면 아직 물어보지 않은 상태**([legacyMissing]).
  final bool? timeKnown;

  /// 자정으로부터의 분. [timeKnown]이 true일 때만 값이 있다.
  final int? minutes;

  final String calendarType;
  final String timeZone;

  const BirthProfile({
    required this.timeKnown,
    required this.minutes,
    this.calendarType = solarCalendar,
    this.timeZone = seoulTimeZone,
  });

  /// 출생시간을 물어본 적이 없는 기존 사용자 상태.
  const BirthProfile.legacyMissing()
    : timeKnown = null,
      minutes = null,
      calendarType = solarCalendar,
      timeZone = seoulTimeZone;

  /// 사용자가 "몰라요"를 선택한 상태.
  const BirthProfile.unknownTime()
    : timeKnown = false,
      minutes = null,
      calendarType = solarCalendar,
      timeZone = seoulTimeZone;

  /// 사용자가 시각을 입력한 상태.
  const BirthProfile.knownTime(int this.minutes)
    : timeKnown = true,
      calendarType = solarCalendar,
      timeZone = seoulTimeZone;

  factory BirthProfile.fromMap(Map<String, dynamic> data) {
    final known = data['birthTimeKnown'];
    if (known is! bool) return const BirthProfile.legacyMissing();
    final rawMinutes = data['birthTimeMinutes'];
    return BirthProfile(
      timeKnown: known,
      minutes: known && rawMinutes is int ? rawMinutes : null,
      calendarType: data['birthCalendarType'] as String? ?? solarCalendar,
      timeZone: data['birthTimeZone'] as String? ?? seoulTimeZone,
    );
  }

  BirthProfileStatus get status {
    if (timeKnown == null) return BirthProfileStatus.legacyMissing;
    return timeKnown!
        ? BirthProfileStatus.dateAndTime
        : BirthProfileStatus.dateOnly;
  }

  /// 출생시간 보완 안내를 띄워야 하는지.
  bool get needsCompletion => status == BirthProfileStatus.legacyMissing;

  /// 시주를 계산할 수 있는 상태인지.
  bool get hasKnownTime => status == BirthProfileStatus.dateAndTime;

  /// 저장 계약을 지키는 값인지. 화면과 서버가 같은 불변식을 쓴다.
  bool get isValid {
    if (calendarType != solarCalendar || timeZone != seoulTimeZone) return false;
    if (timeKnown == null) return minutes == null;
    if (timeKnown!) {
      return minutes != null && minutes! >= minMinutes && minutes! <= maxMinutes;
    }
    return minutes == null;
  }

  /// Phase 5-1의 계산 입력 계약으로 변환한다. 시각을 모르면 dateOnly가 된다.
  SajuBirthInput toSajuInput(DateTime birthDate) {
    return SajuBirthInput(
      calendarType: SajuCalendarType.solar,
      year: birthDate.year,
      month: birthDate.month,
      day: birthDate.day,
      birthTime: hasKnownTime ? formatClock(minutes!) : null,
      timeZone: timeZone,
      lunarLeapMonth: null,
    );
  }

  /// 신규 가입 시 `users/{uid}`에 함께 쓰는 필드.
  Map<String, dynamic> toFirestoreFields() {
    return {
      'birthCalendarType': calendarType,
      'birthTimeKnown': timeKnown,
      'birthTimeMinutes': timeKnown == true ? minutes : null,
      'birthTimeZone': timeZone,
      'sajuInputVersion': currentInputVersion,
      'birthProfileUpdatedAt': FieldValue.serverTimestamp(),
    };
  }

  /// 'HH:mm' 24시간 표기. 정규화 저장값과 별개로 계산 입력에만 쓴다.
  static String formatClock(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 화면 표시용 한국어 표기. 예: 455 → '오전 7:35', 1390 → '오후 11:10'
  static String formatKorean(int minutes) {
    final hour24 = minutes ~/ 60;
    final minute = minutes % 60;
    final period = hour24 < 12 ? '오전' : '오후';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    return '$period $hour12:${minute.toString().padLeft(2, '0')}';
  }

  /// 이 앱이 채택한 계산 convention. 서버와 같은 값을 쓴다.
  static const SajuConvention convention = currentConvention;
}
