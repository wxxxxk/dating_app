// ChatScreen은 concrete 서비스들을 요구하고, 그 생성자는 FirebaseFirestore/
// FirebaseFunctions.instance를 건드린다. 기존 chat 테스트와 같은 방식으로
// firebase_core 플랫폼만 fake로 바꿔 인스턴스 생성을 가능하게 한 뒤,
// 필요한 메서드만 오버라이드해 실제 네트워크 없이 화면을 검증한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/features/chat/chat_screen.dart';
import 'package:dating_app/models/appointment_safety_checkin.dart';
import 'package:dating_app/models/chat_appointment.dart';
import 'package:dating_app/models/chat_presence.dart';
import 'package:dating_app/models/message_model.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/services/chat/appointment_safety_service.dart';
import 'package:dating_app/services/chat/chat_presence_service.dart';
import 'package:dating_app/services/chat/chat_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/fortune/fortune_service.dart';
import 'package:dating_app/services/matches/matches_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const String kMe = 'userA';
const String kOther = 'userB';
const String kMatch = 'match1';
const String kApt = 'apt1';

final DateTime kScheduled = DateTime(2026, 7, 25, 19);
final DateTime kBefore = kScheduled.subtract(const Duration(hours: 5));
final DateTime kAfter = kScheduled.add(const Duration(hours: 3));

const Key kPreButton = ValueKey('appointment-pre-safety-button-$kApt');
const Key kPostButton = ValueKey('appointment-post-safety-button-$kApt');
const Key kSupportButton = ValueKey('appointment-support-button-$kApt');
const Key kSafetySection = ValueKey('appointment-safety-section-$kApt');
const Key kPreSheet = ValueKey('pre-date-safety-sheet');
const Key kPreSubmit = ValueKey('pre-date-safety-submit-button');
const Key kPostSheet = ValueKey('post-date-safety-sheet');
const Key kPostSubmit = ValueKey('post-date-safety-submit-button');
const Key kSupportSheet = ValueKey('appointment-support-sheet');

class _FakeApp extends Fake
    with MockPlatformInterfaceMixin
    implements FirebaseAppPlatform {
  @override
  String get name => defaultFirebaseAppName;
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'k',
    appId: 'a',
    messagingSenderId: 's',
    projectId: 'p',
    storageBucket: 'b.appspot.com',
  );
}

class _FakeFirebasePlatform extends FirebasePlatform {
  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) => _FakeApp();
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async => _FakeApp();
  @override
  List<FirebaseAppPlatform> get apps => [_FakeApp()];
}

class _FakePresenceService extends ChatPresenceService {
  final _controller = StreamController<ChatPresence?>.broadcast();

  @override
  Stream<ChatPresence?> watchPresence({
    required String matchId,
    required String uid,
  }) => _controller.stream;

  @override
  Future<void> setPresence({
    required String matchId,
    required String uid,
    required bool isOnline,
    required bool isTyping,
  }) async {}
}

/// 안전 확인 호출을 캡처하는 test double.
class _FakeSafetyCheckinService extends AppointmentSafetyService {
  _FakeSafetyCheckinService({AppointmentSafetyCheckin? initial})
    : _controller = StreamController<AppointmentSafetyCheckin?>.broadcast() {
    _latest = initial;
  }

  final StreamController<AppointmentSafetyCheckin?> _controller;
  AppointmentSafetyCheckin? _latest;

  int preCalls = 0;
  final List<AppointmentPostSafetyStatus> postCalls = [];
  final List<String> watchedUids = [];

  void emit(AppointmentSafetyCheckin? checkin) {
    _latest = checkin;
    _controller.add(checkin);
  }

  @override
  Stream<AppointmentSafetyCheckin?> watchCheckin({
    required String matchId,
    required String appointmentId,
    required String uid,
  }) {
    watchedUids.add(uid);
    return _controller.stream.startsWithLatest(_latest);
  }

