// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/community/group_chat/party_group_chat_list_screen.dart';
import 'package:dating_app/features/community/group_chat/party_group_chat_screen.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
import 'package:dating_app/models/community/community_party.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:dating_app/services/community/community_service.dart';
import 'package:dating_app/services/community/party_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// Phase 4-5 — 파티 그룹 채팅 화면 위젯 테스트.
//
// 확인 범위: 목록(active만 표시, pending/cancelled 제외), 메시지 목록 상태,
// 전송·중복 방지·연락처 경고 재전송, 본인 삭제/타인 신고, 신고 후 차단,
// 차단·지인 피하기 필터, 취소된 파티 처리, 그리고 UID·전화번호가 화면에
// 노출되지 않는지.
//
// 모든 pump는 앱 실제 theme(AppTheme.light)을 쓴다 — 기본 theme만 쓰면
// Row 안 전송 버튼의 무한 폭 같은 레이아웃 오류를 놓친다(Phase 4-3A 회귀).

const String kMe = 'me-uid';
const String kOther = 'other-uid';
const String kBlocked = 'blocked-uid';
const String kAvoided = 'avoided-uid';
const String kPartyId = 'p1';

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

class _FakeUser extends Fake implements User {
  @override
  String get uid => kMe;
}

class _FakeAuthService extends Fake implements AuthService {
  @override
  User? get currentUser => _FakeUser();
}

class _FakeSafetyService extends SafetyService {
  _FakeSafetyService({this.blocked = const {}})
    : super(firestoreService: FirestoreService());

  Set<String> blocked;
  final List<String> blockCalls = [];

  @override
  Future<Set<String>> getBlockedRelationshipUids(String currentUid) async =>
      blocked;

  @override
  Future<void> blockUser({
    required String currentUid,
    required String blockedUid,
  }) async {
    blockCalls.add(blockedUid);
    blocked = {...blocked, blockedUid};
  }
}

class _FakeContactAvoidanceService extends ContactAvoidanceService {
  final _controller = StreamController<Set<String>>.broadcast();

  void emit(Set<String> uids) => _controller.add(uids);

  @override
  Stream<Set<String>> watchAvoidedUids(String uid) async* {
    yield const <String>{};
    yield* _controller.stream;
  }

  Future<void> dispose() => _controller.close();
}

class _FakePartyService extends Fake implements PartyService {
  final _messages = StreamController<List<PartyGroupMessage>>.broadcast();
  final _memberships =
      StreamController<List<CommunityPartyMembership>>.broadcast();
  final Map<String, StreamController<CommunityParty?>> _parties = {};

  final List<String> calls = [];

  /// 전송 실패를 흉내 낸다. 큐에 담긴 순서대로 한 번씩 던진다.
  final List<Object> sendFailures = [];
  final List<bool> sendAcknowledged = [];
  String? lastSentText;
  String? lastDeletedMessageId;
  Completer<void>? sendGate;

  void emitMessages(List<PartyGroupMessage> value) => _messages.add(value);
  void emitMessagesError() => _messages.addError(StateError('firestore raw'));
  void emitMemberships(List<CommunityPartyMembership> value) =>
      _memberships.add(value);
  void emitMembershipsError() =>
      _memberships.addError(StateError('firestore raw'));
  void emitParty(String partyId, CommunityParty? party) =>
      _partyController(partyId).add(party);

  StreamController<CommunityParty?> _partyController(String partyId) =>
      _parties.putIfAbsent(
        partyId,
        () => StreamController<CommunityParty?>.broadcast(),
      );

  @override
  Stream<CommunityParty?> watchParty(String partyId) =>
      _partyController(partyId).stream;

  @override
  Stream<List<PartyGroupMessage>> watchGroupMessages({
    required String partyId,
    int limit = PartyService.defaultMessageLimit,
  }) async* {
    calls.add('watchMessages');
    yield* _messages.stream;
  }

