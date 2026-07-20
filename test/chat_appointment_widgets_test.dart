import 'dart:async';

import 'package:dating_app/features/chat/chat_appointment_widgets.dart';
import 'package:dating_app/models/chat_appointment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatAppointment _apt({
  required ChatAppointmentStatus status,
  String proposer = 'userA',
  String recipient = 'userB',
  String note = '카페에서 만나요',
}) {
  return ChatAppointment(
    id: 'apt1',
    proposerUid: proposer,
    recipientUid: recipient,
    scheduledAt: DateTime(2026, 7, 24, 19),
    place: '성수역 3번 출구',
    note: note,
    status: status,
    createdAt: DateTime(2026, 7, 20, 10),
    respondedAt: null,
    respondedBy: null,
  );
}

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

/// 시트를 pushed route로 열어 pop(성공 시)이 안전하게 동작하도록 한다.
Future<void> _openSheet(
  WidgetTester tester,
  AppointmentProposalSheet sheet,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => Scaffold(body: sheet)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('1. 캘린더 약속 버튼이 표시된다', (tester) async {
    await tester.pumpWidget(_host(ChatAppointmentButton(onPressed: () {})));
    expect(find.byKey(const ValueKey('chat-appointment-button')), findsOneWidget);
    expect(find.byIcon(Icons.calendar_month_rounded), findsOneWidget);
  });

  testWidgets('2. onPressed가 null이면 버튼이 비활성화된다(blocked/unmatched/제출 중)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const ChatAppointmentButton(onPressed: null)),
    );
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('chat-appointment-button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('3. 정상 입력 제출 시 onSubmit이 정확히 1회 호출된다(중복 제출 방지)', (
    tester,
  ) async {
    var calls = 0;
    final completer = Completer<bool>();
    DateTime? submittedAt;
    String? submittedPlace;
    final sheet = AppointmentProposalSheet(
      initialDate: DateTime(2026, 7, 24),
      initialTime: const TimeOfDay(hour: 19, minute: 0),
      now: DateTime(2026, 7, 20, 12),
      onSubmit: ({required scheduledAt, required place, required note}) {
        calls++;
        submittedAt = scheduledAt;
        submittedPlace = place;
        return completer.future;
      },
    );
    await _openSheet(tester, sheet);

    await tester.enterText(
      find.byKey(const ValueKey('chat-appointment-place')),
      '성수역 3번 출구',
    );
    await tester.pump();
    // 첫 제출은 in-flight 상태로 두고, 그 동안 다시 탭해도 무시되는지 확인한다.
    await tester.tap(find.byKey(const ValueKey('chat-appointment-submit')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('chat-appointment-submit')),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(calls, 1);
    expect(submittedAt, DateTime(2026, 7, 24, 19));
    expect(submittedPlace, '성수역 3번 출구');

    completer.complete(true);
    await tester.pumpAndSettle();
  });

  testWidgets('4. 과거 시간 제출은 거부되고 onSubmit이 호출되지 않는다', (tester) async {
    var calls = 0;
    final sheet = AppointmentProposalSheet(
      initialDate: DateTime(2026, 7, 20),
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      now: DateTime(2026, 7, 20, 12),
      onSubmit: ({required scheduledAt, required place, required note}) async {
        calls++;
        return true;
      },
    );
    await _openSheet(tester, sheet);

    await tester.enterText(
      find.byKey(const ValueKey('chat-appointment-place')),
      '성수역',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-appointment-submit')));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byKey(const ValueKey('chat-appointment-error')), findsOneWidget);
  });

  testWidgets('12. 키보드가 올라와도 시트에 overflow가 없다', (tester) async {
    final sheet = AppointmentProposalSheet(
      onSubmit: ({required scheduledAt, required place, required note}) async =>
          true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 320)),
          child: Scaffold(body: sheet),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // overflow가 있으면 tester가 예외를 던진다. 여기까지 오면 통과.
    expect(tester.takeException(), isNull);
    expect(find.text('약속 제안하기'), findsWidgets);
  });

  testWidgets('6. pending 제안자 카드는 대기 문구를 보이고 버튼이 없다', (tester) async {
    await tester.pumpWidget(
      _host(
        AppointmentMessageCard(
          appointmentId: 'apt1',
          currentUid: 'userA', // proposer
          stream: Stream.value(_apt(status: ChatAppointmentStatus.pending)),
          onRespond: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-appointment-card-apt1')), findsOneWidget);
    expect(find.text('상대의 답변을 기다리고 있어요.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-appointment-accept-apt1')),
      findsNothing,
    );
  });

  testWidgets('7. pending 수신자 카드는 수락/거절 버튼을 보인다', (tester) async {
    ChatAppointmentStatus? responded;
    await tester.pumpWidget(
      _host(
        AppointmentMessageCard(
          appointmentId: 'apt1',
          currentUid: 'userB', // recipient
          stream: Stream.value(_apt(status: ChatAppointmentStatus.pending)),
          onRespond: (status) async {
            responded = status;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chat-appointment-accept-apt1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat-appointment-decline-apt1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('chat-appointment-accept-apt1')));
    await tester.pumpAndSettle();
    expect(responded, ChatAppointmentStatus.accepted);
  });

  testWidgets('8. accepted 상태는 약속 확정 배지를 보인다', (tester) async {
    await tester.pumpWidget(
      _host(
        AppointmentMessageCard(
          appointmentId: 'apt1',
          currentUid: 'userB',
          stream: Stream.value(_apt(status: ChatAppointmentStatus.accepted)),
          onRespond: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('약속 확정'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-appointment-accept-apt1')),
      findsNothing,
    );
  });

  testWidgets('9. declined 상태는 제안 종료 배지와 안내 문구를 보인다', (tester) async {
    await tester.pumpWidget(
      _host(
        AppointmentMessageCard(
          appointmentId: 'apt1',
          currentUid: 'userB',
          stream: Stream.value(_apt(status: ChatAppointmentStatus.declined)),
          onRespond: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('제안 종료'), findsOneWidget);
    expect(find.text('이번 약속은 성사되지 않았어요.'), findsOneWidget);
  });

  testWidgets('malformed(null) 약속은 안전한 대체 문구를 보인다', (tester) async {
    await tester.pumpWidget(
      _host(
        AppointmentMessageCard(
          appointmentId: 'apt1',
          currentUid: 'userB',
          stream: Stream<ChatAppointment?>.value(null),
          onRespond: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('약속을 불러오지 못했어요.'), findsOneWidget);
  });

  testWidgets('10. 응답 시스템 행이 가운데 정렬 텍스트로 표시된다', (tester) async {
    await tester.pumpWidget(
      _host(const AppointmentResponseRow(text: '약속을 수락했어요.')),
    );
    expect(find.text('약속을 수락했어요.'), findsOneWidget);
    expect(find.byType(Center), findsWidgets);
  });
}
