import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/profile/profile_keyword_summary_service.dart';
import '../../services/storage/profile_photo_processor.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../models/fortune/birth_profile.dart';
import 'basic_info_step.dart';
import 'detail_info_step.dart';
import 'photo_upload_step.dart';
import 'relationship_goal_step.dart';
import 'tag_selection_step.dart';

/// 온보딩 화면 — 7스텝 컨테이너 (M2.5).
///
/// 스텝 0: 사진 선택 (메인 1장 + 일상 3장)
/// 스텝 1: 기본 정보 (이름·생년월일·성별·소개)
/// 스텝 2: 상세 정보 (키·종교·흡연·음주·직업·학력·MBTI) — 선택
/// 스텝 3: 관심사 태그 — 선택
/// 스텝 4: 성향 태그 — 선택
/// 스텝 5: 이상형 태그 — 선택
/// 스텝 6: 찾는 관계 (단일 선택) — 선택 + 최종 저장 트리거
///
/// 스텝 간 공유 데이터와 최종 Firestore/Storage 저장 로직을 여기서 관리한다.
/// 각 스텝 위젯은 UI와 입력 수집에만 집중하고 Firebase 호출은 여기서 한다.
/// 온보딩 제출을 중단해야 하는지 판정한다.
///
/// 로그아웃·계정 전환 뒤에도 제출이 이어지면 사라진 uid나 다른 계정 uid로
/// 프로필을 쓰게 된다. [readAuthUid]가 null이면(Auth를 붙이지 않은 위젯 테스트)
/// 검사를 건너뛴다.
bool shouldAbortSubmitForAuthChange({
  required String? Function()? readAuthUid,
  required String onboardingUid,
}) {
  if (readAuthUid == null) return false;
  return readAuthUid() != onboardingUid;
}

class OnboardingScreen extends StatefulWidget {
  final String uid;
  final AuthService authService;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final VoidCallback onCompleted;

  /// 온보딩 도중 로그인 화면으로 빠져나가기 위한 경로.
  ///
  /// 첫 단계(사진 등록)에는 뒤로가기가 없어서, 잘못 들어왔을 때 나갈 방법이
  /// 전혀 없었다. 로그아웃을 유일한 출구로 항상 열어둔다.
  final Future<void> Function()? onSignOut;

  /// 제출 직전 현재 Auth uid를 확인하는 훅.
  ///
  /// 로그아웃·계정 전환 뒤에도 제출이 이어지면 사라진 uid로 프로필을 쓰게 된다.
  /// null이면 검사를 건너뛴다(Auth를 붙이지 않는 위젯 테스트용).
  final String? Function()? currentAuthUid;
  final ProfileKeywordSummaryService? profileKeywordSummaryService;

  /// 사진 선택기 주입점(위젯 테스트용). production은 기본 구현을 쓴다.
  final ProfilePhotoPicker? photoPicker;

