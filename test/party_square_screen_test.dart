// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/community/party/party_compose_screen.dart';
import 'package:dating_app/features/community/party/party_detail_screen.dart';
import 'package:dating_app/features/community/party/party_square_screen.dart';
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

// Phase 4-4 — Party·Square 화면 위젯 테스트.
//
// 확인 범위: Square 목록 상태(로딩/빈/오류), 관계 필터(차단·지인 피하기 호스트
// 숨김, 본인 파티 유지), 내 파티 상태 분류, 작성 검증(시각·안내 체크박스),
// 참여 요청/취소/나가기/취소/신고 흐름, 그리고 UID·정확 주소·전화번호가
// 화면에 절대 노출되지 않는지.
//
// 모든 pump는 앱 실제 theme(AppTheme.light)을 쓴다 — 기본 theme만 쓰면
// Row 안의 버튼 무한 폭 같은 레이아웃 오류를 놓친다(Phase 4-3A 회귀).

const String kMe = 'me-uid';
const String kHost = 'host-uid';
const String kBlockedHost = 'blocked-host-uid';
const String kAvoidedHost = 'avoided-host-uid';

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

/// 스트림과 callable 호출을 제어하는 PartyService fake.
class _FakePartyService extends Fake implements PartyService {
  _FakePartyService({this.squareError = false});

  final bool squareError;

  final _square = StreamController<List<CommunityParty>>.broadcast();
  final _memberships =
      StreamController<List<CommunityPartyMembership>>.broadcast();
  final _requests =
      StreamController<List<CommunityPartyJoinRequest>>.broadcast();
  final _myRequest = StreamController<CommunityPartyJoinRequest?>.broadcast();
  final _isMember = StreamController<bool>.broadcast();
  final Map<String, StreamController<CommunityParty?>> _parties = {};

  final List<String> calls = [];
  CommunityActionError? failure;
  String? lastRequestMessage;
  String? lastReviewedUid;
  bool? lastApprove;

  /// 작성 화면이 보낸 입력(서버에는 key만 간다는 계약 확인용).
  Map<String, Object?>? lastCreateInput;

  void emitSquare(List<CommunityParty> parties) => _square.add(parties);
  void emitSquareError() => _square.addError(StateError('firestore raw'));
  void emitMemberships(List<CommunityPartyMembership> value) =>
      _memberships.add(value);
  void emitRequests(List<CommunityPartyJoinRequest> value) =>
      _requests.add(value);
  void emitMyRequest(CommunityPartyJoinRequest? value) => _myRequest.add(value);
  void emitIsMember(bool value) => _isMember.add(value);
  void emitParty(String partyId, CommunityParty? party) =>
      _partyController(partyId).add(party);

  StreamController<CommunityParty?> _partyController(String partyId) =>
      _parties.putIfAbsent(
        partyId,
        () => StreamController<CommunityParty?>.broadcast(),
      );

  @override
  Stream<List<CommunityParty>> watchSquareParties({
    int limit = PartyService.defaultSquareLimit,
    DateTime? now,
  }) async* {
    calls.add('watchSquare');
    if (squareError) {
      yield* Stream<List<CommunityParty>>.error(StateError('firestore raw'));
      return;
    }
    yield* _square.stream;
  }

  @override
  Stream<CommunityParty?> watchParty(String partyId) =>
      _partyController(partyId).stream;

  @override
  Stream<List<CommunityPartyMembership>> watchMyMemberships({
    required String uid,
    int limit = PartyService.defaultMembershipLimit,
  }) async* {
    yield const <CommunityPartyMembership>[];
    yield* _memberships.stream;
  }

  @override
  Stream<List<CommunityPartyJoinRequest>> watchPendingJoinRequests({
    required String partyId,
    int limit = PartyService.defaultRequestLimit,
  }) async* {
    yield const <CommunityPartyJoinRequest>[];
    yield* _requests.stream;
  }

