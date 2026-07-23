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

  // ══ Light Premium v1 (Design Phase 1-A) ═══════════════════════════════════
  //
  // 앱 전체를 다크로 전환하던 이전 방향은 폐기했다. 확정 방향은
  // "웜 화이트 캔버스 + 흰색 카드 + 차콜 타이포 + 민트 단일 브랜드 컬러"다.
  //
  // 기존 토큰(background/surface/mint/seal 계열)은 값을 바꾸지 않는다 —
  // 이미 20개 이상 화면이 참조하고 있어서 값을 건드리면 파일럿 범위를 넘는
  // 변화가 앱 전체에 번진다. 대신 아래 semantic 토큰을 새로 추가하고,
  // 리디자인한 화면부터 순차적으로 이쪽으로 옮긴다.
  //
  // 사주 화면도 fortuneAccent(레드)를 일반 강조에 쓰지 않고 brandPrimary
  // 계열을 쓴다. 레드는 오류/삭제/위험에만 남긴다.

  // ── Canvas: 화면 배경 ─────────────────────────────────────────────────────
  /// 기본 화면 배경. 기존 background(#FAF7F2)보다 노란기를 뺀 뉴트럴 웜 화이트.
  static const Color warmCanvas = Color(0xFFF7F7F4);

  /// 캔버스 위에서 한 단계 눌러 앉힌 영역(구분선 대용 밴드, 비활성 트랙 등).
  static const Color canvasSubtle = Color(0xFFF1F3F1);

  // ── Surface: 카드 ─────────────────────────────────────────────────────────
  static const Color surfacePrimary = Color(0xFFFFFFFF);
  static const Color surfaceSecondary = Color(0xFFF4F7F5);

  /// 브랜드 톤의 아주 옅은 서피스. 강조 카드/보조 정보 블록에만 쓰고,
  /// 카드마다 서로 다른 파스텔을 배정하지 않는다.
  static const Color surfaceMintSoft = Color(0xFFEAF9F2);
  static const Color surfacePressed = Color(0xFFEEF2F0);

  // ── Brand: 민트 단일 브랜드 컬러 ──────────────────────────────────────────
  //
  // 대비 실측(흰 배경/흰 글자 기준):
  // - brandPrimary #16A874 : 흰 배경 대비 약 3.1:1 → 아이콘·보더·큰 텍스트·
  //   선택 상태 표시용. 작은 본문 텍스트에는 쓰지 않는다.
  // - brandPrimaryStrong #0B855B : 흰 배경 대비 약 4.6:1, 흰 글자 대비 약
  //   4.6:1 → 본문 링크/라벨 텍스트와 CTA fill 양쪽에 안전하다.
  //   그래서 primary 버튼 배경은 brandPrimary가 아니라 이쪽을 쓴다.
  static const Color brandPrimary = Color(0xFF16A874);
  static const Color brandPrimaryStrong = Color(0xFF0B855B);
  static const Color brandPrimaryPressed = Color(0xFF096F4B);
  static const Color brandPrimarySoft = Color(0xFFDDF6EB);
  static const Color onBrandPrimary = Color(0xFFFFFFFF);

  // ── Typography ────────────────────────────────────────────────────────────
  static const Color textStrong = Color(0xFF171A1D);
  static const Color textBody = Color(0xFF596168);
  static const Color textMuted = Color(0xFF8A9298);
  static const Color textOnImage = Color(0xFFFFFFFF);

  // ── Border ────────────────────────────────────────────────────────────────
  static const Color borderSubtle = Color(0xFFE4E8E5);
  static const Color borderStrong = Color(0xFFCDD4D0);

  // ── Status ────────────────────────────────────────────────────────────────
  //
  // 브랜드 민트와 혼동되지 않도록 success는 별도로 만들지 않는다 —
  // 성공/활성 상태는 brandPrimary 계열을 그대로 쓴다.
  static const Color statusWarning = Color(0xFFE9A23B);
  static const Color statusWarningSoft = Color(0xFFFDF3E3);
  static const Color statusDanger = Color(0xFFD84B4B);
  static const Color statusDangerSoft = Color(0xFFFCEDED);

  // ── Expressive accent (Design Phase 1-A-2) ────────────────────────────────
  //
  // 브랜드 민트는 "기능"의 색이다. 설렘·인연·AI 생성 결과처럼 감정을 다루는
  // 표현에는 민트만으로 부족해서 soft coral 하나만 추가한다. 라벤더는 채택하지
  // 않았다 — 코랄이 데이팅 맥락의 온기와 더 맞고, 사주 레드(seal #C8372D)와도
  // 채도/명도가 확연히 달라 "전통 운세 레드"로 읽히지 않는다.
  //
  // 허용: abstract motif, AI 이상형 preview, 매치/설렘 장식, 축하 상태.
  // 금지: CTA, 하단 내비, 링크 텍스트, 오류, 카드 배경 전면, 화면 전체 tint.
  static const Color expressiveAccent = Color(0xFFF08B7A);
  static const Color expressiveAccentSoft = Color(0xFFFDEDE8);
}

