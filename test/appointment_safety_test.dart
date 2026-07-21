import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/appointment_safety_checkin.dart';
import 'package:dating_app/services/chat/appointment_safety_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2-5 — 안전 확인 모델·순수 함수·payload 계약 테스트.
///
/// 실제 Firestore transaction 경로는 Emulator rules 테스트가 검증하고, 여기서는
/// 파싱·단계 판정·문서 경로/필드 계약을 Firebase 없이 확인한다.
final _scheduled = DateTime(2026, 7, 25, 19);

void main() {
  group('모델 파싱', () {
    test('1. 정상 문서를 파싱한다', () {
      final parsed = AppointmentSafetyCheckin.fromMap('userA', {
        'uid': 'userA',
        'preCheckCompletedAt': Timestamp.fromDate(DateTime(2026, 7, 25, 12)),
        'postStatus': 'needs_support',
        'postCheckedAt': Timestamp.fromDate(DateTime(2026, 7, 25, 22)),
        'updatedAt': Timestamp.fromDate(DateTime(2026, 7, 25, 22)),
      });

      expect(parsed, isNotNull);
      expect(parsed!.uid, 'userA');
      expect(parsed.preCheckCompletedAt, DateTime(2026, 7, 25, 12));
      expect(parsed.postStatus, AppointmentPostSafetyStatus.needsSupport);
      expect(parsed.postCheckedAt, DateTime(2026, 7, 25, 22));
      expect(parsed.hasCompletedPreCheck, isTrue);
      expect(parsed.hasCompletedPostCheck, isTrue);
      expect(parsed.needsSupport, isTrue);
    });

    test('2. malformed Timestamp는 crash 없이 null로 처리한다', () {
      final parsed = AppointmentSafetyCheckin.fromMap('userA', {
        'uid': 42,
        'preCheckCompletedAt': 'not-a-timestamp',
        'postStatus': 'safe',
        'postCheckedAt': 12345,
        'updatedAt': null,
        // unknown field는 무시한다
        'location': {'lat': 1, 'lng': 2},
      });

      expect(parsed, isNotNull);
      expect(parsed!.preCheckCompletedAt, isNull);
      expect(parsed.postCheckedAt, isNull);
      expect(parsed.updatedAt, isNull);
      expect(parsed.postStatus, AppointmentPostSafetyStatus.safe);
      expect(parsed.hasCompletedPreCheck, isFalse);
      expect(AppointmentSafetyCheckin.fromMap('userA', null), isNull);
      expect(AppointmentSafetyCheckin.fromMap('', {}), isNull);
    });

    test('3. 알 수 없는 postStatus는 null로 둔다', () {
      final parsed = AppointmentSafetyCheckin.fromMap('userA', {
        'uid': 'userA',
        'postStatus': 'exploded',
        'postCheckedAt': Timestamp.now(),
      });

      expect(parsed!.postStatus, isNull);
      expect(parsed.hasCompletedPostCheck, isFalse);
      expect(parsed.needsSupport, isFalse);
      // 상태가 없으면 기록 시각도 비운다.
      expect(parsed.postCheckedAt, isNull);
    });

    test('status 문자열 변환은 왕복한다', () {
      for (final status in AppointmentPostSafetyStatus.values) {
        final raw = appointmentPostSafetyStatusToString(status);
        expect(appointmentPostSafetyStatusFromString(raw), status);
      }
      expect(appointmentPostSafetyStatusToString(
        AppointmentPostSafetyStatus.needsSupport,
      ), 'needs_support');
      expect(appointmentPostSafetyStatusFromString(null), isNull);
    });
  });

  group('4~6. 단계 판정', () {
    test('4. 약속 시각 전이면 preDate', () {
      expect(
        appointmentSafetyPhase(
          scheduledAt: _scheduled,
          now: _scheduled.subtract(const Duration(minutes: 1)),
        ),
        AppointmentSafetyPhase.preDate,
      );
    });

    test('5. 약속 시각 이후(같은 시각 포함)면 postDate', () {
      expect(
        appointmentSafetyPhase(scheduledAt: _scheduled, now: _scheduled),
        AppointmentSafetyPhase.postDate,
      );
      expect(
        appointmentSafetyPhase(
          scheduledAt: _scheduled,
          now: _scheduled.add(const Duration(hours: 3)),
        ),
        AppointmentSafetyPhase.postDate,
      );
    });

    test('6. helper 상태값', () {
      const empty = AppointmentSafetyCheckin(
        uid: 'userA',
        preCheckCompletedAt: null,
        postStatus: null,
        postCheckedAt: null,
        updatedAt: null,
      );
      expect(empty.hasCompletedPreCheck, isFalse);
      expect(empty.hasCompletedPostCheck, isFalse);
      expect(empty.needsSupport, isFalse);

      final safe = AppointmentSafetyCheckin(
        uid: 'userA',
        preCheckCompletedAt: _scheduled,
        postStatus: AppointmentPostSafetyStatus.safe,
        postCheckedAt: _scheduled,
        updatedAt: _scheduled,
      );
      expect(safe.hasCompletedPreCheck, isTrue);
      expect(safe.hasCompletedPostCheck, isTrue);
      expect(safe.needsSupport, isFalse);
    });
  });

  group('서비스 계약', () {
    test('1. 문서 경로는 appointments 하위 safetyCheckins/{uid}다', () {
      expect(
        AppointmentSafetyService.checkinPath(
          matchId: 'match1',
          appointmentId: 'apt1',
          uid: 'userA',
        ),
        'matches/match1/appointments/apt1/safetyCheckins/userA',
      );
    });

    test('2. pre check 최초 payload는 다섯 필드를 모두 담는다', () {
      final doc = AppointmentSafetyService.buildInitialCheckinDoc(
        uid: 'userA',
        timestamp: 'ts',
        preCheckCompletedAt: 'ts',
      );

      expect(doc, {
        'uid': 'userA',
        'preCheckCompletedAt': 'ts',
        'postStatus': null,
        'postCheckedAt': null,
        'updatedAt': 'ts',
      });
    });

    test('post 최초 payload는 상태와 기록 시각을 함께 담는다', () {
      final doc = AppointmentSafetyService.buildInitialCheckinDoc(
        uid: 'userA',
        timestamp: 'ts',
        postStatus: AppointmentPostSafetyStatus.needsSupport,
      );

      expect(doc['postStatus'], 'needs_support');
      expect(doc['postCheckedAt'], 'ts');
      expect(doc['preCheckCompletedAt'], isNull);
    });

    test('11. payload에 위치·연락처·체크리스트 답변 필드가 없다', () {
      final doc = AppointmentSafetyService.buildInitialCheckinDoc(
        uid: 'userA',
        timestamp: 'ts',
        preCheckCompletedAt: 'ts',
        postStatus: AppointmentPostSafetyStatus.safe,
      );

      expect(doc.keys.toSet(), {
        'uid',
        'preCheckCompletedAt',
        'postStatus',
        'postCheckedAt',
        'updatedAt',
      });
      for (final forbidden in [
        'location',
        'checklist',
        'answers',
        'emergencyContact',
        'phone',
        'note',
        'reportDetail',
      ]) {
        expect(doc.containsKey(forbidden), isFalse, reason: '$forbidden 미저장');
      }
    });

    test('8. 약속 시간 전 post check는 검증 오류로 거부된다', () async {
      final service = AppointmentSafetyService(firestore: _NeverCalledDb());
      await expectLater(
        service.completePostCheck(
          matchId: 'match1',
          appointmentId: 'apt1',
          uid: 'userA',
          scheduledAt: _scheduled,
          status: AppointmentPostSafetyStatus.safe,
          now: _scheduled.subtract(const Duration(minutes: 1)),
        ),
        throwsA(isA<AppointmentSafetyValidationError>()),
      );
    });

    test('빈 uid는 ArgumentError로 거부된다', () async {
      final service = AppointmentSafetyService(firestore: _NeverCalledDb());
      await expectLater(
        service.completePreCheck(
          matchId: 'match1',
          appointmentId: 'apt1',
          uid: '',
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.completePostCheck(
          matchId: 'match1',
          appointmentId: 'apt1',
          uid: '',
          scheduledAt: _scheduled,
          status: AppointmentPostSafetyStatus.safe,
          now: _scheduled.add(const Duration(hours: 1)),
        ),
        throwsArgumentError,
      );
    });
  });
}

/// 검증 단계에서 걸러져 Firestore에 절대 닿지 않아야 하는 경로를 확인하기 위한
/// 스텁. 실제로 호출되면 NoSuchMethodError로 테스트가 실패한다.
class _NeverCalledDb extends Fake implements FirebaseFirestore {}
