import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
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
class OnboardingScreen extends StatefulWidget {
  final String uid;
  final AuthService authService;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final VoidCallback onCompleted;

  const OnboardingScreen({
    super.key,
    required this.uid,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.onCompleted,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _isLoading = false;

  // ── 스텝 0: 사진 ──────────────────────────────────────────────────────────
  File? _mainImage;
  final List<File> _subImages = [];

  // ── 스텝 1: 기본 정보 ────────────────────────────────────────────────────
  String _name = '';
  DateTime? _birthDate;
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

  void _nextStep() => setState(() => _step++);
  void _prevStep() => setState(() => _step--);

  /// 모든 데이터를 모아 Storage + Firestore에 저장한다.
  /// [goalKey]: 스텝 6에서 선택한 찾는 관계 key.
  Future<void> _handleSubmit(String? goalKey) async {
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
        verifications: VerificationStatus(
          email: widget.authService.isEmailVerified,
        ),
      );
      await widget.firestoreService.createUserProfile(profile);

      // 3. 완료: app.dart에 알려 HomeScreen으로 전환
      widget.onCompleted();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('저장 중 오류가 발생했습니다: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0:
        return PhotosUploadStep(
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
                required gender,
                required bio,
              }) {
                _name = name;
                _birthDate = birthDate;
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
            // 스텝 0에서는 뒤로가기 없음 — 로그인 화면으로 돌아갈 필요가 없다.
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
            title: _StepIndicator(current: _step + 1, total: _totalSteps),
            centerTitle: true,
            backgroundColor: AppColors.background.withValues(alpha: 0),
            elevation: 0,
          ),
          body: SafeArea(child: _buildCurrentStep()),
        ),
        // 저장 중 전체 화면 오버레이 — 중복 탭 방지
        if (_isLoading) const LoadingIndicator(overlay: true),
      ],
    );
  }
}

/// 현재 스텝 위치를 점(dot) 형태로 표시하는 진행 인디케이터.
class _StepIndicator extends StatelessWidget {
  final int current;
  final int total;

  const _StepIndicator({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final active = i + 1 == current;
        return AnimatedContainer(
          duration: AppDurations.base,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? AppColors.primary : AppColors.border,
            borderRadius: BorderRadius.circular(AppSpacing.xs),
          ),
        );
      }),
    );
  }
}
