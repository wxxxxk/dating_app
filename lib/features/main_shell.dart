import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../services/auth/auth_service.dart';
import '../services/chat/appointment_safety_service.dart';
import '../services/chat/chat_presence_service.dart';
import '../services/chat/chat_service.dart';
import '../services/charm/charm_service.dart';
import '../services/database/firestore_service.dart';
import '../services/discovery/discovery_service.dart';
import '../services/fortune/fortune_service.dart';
import '../services/jelly/jelly_purchase_service.dart';
import '../services/jelly/jelly_service.dart';
import '../services/likes/likes_service.dart';
import '../services/matches/matches_service.dart';
import '../services/safety/safety_service.dart';
import '../services/storage/storage_service.dart';
import 'discovery/discovery_screen.dart';
import 'fortune/fortune_hub_screen.dart';
import 'home/home_screen.dart';
import 'matches/matches_screen.dart';

/// 하단 4탭 내비게이션 쉘.
///
/// 탭 0: 둘러보기 (DiscoveryScreen)
/// 탭 1: 매칭    (MatchesScreen)   ← M4 신규
/// 탭 2: 사주    (FortuneHubScreen) ← M6.5 신규 — 오늘의 운세/내 사주/궁합 허브
/// 탭 3: 내 프로필 (HomeScreen)
///
/// 사주는 "매칭 앱 + 강력한 사주 코너" 정체성을 위한 독립 탭이다.
/// 매칭 순서·스와이프 카드에는 사주를 강제로 결합하지 않는다(의도적 제외).
///
/// IndexedStack으로 탭 전환 시 각 화면의 State를 보존한다.
class MainShell extends StatefulWidget {
  final AuthService authService;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final DiscoveryService discoveryService;
  final MatchesService matchesService;
  final ChatService chatService;
  final ChatPresenceService presenceService;
  final AppointmentSafetyService appointmentSafetyService;
  final CharmService charmService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final LikesService likesService;
  final SafetyService safetyService;
  final ValueNotifier<int?> mainTabRequest;

