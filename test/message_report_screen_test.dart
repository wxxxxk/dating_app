// ChatScreen은 concrete 서비스들을 요구하고, 그 생성자는 FirebaseFirestore/
// FirebaseFunctions.instance를 건드린다. 기존 chat 테스트와 같은 방식으로
// firebase_core 플랫폼만 fake로 바꿔 인스턴스 생성을 가능하게 한 뒤,
// 필요한 메서드만 오버라이드해 실제 네트워크 없이 화면을 검증한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/features/chat/chat_screen.dart';
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

const String kOtherText = '너 진짜 별로다';
const String kMineText = '무슨 말이에요?';

const Key kActionSheet = ValueKey('message-action-sheet');
const Key kActionReport = ValueKey('message-action-report');
const Key kActionClose = ValueKey('message-action-close');
const Key kReportSheet = ValueKey('message-report-sheet');
const Key kReportSubmit = ValueKey('message-report-submit-button');
const Key kReportCancel = ValueKey('message-report-cancel-button');
const Key kReportBlock = ValueKey('message-report-block-checkbox');
const Key kReportPreview = ValueKey('message-report-preview');
const Key kReportDetail = ValueKey('message-report-detail-field');

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
  final _unmatched = StreamController<bool>.broadcast();

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

/// 신고/차단 호출을 캡처하는 test double.
class _FakeSafetyService extends SafetyService {
  _FakeSafetyService({this.failReport = false})
    : super(firestoreService: FirestoreService());

  final bool failReport;

  final List<Map<String, dynamic>> messageReports = [];
  final List<({String currentUid, String blockedUid})> blocks = [];
  int userReports = 0;
  Completer<void>? gate;

  @override
  Future<bool> isBlockedBetween({
    required String currentUid,
    required String otherUid,
  }) async => false;

  @override
  Future<void> reportMessage({
    required String reporterUid,
    required String reportedUid,
    required String matchId,
    required String messageId,
    required String reason,
    String? detail,
  }) async {
    if (gate != null) await gate!.future;
    if (failReport) throw StateError('reject');
    messageReports.add(
      SafetyService.buildMessageReportDoc(
        reporterUid: reporterUid,
        reportedUid: reportedUid,
        matchId: matchId,
        messageId: messageId,
        reason: reason,
        detail: detail,
        createdAt: 'ts',
      ),
    );
  }

  @override
  Future<void> reportUser({
    required String reporterUid,
    required String reportedUid,
    required String reason,
    String? detail,
  }) async {
    userReports += 1;
  }

  @override
  Future<void> blockUser({
    required String currentUid,
    required String blockedUid,
  }) async {
    blocks.add((currentUid: currentUid, blockedUid: blockedUid));
  }
}

MessageModel _text(String id, String senderId, String text) {
  return MessageModel(
    id: id,
    senderId: senderId,
    text: text,
    createdAt: DateTime(2026, 7, 21, 12, 0),
  );
}

MessageModel _appointment(String id) {
  return MessageModel(
    id: id,
    senderId: kOther,
    text: ChatService.appointmentProposalText,
    createdAt: DateTime(2026, 7, 21, 12, 30),
    type: ChatMessageType.appointment,
    appointmentId: 'apt1',
  );
}

MessageModel _appointmentResponse(String id) {
  return MessageModel(
    id: id,
    senderId: kOther,
    text: ChatService.appointmentAcceptedText,
    createdAt: DateTime(2026, 7, 21, 12, 40),
    type: ChatMessageType.appointmentResponse,
    appointmentId: 'apt1',
    appointmentStatus: ChatAppointmentStatus.accepted,
  );
}

final _otherProfile = PublicProfile(
  uid: kOther,
  displayName: '상대',
  age: 27,
  gender: 'female',
);

