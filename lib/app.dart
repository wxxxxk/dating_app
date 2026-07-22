import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/constants/app_constants.dart';
import 'core/routes/app_routes.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/auth_gate_controller.dart';
import 'features/auth/auth_gate_error_view.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/signup_screen.dart';
import 'models/user_profile.dart';
import 'features/main_shell.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'services/auth/auth_service.dart';
import 'services/chat/appointment_safety_service.dart';
import 'services/chat/chat_presence_service.dart';
import 'features/privacy/screen_protection_widgets.dart';
import 'services/privacy/contact_avoidance_service.dart';
import 'services/privacy/screen_protection_service.dart';
import 'services/chat/chat_service.dart';
import 'services/charm/charm_service.dart';
import 'services/community/community_media_service.dart';
import 'services/community/community_service.dart';
import 'services/community/party_service.dart';
import 'services/database/firestore_service.dart';
import 'services/discovery/discovery_service.dart';
import 'services/fortune/fortune_service.dart';
import 'services/jelly/jelly_purchase_service.dart';
import 'services/jelly/jelly_service.dart';
import 'services/likes/likes_service.dart';
import 'services/matches/matches_service.dart';
import 'services/notifications/notification_service.dart';
import 'services/safety/safety_service.dart';
import 'services/storage/storage_service.dart';
import 'shared/state/auth_state.dart';
import 'shared/widgets/loading_indicator.dart';

/// 앱 루트 위젯.
///
/// 앱 전체에서 하나만 있어야 하는 서비스 객체들을 여기서 생성한다.
/// 외부 상태관리 패키지 없이 생성자 주입(constructor injection)으로 내려준다.
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AuthService _authService;
  late final AuthState _authState;
  late final FirestoreService _firestoreService;
  late final StorageService _storageService;
  late final DiscoveryService _discoveryService;
  late final MatchesService _matchesService;
  late final ChatService _chatService;
  late final ChatPresenceService _presenceService;
  late final AppointmentSafetyService _appointmentSafetyService;
  late final ContactAvoidanceService _contactAvoidanceService;
  late final CommunityService _communityService;
  late final CommunityMediaService _communityMediaService;
  late final PartyService _partyService;
  late final MethodChannelScreenProtectionService _screenProtectionService;
  late final CharmService _charmService;
  late final FortuneService _fortuneService;
  late final JellyService _jellyService;
  late final JellyPurchaseService _jellyPurchaseService;
  late final LikesService _likesService;
  late final SafetyService _safetyService;
  late final NotificationService _notificationService;
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _mainTabRequest = ValueNotifier<int?>(null);

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _authState = AuthState(_authService);
    _firestoreService = FirestoreService();
    _storageService = StorageService();
    _discoveryService = DiscoveryService();
    _chatService = ChatService();
    _presenceService = ChatPresenceService();
    _appointmentSafetyService = AppointmentSafetyService();
    _contactAvoidanceService = ContactAvoidanceService();
    _communityService = CommunityService();
    _communityMediaService = CommunityMediaService();
    _partyService = PartyService();
    _screenProtectionService = MethodChannelScreenProtectionService();
    _charmService = CharmService();
    _fortuneService = FortuneService();
    _jellyService = JellyService();
    _jellyPurchaseService = JellyPurchaseService();
    _safetyService = SafetyService(firestoreService: _firestoreService);
    // NotificationService보다 먼저 만들어야 한다 — 알림 탭으로 채팅방을 열 때
    // ChatScreen에 matchesService(매칭 해제용)를 넘겨줘야 하기 때문이다.
    _matchesService = MatchesService(
      firestoreService: _firestoreService,
      safetyService: _safetyService,
    );
    _notificationService = NotificationService(
      authService: _authService,
      firestoreService: _firestoreService,
      chatService: _chatService,
      presenceService: _presenceService,
      appointmentSafetyService: _appointmentSafetyService,
      fortuneService: _fortuneService,
      matchesService: _matchesService,
      safetyService: _safetyService,
      navigatorKey: _navigatorKey,
      mainTabRequest: _mainTabRequest,
    );
    _likesService = LikesService(
      firestoreService: _firestoreService,
      safetyService: _safetyService,
    );
    unawaited(_notificationService.initialize());
  }

  @override
  void dispose() {
    _authState.dispose();
    _mainTabRequest.dispose();
    unawaited(_notificationService.dispose());
    unawaited(_screenProtectionService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light,
      home: _AuthGate(
        authState: _authState,
        authService: _authService,
        firestoreService: _firestoreService,
        storageService: _storageService,
        discoveryService: _discoveryService,
        matchesService: _matchesService,
        chatService: _chatService,
        presenceService: _presenceService,
        appointmentSafetyService: _appointmentSafetyService,
        contactAvoidanceService: _contactAvoidanceService,
        communityService: _communityService,
        communityMediaService: _communityMediaService,
        partyService: _partyService,
        screenProtectionService: _screenProtectionService,
        charmService: _charmService,
        fortuneService: _fortuneService,
        jellyService: _jellyService,
        jellyPurchaseService: _jellyPurchaseService,
        likesService: _likesService,
        safetyService: _safetyService,
        notificationService: _notificationService,
        mainTabRequest: _mainTabRequest,
      ),
      // 이름 기반 라우트는 화면 간 직접 이동이 필요할 때 사용.
      // onGenerateRoute를 쓰는 이유: 각 화면에 서비스를 주입하면서 만들어야 하기 때문.
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case AppRoutes.signup:
            return MaterialPageRoute(
              builder: (_) => SignupScreen(authService: _authService),
              settings: settings,
            );
          case AppRoutes.home:
            return MaterialPageRoute(
              builder: (_) => MainShell(
                authService: _authService,
                firestoreService: _firestoreService,
                storageService: _storageService,
                discoveryService: _discoveryService,
                matchesService: _matchesService,
                chatService: _chatService,
                presenceService: _presenceService,
                appointmentSafetyService: _appointmentSafetyService,
                contactAvoidanceService: _contactAvoidanceService,
                communityService: _communityService,
                communityMediaService: _communityMediaService,
                partyService: _partyService,
                charmService: _charmService,
                fortuneService: _fortuneService,
                jellyService: _jellyService,
                jellyPurchaseService: _jellyPurchaseService,
                likesService: _likesService,
                safetyService: _safetyService,
                mainTabRequest: _mainTabRequest,
              ),
              settings: settings,
            );
          case AppRoutes.login:
            return MaterialPageRoute(
              builder: (_) => LoginScreen(authService: _authService),
              settings: settings,
            );
          default:
            return null;
        }
      },
    );
  }
}

