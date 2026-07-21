// ChatScreen은 concrete 서비스들을 요구하고, 그 생성자는 FirebaseFirestore/
// FirebaseFunctions.instance를 건드린다. 기존 테스트(chat_presence_screen_test 등)와
// 같은 방식으로 firebase_core 플랫폼만 fake로 바꿔 인스턴스 생성을 가능하게 한 뒤,
// 필요한 메서드만 오버라이드해 실제 네트워크 없이 화면을 검증한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/features/chat/chat_screen.dart';
import 'package:dating_app/models/chat_appointment.dart';
import 'package:dating_app/models/chat_presence.dart';
import 'package:dating_app/models/message_model.dart';
import 'package:dating_app/models/public_profile.dart';
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

const Key kBanner = ValueKey('chat-safety-guide-banner');
const Key kBannerOpen = ValueKey('chat-safety-guide-open-button');
const Key kBannerDismiss = ValueKey('chat-safety-guide-dismiss-button');
const Key kGuideSheet = ValueKey('chat-safety-guide-sheet');
const Key kWarningSheet = ValueKey('chat-safety-warning-sheet');
const Key kWarningCancel = ValueKey('chat-safety-warning-cancel-button');
const Key kWarningConfirm = ValueKey('chat-safety-warning-confirm-button');

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

  void emit(ChatPresence? presence) => _controller.add(presence);

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

class _FakeChatService extends ChatService {
  _FakeChatService({List<MessageModel>? messages})
    : messages = messages ?? const [];

  final List<MessageModel> messages;
  final List<String> sent = [];
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
  Future<void> sendMessage({
    required String matchId,
    required String senderId,
    required String text,
  }) async {
    sent.add(text);
  }

  @override
  Stream<ChatAppointment?> watchAppointment({
    required String matchId,
    required String appointmentId,
  }) {
    return Stream.value(
      ChatAppointment(
        id: appointmentId,
        proposerUid: kOther,
        recipientUid: kMe,
        scheduledAt: DateTime(2026, 8, 1, 19),
        place: '성수역 3번 출구',
        note: '',
        status: ChatAppointmentStatus.pending,
        createdAt: DateTime(2026, 7, 21, 10),
        respondedAt: null,
        respondedBy: null,
      ),
    );
  }
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
}

MessageModel _appointmentMessage(String id) {
  return MessageModel(
    id: id,
    senderId: kOther,
    text: ChatService.appointmentProposalText,
    createdAt: DateTime(2026, 7, 21, 12, 30),
    type: ChatMessageType.appointment,
    appointmentId: 'apt1',
  );
}

final _otherProfile = PublicProfile(
  uid: kOther,
  displayName: '상대',
  age: 27,
  gender: 'female',
);