  @override
  Stream<List<CommunityPartyMembership>> watchMyMemberships({
    required String uid,
    int limit = PartyService.defaultMembershipLimit,
  }) async* {
    yield* _memberships.stream;
  }

  @override
  Future<String> sendGroupMessage({
    required String partyId,
    required String text,
    bool safetyAcknowledged = false,
  }) async {
    calls.add('send');
    lastSentText = text;
    sendAcknowledged.add(safetyAcknowledged);
    await sendGate?.future;
    if (sendFailures.isNotEmpty) throw sendFailures.removeAt(0);
    return 'new-message';
  }

  @override
  Future<void> deleteGroupMessage({
    required String partyId,
    required String messageId,
  }) async {
    calls.add('delete');
    lastDeletedMessageId = messageId;
  }

  @override
  Future<void> reportGroupMessage({
    required String partyId,
    required String messageId,
    required String reason,
    String? detail,
  }) async {
    calls.add('report');
  }

  Future<void> dispose() async {
    await _messages.close();
    await _memberships.close();
    for (final controller in _parties.values) {
      await controller.close();
    }
  }
}

CommunityAuthorSnapshot _author(String uid, {String name = '참여자'}) =>
    CommunityAuthorSnapshot(
      uid: uid,
      displayName: name,
      photoUrl: '',
      photoVerified: false,
      workVerified: true,
      schoolVerified: false,
    );

CommunityParty _party({
  String id = kPartyId,
  String title = '한강 산책 같이 해요',
}) {
  return CommunityParty(
    id: id,
    hostUid: kOther,
    host: _author(kOther, name: '호스트'),
    title: title,
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAt: DateTime.now().add(const Duration(days: 1)),
    maxParticipants: 4,
    participantCount: 2,
    status: CommunityPartyStatus.open,
    createdAt: DateTime(2026, 7, 20, 12),
    updatedAt: DateTime(2026, 7, 20, 12),
    schemaVersion: 1,
  );
}

PartyGroupMessage _message({
  String id = 'm1',
  String senderUid = kOther,
  String name = '참여자',
  String text = '오늘 3시에 만나요',
  DateTime? createdAt,
}) {
  return PartyGroupMessage(
    id: id,
    senderUid: senderUid,
    sender: _author(senderUid, name: name),
    text: text,
    createdAt: createdAt ?? DateTime(2026, 7, 20, 15),
  );
}

CommunityPartyMembership _membership({
  String partyId = kPartyId,
  CommunityPartyRole role = CommunityPartyRole.member,
  CommunityPartyMembershipState state = CommunityPartyMembershipState.active,
}) {
  return CommunityPartyMembership(
    partyId: partyId,
    role: role,
    state: state,
    updatedAt: DateTime(2026, 7, 20, 12),
  );
}

typedef _Ctx = ({
  _FakePartyService party,
  _FakeContactAvoidanceService avoid,
  _FakeSafetyService safety,
});