/// Light Premium v1 타이포 계층.
///
/// 화면마다 임의의 TextStyle을 새로 만들지 않도록 계층을 고정한다. 색상만으로
/// 강조하지 않고 크기·굵기·행간을 함께 쓴다.
class AppTextStyles {
  AppTextStyles._();

  /// **Insight typography** — "사주 전용"이 아니라 **깊은 분석 결과 전용**이다.
  ///
  /// 허용 범위: 오늘의 운세 mood, 궁합 핵심 결과, 매력 리포트 결론처럼 사용자가
  /// 읽고 곱씹는 한 줄. 명조(MaruBuri)를 유지한 판단 근거는, 이 서체가 문제가
  /// 되는 것은 "사주 앱스러운 레드/금색/문양"과 함께 쓰일 때이고, 웜 화이트 +
  /// 민트 editorial 위에서 산세리프 본문과 대비될 때는 에디토리얼 인상을 만들기
  /// 때문이다. 그 전제를 지키기 위해 아래를 금지한다:
  /// 내비게이션, 버튼, 일반 카드 제목, 라벨, 목록 항목.
  static const TextStyle insight = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 27,
    height: 1.28,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  static const TextStyle screenTitle = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 22,
    height: 1.26,
    fontWeight: FontWeight.w800,
    color: AppColors.textStrong,
  );

  static const TextStyle sectionTitle = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  static const TextStyle cardTitle = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 16,
    height: 1.32,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  static const TextStyle body = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 15,
    height: 1.62,
    fontWeight: FontWeight.w400,
    color: AppColors.textStrong,
  );

  /// 카드 부제/설명. 본문보다 한 단계 작지만 muted까지 내리지 않는다.
  static const TextStyle bodySecondary = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 14,
    height: 1.55,
    fontWeight: FontWeight.w400,
    color: AppColors.textBody,
  );

  static const TextStyle label = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: AppColors.textBody,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 12.5,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.textMuted,
  );
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  // ── Light Premium v1 ──────────────────────────────────────────────────────
  // 4·8·12·16·20·24·32 스케일에서 비어 있던 20 단계와, 반복되는 화면 여백을
  // 이름으로 고정한다. 화면마다 13/17/23 같은 임의값을 만들지 않는다.
  static const double lg20 = 20;

  /// 화면 좌우 기본 padding. 좁은 기기에서는 [screenHCompact]까지 줄인다.
  static const double screenH = 20;
  static const double screenHCompact = 16;

  /// 일반 카드 내부 padding.
  static const double cardPadding = 18;

  /// 히어로 카드 내부 padding.
  static const double heroPadding = 22;
}

class AppRadius {
  AppRadius._();

  static const double card = 20;
  static const double hero = 28;
  static const double button = 14;
  static const double chip = 999;
  static const double sheet = 28;

  // ── Light Premium v1 ──────────────────────────────────────────────────────
  // 카드와 컨트롤이 같은 radius로 뭉개지지 않도록 단계를 분리한다.
  // 완전한 pill([chip])은 태그·상태 표시에만 쓴다.
  static const double small = 12;
  static const double control = 12;
  static const double surface = 18;
  static const double heroSoft = 22;
}

/// Light Premium v1 모션 규칙.
///
/// 새 애니메이션 패키지를 쓰지 않고 Flutter 기본 위젯만으로 표현한다.
/// 모션이 입력 반응을 지연시키지 않는 것이 원칙이다 — 콜백은 즉시 실행하고
/// 시각 효과만 뒤따른다.
class AppMotion {
  AppMotion._();

  /// 터치 피드백. 눌린 느낌만 주고 바로 복귀한다.
  static const Duration press = Duration(milliseconds: 120);
  static const double pressScale = 0.98;

  /// 작은 상태 변화(색/보더/아이콘 전환).
  static const Duration small = Duration(milliseconds: 200);

  /// 카드/콘텐츠 전환.
  static const Duration content = Duration(milliseconds: 280);

  /// 화면 진입 fade + slide.
  static const Duration entrance = Duration(milliseconds: 340);
  static const double entranceOffsetY = 12;

  /// 카드 사이 stagger 간격. 전체 진입은 500ms 안에 끝난다.
  static const Duration staggerStep = Duration(milliseconds: 55);
  static const Duration staggerCap = Duration(milliseconds: 220);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;

  /// index번째 요소의 진입 지연. 뒤쪽 카드가 무한정 늦어지지 않도록 캡을 둔다.
  static Duration staggerDelay(int index) {
    final ms = index * staggerStep.inMilliseconds;
    return Duration(
      milliseconds: ms > staggerCap.inMilliseconds
          ? staggerCap.inMilliseconds
          : ms,
    );
  }
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