/// 시트 애니메이션을 진행시킨다. presence의 주기 타이머 때문에
/// pumpAndSettle 대신 고정 프레임을 돌린다.
Future<void> _settleSheet(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<_FakeChatService> _pumpChat(
  WidgetTester tester, {
  _FakeChatService? chatService,
  _FakeSafetyService? safetyService,
  _FakePresenceService? presenceService,
}) async {
  final chat = chatService ?? _FakeChatService();
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        matchId: kMatch,
        otherProfile: _otherProfile,
        currentUid: kMe,
        chatService: chat,
        presenceService: presenceService ?? _FakePresenceService(),
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
  await tester.pump();
  return chat;
}

/// 입력 후 전송 버튼을 누른다.
Future<void> _typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send_rounded));
  await tester.pump();
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  testWidgets('1. 채팅 진입 시 안전 가이드 배너가 표시된다', (tester) async {
    await _pumpChat(tester);

    expect(find.byKey(kBanner), findsOneWidget);
    expect(find.text('안전하게 대화해요'), findsOneWidget);
    expect(find.text('연락처·인증번호·송금 요청은 충분히 신뢰한 뒤 확인하세요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('2. 배너를 닫으면 이 세션에서 숨겨진다', (tester) async {
    await _pumpChat(tester);

    await tester.tap(find.byKey(kBannerDismiss));
    await tester.pump();
    expect(find.byKey(kBanner), findsNothing);
    // 다른 기능(입력창·약속 버튼)은 그대로 남는다.
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('3~4. 배너와 메뉴에서 전체 가이드 시트를 열고 네 항목을 본다', (tester) async {
    await _pumpChat(tester);

    await tester.tap(find.byKey(kBannerOpen));
    await _settleSheet(tester);

    expect(find.byKey(kGuideSheet), findsOneWidget);
    expect(find.text('안전하게 대화하는 방법'), findsOneWidget);
    expect(find.text('개인정보는 천천히'), findsOneWidget);
    expect(find.text('인증번호는 공유하지 않기'), findsOneWidget);
    expect(find.text('송금 요청 주의'), findsOneWidget);
    expect(find.text('첫 만남은 공개된 장소에서'), findsOneWidget);
    expect(
      find.text('불편하거나 수상한 상황에서는 우측 상단 메뉴에서 신고하거나 차단할 수 있어요.'),
      findsOneWidget,
    );

    await tester.tap(find.text('확인했어요'));
    await _settleSheet(tester);
    expect(find.byKey(kGuideSheet), findsNothing);

    // 배너를 닫은 뒤에도 우측 상단 메뉴에서 다시 열 수 있다.
    await tester.tap(find.byKey(kBannerDismiss));
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settleSheet(tester);
    expect(find.text('안전하게 대화하기'), findsOneWidget);
    // 기존 메뉴도 유지된다.
    expect(find.text('신고하기'), findsOneWidget);
    expect(find.text('차단하기'), findsOneWidget);
    expect(find.text('매칭 해제'), findsOneWidget);

    await tester.tap(find.text('안전하게 대화하기'));
    await _settleSheet(tester);
    expect(find.byKey(kGuideSheet), findsOneWidget);

    await tester.tap(find.text('확인했어요'));
    await _settleSheet(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('5. 일반 메시지는 경고 없이 정확히 1회 전송된다', (tester) async {
    final chat = await _pumpChat(tester);

    await _typeAndSend(tester, '주말에 시간 괜찮으세요?');
    await tester.pump();

    expect(find.byKey(kWarningSheet), findsNothing);
    expect(chat.sent, ['주말에 시간 괜찮으세요?']);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('6~7. 위험 메시지는 확인 전 미전송, "다시 확인"이면 입력이 유지된다', (tester) async {
    final chat = await _pumpChat(tester);

    await _typeAndSend(tester, '제 번호는 010-1234-5678이에요');
    await _settleSheet(tester);

    // 확인 전에는 service를 호출하지 않는다.
    expect(chat.sent, isEmpty);
    expect(find.byKey(kWarningSheet), findsOneWidget);
    expect(find.text('보내기 전에 확인해주세요'), findsOneWidget);
    expect(find.text('전화번호 또는 연락처'), findsOneWidget);
    // 원문은 시트에 다시 노출하지 않는다(입력창에는 그대로 남아 있어야 한다).
    expect(
      find.descendant(
        of: find.byKey(kWarningSheet),
        matching: find.textContaining('010-1234-5678'),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(kWarningCancel));
    await _settleSheet(tester);

    expect(chat.sent, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '제 번호는 010-1234-5678이에요',
      reason: '취소하면 작성 중이던 내용이 유지돼야 한다',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('8~9. "그래도 보내기"는 1회만 전송하고 경고를 반복하지 않는다', (tester) async {
    final chat = await _pumpChat(tester);

    await _typeAndSend(tester, '카톡 아이디 알려줘');
    await _settleSheet(tester);
    expect(find.text('외부 메신저 정보'), findsOneWidget);

    await tester.tap(find.byKey(kWarningConfirm));
    await _settleSheet(tester);

    expect(chat.sent, ['카톡 아이디 알려줘']);
    // 확인 후 detector가 다시 돌아 경고가 재등장하지 않는다.
    expect(find.byKey(kWarningSheet), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');

    // 추가 프레임을 돌려도 중복 전송이 없다.
    await _settleSheet(tester);
    expect(chat.sent.length, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('10-a. 차단 상태에서는 배너와 입력창이 없다', (tester) async {
    final chat = await _pumpChat(
      tester,
      safetyService: _FakeSafetyService(blocked: true),
    );

    expect(find.byKey(kBanner), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(chat.sent, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('10-b. 매칭 해제 시 배너가 숨겨지고 기존 전송 차단이 유지된다', (tester) async {
    final chat = await _pumpChat(tester);
    await tester.enterText(find.byType(TextField), '010-1234-5678');
    await tester.pump();

    chat.setUnmatched(true);
    await tester.pump();

    expect(find.byKey(kBanner), findsNothing);
    expect(find.text('매칭이 해제되어 더 이상 대화할 수 없어요.'), findsOneWidget);
    expect(chat.sent, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('11~12. 약속 카드·presence UI 회귀 없음, 키보드/작은 화면 overflow 없음', (
    tester,
  ) async {
    final presence = _FakePresenceService();
    await _pumpChat(
      tester,
      chatService: _FakeChatService(messages: [_appointmentMessage('m1')]),
      presenceService: presence,
    );

    presence.emit(
      ChatPresence(
        uid: kOther,
        isOnline: true,
        isTyping: true,
        lastActiveAt: DateTime.now(),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('message-row-m1')), findsOneWidget);
    expect(find.text('성수역 3번 출구'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-appointment-button')), findsOneWidget);
    expect(find.text('입력 중...'), findsOneWidget);
    expect(find.byKey(kBanner), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 작은 화면 + 키보드 노출 — 배너는 자리를 비우고 overflow가 없어야 한다.
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.reset);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(kBanner), findsNothing);

    // 같은 조건에서 메뉴로 가이드 시트를 열어도 overflow가 없어야 한다.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settleSheet(tester);
    await tester.tap(find.text('안전하게 대화하기'));
    await _settleSheet(tester);
    expect(find.byKey(kGuideSheet), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 키보드가 내려가면 배너가 다시 보인다.
    await tester.tap(find.text('확인했어요'));
    await _settleSheet(tester);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    expect(find.byKey(kBanner), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