  const MainShell({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.presenceService,
    required this.appointmentSafetyService,
    required this.charmService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.likesService,
    required this.safetyService,
    required this.mainTabRequest,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
  Stream<int>? _unreadMatchStream;

  @override
  void initState() {
    super.initState();
    widget.mainTabRequest.addListener(_handleTabRequest);
    _applyPendingTabRequest();
    final uid = widget.authService.currentUser?.uid;
    if (uid != null) {
      _unreadMatchStream = widget.matchesService.watchUnreadMatchCount(
        currentUid: uid,
      );
    }
  }

  @override
  void dispose() {
    widget.mainTabRequest.removeListener(_handleTabRequest);
    super.dispose();
  }

  void _handleTabRequest() {
    _applyPendingTabRequest();
  }

  void _applyPendingTabRequest() {
    final requestedIndex = widget.mainTabRequest.value;
    if (requestedIndex == null) return;
    if (requestedIndex < 0 || requestedIndex > 3) {
      widget.mainTabRequest.value = null;
      return;
    }
    if (mounted) {
      setState(() => _selectedIndex = requestedIndex);
    } else {
      _selectedIndex = requestedIndex;
    }
    widget.mainTabRequest.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          DiscoveryScreen(
            authService: widget.authService,
            firestoreService: widget.firestoreService,
            discoveryService: widget.discoveryService,
            matchesService: widget.matchesService,
            chatService: widget.chatService,
            presenceService: widget.presenceService,
            appointmentSafetyService: widget.appointmentSafetyService,
            fortuneService: widget.fortuneService,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            safetyService: widget.safetyService,
          ),
          MatchesScreen(
            authService: widget.authService,
            matchesService: widget.matchesService,
            chatService: widget.chatService,
            presenceService: widget.presenceService,
            appointmentSafetyService: widget.appointmentSafetyService,
            firestoreService: widget.firestoreService,
            fortuneService: widget.fortuneService,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            discoveryService: widget.discoveryService,
            likesService: widget.likesService,
            safetyService: widget.safetyService,
          ),
          FortuneHubScreen(
            authService: widget.authService,
            firestoreService: widget.firestoreService,
            matchesService: widget.matchesService,
            fortuneService: widget.fortuneService,
            onExploreTap: () => setState(() => _selectedIndex = 0),
          ),
          HomeScreen(
            authService: widget.authService,
            firestoreService: widget.firestoreService,
            storageService: widget.storageService,
            discoveryService: widget.discoveryService,
            matchesService: widget.matchesService,
            charmService: widget.charmService,
            fortuneService: widget.fortuneService,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            likesService: widget.likesService,
            safetyService: widget.safetyService,
            onOpenDiscovery: () => setState(() => _selectedIndex = 0),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        // 발표용 긴급 안정화: 탭바를 전면 다크로 고정하지 않고 앱 전체와
        // 같은 라이트/크림 언어로 복구한다. 선택 상태만 mintDeep으로 강조한다.
        decoration: const BoxDecoration(
          color: AppColors.background,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) => setState(() => _selectedIndex = index),
          selectedItemColor: AppColors.matchPrimary,
          unselectedItemColor: AppColors.inkSecondary,
          backgroundColor: AppColors.background,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          items: [
            const BottomNavigationBarItem(
              icon: _NavIconPill(icon: Icons.explore_outlined, selected: false),
              activeIcon: _NavIconPill(
                icon: Icons.explore_rounded,
                selected: true,
              ),
              label: '둘러보기',
            ),
            BottomNavigationBarItem(
              icon: _NavIconPill(
                selected: false,
                child: _MatchesTabIcon(
                  stream: _unreadMatchStream,
                  icon: Icons.favorite_outline_rounded,
                  selected: false,
                ),
              ),
              activeIcon: _NavIconPill(
                selected: true,
                child: _MatchesTabIcon(
                  stream: _unreadMatchStream,
                  icon: Icons.favorite_rounded,
                  selected: true,
                ),
              ),
              label: '매칭',
            ),
            const BottomNavigationBarItem(
              icon: _NavIconPill(
                icon: Icons.auto_awesome_outlined,
                selected: false,
              ),
              activeIcon: _NavIconPill(
                icon: Icons.auto_awesome_rounded,
                selected: true,
              ),
              label: '사주',
            ),
            const BottomNavigationBarItem(
              icon: _NavIconPill(
                icon: Icons.person_outline_rounded,
                selected: false,
              ),
              activeIcon: _NavIconPill(
                icon: Icons.person_rounded,
                selected: true,
              ),
              label: '내 프로필',
            ),
          ],
        ),
      ),
    );
  }
}

/// 선택된 탭에 부드러운 pill 배경을 깔아 "이 탭이 활성 상태"라는 신호를
/// 아이콘 색만이 아니라 배경으로도 준다 — 프리미엄 매칭앱 탭바에서 흔한
/// 패턴. [child]가 있으면(매칭 탭처럼 배지 조합이 필요한 경우) 그걸 감싸고,
/// 없으면 [icon]을 바로 그린다.
class _NavIconPill extends StatelessWidget {
  final IconData? icon;
  final Widget? child;
  final bool selected;

  const _NavIconPill({this.icon, this.child, required this.selected})
    : assert(icon != null || child != null, 'icon 또는 child 중 하나는 있어야 한다');

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppDurations.fast,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? AppColors.mintSoft : null,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child:
          child ??
          Icon(
            icon,
            size: 22,
            color: selected ? AppColors.matchPrimary : AppColors.inkSecondary,
          ),
    );
  }
}

/// "매칭" 탭 아이콘 + 안읽음 배지.
///
/// StreamBuilder를 아이콘 단위로 좁혀서, 안읽음 개수가 바뀔 때
/// BottomNavigationBar 전체가 아니라 이 작은 위젯만 다시 그린다.
class _MatchesTabIcon extends StatelessWidget {
  final Stream<int>? stream;
  final IconData icon;
  final bool selected;

  const _MatchesTabIcon({
    required this.stream,
    required this.icon,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.matchPrimary : AppColors.inkSecondary;
    final s = stream;
    if (s == null) return Icon(icon, color: color);
    return StreamBuilder<int>(
      stream: s,
      builder: (context, snap) {
        final count = snap.data ?? 0;
        return Badge(
          isLabelVisible: count > 0,
          label: Text(count > 9 ? '9+' : '$count'),
          backgroundColor: AppColors.danger,
          child: Icon(icon, color: color),
        );
      },
    );
  }
}