  @override
  Stream<CommunityPartyJoinRequest?> watchMyJoinRequest({
    required String partyId,
    required String uid,
  }) async* {
    yield null;
    yield* _myRequest.stream;
  }

  @override
  Stream<bool> watchIsMember({
    required String partyId,
    required String uid,
  }) async* {
    yield false;
    yield* _isMember.stream;
  }

  @override
  Future<String> createParty({
    required String title,
    required String description,
    required String category,
    required String area,
    required DateTime startAt,
    required int maxParticipants,
  }) async {
    calls.add('createParty');
    lastCreateInput = {
      'title': title,
      'description': description,
      'category': category,
      'area': area,
      'startAt': startAt,
      'maxParticipants': maxParticipants,
    };
    final failure = this.failure;
    if (failure != null) throw failure;
    return 'new-party';
  }

  @override
  Future<void> requestJoin({
    required String partyId,
    String message = '',
  }) async {
    calls.add('requestJoin');
    lastRequestMessage = message;
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  @override
  Future<PartyReviewResult> reviewJoinRequest({
    required String partyId,
    required String requesterUid,
    required bool approve,
  }) async {
    calls.add('review');
    lastReviewedUid = requesterUid;
    lastApprove = approve;
    final failure = this.failure;
    if (failure != null) throw failure;
    return PartyReviewResult(
      approved: approve,
      participantCount: approve ? 2 : 1,
      status: CommunityPartyStatus.open,
    );
  }

  @override
  Future<void> withdrawJoinRequest({required String partyId}) async {
    calls.add('withdraw');
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> leaveParty({required String partyId}) async {
    calls.add('leave');
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> cancelParty({required String partyId}) async {
    calls.add('cancel');
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> reportParty({
    required String partyId,
    required String reason,
    String? detail,
  }) async {
    calls.add('report');
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  Future<void> dispose() async {
    await _square.close();
    await _memberships.close();
    await _requests.close();
    await _myRequest.close();
    await _isMember.close();
    for (final controller in _parties.values) {
      await controller.close();
    }
  }
}

CommunityAuthorSnapshot _author(String uid, {String name = '호스트'}) =>
    CommunityAuthorSnapshot(
      uid: uid,
      displayName: name,
      photoUrl: '',
      photoVerified: false,
      workVerified: true,
      schoolVerified: false,
    );

CommunityParty _party({
  String id = 'p1',
  String hostUid = kHost,
  String title = '한강 산책 같이 해요',
  String hostName = '호스트',
  int participantCount = 1,
  int maxParticipants = 4,
  CommunityPartyStatus status = CommunityPartyStatus.open,
  DateTime? startAt,
}) {
  return CommunityParty(
    id: id,
    hostUid: hostUid,
    host: _author(hostUid, name: hostName),
    title: title,
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAt: startAt ?? DateTime.now().add(const Duration(days: 1)),
    maxParticipants: maxParticipants,
    participantCount: participantCount,
    status: status,
    createdAt: DateTime(2026, 7, 20, 12),
    updatedAt: DateTime(2026, 7, 20, 12),
    schemaVersion: 1,
  );
}

CommunityPartyMembership _membership({
  String partyId = 'p1',
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

CommunityPartyJoinRequest _joinRequest({
  String requesterUid = 'guest-uid',
  String name = '게스트',
  String message = '함께 걷고 싶어요',
  CommunityPartyJoinStatus status = CommunityPartyJoinStatus.pending,
}) {
  return CommunityPartyJoinRequest(
    requesterUid: requesterUid,
    requester: _author(requesterUid, name: name),
    message: message,
    status: status,
    createdAt: DateTime(2026, 7, 20, 12),
    updatedAt: DateTime(2026, 7, 20, 12),
  );
}

typedef _Ctx = ({
  _FakePartyService party,
  _FakeContactAvoidanceService avoid,
  _FakeSafetyService safety,
});

Future<_Ctx> _pumpSquare(
  WidgetTester tester, {
  _FakePartyService? party,
  Set<String> blocked = const {},
  Size viewport = const Size(800, 1600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final p = party ?? _FakePartyService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService(blocked: blocked);
  addTearDown(p.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: PartySquareScreen(
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

Future<_Ctx> _pumpDetail(
  WidgetTester tester, {
  _FakePartyService? party,
  String partyId = 'p1',
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
      home: PartyDetailScreen(
        partyId: partyId,
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

Future<_FakePartyService> _pumpCompose(
  WidgetTester tester, {
  _FakePartyService? party,
  Size viewport = const Size(800, 1600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final p = party ?? _FakePartyService();
  addTearDown(p.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: PartyComposeScreen(partyService: p),
    ),
  );
  await tester.pump();
  return p;
}

/// 화면에 UID·전화번호·정확 주소 같은 값이 없는지 확인한다.
void _expectNoSensitiveText(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .join('\n');
  for (final forbidden in [
    kMe,
    kHost,
    'guest-uid',
    '010-',
    '강남역 3번 출구',
    '1999-01-01',
  ]) {
    expect(texts.contains(forbidden), isFalse, reason: '$forbidden\n$texts');
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('B-16. 스퀘어 탐색', () {
    testWidgets('로딩 상태를 보여준다', (tester) async {
      await _pumpSquare(tester);
      expect(find.byKey(const ValueKey('party-square-screen')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('party-square-loading')),
        findsOneWidget,
      );
    });

    testWidgets('빈 상태 문구를 보여준다', (tester) async {
      final ctx = await _pumpSquare(tester);
      ctx.party.emitSquare(const []);
      await tester.pump();

      expect(find.text('아직 참여할 수 있는 파티가 없어요.'), findsOneWidget);
    });

    testWidgets('오류는 다시 시도할 수 있는 상태로 안내한다', (tester) async {
      final ctx = await _pumpSquare(
        tester,
        party: _FakePartyService(squareError: true),
      );
      ctx.party.emitSquareError();
      await tester.pump();

      expect(find.text('파티 목록을 불러오지 못했어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('party-square-retry')), findsOneWidget);
      // raw Firebase 오류는 노출하지 않는다.
      expect(find.textContaining('firestore raw'), findsNothing);
    });

    testWidgets('open/full 카드를 상태와 함께 보여준다', (tester) async {
      final ctx = await _pumpSquare(tester);
      ctx.party.emitSquare([
        _party(id: 'p1', title: '모집 중 파티'),
        _party(
          id: 'p2',
          title: '마감된 파티',
          participantCount: 4,
          maxParticipants: 4,
          status: CommunityPartyStatus.full,
        ),
      ]);
      await tester.pump();

      expect(find.byKey(const ValueKey('party-card-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('party-card-p2')), findsOneWidget);
      expect(find.text('모집 중'), findsOneWidget);
      expect(find.text('마감'), findsOneWidget);
      expect(find.text('1/4명'), findsOneWidget);
      expect(find.text('4/4명'), findsOneWidget);
      // 광역 지역만 보여준다(정확 주소 없음).
      expect(find.text('서울'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      _expectNoSensitiveText(tester);
    });

    testWidgets('차단·지인 피하기 호스트는 숨기고 본인 파티는 유지한다', (tester) async {
      final ctx = await _pumpSquare(tester, blocked: {kBlockedHost});
      ctx.party.emitSquare([
        _party(id: 'mine', hostUid: kMe, title: '내가 연 파티', hostName: '나'),
        _party(id: 'blocked', hostUid: kBlockedHost, title: '차단 호스트 파티'),
        _party(id: 'avoided', hostUid: kAvoidedHost, title: '지인 호스트 파티'),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('내가 연 파티'), findsOneWidget);
      expect(find.text('차단 호스트 파티'), findsNothing);
      expect(find.text('지인 호스트 파티'), findsOneWidget);

      ctx.avoid.emit({kAvoidedHost});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('지인 호스트 파티'), findsNothing);
      expect(find.text('내가 연 파티'), findsOneWidget, reason: '본인 파티는 유지된다');
    });

    testWidgets('카드를 누르면 상세 화면으로 간다', (tester) async {
      final ctx = await _pumpSquare(tester);
      ctx.party.emitSquare([_party()]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('party-card-p1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('party-detail-screen')), findsOneWidget);
    });
  });

  group('B-16. 내 파티', () {
    testWidgets('빈 상태 문구를 보여준다', (tester) async {
      final ctx = await _pumpSquare(tester);
      await tester.tap(find.byKey(const ValueKey('party-tab-mine')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      ctx.party.emitMemberships(const []);
      await tester.pump();

      expect(find.text('아직 참여 중이거나 만든 파티가 없어요.'), findsOneWidget);
    });

    testWidgets('host/참여 중/승인 대기를 구분해 보여준다', (tester) async {
      final ctx = await _pumpSquare(tester);
      await tester.tap(find.byKey(const ValueKey('party-tab-mine')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      ctx.party.emitMemberships([
        _membership(partyId: 'hosted', role: CommunityPartyRole.host),
        _membership(partyId: 'joined'),
        _membership(
          partyId: 'pending',
          state: CommunityPartyMembershipState.pending,
        ),
      ]);
      await tester.pump();
      for (final id in ['hosted', 'joined', 'pending']) {
        ctx.party.emitParty(id, _party(id: id, title: '$id 파티'));
      }
      await tester.pump();

      expect(find.text('내가 만든 파티'), findsOneWidget);
      expect(find.text('참여 중'), findsOneWidget);
      expect(find.text('승인 대기'), findsOneWidget);
      expect(find.byKey(const ValueKey('party-card-hosted')), findsOneWidget);
      expect(find.byKey(const ValueKey('party-card-joined')), findsOneWidget);
      expect(find.byKey(const ValueKey('party-card-pending')), findsOneWidget);
      // partyId 원문은 화면에 그대로 나오지 않는다(제목만 나온다).
      expect(find.text('hosted'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('B-17. 파티 작성', () {
    testWidgets('안내 체크 전에는 생성할 수 없다', (tester) async {
      await _pumpCompose(tester);

      await tester.enterText(
        find.byKey(const ValueKey('party-compose-title')),
        '한강 산책',
      );
      await tester.enterText(
        find.byKey(const ValueKey('party-compose-description')),
        '가볍게 걸어요',
      );
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('party-compose-submit')),
      );
      expect(button.onPressed, isNull, reason: '시각 미선택 + 체크박스 미확인');
      expect(
        find.byKey(const ValueKey('party-compose-safety-check')),
        findsOneWidget,
      );
      expect(find.text('정확한 주소·연락처·금전 정보를 공개 설명에 적지 않았어요.'), findsOneWidget);
    });

    testWidgets('정확한 주소·연락처 입력 필드가 없다', (tester) async {
      await _pumpCompose(tester);

      // 상세 주소·연락처·참가비 입력 자리를 만들지 않는다.
      for (final forbidden in ['주소', '연락처', '참가비', '전화번호', '계좌']) {
        expect(
          find.textContaining(forbidden, findRichText: true),
          // 안내 문구에서만 등장할 수 있다(입력 필드 라벨로는 없다).
          isNot(_matchesInputLabel(forbidden)),
        );
      }
      expect(find.byKey(const ValueKey('party-safety-notice')), findsOneWidget);
    });

    testWidgets('최대 인원은 3~8 범위를 벗어나지 않는다', (tester) async {
      await _pumpCompose(tester);

      expect(find.text('4명'), findsOneWidget);
      for (var i = 0; i < 8; i++) {
        await tester.tap(
          find.byKey(const ValueKey('party-compose-participants-plus')),
        );
        await tester.pump();
      }
      expect(find.text('8명'), findsOneWidget);

      for (var i = 0; i < 10; i++) {
        await tester.tap(
          find.byKey(const ValueKey('party-compose-participants-minus')),
        );
        await tester.pump();
      }
      expect(find.text('3명'), findsOneWidget);
    });

    testWidgets('카테고리·지역은 key 목록에서만 고른다', (tester) async {
      final party = await _pumpCompose(tester);

      await tester.tap(
        find.byKey(const ValueKey('party-compose-category-dining')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-compose-area-busan')));
      await tester.pump();

      expect(party.calls, isEmpty, reason: '선택만으로는 서버 호출이 없다');
      expect(find.text('맛집·식사'), findsOneWidget);
      expect(find.text('부산'), findsOneWidget);
    });

    testWidgets('작은 화면·키보드에서도 overflow가 없다', (tester) async {
      await _pumpCompose(tester, viewport: const Size(360, 560));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });

  group('B-18. 파티 상세 — 참여자', () {
    testWidgets('본문·안전 안내·그룹 채팅 안내를 보여준다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();

      expect(find.byKey(const ValueKey('party-detail-body')), findsOneWidget);
      expect(find.text('한강 산책 같이 해요'), findsOneWidget);
      expect(find.byKey(const ValueKey('party-safety-notice')), findsOneWidget);
      // Phase 4-5: 비멤버에게는 그룹 채팅 버튼을 보여주지 않는다.
      expect(find.byKey(const ValueKey('party-open-group-chat')), findsNothing);
      expect(tester.takeException(), isNull);
      _expectNoSensitiveText(tester);
    });

    testWidgets('참여 요청을 보낸다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('party-join-message')),
        '함께 걷고 싶어요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-join-button')));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('requestJoin'));
      expect(ctx.party.lastRequestMessage, '함께 걷고 싶어요');
      expect(find.text('참여 요청을 보냈어요.'), findsOneWidget);
    });

    testWidgets('요청 메시지에 전화번호가 있으면 제출 전에 막는다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('party-join-message')),
        '010-1234-5678로 연락 주세요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('party-join-button')));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, isNot(contains('requestJoin')));
    });

    testWidgets('승인 대기 상태에서 요청을 취소한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      // 참여 상태 StreamBuilder는 파티가 뜬 뒤에야 구독을 시작한다.
      ctx.party.emitMyRequest(_joinRequest());
      await tester.pump();

      expect(find.byKey(const ValueKey('party-state-pending')), findsOneWidget);
      expect(find.text('승인 대기'), findsOneWidget);
      expect(find.byKey(const ValueKey('party-join-button')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('party-withdraw-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('요청 취소'));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('withdraw'));
    });

    testWidgets('참여 중이면 나가기를 할 수 있다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      ctx.party.emitIsMember(true);
      await tester.pump();

      expect(find.byKey(const ValueKey('party-state-joined')), findsOneWidget);
      expect(find.text('참여 중'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('party-leave-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('나가기'));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('leave'));
      expect(find.text('파티에서 나왔어요.'), findsOneWidget);
    });

    testWidgets('B-4. 참여 중이면 그룹 채팅 버튼이 보인다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      ctx.party.emitIsMember(true);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('party-open-group-chat')),
        findsOneWidget,
      );
    });

    testWidgets('B-4. 승인 대기 중에는 채팅 대신 안내만 보인다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      ctx.party.emitMyRequest(_joinRequest());
      await tester.pump();

      expect(find.byKey(const ValueKey('party-open-group-chat')), findsNothing);
      expect(find.text('참여 승인 후 그룹 채팅을 이용할 수 있어요.'), findsOneWidget);
    });

    testWidgets('마감된 파티는 참여 요청을 보낼 수 없다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty(
        'p1',
        _party(
          participantCount: 4,
          maxParticipants: 4,
          status: CommunityPartyStatus.full,
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('party-join-closed')), findsOneWidget);
      expect(find.byKey(const ValueKey('party-join-button')), findsNothing);
    });

    testWidgets('신고 후 차단하면 SafetyService를 호출한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('party-report-button')));
      await tester.pumpAndSettle();

      expect(find.text('파티 신고'), findsOneWidget);
      expect(find.text('신고 후 이 호스트 차단'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('community-report-reason-spam_scam')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('community-report-block')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('community-report-submit')));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('report'));
      expect(ctx.safety.blockCalls, [kHost]);
      expect(find.text('신고하고 차단했어요.'), findsOneWidget);
    });

    testWidgets('취소·삭제된 파티는 볼 수 없는 상태로 바뀐다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      expect(find.text('한강 산책 같이 해요'), findsOneWidget);

      ctx.party.emitParty('p1', null);
      await tester.pump();
      expect(find.text('이 파티는 더 이상 볼 수 없어요.'), findsOneWidget);
    });
  });

  group('B-18. 파티 상세 — 호스트', () {
    testWidgets('대기 중 요청을 공개 정보로만 보여주고 승인·거절한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party(hostUid: kMe, hostName: '나'));
      await tester.pump();
      ctx.party.emitRequests([_joinRequest()]);
      await tester.pump();

      expect(find.byKey(const ValueKey('party-requests-list')), findsOneWidget);
      expect(find.text('게스트'), findsOneWidget);
      expect(find.text('함께 걷고 싶어요'), findsOneWidget);
      _expectNoSensitiveText(tester);

      await tester.tap(find.text('승인'));
      await tester.pumpAndSettle();
      expect(ctx.party.calls, contains('review'));
      expect(ctx.party.lastReviewedUid, 'guest-uid');
      expect(ctx.party.lastApprove, isTrue);

      await tester.tap(find.text('거절'));
      await tester.pumpAndSettle();
      expect(ctx.party.lastApprove, isFalse);
    });

    testWidgets('요청이 없으면 빈 상태를 보여준다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party(hostUid: kMe, hostName: '나'));
      await tester.pump();
      ctx.party.emitRequests(const []);
      await tester.pump();

      expect(find.text('아직 참여 요청이 없어요.'), findsOneWidget);
    });

    testWidgets('호스트는 파티를 취소할 수 있고 참여/신고 버튼은 없다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party(hostUid: kMe, hostName: '나'));
      await tester.pump();

      expect(find.byKey(const ValueKey('party-join-button')), findsNothing);
      expect(find.byKey(const ValueKey('party-leave-button')), findsNothing);
      expect(find.byKey(const ValueKey('party-report-button')), findsNothing);
      // 호스트도 members 문서를 갖고 있으므로 채팅에 들어갈 수 있다.
      expect(
        find.byKey(const ValueKey('party-open-group-chat')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('party-cancel-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('파티 취소'));
      await tester.pumpAndSettle();

      expect(ctx.party.calls, contains('cancel'));
    });
  });

  group('오류·레이아웃', () {
    testWidgets('실패는 고정 문구로만 안내한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      ctx.party.failure = const CommunityActionError('모집 인원이 모두 찼어요.');

      await tester.tap(find.byKey(const ValueKey('party-join-button')));
      await tester.pumpAndSettle();

      expect(find.text('모집 인원이 모두 찼어요.'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('firebase'), findsNothing);
    });

    testWidgets('작은 화면에서도 overflow가 없다', (tester) async {
      final ctx = await _pumpSquare(tester, viewport: const Size(360, 640));
      ctx.party.emitSquare([_party(), _party(id: 'p2', title: '두 번째 파티')]);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('상세도 작은 화면에서 overflow가 없다', (tester) async {
      final ctx = await _pumpDetail(tester, viewport: const Size(360, 640));
      ctx.party.emitParty('p1', _party());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

/// 입력 필드 라벨로는 등장하지 않아야 하는 문자열 matcher.
Matcher _matchesInputLabel(String label) => predicate<Finder>(
  (finder) => finder.evaluate().any((element) {
    final widget = element.widget;
    return widget is Text && widget.data == label;
  }),
  '"$label" 입력 필드 라벨',
);
