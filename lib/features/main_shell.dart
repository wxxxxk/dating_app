import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../services/auth/auth_service.dart';
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
  final CharmService charmService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final LikesService likesService;
  final SafetyService safetyService;

  const MainShell({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.charmService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.likesService,
    required this.safetyService,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

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
            fortuneService: widget.fortuneService,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            safetyService: widget.safetyService,
          ),
          MatchesScreen(
            authService: widget.authService,
            matchesService: widget.matchesService,
            chatService: widget.chatService,
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
            charmService: widget.charmService,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            safetyService: widget.safetyService,
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textSecondary,
        backgroundColor: AppColors.background,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.explore_outlined),
            activeIcon: Icon(Icons.explore),
            label: '둘러보기',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.favorite_outline_rounded),
            activeIcon: Icon(Icons.favorite_rounded),
            label: '매칭',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_awesome_outlined),
            activeIcon: Icon(Icons.auto_awesome_rounded),
            label: '사주',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: '내 프로필',
          ),
        ],
      ),
    );
  }
}