/// 로그인 상태와 프로필 존재 여부를 보고 보여줄 화면을 결정하는 게이트.
///
/// 분기 로직:
///   미인증 → LoginScreen
///   인증됨 + 프로필 없음 → OnboardingScreen
///   인증됨 + 프로필 있음 → MainShell (둘러보기 · 매칭 · 내 프로필 탭)
///
/// StatefulWidget인 이유: 로그인 후 Firestore 조회 결과(_hasProfile, _profileChecked)를
/// 상태로 들고 있어야 하기 때문이다. ListenableBuilder 대신 addListener로 직접 구독해
/// 인증 변경 시 필요한 경우에만 setState를 호출한다.
class _AuthGate extends StatefulWidget {
  final AuthState authState;
  final AuthService authService;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final DiscoveryService discoveryService;
  final MatchesService matchesService;
  final ChatService chatService;
  final ChatPresenceService presenceService;
  final AppointmentSafetyService appointmentSafetyService;
  final ContactAvoidanceService contactAvoidanceService;
  final CommunityService communityService;
  final CommunityMediaService communityMediaService;
  final PartyService partyService;
  final ScreenProtectionService screenProtectionService;
  final CharmService charmService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final LikesService likesService;
  final SafetyService safetyService;
  final NotificationService notificationService;
  final ValueNotifier<int?> mainTabRequest;