/// 시트 애니메이션 진행용. presence 주기 타이머 때문에 pumpAndSettle은 쓰지 않는다.
Future<void> _settleSheet(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 약속 카드까지 포함한 전체 메시지 세트(신고 대상 범위 검증용).
final _allMessages = [
  _text('m-other', kOther, kOtherText),
  _text('m-mine', kMe, kMineText),
  _appointment('m-apt'),
  _appointmentResponse('m-apt-res'),
];

/// 신고 흐름 테스트 기본값. 목록이 길면 ListView가 대상 말풍선을 화면 밖으로
/// 밀어내 롱프레스를 못 하므로 텍스트 두 개만 둔다.
final _defaultMessages = [
  _text('m-other', kOther, kOtherText),
  _text('m-mine', kMe, kMineText),
];

Future<_FakeSafetyService> _pumpChat(
  WidgetTester tester, {
  List<MessageModel>? messages,
  _FakeSafetyService? safetyService,
  _FakePresenceService? presenceService,
}) async {
  final safety = safetyService ?? _FakeSafetyService();
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        matchId: kMatch,
        otherProfile: _otherProfile,
        currentUid: kMe,
        chatService: _FakeChatService(messages: messages ?? _defaultMessages),
        presenceService: presenceService ?? _FakePresenceService(),
        appointmentSafetyService: AppointmentSafetyService(),
        fortuneService: FortuneService(),
        matchesService: MatchesService(
          firestoreService: FirestoreService(),
          safetyService: _FakeSafetyService(),
        ),
        safetyService: safety,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return safety;
}

/// 스크롤되는 시트 안의 위젯을 보이게 한 뒤 탭한다.
Future<void> _tapInSheet(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settleSheet(tester);
}

/// 상대 메시지를 길게 눌러 액션 시트 → 신고 폼까지 연다.
Future<void> _openReportSheet(WidgetTester tester) async {
  final target = find.byKey(const ValueKey('message-reportable-m-other'));
  // 목록이 길면 대상 말풍선이 화면 밖에 있을 수 있어 먼저 보이게 만든다.
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.longPress(target);
  await _settleSheet(tester);
  await tester.tap(find.byKey(kActionReport));
  await _settleSheet(tester);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  testWidgets('1~4. 상대 텍스트만 신고 대상이다(내 메시지·약속 카드·응답 제외)', (tester) async {
    await _pumpChat(tester, messages: _allMessages);

    expect(
      find.byKey(const ValueKey('message-reportable-m-other')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('message-reportable-m-mine')), findsNothing);
    expect(find.byKey(const ValueKey('message-reportable-m-apt')), findsNothing);
    expect(
      find.byKey(const ValueKey('message-reportable-m-apt-res')),
      findsNothing,
    );

    // 내 메시지를 길게 눌러도 액션 시트가 열리지 않는다.
    await tester.longPress(find.text(kMineText));
    await _settleSheet(tester);
    expect(find.byKey(kActionSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('5~7. 액션 시트 → 신고 폼, 사유 목록과 preview 줄 수', (tester) async {
    await _pumpChat(tester);

    await tester.longPress(
      find.byKey(const ValueKey('message-reportable-m-other')),
    );
    await _settleSheet(tester);
    expect(find.byKey(kActionSheet), findsOneWidget);
    expect(find.text('선택한 메시지'), findsOneWidget);
    expect(find.byKey(kActionClose), findsOneWidget);

    await tester.tap(find.byKey(kActionReport));
    await _settleSheet(tester);

    expect(find.byKey(kReportSheet), findsOneWidget);
    expect(find.text('이 메시지를 신고할까요?'), findsOneWidget);
    expect(find.text('운영 검토를 위해 메시지와 대화 정보를 함께 확인해요.'), findsOneWidget);
    for (final label in messageReportReasonLabels.values) {
      expect(find.text(label), findsOneWidget);
    }

    // preview는 최대 3줄 + ellipsis로만 표시한다.
    final preview = tester.widget<Text>(find.byKey(kReportPreview));
    expect(preview.maxLines, 3);
    expect(preview.overflow, TextOverflow.ellipsis);
    expect(preview.data, kOtherText);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('8. 취소하면 어떤 write도 하지 않는다', (tester) async {
    final safety = await _pumpChat(tester);

    await _openReportSheet(tester);
    await _tapInSheet(tester, find.byKey(kReportCancel));

    expect(safety.messageReports, isEmpty);
    expect(safety.blocks, isEmpty);
    expect(find.byKey(kReportSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('9~10. 제출하면 reportMessage 1회, 차단 미선택이면 채팅이 유지된다', (
    tester,
  ) async {
    final safety = await _pumpChat(tester);

    await _openReportSheet(tester);
    await _tapInSheet(tester, find.text('성적 불쾌감'));
    await tester.enterText(find.byKey(kReportDetail), '  반복적으로 보냈어요  ');
    await tester.pump();
    await _tapInSheet(tester, find.byKey(kReportSubmit));

    expect(safety.messageReports, hasLength(1));
    expect(safety.messageReports.single, {
      'reportType': 'message',
      'reporterUid': kMe,
      'reportedUid': kOther,
      'matchId': kMatch,
      'messageId': 'm-other',
      'reason': 'sexual_harassment',
      'detail': '반복적으로 보냈어요',
      'createdAt': 'ts',
    });
    // 원문은 신고 문서에 담기지 않는다.
    expect(safety.messageReports.single.values.join(' '), isNot(contains(kOtherText)));

    expect(safety.blocks, isEmpty);
    expect(find.text('메시지 신고가 접수되었어요.'), findsOneWidget);
    // 차단하지 않았으므로 채팅 입력이 유지되고 메시지도 그대로 남는다.
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('11. 차단을 선택하면 blockUser 호출 후 차단 화면으로 전환된다', (tester) async {
    final safety = await _pumpChat(tester);

    await _openReportSheet(tester);
    await _tapInSheet(tester, find.byKey(kReportBlock));
    await _tapInSheet(tester, find.byKey(kReportSubmit));

    expect(safety.messageReports, hasLength(1));
    expect(safety.blocks, hasLength(1));
    expect(safety.blocks.single.blockedUid, kOther);
    expect(find.text('메시지를 신고하고 사용자를 차단했어요.'), findsOneWidget);
    // 차단 상태 화면으로 바뀌어 입력창이 사라진다.
    expect(find.byType(TextField), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('12. 제출 진행 중에는 중복 신고를 시작하지 않는다', (tester) async {
    final safety = _FakeSafetyService()..gate = Completer<void>();
    await _pumpChat(tester, safetyService: safety);

    await _openReportSheet(tester);
    await _tapInSheet(tester, find.byKey(kReportSubmit));

    // 첫 신고가 아직 끝나지 않은 상태에서 다시 길게 눌러도 시트가 열리지 않는다.
    await tester.longPress(
      find.byKey(const ValueKey('message-reportable-m-other')),
    );
    await _settleSheet(tester);
    expect(find.byKey(kActionSheet), findsNothing);

    safety.gate!.complete();
    await _settleSheet(tester);
    expect(safety.messageReports, hasLength(1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('13. 같은 세션에서 재신고하면 안내만 표시한다', (tester) async {
    final safety = await _pumpChat(tester);

    await _openReportSheet(tester);
    await _tapInSheet(tester, find.byKey(kReportSubmit));
    expect(safety.messageReports, hasLength(1));

    await tester.longPress(
      find.byKey(const ValueKey('message-reportable-m-other')),
    );
    await _settleSheet(tester);

    expect(find.text('이미 신고한 메시지예요.'), findsOneWidget);
    expect(find.byKey(kActionSheet), findsNothing);
    expect(safety.messageReports, hasLength(1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('14~15. 실패 시 고정 문구만 보이고 원문은 로그에 남지 않는다', (tester) async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };

    final safety = await _pumpChat(
      tester,
      safetyService: _FakeSafetyService(failReport: true),
    );

    await _openReportSheet(tester);
    await _tapInSheet(tester, find.byKey(kReportSubmit));
    // foundation debug 변수는 테스트가 끝나기 전에 반드시 되돌려야 한다.
    debugPrint = original;

    expect(safety.messageReports, isEmpty);
    expect(find.text('메시지 신고에 실패했어요. 잠시 후 다시 시도해주세요.'), findsOneWidget);
    // 실패 로그에 메시지 원문·발신자 uid가 들어가지 않는다.
    final joined = logs.join('\n');
    expect(joined, isNot(contains(kOtherText)));
    expect(joined, isNot(contains(kOther)));
    // 실패했으므로 세션 신고 기록에 남지 않아 재시도할 수 있다.
    await tester.longPress(
      find.byKey(const ValueKey('message-reportable-m-other')),
    );
    await _settleSheet(tester);
    expect(find.byKey(kActionSheet), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('16. 기존 AppBar 사용자 신고 메뉴가 그대로 유지된다', (tester) async {
    // 기존 사용자 신고 시트(report_sheet.dart)는 스크롤이 없어 600px 기본 테스트
    // 뷰포트에서 overflow가 난다(Phase 2-4 이전부터의 기존 이슈, 이번 범위 밖).
    // 이 테스트의 목적은 "사용자 신고 경로가 그대로 살아 있는가"이므로 충분히
    // 큰 화면에서 확인한다.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpChat(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settleSheet(tester);

    expect(find.text('안전하게 대화하기'), findsOneWidget);
    expect(find.text('신고하기'), findsOneWidget);
    expect(find.text('차단하기'), findsOneWidget);
    expect(find.text('매칭 해제'), findsOneWidget);

    await tester.tap(find.text('신고하기'));
    await _settleSheet(tester);
    // 사용자 신고 시트는 기존 사유 목록을 쓴다(메시지 신고 시트가 아니다).
    expect(find.byKey(kReportSheet), findsNothing);
    expect(find.text('신고하기'), findsWidgets);
    expect(find.text('부적절한 사진'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('17~18. presence·약속·안전 배너 회귀 없음, 작은 화면/키보드 overflow 없음', (
    tester,
  ) async {
    final presence = _FakePresenceService();
    await _pumpChat(tester, messages: _allMessages, presenceService: presence);

    presence.emit(
      ChatPresence(
        uid: kOther,
        isOnline: true,
        isTyping: true,
        lastActiveAt: DateTime.now(),
      ),
    );
    await tester.pump();

    expect(find.text('입력 중...'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-safety-guide-banner')), findsOneWidget);
    expect(find.text('성수역 3번 출구'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-appointment-button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 신고 시트를 연 뒤 작은 화면 + 키보드로 바꿔도 overflow가 없어야 한다.
    await _openReportSheet(tester);
    expect(find.byKey(kReportSheet), findsOneWidget);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(kReportSheet), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