Future<_Ctx> _pumpChat(
  WidgetTester tester, {
  _FakePartyService? party,
  Set<String> blocked = const {},
  Size viewport = const Size(800, 1600),
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final p = party ?? _FakePartyService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService(blocked: blocked);
  addTearDown(p.dispose);
  addTearDown(a.dispose);

  final screen = PartyGroupChatScreen(
    partyId: kPartyId,
    authService: _FakeAuthService(),
    partyService: p,
    safetyService: s,
    contactAvoidanceService: a,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: keyboardInset > 0
          ? MediaQuery(
              data: MediaQueryData(
                size: viewport,
                viewInsets: EdgeInsets.only(bottom: keyboardInset),
              ),
              child: screen,
            )
          : screen,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (party: p, avoid: a, safety: s);
}

Future<_Ctx> _pumpList(
  WidgetTester tester, {
  _FakePartyService? party,
  Size viewport = const Size(800, 1600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final p = party ?? _FakePartyService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService();
  addTearDown(p.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: PartyGroupChatListScreen(
        authService: _FakeAuthService(),
        partyService: p,
        safetyService: s,
        contactAvoidanceService: a,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (party: p, avoid: a, safety: s);
}

/// 화면에 UID·전화번호 같은 값이 없는지 확인한다.
void _expectNoSensitiveText(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .join('\n');
  for (final forbidden in [kMe, kOther, kPartyId, '010-', '1999-01-01']) {
    expect(texts.contains(forbidden), isFalse, reason: '$forbidden\n$texts');
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('B-3. 그룹 채팅 목록', () {
    testWidgets('로딩·빈 상태를 보여준다', (tester) async {
      final ctx = await _pumpList(tester);
      expect(
        find.byKey(const ValueKey('party-group-chat-list-loading')),
        findsOneWidget,
      );

      ctx.party.emitMemberships(const []);
      await tester.pump();
      expect(find.textContaining('아직 참여 중인 파티가 없어요.'), findsOneWidget);
    });

    testWidgets('오류는 고정 문구로만 안내한다', (tester) async {
      final ctx = await _pumpList(tester);
      ctx.party.emitMembershipsError();
      await tester.pump();

      expect(find.text('그룹 채팅 목록을 불러오지 못했어요.'), findsOneWidget);
      expect(find.textContaining('firestore raw'), findsNothing);
    });

    testWidgets('active membership만 표시하고 pending은 제외한다', (tester) async {
      final ctx = await _pumpList(tester);
      ctx.party.emitMemberships([
        _membership(partyId: 'joined'),
        _membership(partyId: 'hosted', role: CommunityPartyRole.host),
        _membership(
          partyId: 'pending',
          state: CommunityPartyMembershipState.pending,
        ),
      ]);
      await tester.pump();
      for (final id in ['joined', 'hosted', 'pending']) {
        ctx.party.emitParty(id, _party(id: id, title: '$id 파티'));
      }
      await tester.pump();

      expect(
        find.byKey(const ValueKey('party-group-chat-joined')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('party-group-chat-hosted')),
        findsOneWidget,
      );
      // 승인 대기 파티는 대화에 들어갈 수 없으므로 목록에 없다.
      expect(
        find.byKey(const ValueKey('party-group-chat-pending')),
        findsNothing,
      );
      expect(find.text('호스트'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('취소·삭제된 파티는 표시하지 않는다', (tester) async {
      final ctx = await _pumpList(tester);
      ctx.party.emitMemberships([
        _membership(partyId: 'alive'),
        _membership(partyId: 'cancelled'),
      ]);
      await tester.pump();
      ctx.party.emitParty('alive', _party(id: 'alive', title: '살아있는 파티'));
      // 취소되면 서비스가 null을 흘린다.
      ctx.party.emitParty('cancelled', null);
      await tester.pump();

      expect(find.text('살아있는 파티'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('party-group-chat-cancelled')),
        findsNothing,
      );
    });

    testWidgets('목록 항목을 누르면 채팅 화면으로 간다', (tester) async {
      final ctx = await _pumpList(tester);
      ctx.party.emitMemberships([_membership()]);
      await tester.pump();
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('party-group-chat-$kPartyId')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('party-group-chat-screen')),
        findsOneWidget,
      );
    });
  });

  group('B-9. 메시지 목록', () {
    testWidgets('로딩·빈 상태를 보여준다', (tester) async {
      final ctx = await _pumpChat(tester);
      expect(find.byKey(const ValueKey('party-chat-loading')), findsOneWidget);

      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(const []);
      await tester.pump();
      expect(find.text('아직 대화가 없어요. 첫 인사를 건네보세요.'), findsOneWidget);
    });

    testWidgets('오류는 고정 문구로만 안내한다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessagesError();
      await tester.pump();

      expect(find.text('대화를 불러오지 못했어요.'), findsOneWidget);
      expect(find.textContaining('firestore raw'), findsNothing);
    });

    testWidgets('파티 제목·안전 안내와 메시지를 실시간으로 보여준다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([_message()]);
      await tester.pump();

      expect(find.text('한강 산책 같이 해요'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('party-chat-safety-banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('party-chat-message-m1')),
        findsOneWidget,
      );
      expect(find.text('오늘 3시에 만나요'), findsOneWidget);

      // 새 메시지가 도착하면 바로 반영된다.
      ctx.party.emitMessages([
        _message(),
        _message(id: 'm2', senderUid: kMe, name: '나', text: '좋아요'),
      ]);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('party-chat-message-m2')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      _expectNoSensitiveText(tester);
    });

    testWidgets('차단·지인 피하기 작성자의 메시지는 숨기고 본인 것은 유지한다', (tester) async {
      final ctx = await _pumpChat(tester, blocked: {kBlocked});
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([
        _message(id: 'mine', senderUid: kMe, name: '나', text: '내 메시지'),
        _message(id: 'blocked', senderUid: kBlocked, text: '차단한 사람 메시지'),
        _message(id: 'avoided', senderUid: kAvoided, text: '지인 메시지'),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('내 메시지'), findsOneWidget);
      expect(find.text('차단한 사람 메시지'), findsNothing);
      expect(find.text('지인 메시지'), findsOneWidget);

      ctx.avoid.emit({kAvoided});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('지인 메시지'), findsNothing);
      expect(find.text('내 메시지'), findsOneWidget, reason: '본인 메시지는 유지된다');
    });

    testWidgets('취소된 파티는 대화를 즉시 닫는다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([_message()]);
      await tester.pump();
      expect(find.text('오늘 3시에 만나요'), findsOneWidget);

      ctx.party.emitParty(kPartyId, null);
      await tester.pump();

      expect(find.text('이 파티 대화는 더 이상 볼 수 없어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('party-chat-input')), findsNothing);
      expect(find.byKey(const ValueKey('party-chat-send')), findsNothing);
    });
  });

  group('B-5/B-10. 전송', () {
    testWidgets('메시지를 보내고 입력창을 비운다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(const []);
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '몇 시에 만날까요?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-chat-send')));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('send'));
      expect(ctx.party.lastSentText, '몇 시에 만날까요?');
      expect(ctx.party.sendAcknowledged, [false]);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('party-chat-input')),
      );
      expect(field.controller?.text, '');
    });

    testWidgets('빈 입력이면 전송 버튼이 비활성화된다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(const []);
      await tester.pump();

      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('party-chat-send')),
      );
      expect(button.onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '   ',
      );
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('party-chat-send')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('전송 중 중복 제출을 막는다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      // 메시지를 흘려두지 않으면 목록 spinner가 계속 돌아 settle되지 않는다.
      ctx.party.emitMessages(const []);
      await tester.pump();
      ctx.party.sendGate = Completer<void>();

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '안녕하세요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-chat-send')));
      await tester.pump();

      // 진행 중에는 spinner가 뜨고 버튼이 잠긴다.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('party-chat-send')),
        warnIfMissed: false,
      );
      await tester.pump();

      ctx.party.sendGate!.complete();
      await tester.pumpAndSettle();

      expect(
        ctx.party.calls.where((c) => c == 'send').length,
        1,
        reason: '중복 전송이 나가면 안 된다',
      );
    });

    testWidgets('연락처 경고를 확인하면 acknowledged로 재전송한다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(const []);
      await tester.pump();
      ctx.party.sendFailures.add(
        const PartyContactAckRequired(PartyContactAckRequired.defaultMessage),
      );

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '카톡으로 옮길까요?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-chat-send')));
      // 확인 다이얼로그가 떠 있는 동안 전송 버튼은 잠긴 채 spinner가 돈다.
      // 계속 애니메이션하므로 pumpAndSettle 대신 프레임을 직접 넘긴다.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('party-chat-contact-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('연락처를 공유하면'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('party-chat-contact-continue')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(ctx.party.sendAcknowledged, [false, true]);
    });

    testWidgets('경고에서 취소하면 재전송하지 않고 입력을 유지한다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(const []);
      await tester.pump();
      ctx.party.sendFailures.add(
        const PartyContactAckRequired(PartyContactAckRequired.defaultMessage),
      );

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '카톡으로 옮길까요?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-chat-send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('다시 쓸게요'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(ctx.party.sendAcknowledged, [false]);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('party-chat-input')),
      );
      expect(field.controller?.text, '카톡으로 옮길까요?');
    });

    testWidgets('전송 실패는 고정 문구로만 안내한다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(const []);
      await tester.pump();
      ctx.party.sendFailures.add(
        const CommunityActionError('이 파티의 참여자만 대화할 수 있어요.'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '안녕하세요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-chat-send')));
      await tester.pumpAndSettle();

      expect(find.text('이 파티의 참여자만 대화할 수 있어요.'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('firebase'), findsNothing);
    });
  });

  group('B-7/B-8. 삭제·신고', () {
    testWidgets('본인 메시지는 삭제 메뉴만 보인다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([
        _message(id: 'mine', senderUid: kMe, name: '나', text: '내 메시지'),
      ]);
      await tester.pump();

      // 항상 보이는 점 세 개 버튼은 없다. 길게 눌러야 메뉴가 뜬다.
      expect(find.text('삭제하기'), findsNothing);
      await tester.longPress(
        find.byKey(const ValueKey('party-chat-message-mine')),
      );
      await tester.pumpAndSettle();
      expect(find.text('삭제하기'), findsOneWidget);
      expect(find.text('신고하기'), findsNothing);

      await tester.tap(find.text('삭제하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기').last);
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('delete'));
      expect(ctx.party.lastDeletedMessageId, 'mine');
      expect(find.text('메시지를 삭제했어요.'), findsOneWidget);
    });

    testWidgets('타인 메시지는 신고 메뉴만 보이고 신고 후 차단할 수 있다', (tester) async {
      final ctx = await _pumpChat(tester);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([_message()]);
      await tester.pump();

      expect(find.text('신고하기'), findsNothing);
      await tester.longPress(
        find.byKey(const ValueKey('party-chat-message-m1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('신고하기'), findsOneWidget);
      expect(find.text('삭제하기'), findsNothing);

      await tester.tap(find.text('신고하기'));
      await tester.pumpAndSettle();

      expect(find.text('메시지 신고'), findsOneWidget);
      expect(find.text('신고 후 이 사용자 차단'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('community-report-reason-abusive_language')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('community-report-block')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('community-report-submit')));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('report'));
      expect(ctx.safety.blockCalls, [kOther]);
      expect(find.text('신고하고 차단했어요.'), findsOneWidget);

      // 차단 즉시 해당 작성자의 메시지가 숨겨진다.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('오늘 3시에 만나요'), findsNothing);
    });
  });

  group('레이아웃', () {
    testWidgets('전송 버튼은 48x48 원형 아이콘이고 exception이 없다', (tester) async {
      final ctx = await _pumpChat(tester, viewport: const Size(360, 720));
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([_message()]);
      await tester.pump();

      expect(tester.takeException(), isNull);
      final size = tester.getSize(
        find.byKey(const ValueKey('party-chat-send')),
      );
      expect(size.width, 48, reason: '무한 폭 회귀 방지 — 크기가 고정돼야 한다');
      expect(size.height, 48);

      final button = tester.getRect(
        find.byKey(const ValueKey('party-chat-send')),
      );
      expect(button.right, lessThanOrEqualTo(360));
      // 글자형 '전송' 버튼이 아니라 send 아이콘이다.
      expect(find.text('전송'), findsNothing);
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    });

    testWidgets('작은 화면 + 키보드에서도 overflow가 없다', (tester) async {
      final ctx = await _pumpChat(
        tester,
        viewport: const Size(360, 560),
        keyboardInset: 280,
      );
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([
        _message(),
        _message(id: 'm2', senderUid: kMe, name: '나', text: '좋아요'),
      ]);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('전송 중 spinner 상태에서도 layout exception이 없다', (tester) async {
      final ctx = await _pumpChat(tester, viewport: const Size(360, 720));
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      // 메시지를 흘려두지 않으면 목록 spinner가 계속 돌아 settle되지 않는다.
      ctx.party.emitMessages(const []);
      await tester.pump();
      ctx.party.sendGate = Completer<void>();

      await tester.enterText(
        find.byKey(const ValueKey('party-chat-input')),
        '안녕하세요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-chat-send')));
      await tester.pump();

      expect(tester.takeException(), isNull);
      ctx.party.sendGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('작은 세로 화면에서도 overflow가 없다', (tester) async {
      final ctx = await _pumpChat(tester, viewport: const Size(360, 480));
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([
        _message(text: '가' * 300),
        _message(id: 'm2', senderUid: kMe, name: '나', text: '좋아요'),
      ]);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  // Phase 4-7 — 게시물 댓글형 카드에서 대화방 말풍선으로 바꾼 UX 계약.
  group('B-19. 대화방 UX', () {
    /// 메시지 두 건(상대 → 나)을 띄운 기본 상태.
    Future<_Ctx> pumpConversation(
      WidgetTester tester, {
      List<PartyGroupMessage>? messages,
      Size viewport = const Size(360, 720),
    }) async {
      final ctx = await _pumpChat(tester, viewport: viewport);
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages(
        messages ??
            [
              _message(text: '오늘 3시에 만나요'),
              _message(id: 'm2', senderUid: kMe, name: '나', text: '좋아요'),
            ],
      );
      await tester.pump();
      return ctx;
    }

    testWidgets('1~2. 본인은 오른쪽, 상대는 왼쪽에 정렬된다', (tester) async {
      await pumpConversation(tester);

      const center = 360 / 2;
      expect(
        tester.getCenter(find.text('좋아요')).dx,
        greaterThan(center),
        reason: '본인 메시지는 오른쪽',
      );
      expect(
        tester.getCenter(find.text('오늘 3시에 만나요')).dx,
        lessThan(center),
        reason: '상대 메시지는 왼쪽',
      );
    });

    testWidgets('3~4. 이름·프로필은 상대 메시지에만 붙는다', (tester) async {
      await pumpConversation(tester);

      // 상대 그룹 첫 메시지에는 이름과 아바타가 있다.
      expect(find.text('참여자'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
      // 본인 메시지에는 이름이 없다.
      expect(find.text('나'), findsNothing);
    });

    testWidgets('5. 같은 사람의 5분 이내 연속 메시지는 한 그룹이다', (tester) async {
      await pumpConversation(
        tester,
        messages: [
          _message(id: 'a1', text: '안녕하세요', createdAt: DateTime(2026, 1, 5, 15)),
          _message(
            id: 'a2',
            text: '반가워요',
            createdAt: DateTime(2026, 1, 5, 15, 3),
          ),
        ],
      );

      // 이름·프로필은 그룹 첫 메시지에만.
      expect(find.text('참여자'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
      // 시간은 그룹 마지막에만.
      expect(find.text('15:03'), findsOneWidget);
      expect(find.text('15:00'), findsNothing);
    });

    testWidgets('6. 발신자가 바뀌면 그룹이 끊긴다', (tester) async {
      await pumpConversation(
        tester,
        messages: [
          _message(id: 'a1', text: '안녕하세요', createdAt: DateTime(2026, 1, 5, 15)),
          _message(
            id: 'b1',
            senderUid: kAvoided,
            name: '다른참여자',
            text: '반가워요',
            createdAt: DateTime(2026, 1, 5, 15, 1),
          ),
        ],
      );

      expect(find.text('참여자'), findsOneWidget);
      expect(find.text('다른참여자'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsNWidgets(2));
      // 앞 메시지도 그룹의 마지막이므로 시간이 붙는다.
      expect(find.text('15:00'), findsOneWidget);
      expect(find.text('15:01'), findsOneWidget);
    });

    testWidgets('7. 5분을 넘기면 같은 사람이어도 그룹이 끊긴다', (tester) async {
      await pumpConversation(
        tester,
        messages: [
          _message(id: 'a1', text: '안녕하세요', createdAt: DateTime(2026, 1, 5, 15)),
          _message(
            id: 'a2',
            text: '아직 계신가요',
            createdAt: DateTime(2026, 1, 5, 15, 6),
          ),
        ],
      );

      expect(find.text('참여자'), findsNWidgets(2));
      expect(find.text('15:00'), findsOneWidget);
      expect(find.text('15:06'), findsOneWidget);
    });

    testWidgets('8. 날짜가 바뀌면 구분선이 들어간다', (tester) async {
      await pumpConversation(
        tester,
        messages: [
          _message(id: 'd1', text: '어제 이야기', createdAt: DateTime(2026, 1, 5, 15)),
          _message(id: 'd2', text: '오늘 이야기', createdAt: DateTime(2026, 1, 6, 9)),
        ],
      );

      expect(find.byKey(const ValueKey('party-chat-date-20260105')), findsOne);
      expect(find.byKey(const ValueKey('party-chat-date-20260106')), findsOne);
      expect(find.text('1월 5일'), findsOneWidget);
      expect(find.text('1월 6일'), findsOneWidget);
    });

    testWidgets('10. 긴 메시지도 말풍선 최대 폭을 넘지 않는다', (tester) async {
      const long = '가나다라마바사아자차카타파하';
      await pumpConversation(
        tester,
        messages: [_message(id: 'long', text: long * 20)],
      );

      final width = tester.getSize(find.text(long * 20)).width;
      expect(
        width,
        lessThanOrEqualTo(360 * 0.78),
        reason: '전체 폭 카드가 아니라 말풍선이어야 한다',
      );
    });

    testWidgets('13. 항상 보이는 popup menu는 없다', (tester) async {
      await pumpConversation(tester);

      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    });

    testWidgets('14~15. 입력창은 둥근 surface, 전송은 원형 아이콘이다', (tester) async {
      await pumpConversation(tester);

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('party-chat-input')),
      );
      expect(field.decoration?.filled, isTrue);
      expect(field.decoration?.hintText, '메시지를 입력하세요');
      expect(field.minLines, 1);
      expect(field.maxLines, 4);
      expect(field.maxLength, PartyGroupMessage.textMaxLength);
      expect(field.textInputAction, TextInputAction.send);
      final border = field.decoration?.border;
      expect(border, isA<OutlineInputBorder>());
      expect(
        (border! as OutlineInputBorder).borderRadius.topLeft.x,
        greaterThan(0),
      );

      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    });

    testWidgets('7장. 안전 안내는 얇은 배너이고 닫을 수 있다', (tester) async {
      await pumpConversation(tester);

      final banner = find.byKey(const ValueKey('party-chat-safety-banner'));
      expect(banner, findsOneWidget);
      // 대화 첫 화면을 밀어내지 않을 만큼 얇아야 한다.
      expect(tester.getSize(banner).height, lessThanOrEqualTo(56));
      expect(find.textContaining('연락처'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('party-chat-safety-dismiss')),
      );
      await tester.pump();
      expect(banner, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('23. 취소된 파티는 대화방 UI 없이 안내만 남는다', (tester) async {
      final ctx = await pumpConversation(tester);
      ctx.party.emitParty(kPartyId, null);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('party-chat-unavailable')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('party-chat-safety-banner')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('party-chat-send')), findsNothing);
      expect(find.text('좋아요'), findsNothing);
    });
  });
}