  const OnboardingScreen({
    super.key,
    required this.uid,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.onCompleted,
    this.onSignOut,
    this.currentAuthUid,
    this.profileKeywordSummaryService,
    this.photoPicker,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final ProfileKeywordSummaryService _profileKeywordSummaryService;

  int _step = 0;
  bool _isLoading = false;

  // ── 스텝 0: 사진 ──────────────────────────────────────────────────────────
  ProcessedProfilePhoto? _mainImage;
  final List<ProcessedProfilePhoto> _subImages = [];

  // ── 스텝 1: 기본 정보 ────────────────────────────────────────────────────
  String _name = '';
  DateTime? _birthDate;
  // 회원가입에서 반드시 선택된다 — legacyMissing 상태로 신규 문서를 만들지 않는다.
  BirthProfile? _birthProfile;
  String? _gender;
  String _bio = '';

  // ── 스텝 2: 상세 정보 ────────────────────────────────────────────────────
  int? _height;
  String? _religion;
  String? _smoking;
  String? _drinking;
  String? _jobCategory;
  String? _jobTitle;
  String? _education;
  String? _mbti;

  // ── 스텝 3~5: 태그 (key 목록) ────────────────────────────────────────────
  List<String> _interests = [];
  List<String> _personalityTags = [];
  List<String> _idealTags = [];

  static const int _totalSteps = 7;

  @override
  void initState() {
    super.initState();
    _profileKeywordSummaryService =
        widget.profileKeywordSummaryService ?? ProfileKeywordSummaryService();
  }

  void _nextStep() => setState(() => _step++);
  void _prevStep() => setState(() => _step--);

  /// 모든 데이터를 모아 Storage + Firestore에 저장한다.
  /// [goalKey]: 스텝 6에서 선택한 찾는 관계 key.
  /// 로그아웃 진행 중 플래그. 중복 실행과 저장 중 이탈을 막는다.
  bool _signingOut = false;

  Future<void> _handleSignOut() async {
    final signOut = widget.onSignOut;
    if (signOut == null) return;
    if (_isLoading || _signingOut) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('로그아웃할까요?'),
        content: const Text('작성 중인 내용은 저장되지 않아요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _signingOut = true);
    try {
      // Navigator로 직접 이동하지 않는다. AuthGate가 선언적으로 LoginScreen을
      // 그리도록 두어야 화면 스택이 어긋나지 않는다.
      await signOut();
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _handleSubmit(String? goalKey) async {
    // Auth 사용자가 사라진 뒤(로그아웃·계정 삭제) 제출을 이어가지 않는다.
    // 그대로 진행하면 사라진 uid나 다른 계정 uid로 프로필을 쓰게 된다.
    if (shouldAbortSubmitForAuthChange(
      readAuthUid: widget.currentAuthUid,
      onboardingUid: widget.uid,
    )) {
      if (kDebugMode) debugPrint('[Onboarding] submit_aborted_auth_changed');
      return;
    }
    if (_signingOut) return;
    setState(() => _isLoading = true);
    try {
      // 1. 사진 업로드 (진행률 표시는 추후 개선 — 이번엔 단순 await)
      final photoUrls = await widget.storageService.uploadMultipleProfilePhotos(
        uid: widget.uid,
        mainPhoto: _mainImage!,
        subPhotos: _subImages,
      );

      // 2. UserProfile 생성 (모든 M2.5 필드 포함)
      final now = DateTime.now();
      await widget.authService.reloadUser();
      final profile = UserProfile(
        uid: widget.uid,
        displayName: _name,
        birthDate: _birthDate!,
        birthProfile: _birthProfile ?? const BirthProfile.unknownTime(),
        gender: _gender!,
        bio: _bio,
        photoUrls: photoUrls,
        createdAt: now,
        updatedAt: now,
        height: _height,
        religion: _religion,
        smoking: _smoking,
        drinking: _drinking,
        jobCategory: _jobCategory,
        jobTitle: _jobTitle,
        education: _education,
        mbti: _mbti,
        interests: _interests,
        personalityTags: _personalityTags,
        idealTags: _idealTags,
        relationshipGoal: goalKey,
        verifications: const VerificationStatus(),
      );
      await widget.firestoreService.createUserProfile(profile);
      await widget.authService.reloadUser();
      if (widget.authService.hasAnyAuthVerificationSignal) {
        try {
          await widget.authService.syncAuthVerificationBadges();
        } on AuthFailure catch (e) {
          if (kDebugMode) {
            debugPrint('[Onboarding] 인증 배지 동기화 실패: ${e.message}');
          }
        }
      }

      unawaited(_generateProfileKeywordSummaryBestEffort());

      // 3. 완료: app.dart에 알려 HomeScreen으로 전환
      widget.onCompleted();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Onboarding] 프로필 저장 실패: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('프로필 저장에 실패했어요. 잠시 후 다시 시도해주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _generateProfileKeywordSummaryBestEffort() async {
    try {
      await _profileKeywordSummaryService.generate();
    } on ProfileKeywordSummaryFailure catch (e) {
      if (kDebugMode) {
        debugPrint('[Onboarding] AI 키워드 요약 생성 실패: ${e.code}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Onboarding] AI 키워드 요약 생성 실패: ${e.runtimeType}');
      }
    }
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0:
        return PhotosUploadStep(
          photoPicker: widget.photoPicker,
          mainImage: _mainImage,
          subImages: _subImages,
          onMainImageChanged: (f) => setState(() => _mainImage = f),
          onSubImagesChanged: (list) => setState(() {
            _subImages
              ..clear()
              ..addAll(list);
          }),
          onNext: _nextStep,
        );
      case 1:
        return BasicInfoStep(
          onNext:
              ({
                required name,
                required birthDate,
                required birthProfile,
                required gender,
                required bio,
              }) {
                _name = name;
                _birthDate = birthDate;
                _birthProfile = birthProfile;
                _gender = gender;
                _bio = bio;
                _nextStep();
              },
        );
      case 2:
        return DetailInfoStep(
          initialHeight: _height,
          initialReligion: _religion,
          initialSmoking: _smoking,
          initialDrinking: _drinking,
          initialJobCategory: _jobCategory,
          initialJobTitle: _jobTitle,
          initialEducation: _education,
          initialMbti: _mbti,
          onNext:
              ({
                required height,
                required religion,
                required smoking,
                required drinking,
                required jobCategory,
                required jobTitle,
                required education,
                required mbti,
              }) {
                _height = height;
                _religion = religion;
                _smoking = smoking;
                _drinking = drinking;
                _jobCategory = jobCategory;
                _jobTitle = jobTitle;
                _education = education;
                _mbti = mbti;
                _nextStep();
              },
        );
      case 3:
        // ValueKey 필수: 스텝 3·4·5 모두 TagSelectionStep이라 key가 없으면
        // Flutter가 같은 위젯으로 판단해 _selectedKeys 상태를 재사용한다.
        // key가 다르면 스텝 전환 시 State가 완전히 재생성되어 initState()가 올바르게 실행된다.
        return TagSelectionStep(
          key: const ValueKey('tag_interests'),
          title: '관심사',
          subtitle: '나의 취미·라이프스타일을 보여주세요\n최대 8개 선택할 수 있어요',
          options: ProfileOptions.interests,
          initialSelected: _interests,
          onNext: (keys) {
            _interests = keys;
            _nextStep();
          },
        );
      case 4:
        return TagSelectionStep(
          key: const ValueKey('tag_personalities'),
          title: '나를 표현하는 키워드',
          subtitle: '나의 성격·스타일을 잘 나타내는 키워드를 골라보세요\n최대 8개',
          options: ProfileOptions.personalities,
          initialSelected: _personalityTags,
          onNext: (keys) {
            _personalityTags = keys;
            _nextStep();
          },
        );
      case 5:
        return TagSelectionStep(
          key: const ValueKey('tag_ideals'),
          title: '이런 친구를 찾고 있어요',
          subtitle: '내가 선호하는 상대의 키워드를 선택해주세요\n최대 8개',
          options: ProfileOptions.ideals,
          initialSelected: _idealTags,
          onNext: (keys) {
            _idealTags = keys;
            _nextStep();
          },
        );
      case 6:
        return RelationshipGoalStep(
          isLoading: _isLoading,
          onCompleted: _handleSubmit,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            // 스텝 0에는 돌아갈 이전 스텝이 없다. 대신 로그아웃을 출구로 둔다.
            automaticallyImplyLeading: false,
            leading: _step > 0
                ? IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 20,
                    ),
                    onPressed: _isLoading ? null : _prevStep,
                  )
                : null,
            actions: [
              if (widget.onSignOut != null)
                TextButton(
                  key: const Key('onboarding-sign-out-button'),
                  onPressed: (_isLoading || _signingOut)
                      ? null
                      : _handleSignOut,
                  child: const Text('로그아웃'),
                ),
            ],
            backgroundColor: AppColors.background.withValues(alpha: 0),
            elevation: 0,
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
                  child: _StepProgressBar(
                    current: _step + 1,
                    total: _totalSteps,
                  ),
                ),
                Expanded(child: _buildCurrentStep()),
              ],
            ),
          ),
        ),
        // 저장 중 전체 화면 오버레이 — 중복 탭 방지
        if (_isLoading) const LoadingIndicator(overlay: true),
      ],
    );
  }
}

/// 현재 스텝 진행률을 얇은 바 형태로 보여주는 프리미엄 진행 인디케이터.
///
/// 기존 dot 인디케이터는 7스텝이 되면서 한눈에 "얼마나 남았는지"를
/// 가늠하기 어려웠다. 바 + 숫자 조합이 더 명확하고 프리미엄 매칭앱에
/// 가까운 느낌을 준다.
class _StepProgressBar extends StatelessWidget {
  final int current;
  final int total;

  const _StepProgressBar({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final progress = (current / total).clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                  ),
                  AnimatedContainer(
                    duration: AppDurations.base,
                    curve: AppCurves.standard,
                    height: 6,
                    width: constraints.maxWidth * progress,
                    decoration: BoxDecoration(
                      color: AppColors.matchPrimary,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '$current / $total',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