  @override
  Future<void> completePreCheck({
    required String matchId,
    required String appointmentId,
    required String uid,
  }) async {
    preCalls += 1;
  }

  @override
  Future<void> completePostCheck({
    required String matchId,
    required String appointmentId,
    required String uid,
    required DateTime scheduledAt,
    required AppointmentPostSafetyStatus status,
    DateTime? now,
  }) async {
    postCalls.add(status);
  }
}

extension _StartsWith<T> on Stream<T> {
  Stream<T> startsWithLatest(T initial) async* {
    yield initial;
    yield* this;
  }
}

class _FakeChatService extends ChatService {
  _FakeChatService({
    required this.appointment,
    List<MessageModel>? messages,
  }) : messages = messages ?? const [];

  final ChatAppointment? appointment;
  final List<MessageModel> messages;
  final _unmatched = StreamController<bool>.broadcast();

  void setUnmatched(bool value) => _unmatched.add(value);

  @override
  Stream<List<MessageModel>> watchMessages(String matchId) =>
      Stream.value(messages);

  @override
  Stream<bool> watchIsUnmatched(String matchId) => _unmatched.stream;

  @override
  Future<void> markMatchRead({
    required String matchId,
    required String currentUid,
  }) async {}

  @override
  Stream<ChatAppointment?> watchAppointment({
    required String matchId,
    required String appointmentId,
  }) => Stream.value(appointment);
}

class _FakeSafetyService extends SafetyService {
  _FakeSafetyService({this.blocked = false})
    : super(firestoreService: FirestoreService());

  final bool blocked;

  @override
  Future<bool> isBlockedBetween({
    required String currentUid,
    required String otherUid,
  }) async => blocked;

  @override
  Future<void> blockUser({
    required String currentUid,
    required String blockedUid,
  }) async {}
}

ChatAppointment _appointment({
  ChatAppointmentStatus status = ChatAppointmentStatus.accepted,
  String proposer = kOther,
  String recipient = kMe,
}) {
  return ChatAppointment(
    id: kApt,
    proposerUid: proposer,
    recipientUid: recipient,
    scheduledAt: kScheduled,
    place: '성수역 3번 출구',
    note: '',
    status: status,
    createdAt: DateTime(2026, 7, 21, 10),
    respondedAt: null,
    respondedBy: null,
  );
}

MessageModel _appointmentMessage() {
  return MessageModel(
    id: 'm-apt',
    senderId: kOther,
    text: ChatService.appointmentProposalText,
    createdAt: DateTime(2026, 7, 21, 12, 30),
    type: ChatMessageType.appointment,
    appointmentId: kApt,
  );
}

AppointmentSafetyCheckin _checkin({
  DateTime? preCheckCompletedAt,
  AppointmentPostSafetyStatus? postStatus,
}) {
  return AppointmentSafetyCheckin(
    uid: kMe,
    preCheckCompletedAt: preCheckCompletedAt,
    postStatus: postStatus,
    postCheckedAt: postStatus == null ? null : kAfter,
    updatedAt: kAfter,
  );
}

final _otherProfile = PublicProfile(
  uid: kOther,
  displayName: '상대',
  age: 27,
  gender: 'female',
);

