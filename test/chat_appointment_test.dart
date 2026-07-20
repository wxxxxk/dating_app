import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/chat_appointment.dart';
import 'package:dating_app/models/message_model.dart';
import 'package:dating_app/services/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatAppointment.fromMap', () {
    Map<String, dynamic> validDoc() => {
      'proposerUid': 'userA',
      'recipientUid': 'userB',
      'scheduledAt': Timestamp.fromDate(DateTime(2026, 7, 24, 19)),
      'place': '성수역 3번 출구',
      'note': '근처 카페에서 만나요',
      'status': 'pending',
      'createdAt': Timestamp.fromDate(DateTime(2026, 7, 20, 10)),
      'respondedAt': null,
      'respondedBy': null,
    };

    test('정상 문서를 파싱한다', () {
      final a = ChatAppointment.fromMap('apt1', validDoc());
      expect(a, isNotNull);
      expect(a!.proposerUid, 'userA');
      expect(a.recipientUid, 'userB');
      expect(a.place, '성수역 3번 출구');
      expect(a.note, '근처 카페에서 만나요');
      expect(a.status, ChatAppointmentStatus.pending);
      expect(a.scheduledAt, DateTime(2026, 7, 24, 19));
      expect(a.isProposer('userA'), isTrue);
      expect(a.isRecipient('userB'), isTrue);
    });

    test('null 데이터는 null을 반환한다(crash 없음)', () {
      expect(ChatAppointment.fromMap('apt1', null), isNull);
    });

    test('필수 필드 누락/타입 오류는 null을 반환한다', () {
      final missingProposer = validDoc()..remove('proposerUid');
      expect(ChatAppointment.fromMap('apt1', missingProposer), isNull);

      final badScheduledAt = validDoc()..['scheduledAt'] = 'not-a-timestamp';
      expect(ChatAppointment.fromMap('apt1', badScheduledAt), isNull);

      final emptyRecipient = validDoc()..['recipientUid'] = '';
      expect(ChatAppointment.fromMap('apt1', emptyRecipient), isNull);
    });

    test('알 수 없는 status는 pending으로 폴백한다', () {
      final doc = validDoc()..['status'] = 'weird_value';
      final a = ChatAppointment.fromMap('apt1', doc);
      expect(a!.status, ChatAppointmentStatus.pending);
    });

    test('place/note가 문자열이 아니면 빈 문자열로 폴백한다', () {
      final doc = validDoc()
        ..['place'] = 123
        ..['note'] = null;
      final a = ChatAppointment.fromMap('apt1', doc);
      expect(a!.place, '');
      expect(a.note, '');
    });
  });

  group('MessageModel.fromMap type 파싱 (하위 호환)', () {
    test('type 필드가 없으면 text로 파싱한다', () {
      final m = MessageModel.fromMap('m1', {
        'senderId': 'u1',
        'text': '안녕하세요',
      });
      expect(m.type, ChatMessageType.text);
      expect(m.isPlainText, isTrue);
      expect(m.isAppointment, isFalse);
      expect(m.text, '안녕하세요');
    });

    test('알 수 없는 type도 안전하게 text로 파싱한다', () {
      final m = MessageModel.fromMap('m1', {
        'senderId': 'u1',
        'text': 'x',
        'type': 'mystery_type',
      });
      expect(m.type, ChatMessageType.text);
      expect(m.isPlainText, isTrue);
    });

    test('appointment 메시지를 파싱한다', () {
      final m = MessageModel.fromMap('m1', {
        'senderId': 'u1',
        'text': '약속을 제안했어요.',
        'type': 'appointment',
        'appointmentId': 'apt1',
      });
      expect(m.type, ChatMessageType.appointment);
      expect(m.appointmentId, 'apt1');
      expect(m.isAppointment, isTrue);
      expect(m.isPlainText, isFalse);
    });

    test('appointmentId가 비면 약속 메시지라도 text로 폴백한다', () {
      final m = MessageModel.fromMap('m1', {
        'senderId': 'u1',
        'text': '약속을 제안했어요.',
        'type': 'appointment',
        'appointmentId': '',
      });
      expect(m.isAppointment, isFalse);
      expect(m.isPlainText, isTrue);
    });

    test('appointment_response 메시지와 상태를 파싱한다', () {
      final m = MessageModel.fromMap('m1', {
        'senderId': 'u1',
        'text': '약속을 수락했어요.',
        'type': 'appointment_response',
        'appointmentId': 'apt1',
        'appointmentStatus': 'accepted',
      });
      expect(m.type, ChatMessageType.appointmentResponse);
      expect(m.isAppointmentResponse, isTrue);
      expect(m.appointmentStatus, ChatAppointmentStatus.accepted);
    });
  });

  group('ChatService.normalizeAppointmentInput', () {
    final now = DateTime(2026, 7, 20, 12);

    test('trim 후 정상 입력을 반환한다', () {
      final r = ChatService.normalizeAppointmentInput(
        scheduledAt: DateTime(2026, 7, 24, 19),
        place: '  성수역 3번 출구  ',
        note: '  카페  ',
        now: now,
      );
      expect(r.place, '성수역 3번 출구');
      expect(r.note, '카페');
    });

    test('과거 시간은 거부한다', () {
      expect(
        () => ChatService.normalizeAppointmentInput(
          scheduledAt: DateTime(2026, 7, 19, 19),
          place: '성수역',
          note: '',
          now: now,
        ),
        throwsA(isA<AppointmentValidationError>()),
      );
    });

    test('장소 미입력은 거부한다', () {
      expect(
        () => ChatService.normalizeAppointmentInput(
          scheduledAt: DateTime(2026, 7, 24, 19),
          place: '   ',
          note: '',
          now: now,
        ),
        throwsA(isA<AppointmentValidationError>()),
      );
    });

    test('장소 80자 초과는 거부한다', () {
      expect(
        () => ChatService.normalizeAppointmentInput(
          scheduledAt: DateTime(2026, 7, 24, 19),
          place: 'a' * 81,
          note: '',
          now: now,
        ),
        throwsA(isA<AppointmentValidationError>()),
      );
    });

    test('메모 200자 초과는 거부한다', () {
      expect(
        () => ChatService.normalizeAppointmentInput(
          scheduledAt: DateTime(2026, 7, 24, 19),
          place: '성수역',
          note: 'a' * 201,
          now: now,
        ),
        throwsA(isA<AppointmentValidationError>()),
      );
    });
  });

  group('ChatService payload builders', () {
    final marker = Timestamp.fromDate(DateTime(2026, 7, 20, 10));

    test('propose appointment 문서 구조', () {
      final doc = ChatService.buildAppointmentDoc(
        proposerUid: 'userA',
        recipientUid: 'userB',
        scheduledAt: DateTime(2026, 7, 24, 19),
        place: '성수역 3번 출구',
        note: '카페',
        createdAt: marker,
      );
      expect(doc['proposerUid'], 'userA');
      expect(doc['recipientUid'], 'userB');
      expect(doc['scheduledAt'], Timestamp.fromDate(DateTime(2026, 7, 24, 19)));
      expect(doc['place'], '성수역 3번 출구');
      expect(doc['note'], '카페');
      expect(doc['status'], 'pending');
      expect(doc['createdAt'], marker);
      expect(doc['respondedAt'], isNull);
      expect(doc['respondedBy'], isNull);
      expect(doc.keys.toSet(), {
        'proposerUid',
        'recipientUid',
        'scheduledAt',
        'place',
        'note',
        'status',
        'createdAt',
        'respondedAt',
        'respondedBy',
      });
    });

    test('propose appointment 메시지 구조', () {
      final msg = ChatService.buildAppointmentMessageDoc(
        senderId: 'userA',
        appointmentId: 'apt1',
        createdAt: marker,
      );
      expect(msg['senderId'], 'userA');
      expect(msg['text'], '약속을 제안했어요.');
      expect(msg['type'], 'appointment');
      expect(msg['appointmentId'], 'apt1');
      expect(msg['createdAt'], marker);
    });

    test('accept 응답 메시지 구조', () {
      final msg = ChatService.buildAppointmentResponseMessageDoc(
        senderId: 'userB',
        appointmentId: 'apt1',
        status: ChatAppointmentStatus.accepted,
        createdAt: marker,
      );
      expect(msg['text'], '약속을 수락했어요.');
      expect(msg['type'], 'appointment_response');
      expect(msg['appointmentStatus'], 'accepted');
      expect(msg['appointmentId'], 'apt1');
    });

    test('decline 응답 메시지 구조', () {
      final msg = ChatService.buildAppointmentResponseMessageDoc(
        senderId: 'userB',
        appointmentId: 'apt1',
        status: ChatAppointmentStatus.declined,
        createdAt: marker,
      );
      expect(msg['text'], '이번 약속은 어려워요.');
      expect(msg['appointmentStatus'], 'declined');
    });
  });

  group('ChatService.respondToAppointment invalid status', () {
    test('pending 응답은 ArgumentError', () async {
      final service = ChatService(firestore: _ThrowingFirestore());
      await expectLater(
        service.respondToAppointment(
          matchId: 'm1',
          appointmentId: 'apt1',
          responderUid: 'userB',
          status: ChatAppointmentStatus.pending,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

/// respond의 status 검증이 Firestore 접근 이전에 일어나는지 확인하기 위한 스텁.
/// 검증을 통과하면 이 인스턴스를 건드리게 되고, pending이면 건드리기 전에 던진다.
class _ThrowingFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError('Firestore should not be touched for invalid status');
  }
}
