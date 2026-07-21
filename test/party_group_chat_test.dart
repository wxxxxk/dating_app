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
}) {
  return PartyGroupMessage(
    id: id,
    senderUid: senderUid,
    sender: _author(senderUid, name: name),
    text: text,
    createdAt: DateTime(2026, 7, 20, 15),
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
      expect(find.byKey(const ValueKey('party-safety-notice')), findsOneWidget);
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

      final button = tester.widget<FilledButton>(
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
            .widget<FilledButton>(find.byKey(const ValueKey('party-chat-send')))
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

      await tester.tap(find.byKey(const ValueKey('party-chat-menu-mine')));
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

      await tester.tap(find.byKey(const ValueKey('party-chat-menu-m1')));
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
    testWidgets('전송 버튼은 폭 64~80·높이 48이고 exception이 없다', (tester) async {
      final ctx = await _pumpChat(tester, viewport: const Size(360, 720));
      ctx.party.emitParty(kPartyId, _party());
      await tester.pump();
      ctx.party.emitMessages([_message()]);
      await tester.pump();

      expect(tester.takeException(), isNull);
      final size = tester.getSize(
        find.byKey(const ValueKey('party-chat-send')),
      );
      expect(size.width, greaterThanOrEqualTo(64));
      expect(size.width, lessThanOrEqualTo(80));
      expect(size.height, 48);

      final button = tester.getRect(
        find.byKey(const ValueKey('party-chat-send')),
      );
      expect(button.right, lessThanOrEqualTo(360));
      expect(find.text('전송'), findsOneWidget);
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
  });
}
