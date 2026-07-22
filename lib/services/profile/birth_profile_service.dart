import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../models/fortune/birth_profile.dart';

/// 출생정보 저장/수정 서비스 (Phase 5-2).
///
/// 출생정보는 사주 계산의 유일한 근거이자 민감한 비공개 데이터라, 클라이언트가
/// Firestore에 직접 쓰지 않고 `updateMyBirthProfile` callable의 서버 검증을
/// 거친다. 서버가 날짜 실재 여부·연령·시간 계약을 모두 다시 확인한다.
class BirthProfileService {
  BirthProfileService({FirebaseFunctions? functions})
    : _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFunctions _functions;

  /// 출생정보를 저장한다. 성공하면 서버가 확정한 precision을 돌려준다.
  Future<BirthProfileSaveResult> save({
    required DateTime birthDate,
    required BirthProfile birthProfile,
  }) async {
    if (!birthProfile.isValid || birthProfile.needsCompletion) {
      throw const BirthProfileFailure('invalid-argument');
    }
    try {
      final callable = _functions.httpsCallable('updateMyBirthProfile');
      final result = await callable.call({
        'birthDateMillis': birthDate.millisecondsSinceEpoch,
        'birthCalendarType': birthProfile.calendarType,
        'birthTimeKnown': birthProfile.timeKnown,
        'birthTimeMinutes': birthProfile.timeKnown == true
            ? birthProfile.minutes
            : null,
        'birthTimeZone': birthProfile.timeZone,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      return BirthProfileSaveResult(
        timeKnown: data['birthTimeKnown'] as bool? ?? false,
        precision: data['precision'] as String? ?? 'dateOnly',
      );
    } on FirebaseFunctionsException catch (e) {
      final code = BirthProfileFailure.safeCode(e.code);
      if (kDebugMode) {
        debugPrint('[BirthProfileService] save_failed code=$code');
      }
      throw BirthProfileFailure(code);
    }
  }
}

class BirthProfileSaveResult {
  final bool timeKnown;
  final String precision;

  const BirthProfileSaveResult({
    required this.timeKnown,
    required this.precision,
  });
}

/// 화면에 노출해도 안전한 실패 코드만 남긴다. 서버 메시지는 그대로 쓰지 않는다.
class BirthProfileFailure implements Exception {
  final String code;

  const BirthProfileFailure(this.code);

  static const _allowedCodes = {
    'unauthenticated',
    'permission-denied',
    'invalid-argument',
    'not-found',
    'failed-precondition',
    'resource-exhausted',
    'unavailable',
    'deadline-exceeded',
    'internal',
    'unknown',
  };

  static String safeCode(String code) =>
      _allowedCodes.contains(code) ? code : 'unknown';
}