Future<void> _settleSheet(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 스크롤 영역(메시지 목록·시트) 안의 위젯을 보이게 만든 뒤 탭한다.
Future<void> _tapInSheet(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settleSheet(tester);
}

Future<
  ({_FakeSafetyCheckinService safety, _FakeChatService chat})
> _pumpChat(
  WidgetTester tester, {
  ChatAppointment? appointment,
  AppointmentSafetyCheckin? checkin,
  _FakeSafetyService? safetyService,
}) async {
  final safety = _FakeSafetyCheckinService(initial: checkin);
  final chat = _FakeChatService(
    appointment: appointment ?? _appointment(),
    messages: [_appointmentMessage()],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        matchId: kMatch,
        otherProfile: _otherProfile,
        currentUid: kMe,
        chatService: chat,
        presenceService: _FakePresenceService(),
        appointmentSafetyService: safety,
        fortuneService: FortuneService(),
        matchesService: MatchesService(
          firestoreService: FirestoreService(),
          safetyService: _FakeSafetyService(),
        ),
        safetyService: safetyService ?? _FakeSafetyService(),
      ),
    ),
  );
  await tester.pump();
  // 메시지 목록 → 약속 카드 → checkin 스트림 순으로 구독이 시작되므로
  // 각 스트림의 첫 값이 반영될 프레임을 충분히 돌린다.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (safety: safety, chat: chat);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  // 카드의 단계 판정은 실제 현재 시각을 쓰므로, 과거/미래 약속으로 단계를 만든다.
  ChatAppointment futureAppointment() => ChatAppointment(
    id: kApt,
    proposerUid: kOther,
    recipientUid: kMe,
    scheduledAt: DateTime.now().add(const Duration(days: 2)),
    place: '성수역 3번 출구',
    note: '',
    status: ChatAppointmentStatus.accepted,
    createdAt: DateTime(2026, 7, 21, 10),
    respondedAt: null,
    respondedBy: null,
  );
  ChatAppointment pastAppointment() => ChatAppointment(
    id: kApt,
    proposerUid: kOther,
    recipientUid: kMe,
    scheduledAt: DateTime.now().subtract(const Duration(hours: 3)),
    place: '성수역 3번 출구',
    note: '',
    status: ChatAppointmentStatus.accepted,
    createdAt: DateTime(2026, 7, 21, 10),
    respondedAt: null,
    respondedBy: null,
  );

  testWidgets('1~3. accepted 미래 약속에만 pre 버튼이 뜬다(pending·declined 제외)', (
    tester,
  ) async {
    await _pumpChat(tester, appointment: futureAppointment());
    expect(find.byKey(kPreButton), findsOneWidget);
    expect(find.text('만나기 전에 장소와 귀가 계획을 한 번 확인해보세요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await _pumpChat(
      tester,
      appointment: _appointment(status: ChatAppointmentStatus.pending),
    );
    expect(find.byKey(kSafetySection), findsNothing);
    expect(find.byKey(kPreButton), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await _pumpChat(
      tester,
      appointment: _appointment(status: ChatAppointmentStatus.declined),
    );
    expect(find.byKey(kSafetySection), findsNothing);
    expect(find.byKey(kPostButton), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('4~6. 사전 체크리스트는 네 항목을 모두 선택해야 완료된다', (tester) async {
    final ctx = await _pumpChat(tester, appointment: futureAppointment());

    await _tapInSheet(tester, find.byKey(kPreButton));

    expect(find.byKey(kPreSheet), findsOneWidget);
    expect(find.text('만나기 전 안전 확인'), findsOneWidget);
    expect(find.text('공개된 장소에서 만나기로 했어요'), findsOneWidget);
    expect(find.text('믿을 수 있는 사람에게 약속을 알려두었어요'), findsOneWidget);
    expect(find.text('돌아오는 방법을 미리 확인했어요'), findsOneWidget);
    expect(find.text('주소·인증번호·금전 정보는 공유하지 않을게요'), findsOneWidget);
    expect(find.text('체크 항목 자체는 저장되지 않고, 확인 완료 시각만 기록돼요.'), findsOneWidget);

    // 전부 선택하기 전에는 제출 비활성.
    expect(
      tester.widget<FilledButton>(find.byKey(kPreSubmit)).onPressed,
      isNull,
    );
    for (var i = 0; i < 3; i++) {
      await _tapInSheet(tester, find.byKey(ValueKey('pre-date-safety-check-$i')));
    }
    expect(
      tester.widget<FilledButton>(find.byKey(kPreSubmit)).onPressed,
      isNull,
      reason: '세 개만 선택한 상태에서는 여전히 비활성',
    );
    expect(ctx.safety.preCalls, 0);

    await _tapInSheet(tester, find.byKey(const ValueKey('pre-date-safety-check-3')));
    expect(
      tester.widget<FilledButton>(find.byKey(kPreSubmit)).onPressed,
      isNotNull,
    );
    await _tapInSheet(tester, find.byKey(kPreSubmit));

    expect(ctx.safety.preCalls, 1);
    expect(find.text('만남 전 안전 확인을 기록했어요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('7. pre 완료 상태는 재제출 버튼 없이 표시된다', (tester) async {
    await _pumpChat(
      tester,
      appointment: futureAppointment(),
      checkin: _checkin(preCheckCompletedAt: kBefore),
    );

    expect(find.text('안전 확인 완료'), findsOneWidget);
    expect(find.text('만남 전 준비를 확인했어요.'), findsOneWidget);
    expect(find.byKey(kPreButton), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('8. 약속 시간이 지나면 post 버튼이 뜬다(pre 미완료여도 가능)', (tester) async {
    final ctx = await _pumpChat(tester, appointment: pastAppointment());

    expect(find.byKey(kPostButton), findsOneWidget);
    expect(find.text('만남을 마친 뒤 현재 상태를 알려주세요.'), findsOneWidget);

    await _tapInSheet(tester, find.byKey(kPostButton));
    expect(find.byKey(kPostSheet), findsOneWidget);
    expect(find.text('만남은 괜찮았나요?'), findsOneWidget);
    expect(find.text('이 선택은 상대에게 공개되지 않아요.'), findsOneWidget);
    // 선택 전에는 기록 버튼 비활성.
    expect(
      tester.widget<FilledButton>(find.byKey(kPostSubmit)).onPressed,
      isNull,
    );

    await _tapInSheet(tester, find.text('무사히 돌아왔어요'));
    await _tapInSheet(tester, find.byKey(kPostSubmit));

    expect(ctx.safety.postCalls, [AppointmentPostSafetyStatus.safe]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('9~10. safe·cancelled 상태 표시', (tester) async {
    await _pumpChat(
      tester,
      appointment: pastAppointment(),
      checkin: _checkin(postStatus: AppointmentPostSafetyStatus.safe),
    );
    expect(find.text('무사히 돌아왔다고 기록했어요'), findsOneWidget);
    expect(find.byKey(kPostButton), findsNothing);
    expect(find.byKey(kSupportButton), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await _pumpChat(
      tester,
      appointment: pastAppointment(),
      checkin: _checkin(postStatus: AppointmentPostSafetyStatus.cancelled),
    );
    expect(find.text('만남이 취소되었다고 기록했어요'), findsOneWidget);
    expect(find.byKey(kSupportButton), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('11~14. needsSupport 상태·도움 시트와 신고/차단/가이드 연결', (tester) async {
    await _pumpChat(
      tester,
      appointment: pastAppointment(),
      checkin: _checkin(postStatus: AppointmentPostSafetyStatus.needsSupport),
    );

    expect(find.text('도움이 필요한 상태로 기록했어요'), findsOneWidget);
    expect(find.byKey(kSupportButton), findsOneWidget);

    // 11. 기록된 카드에서도 도움 시트를 다시 열 수 있다.
    await _tapInSheet(tester, find.byKey(kSupportButton));
    expect(find.byKey(kSupportSheet), findsOneWidget);
    expect(find.text('도움이 필요하신가요?'), findsOneWidget);
    expect(
      find.text('지금 위험한 상황이라면 앱 안의 기능보다 지역 긴급기관이나 주변의 믿을 수 있는 사람에게 먼저 도움을 요청하세요.'),
      findsOneWidget,
    );

    // 14. 안전 가이드 연결
    await _tapInSheet(tester, find.text('안전 가이드 보기'));
    expect(find.byKey(const ValueKey('chat-safety-guide-sheet')), findsOneWidget);
    await _tapInSheet(tester, find.text('확인했어요'));

    // 12. 신고 연결 — 기존 사용자 신고 시트가 열린다.
    await _tapInSheet(tester, find.byKey(kSupportButton));
    await _tapInSheet(tester, find.text('사용자 신고하기'));
    // 기존 사용자 신고 시트(사유 목록)가 그대로 열린다.
    expect(find.text('부적절한 사진'), findsOneWidget);
    expect(find.text('신고 제출'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('13. 도움 시트의 차단은 기존 차단 확인 다이얼로그로 연결된다', (tester) async {
    await _pumpChat(
      tester,
      appointment: pastAppointment(),
      checkin: _checkin(postStatus: AppointmentPostSafetyStatus.needsSupport),
    );

    await _tapInSheet(tester, find.byKey(kSupportButton));
    await _tapInSheet(tester, find.text('사용자 차단하기'));

    expect(find.text('차단하면 서로 디스커버리, 매칭, 채팅에서 볼 수 없어요.'), findsOneWidget);
    // 자동 실행이 아니라 사용자가 확인해야 한다.
    await _tapInSheet(tester, find.text('취소'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('15. 본인 checkin만 구독하고 상대 상태는 표시하지 않는다', (tester) async {
    final ctx = await _pumpChat(
      tester,
      appointment: pastAppointment(),
      checkin: _checkin(postStatus: AppointmentPostSafetyStatus.safe),
    );

    expect(ctx.safety.watchedUids, isNotEmpty);
    expect(ctx.safety.watchedUids.every((uid) => uid == kMe), isTrue);
    // 안전 영역에는 상대 상태를 암시하는 문구가 없어야 한다
    // (AppBar의 상대 이름은 기존 UI이므로 영역을 좁혀서 확인한다).
    expect(
      find.descendant(
        of: find.byKey(kSafetySection),
        matching: find.textContaining('상대'),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('16. 매칭 해제 후에도 본인 안전 확인은 계속 가능하다', (tester) async {
    final ctx = await _pumpChat(tester, appointment: pastAppointment());

    ctx.chat.setUnmatched(true);
    await tester.pump();

    // 입력은 막히지만 안전 확인 버튼은 남는다.
    expect(find.text('매칭이 해제되어 더 이상 대화할 수 없어요.'), findsOneWidget);
    expect(find.byKey(kPostButton), findsOneWidget);

    await _tapInSheet(tester, find.byKey(kPostButton));
    await _tapInSheet(tester, find.text('만남이 취소됐어요'));
    await _tapInSheet(tester, find.byKey(kPostSubmit));
    expect(ctx.safety.postCalls, [AppointmentPostSafetyStatus.cancelled]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('17. 차단 상태에서는 약속 카드와 안전 UI가 보이지 않는다', (tester) async {
    await _pumpChat(
      tester,
      appointment: pastAppointment(),
      safetyService: _FakeSafetyService(blocked: true),
    );

    expect(find.byKey(kSafetySection), findsNothing);
    expect(find.byKey(kPostButton), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('18~19. 약속 카드 기본 정보 회귀 + 작은 화면 overflow 없음', (tester) async {
    await _pumpChat(tester, appointment: pastAppointment());

    expect(find.text('약속 제안'), findsOneWidget);
    expect(find.text('성수역 3번 출구'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-appointment-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await _tapInSheet(tester, find.byKey(kPostButton));
    expect(find.byKey(kPostSheet), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('20. 기존 사용자 신고 시트가 작은 화면에서도 overflow 없이 열린다', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 500);
    addTearDown(tester.view.reset);

    await _pumpChat(tester, appointment: pastAppointment());

    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settleSheet(tester);
    await tester.tap(find.text('신고하기'));
    await _settleSheet(tester);

    expect(find.text('부적절한 사진'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
