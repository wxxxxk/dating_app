import 'package:flutter/material.dart';

class AppFonts {
  AppFonts._();

  static const String body = 'Pretendard';
  static const String display = 'MaruBuri';
}

class AppColors {
  AppColors._();

  static const Color background = Color(0xFFFAF7F2);
  static const Color surface = Color(0xFFFFFFFF);

  static const Color ink = Color(0xFF1C1B19);
  static const Color inkSecondary = Color(0xFF6B675F);

  static const Color seal = Color(0xFFC8372D);
  static const Color sealPressed = Color(0xFFA82C24);

  static const Color divider = Color(0xFFE8E2D8);

  static const Color wood = Color(0xFF3A7D5C);
  static const Color fire = Color(0xFFC8372D);
  static const Color earth = Color(0xFFC99A3C);
  static const Color metal = Color(0xFF8C8C88);
  static const Color water = Color(0xFF2E4A62);

  static const Color primary = mintDeep; // Phase 4: seal → 딥 민트로 repoint
  static const Color primaryDark = mintDeepPressed;
  static const Color secondary = inkSecondary;

  static const Color textPrimary = ink;
  static const Color textSecondary = inkSecondary;
  static const Color border = divider;
  static const Color error = sealPressed;
  static const Color white = surface;

  // ── Signature mint (Design Overhaul Phase 4: vivid mint) ─────────────────
  //
  // 레퍼런스(Marry Fit 계열 프리미엄 매칭앱)의 문법을 따른다:
  // "뉴트럴 base + 비비드 민트 단일 악센트".
  //
  // - mint: 시그니처 비비드 민트. CTA 버튼 fill, 다크 서피스 위 강조,
  //   선택된 칩 배경. 민트 fill 위 텍스트는 반드시 onMint(진한 잉크)를 쓴다
  //   — 흰 텍스트 금지(대비 부족 + 레퍼런스 문법과 다름).
  // - mintDeep: 라이트 배경 위 텍스트/아이콘/링크/outline 강조용 딥 민트.
  //   흰 배경 위에서 mint 원색은 대비가 부족하므로 글자에는 항상 이쪽.
  static const Color mint = Color(0xFF4BE39B);
  static const Color mintPressed = Color(0xFF33C983);
  static const Color onMint = Color(0xFF0C231A);
  static const Color mintDeep = Color(0xFF0E9F6B);
  static const Color mintDeepPressed = Color(0xFF0B8256);
  static const Color mintSoft = Color(0xFFE4FFF2);
  static const Color mintStrong = Color(0xFF62F2AB);

  // ── Dark premium surfaces (하이브리드 다크 영역) ──────────────────────────
  //
  // 앱 전체는 라이트를 유지하되, 히어로/프리미엄 영역(오늘의 인연, AI 이상형,
  // 젤리/멤버십, 매칭 성사)은 다크 서피스 카드로 대비를 만든다.
  static const Color night = Color(0xFF141816);
  static const Color nightAlt = Color(0xFF1E2421);
  static const Color nightBorder = Color(0xFF2A322E);
  static const Color onNight = Color(0xFFF2F5F3);
  static const Color onNightSecondary = Color(0xFF97A29B);

  // Premium Mint Dark Foundation v1 semantic aliases.
  static const Color backgroundDark = night;
  static const Color surfaceDark = nightAlt;
  static const Color surfaceElevated = Color(0xFF252D29);
  static const Color textOnDark = onNight;
  static const Color textMutedOnDark = onNightSecondary;
  static const Color creamBackground = background;
  static const Color danger = error;

  // ── Premium accent (구 다크 그린 → 딥 민트로 승계) ────────────────────────
  static const Color premium = mintDeep;
  static Color get premiumSoft => premium.withValues(alpha: 0.08);
  static Color get premiumBorder => premium.withValues(alpha: 0.22);

  // ── 색상 역할 정의 ────────────────────────────────────────────────────────
  //
  // 이 앱은 "사주 앱"이 아니라 "프리미엄 매칭앱에 사주/AI 인사이트가 얹힌
  // 앱"이다. 색의 역할을 용도 기준으로 나눈다:
  //
  // - matchPrimary(딥 민트): 라이트 배경의 활성 탭·링크·선택 상태·AI/매칭
  //   기능 강조. 이 앱의 핵심 accent.
  // - mint(비비드 민트): CTA fill과 다크 서피스 위 강조.
  // - fortuneAccent(=seal, 붉은 계열): 사주/궁합/오행 insight 강조 전용.
  //   매칭/AI 기능·버튼·버블에는 절대 쓰지 않는다.
  // - error(=sealPressed): 차단/신고/삭제 같은 destructive 액션 전용.
  //
  // Phase 4에서 AppColors.primary를 seal → matchPrimary로 repoint했다.
  // 아직 개별 리팩터를 거치지 않은 화면도 자동으로 민트 계열로 정리되며,
  // 사주 화면은 AppColors.fortuneAccent를 명시적으로 사용한다.
  static const Color matchPrimary = mintDeep;
  static const Color fortuneAccent = seal;

  /// 다크 서피스 위에서 쓰는 사주 레드. 원색 seal은 다크 배경에서 대비가
  /// 부족하므로 한 단계 밝힌 값을 쓴다.
  static const Color fortuneAccentBright = Color(0xFFF07A6C);
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  AppRadius._();

  static const double card = 20;
  static const double hero = 28;
  static const double button = 14;
  static const double chip = 999;
  static const double sheet = 28;
}

/// 카드 깊이 표현. flat 1px 보더만 쓰던 것에서 벗어나, 라이트 카드에는
/// 은은한 소프트 섀도우, 다크/히어로 카드에는 민트 글로우를 쓴다.
class AppShadows {
  AppShadows._();

  static List<BoxShadow> get card => [
    BoxShadow(
      color: const Color(0xFF1C1B19).withValues(alpha: 0.06),
      blurRadius: 20,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> get hero => [
    BoxShadow(
      color: const Color(0xFF1C1B19).withValues(alpha: 0.18),
      blurRadius: 28,
      offset: const Offset(0, 10),
    ),
  ];

  static List<BoxShadow> get mintGlow => [
    BoxShadow(
      color: AppColors.mint.withValues(alpha: 0.28),
      blurRadius: 24,
      offset: const Offset(0, 4),
    ),
  ];
}

class AppDurations {
  AppDurations._();

  static const Duration fast = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 280);
  static const Duration emphasis = Duration(milliseconds: 550);
  static const Duration staggerInterval = Duration(milliseconds: 40);
  static const Duration staggerWindow = Duration(milliseconds: 300);

  static Duration staggerDelay(int index) {
    final maxDelayMs = staggerWindow.inMilliseconds - fast.inMilliseconds;
    final delayMs = index * staggerInterval.inMilliseconds;
    final cappedMs = delayMs > maxDelayMs ? maxDelayMs : delayMs;
    return Duration(milliseconds: cappedMs < 0 ? 0 : cappedMs);
  }
}

class AppCurves {
  AppCurves._();

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutBack;
  static const Curve returnToCenter = Curves.elasticOut;
  static const Curve exit = Curves.easeInCubic;
}
