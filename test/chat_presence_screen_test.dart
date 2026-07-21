// ChatScreen은 concrete 서비스들을 요구하고, 그 생성자는 FirebaseFirestore/
// FirebaseFunctions.instance를 건드린다. 기존 테스트(profile_edit_*)와 같은
// 방식으로 firebase_core 플랫폼만 fake로 바꿔 인스턴스 생성을 가능하게 한 뒤,
// 필요한 메서드만 오버라이드해 실제 네트워크 없이 화면을 검증한다.
// (새 mocking 의존성 없이 flutter_test의 Fake + plugin_platform_interface만 사용)
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

/// presence write를 캡처하는 test double.
class _FakePresenceService extends ChatPresenceService {
  final List<({bool isOnline, bool isTyping})> writes = [];
  final _controller = StreamController<ChatPresence?>.broadcast();

  int get onlineWrites => writes.where((w) => w.isOnline).length;
  int get typingTrueWrites => writes.where((w) => w.isTyping).length;
  int get offlineWrites => writes.where((w) => !w.isOnline).length;

  void emit(ChatPresence? presence) => _controller.add(presence);

  @override
  Stream<ChatPresence?> watchPresence({
    required String matchId,
    required String uid,
  }) {
    return _controller.stream;
  }

  @override
  Future<void> setPresence({
    required String matchId,
    required String uid,
    required bool isOnline,
    required bool isTyping,
  }) async {
    writes.add((isOnline: isOnline, isTyping: isOnline && isTyping));
  }
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

MessageModel _textMessage(String id, String senderId, String text) {
  return MessageModel(
    id: id,
    senderId: senderId,
    text: text,
    createdAt: DateTime(2026, 7, 21, 12, 0),
  );
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

ChatPresence _presence({
  bool isOnline = true,
  bool isTyping = false,
  Duration ago = const Duration(seconds: 5),
}) {
  return ChatPresence(
    uid: kOther,
    isOnline: isOnline,
    isTyping: isTyping,
    lastActiveAt: DateTime.now().subtract(ago),
  );
}

/// 사진 로딩이 테스트를 흔들지 않도록 photoUrls는 비워 둔다.
final _otherProfile = PublicProfile(
  uid: kOther,
  displayName: '상대',
  age: 27,
  gender: 'female',
);

Future<_FakePresenceService> _pumpChat(
  WidgetTester tester, {
  _FakeChatService? chatService,
  _FakeSafetyService? safetyService,
  _FakePresenceService? presenceService,
}) async {
  final presence = presenceService ?? _FakePresenceService();
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        matchId: kMatch,
        otherProfile: _otherProfile,
        currentUid: kMe,
        chatService: chatService ?? _FakeChatService(),
        presenceService: presence,
        fortuneService: FortuneService(),
        matchesService: MatchesService(
          firestoreService: FirestoreService(),
          safetyService: _FakeSafetyService(),
        ),
        safetyService: safetyService ?? _FakeSafetyService(),
      ),
    ),
  );
  // 차단 확인(비동기) + 첫 프레임 반영. periodic timer가 있어 pumpAndSettle은 쓰지 않는다.
  await tester.pump();
  await tester.pump();
  return presence;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  testWidgets('11~13. 입력 시 typing true 1회, 연속 입력은 중복 write 없음, 2초 후 false', (
    tester,
  ) async {
    final presence = await _pumpChat(tester);
    presence.writes.clear();

    await tester.enterText(find.byType(TextField), '안');
    await tester.pump();
    expect(presence.typingTrueWrites, 1);

    // 연속 입력 — 이미 typing true이므로 추가 write가 없어야 한다.
    await tester.enterText(find.byType(TextField), '안녕');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '안녕하');
    await tester.pump();
    expect(presence.typingTrueWrites, 1);

    // 2초 debounce 만료 → typing false 1회
    await tester.pump(const Duration(seconds: 3));
    expect(
      presence.writes.where((w) => w.isOnline && !w.isTyping).length,
      1,
      reason: 'debounce 만료 시 online + typing false 1회만 기록돼야 한다',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('13-b. 입력을 지우면 즉시 typing false', (tester) async {
    final presence = await _pumpChat(tester);
    await tester.enterText(find.byType(TextField), '안녕');
    await tester.pump();
    presence.writes.clear();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(presence.writes.length, 1);
    expect(presence.writes.single.isTyping, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('14. 메시지를 전송하면 typing이 false로 내려간다', (tester) async {
    final chat = _FakeChatService();
    final presence = await _pumpChat(tester, chatService: chat);
    await tester.enterText(find.byType(TextField), '안녕하세요');
    await tester.pump();
    presence.writes.clear();

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    await tester.pump();

    expect(chat.sent, ['안녕하세요']);
    expect(presence.writes.any((w) => !w.isTyping), isTrue);
    expect(presence.typingTrueWrites, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('15~16. lifecycle paused는 offline, resumed는 online write', (
    tester,
  ) async {
    final presence = await _pumpChat(tester);
    // 진입 시 online write 1회
    expect(presence.onlineWrites, greaterThanOrEqualTo(1));
    presence.writes.clear();

    // 프레임워크가 허용하는 전이 순서(resumed → inactive → paused)를 따른다.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(presence.onlineWrites, 0);
    expect(presence.offlineWrites, greaterThanOrEqualTo(1));
    expect(presence.writes.every((w) => !w.isTyping), isTrue);

    presence.writes.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(presence.onlineWrites, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('6~7. 상대 online이면 "온라인", typing이면 "입력 중..."', (tester) async {
    final presence = await _pumpChat(tester);

    presence.emit(_presence());
    await tester.pump();
    expect(find.text('온라인'), findsOneWidget);

    presence.emit(_presence(isTyping: true));
    await tester.pump();
    expect(find.text('입력 중...'), findsOneWidget);
    // typing 인디케이터도 같은 presence로 표시된다.
    expect(find.byKey(const ValueKey('typing-on')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('8~10. offline은 마지막 접속 문구, stale online도 offline 취급', (
    tester,
  ) async {
    final presence = await _pumpChat(tester);

    presence.emit(
      _presence(isOnline: false, ago: const Duration(seconds: 20)),
    );
    await tester.pump();
    expect(find.text('방금 전 접속'), findsOneWidget);
    expect(find.byKey(const ValueKey('typing-on')), findsNothing);

    presence.emit(
      _presence(isOnline: false, ago: const Duration(minutes: 12)),
    );
    await tester.pump();
    expect(find.text('12분 전 접속'), findsOneWidget);

    // isOnline true지만 heartbeat 만료(150초) → offline 문구
    presence.emit(
      _presence(isTyping: true, ago: const Duration(seconds: 150)),
    );
    await tester.pump();
    expect(find.text('온라인'), findsNothing);
    expect(find.text('입력 중...'), findsNothing);
    expect(find.byKey(const ValueKey('typing-on')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('17-a. 차단 상태면 상태 바를 숨기고 presence를 쓰지 않는다', (tester) async {
    final presence = await _pumpChat(
      tester,
      safetyService: _FakeSafetyService(blocked: true),
    );

    presence.emit(_presence(isTyping: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-status-label')), findsNothing);
    expect(find.text('입력 중...'), findsNothing);
    // 차단 확인 직후 offline write가 나간다.
    expect(presence.offlineWrites, greaterThanOrEqualTo(1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('17-b. 매칭 해제되면 상태를 숨기고 offline로 내린다', (tester) async {
    final chat = _FakeChatService();
    final presence = await _pumpChat(tester, chatService: chat);
    presence.emit(_presence(isTyping: true));
    await tester.pump();
    expect(find.text('입력 중...'), findsOneWidget);
    presence.writes.clear();

    chat.setUnmatched(true);
    await tester.pump();

    expect(find.byKey(const ValueKey('chat-status-label')), findsNothing);
    expect(find.text('입력 중...'), findsNothing);
    expect(presence.offlineWrites, 1);
    // 기존 매칭 해제 안내는 유지된다.
    expect(find.text('매칭이 해제되어 더 이상 대화할 수 없어요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('18~19. 기존 텍스트/약속 카드 렌더링과 키보드 레이아웃이 유지된다', (tester) async {
    final chat = _FakeChatService(
      messages: [
        _textMessage('m1', kOther, '안녕하세요'),
        _appointmentMessage('m2'),
      ],
    );
    final presence = await _pumpChat(tester, chatService: chat);
    presence.emit(_presence(isTyping: true));
    await tester.pump();

    expect(find.text('안녕하세요'), findsOneWidget);
    expect(find.byKey(const ValueKey('message-row-m2')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 키보드가 올라온 상태(뷰 인셋)에서도 overflow가 발생하지 않아야 한다.
    tester.view.viewInsets = const FakeViewPadding(bottom: 500);
    addTearDown(tester.view.reset);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('화면을 벗어나면 best-effort offline write가 나간다', (tester) async {
    final presence = await _pumpChat(tester);
    presence.writes.clear();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(presence.offlineWrites, 1);
  });
}
