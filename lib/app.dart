import 'dart:async';

import 'package:flutter/material.dart';

import 'core/constants/app_constants.dart';
import 'core/routes/app_routes.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/main_shell.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'services/auth/auth_service.dart';
import 'services/chat/chat_presence_service.dart';
import 'services/chat/chat_service.dart';
import 'services/charm/charm_service.dart';
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
  bool _profileChecked = false;
  bool _hasProfile = false;

  @override
  void initState() {
    super.initState();
    widget.authState.addListener(_onAuthChanged);
    // 앱 시작 시 Firebase Auth 스트림이 이미 발화된 상태일 때를 대비한 초기 체크.
    if (!widget.authState.initializing && widget.authState.isLoggedIn) {
      _fetchProfile();
    }
  }

  @override
  void dispose() {
    widget.authState.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!widget.authState.isLoggedIn) {
      // 로그아웃: 캐시된 프로필 체크 결과를 초기화해 다음 로그인에 대비한다.
      setState(() {
        _profileChecked = false;
        _hasProfile = false;
      });
      return;
    }
    if (!_profileChecked) {
      // 로그인됐지만 프로필 확인 전: 로딩 화면을 즉시 그린 뒤 조회를 시작한다.
      setState(() {});
      _fetchProfile();
    }
  }

  Future<void> _fetchProfile() async {
    final uid = widget.authState.currentUser?.uid;
    if (uid == null) return;
    debugPrint('[AuthGate] 프로필 조회 시작 — uid: $uid');
    try {
      final profile = await widget.firestoreService.getUserProfile(uid);
      if (profile != null) {
        await widget.authService.reloadUser();
        final shouldSyncVerifications =
            widget.authService.isEmailVerified != profile.verifications.email ||
            widget.authService.hasPhoneNumber != profile.verifications.phone ||
            profile.verifications.photo;
        if (shouldSyncVerifications) {
          try {
            await widget.authService.syncAuthVerificationBadges();
          } on AuthFailure catch (e) {
            if (mounted) {
              debugPrint('[AuthGate] 인증 배지 동기화 실패: ${e.message}');
            }
          }
        }
        unawaited(widget.notificationService.registerForUser(uid));
      }
      debugPrint(
        '[AuthGate] 조회 결과: ${profile != null ? "있음 (기존 유저)" : "없음 (신규 유저)"}',
      );
      if (mounted) {
        setState(() {
          _hasProfile = profile != null;
          _profileChecked = true;
        });
      }
    } catch (e) {
      // 권한 거부·네트워크 오류 등 모든 실패는 여기서 잡는다.
      // _profileChecked를 true로 바꿔 무한 로딩을 탈출하고,
      // _hasProfile을 false로 두어 온보딩 화면으로 안전하게 보낸다.
      debugPrint('[AuthGate] 조회 에러: $e');
      if (mounted) {
        setState(() {
          _hasProfile = false;
          _profileChecked = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 인증 초기화 중, 또는 로그인 후 프로필 조회 중에는 로딩.
    if (widget.authState.initializing ||
        (widget.authState.isLoggedIn && !_profileChecked)) {
      return const Scaffold(body: LoadingIndicator());
    }

    if (!widget.authState.isLoggedIn) {
      return LoginScreen(authService: widget.authService);
    }

    if (!_hasProfile) {
      return OnboardingScreen(
        uid: widget.authState.currentUser!.uid,
        authService: widget.authService,
        firestoreService: widget.firestoreService,
        storageService: widget.storageService,
        // 온보딩 완료 후 다시 Firestore를 조회하는 대신 플래그만 뒤집는다.
        // 방금 저장했으니 존재가 확실하고, 불필요한 네트워크 왕복을 줄인다.
        onCompleted: () {
          final uid = widget.authState.currentUser!.uid;
          setState(() => _hasProfile = true);
          unawaited(widget.notificationService.registerForUser(uid));
        },
      );
    }

    return MainShell(
      authService: widget.authService,
      firestoreService: widget.firestoreService,
      storageService: widget.storageService,
      discoveryService: widget.discoveryService,
      matchesService: widget.matchesService,
      chatService: widget.chatService,
      presenceService: widget.presenceService,
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