  const _AuthGate({
    required this.authState,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.presenceService,
    required this.appointmentSafetyService,
    required this.contactAvoidanceService,
    required this.communityService,
    required this.communityMediaService,
    required this.partyService,
    required this.screenProtectionService,
    required this.charmService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.likesService,
    required this.safetyService,
    required this.notificationService,
    required this.mainTabRequest,
  });

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late final AuthGateController _controller;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _controller = AuthGateController(
      auth: widget.authState,
      loadProfile: (uid) => widget.firestoreService.getUserProfile(uid),
      runSideEffects: _runProfileSideEffects,
    );
    _controller.addListener(_onControllerChanged);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// 라우팅이 확정된 **뒤에** 실행되는 부가 작업.
  ///
  /// 예전에는 이 세 가지가 프로필 판정과 같은 try 안에 있어서, `reloadUser()`가
  /// 던지면 프로필이 실제로 존재하는데도 "프로필 없음"으로 접혔다. 각각을
  /// 독립적으로 감싸 어느 하나가 실패해도 나머지와 라우팅에 영향이 없게 한다.
  Future<void> _runProfileSideEffects(String uid, UserProfile profile) async {
    try {
      await widget.authService.reloadUser();
    } catch (_) {
      if (kDebugMode) debugPrint('[AuthGate] reload_user_failed');
    }

    try {
      final shouldSyncVerifications =
          widget.authService.isEmailVerified != profile.verifications.email ||
          widget.authService.hasPhoneNumber != profile.verifications.phone ||
          profile.verifications.photo;
      if (shouldSyncVerifications) {
        await widget.authService.syncAuthVerificationBadges();
      }
    } catch (_) {
      if (kDebugMode) debugPrint('[AuthGate] verification_badge_sync_failed');
    }

    try {
      await widget.notificationService.registerForUser(uid);
    } catch (_) {
      if (kDebugMode) debugPrint('[AuthGate] notification_register_failed');
    }
  }

  Future<void> _handleSignOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      await widget.authService.signOut();
      // Navigator로 억지로 이동하지 않는다. authState가 바뀌면 컨트롤러가
      // unauthenticated로 내려가고 아래 build가 LoginScreen을 그린다.
    } catch (_) {
      if (kDebugMode) debugPrint('[AuthGate] sign_out_failed');
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 화면 캡처 보호(Phase 3-5)는 route가 아니라 로그인 상태 한 곳에서만
    // 켜고 끈다. 인증 상태가 확정되기 전(initializing)에는 보호를 켠 상태로
    // 두어(fail-closed) 첫 프레임이 노출되지 않게 한다.
    final protectionEnabled =
        widget.authState.initializing || widget.authState.isLoggedIn;
    return ScreenProtectionCoordinator(
      service: widget.screenProtectionService,
      loggedIn: protectionEnabled,
      child: _buildGate(context),
    );
  }

  Widget _buildGate(BuildContext context) {
    switch (_controller.status) {
      case AuthGateStatus.loading:
        return const Scaffold(
          key: Key('auth-gate-loading'),
          body: LoadingIndicator(),
        );

      case AuthGateStatus.unauthenticated:
        return LoginScreen(authService: widget.authService);

      case AuthGateStatus.recoverableError:
        // 조회 실패는 실패로 표시한다. 여기서 온보딩을 보여주면 기존 유저가
        // 사진 등록 화면에 갇힌다.
        return AuthGateErrorView(
          busy: _signingOut,
          onRetry: () => unawaited(_controller.retry()),
          onSignOut: () => unawaited(_handleSignOut()),
        );

      case AuthGateStatus.onboarding:
        return OnboardingScreen(
          uid: widget.authState.currentUser!.uid,
          authService: widget.authService,
          firestoreService: widget.firestoreService,
          storageService: widget.storageService,
          onSignOut: _handleSignOut,
          currentAuthUid: () => widget.authState.currentUid,
          // 온보딩 완료 후 다시 Firestore를 조회하는 대신 플래그만 뒤집는다.
          // 방금 저장했으니 존재가 확실하고, 불필요한 네트워크 왕복을 줄인다.
          onCompleted: () {
            final uid = widget.authState.currentUser!.uid;
            _controller.markProfileCreated(uid);
            unawaited(widget.notificationService.registerForUser(uid));
          },
        );

      case AuthGateStatus.authenticated:
        return _buildMainShell();
    }
  }

  Widget _buildMainShell() {
    return MainShell(
      authService: widget.authService,
      firestoreService: widget.firestoreService,
      storageService: widget.storageService,
      discoveryService: widget.discoveryService,
      matchesService: widget.matchesService,
      chatService: widget.chatService,
      presenceService: widget.presenceService,
      appointmentSafetyService: widget.appointmentSafetyService,
      contactAvoidanceService: widget.contactAvoidanceService,
      communityService: widget.communityService,
      communityMediaService: widget.communityMediaService,
      partyService: widget.partyService,
      charmService: widget.charmService,
      fortuneService: widget.fortuneService,
      jellyService: widget.jellyService,
      jellyPurchaseService: widget.jellyPurchaseService,
      likesService: widget.likesService,
      safetyService: widget.safetyService,
      mainTabRequest: widget.mainTabRequest,
    );
  }
}
