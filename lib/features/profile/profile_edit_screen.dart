import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/profile_options.dart';
import '../../core/constants/profile_story_prompts.dart';
import '../../core/constants/value_questions.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/profile_story.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/profile/profile_keyword_summary_service.dart';
import '../../services/storage/profile_photo_processor.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';
import '../onboarding/tag_selection_step.dart';
import 'profile_stories_edit_screen.dart';
import 'value_answers_edit_screen.dart';
import 'widgets/job_picker.dart';

/// 최대 사진 수 — 메인 1장 + 일상 3장. 온보딩(photo_upload_step.dart)과 동일한
/// 제약을 여기서도 지킨다.
const int kMaxProfilePhotos = 4;

/// 프로필 편집 화면.
///
/// 기존 [profile]을 받아 모든 필드를 인라인으로 편집하고,
/// "저장" 버튼 한 번으로 Firestore에 반영한다.
/// 저장 완료 후 `Navigator.pop(context, updatedProfile)`으로
/// HomeScreen에 최신 프로필을 전달해 재조회 없이 화면을 갱신한다.
class ProfileEditScreen extends StatefulWidget {
  final UserProfile profile;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final ProfileKeywordSummaryService? profileKeywordSummaryService;

  const ProfileEditScreen({
    super.key,
    required this.profile,
    required this.firestoreService,
    required this.storageService,
    this.profileKeywordSummaryService,
  });

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _bioController;
  late final TextEditingController _heightController;
  late final ProfileKeywordSummaryService _profileKeywordSummaryService;

  late String _gender;
  String? _religion;
  String? _smoking;
  String? _drinking;
  String? _jobCategory;
  String? _jobTitle;
  String? _education;
  String? _mbti;
  String? _relationshipGoal;
  late List<String> _interests;
  late List<String> _personalityTags;
  late List<String> _idealTags;
  late List<String> _photoUrls;
  // 가치관 답변(questionKey → answerKey). 원본을 직접 건드리지 않도록
  // initState에서 방어 복사한다. 전용 화면(ValueAnswersEditScreen)에서
  // 임시로 편집한 뒤, "저장" 버튼에서만 dual-write로 반영된다.
  late Map<String, String> _valueAnswers;
  // 이야기 카드(promptKey + answer). 원본 list를 직접 건드리지 않도록
  // initState에서 방어 복사한다. 전용 화면에서 임시 편집하고, 저장 버튼에서만 반영.
  late List<ProfileStory> _profileStories;

  bool _isLoading = false;
  // null이면 사진 작업 중이 아님. 값이 있으면 해당 인덱스 슬롯이 업로드/삭제 중.
  int? _busyPhotoIndex;
  final _profilePhotoProcessor = ProfilePhotoProcessor();

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _photoUrls = List<String>.from(p.photoUrls);
    _nameController = TextEditingController(text: p.displayName);
    _bioController = TextEditingController(text: p.bio);
    _heightController = TextEditingController(
      text: p.height != null ? p.height.toString() : '',
    );
    _gender = p.gender;
    _religion = p.religion;
    _smoking = p.smoking;
    _drinking = p.drinking;
    _jobCategory = p.jobCategory;
    _jobTitle = p.jobTitle;
    _education = p.education;
    _mbti = p.mbti;
    _relationshipGoal = p.relationshipGoal;
    _interests = List<String>.from(p.interests);
    _personalityTags = List<String>.from(p.personalityTags);
    _idealTags = List<String>.from(p.idealTags);
    _valueAnswers = Map<String, String>.from(p.valueAnswers);
    _profileStories = List<ProfileStory>.from(p.profileStories);
    _profileKeywordSummaryService =
        widget.profileKeywordSummaryService ?? ProfileKeywordSummaryService();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  // ── 저장 ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final bio = _bioController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이름을 입력해주세요.')));
      return;
    }
    if (bio.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('한줄 소개를 입력해주세요.')));
      return;
    }
    if (_photoUrls.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('사진을 최소 1장 등록해주세요.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final heightText = _heightController.text.trim();
      final updatedProfile = widget.profile.copyWith(
        displayName: name,
        bio: bio,
        gender: _gender,
        photoUrls: _photoUrls,
        height: heightText.isNotEmpty ? int.tryParse(heightText) : null,
        religion: _religion,
        smoking: _smoking,
        drinking: _drinking,
        jobCategory: _jobCategory,
        jobTitle: (_jobTitle == null || _jobTitle!.isEmpty) ? null : _jobTitle,
        education: _education,
        mbti: _mbti,
        relationshipGoal: _relationshipGoal,
        interests: _interests,
        personalityTags: _personalityTags,
        idealTags: _idealTags,
        valueAnswers: Map<String, String>.from(_valueAnswers),
        profileStories: List<ProfileStory>.from(_profileStories),
        updatedAt: DateTime.now(),
      );
      await widget.firestoreService.updateEditableUserProfile(updatedProfile);

      unawaited(_generateProfileKeywordSummaryBestEffort());

      if (mounted) {
        // 업데이트된 프로필을 HomeScreen에 전달해 재조회 없이 반영
        Navigator.pop(context, updatedProfile);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProfileEdit] 프로필 저장 실패: ${e.runtimeType}');
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
        debugPrint('[ProfileEdit] AI 키워드 요약 생성 실패: ${e.code}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProfileEdit] AI 키워드 요약 생성 실패: ${e.runtimeType}');
      }
    }
  }

  // ── 사진 관리 ────────────────────────────────────────────────────────────
  //
  // photoUrls[0]은 항상 대표 사진으로 취급한다(UserProfile 문서 규칙).
  // 리스트에서 빼거나(removeAt) 앞으로 옮기면(swap) 자동으로 대표 사진이
  // 바뀌므로, 별도의 "대표 사진" 필드 없이 순서만으로 표현한다.

  /// 빈 슬롯 탭 → 바로 갤러리에서 골라 업로드. 기존 사진 탭 → 옵션 시트.
  Future<void> _handlePhotoSlotTap(int index) async {
    if (_busyPhotoIndex != null) return;
    if (index < _photoUrls.length) {
      await _showPhotoOptions(index);
    } else {
      await _pickAndUploadPhoto(index);
    }
  }

  Future<void> _showPhotoOptions(int index) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      backgroundColor: AppColors.surfacePrimary,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderStrong,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
              ),
              const SizedBox(height: 12),
              if (index != 0)
                _PhotoOptionRow(
                  icon: Icons.star_rounded,
                  iconColor: AppColors.mintDeep,
                  label: '대표 사진으로 설정',
                  onTap: () => Navigator.pop(ctx, 'main'),
                ),
              _PhotoOptionRow(
                icon: Icons.photo_library_outlined,
                iconColor: AppColors.textBody,
                label: '다른 사진으로 변경',
                onTap: () => Navigator.pop(ctx, 'replace'),
              ),
              if (_photoUrls.length > 1)
                _PhotoOptionRow(
                  icon: Icons.delete_outline_rounded,
                  iconColor: AppColors.error,
                  label: '삭제',
                  danger: true,
                  onTap: () => Navigator.pop(ctx, 'delete'),
                ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || action == null) return;
    switch (action) {
      case 'main':
        setState(() {
          final photo = _photoUrls.removeAt(index);
          _photoUrls.insert(0, photo);
        });
      case 'replace':
        await _pickAndUploadPhoto(index);
      case 'delete':
        await _deletePhoto(index);
    }
  }

  Future<void> _pickAndUploadPhoto(int index) async {
    // 온보딩과 같은 processor를 쓴다. 진입점마다 기준이 달라지면
    // 같은 사진도 등록 경로에 따라 화질이 달라진다.
    final ProcessedProfilePhoto? processed;
    try {
      processed = await _profilePhotoProcessor.pickFromGallery();
    } on ProfilePhotoFailure catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(failure.userMessage)));
      }
      return;
    }
    if (processed == null || !mounted) return;
    processed.logDiagnostics();

    setState(() => _busyPhotoIndex = index);
    try {
      final url = await widget.storageService.uploadProfilePhoto(
        uid: widget.profile.uid,
        role: index == 0 ? 'main' : 'sub_$index',
        photo: processed,
      );
      if (!mounted) return;
      setState(() {
        if (index < _photoUrls.length) {
          _photoUrls[index] = url;
        } else {
          _photoUrls.add(url);
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('사진 업로드에 실패했어요. 잠시 후 다시 시도해주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyPhotoIndex = null);
    }
  }

  Future<void> _deletePhoto(int index) async {
    if (_photoUrls.length <= 1) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfacePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        icon: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AppColors.statusDangerSoft,
            shape: BoxShape.circle,
          ),
          child: const ExcludeSemantics(
            child: Icon(
              Icons.delete_outline_rounded,
              size: 22,
              color: AppColors.statusDanger,
            ),
          ),
        ),
        title: const Text(
          '사진 삭제',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
          ),
        ),
        content: const Text(
          '이 사진을 삭제할까요?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: AppColors.textBody,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textBody,
                    side: const BorderSide(color: AppColors.borderStrong),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.statusDanger,
                    foregroundColor: AppColors.surface,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text(
                    '삭제',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyPhotoIndex = index);
    final url = _photoUrls[index];
    try {
      // Storage 삭제는 최선의 노력만 한다 — 실패해도(예: 이미 삭제된 파일)
      // Firestore 목록에서는 항상 제거해 화면 상태가 꼬이지 않게 한다.
      await widget.storageService.deleteByUrl(url);
    } catch (_) {
      // 무시 — 아래에서 목록 갱신은 계속 진행한다.
    }
    if (mounted) {
      setState(() {
        _photoUrls.remove(url);
        _busyPhotoIndex = null;
      });
    }
  }

  // ── 단일 선택 바텀 시트 ──────────────────────────────────────────────────

  /// 단일 선택 바텀 시트.
  ///
  /// isScrollControlled + ConstrainedBox + ListView 조합으로
  /// 항목이 많아도(MBTI 16개 등) overflow 없이 스크롤된다.
  Future<void> _showPicker({
    required String title,
    required List<TagOption> options,
    required String? currentKey,
    required void Function(String?) onSelected,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfacePrimary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (ctx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                const Center(child: _SheetHandle()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: options.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      indent: 12,
                      color: AppColors.borderSubtle,
                    ),
                    itemBuilder: (ctx2, i) {
                      final opt = options[i];
                      final isSelected = opt.key == currentKey;
                      return _ChoiceRow(
                        label: opt.label,
                        selected: isSelected,
                        onTap: () {
                          Navigator.pop(ctx);
                          onSelected(opt.key);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 직업 2단계 선택 (카테고리 → 직업명).
  Future<void> _openJobPicker() async {
    final result = await pushJobPicker(
      context,
      initialCategoryKey: _jobCategory,
      initialTitle: _jobTitle,
    );
    if (result != null && mounted) {
      setState(() {
        _jobCategory = result.categoryKey;
        _jobTitle = result.title.isEmpty ? null : result.title;
      });
    }
  }

  /// 직업 선택 결과를 표시용 텍스트로 변환한다.
  String? _jobDisplayText() {
    if (_jobCategory == null && (_jobTitle == null || _jobTitle!.isEmpty)) {
      return null;
    }
    final catLabel = _jobCategory != null
        ? ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            _jobCategory!,
          )
        : null;
    String? catName;
    if (catLabel != null) {
      final spaceIdx = catLabel.indexOf(' ');
      catName = spaceIdx != -1 ? catLabel.substring(spaceIdx + 1) : catLabel;
    }
    final parts = [
      ?catName,
      if (_jobTitle != null && _jobTitle!.isNotEmpty) _jobTitle!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ── 태그 선택 전용 페이지로 이동 ────────────────────────────────────────

  Future<void> _openTagPage({
    required String title,
    required String subtitle,
    required List<TagOption> options,
    required List<String> current,
    required void Function(List<String>) onSaved,
  }) async {
    // TagSelectionStep을 전체 페이지로 래핑해서 편집 화면에 재사용한다.
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Text(
              title,
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: AppColors.textStrong,
                letterSpacing: -0.2,
              ),
            ),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              onPressed: () => Navigator.pop(ctx),
            ),
            backgroundColor: AppColors.background,
            foregroundColor: AppColors.textStrong,
            elevation: 0,
          ),
          body: SafeArea(
            child: TagSelectionStep(
              title: title,
              subtitle: subtitle,
              options: options,
              initialSelected: current,
              buttonLabel: '저장',
              presentation: TagSelectionPresentation.profileEdit,
              onNext: (keys) {
                onSaved(keys);
                Navigator.pop(ctx);
              },
            ),
          ),
        ),
      ),
    );
  }

  // ── 가치관 전용 편집 페이지로 이동 ──────────────────────────────────────

  /// 가치관 전용 화면을 열고, 완료 결과(map)를 임시 상태에만 반영한다.
  /// 여기서는 Firestore write를 하지 않는다 — 실제 저장은 [_save]에서만.
  Future<void> _openValueAnswersPage() async {
    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => ValueAnswersEditScreen(
          initialAnswers: Map<String, String>.from(_valueAnswers),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _valueAnswers = Map<String, String>.from(result);
    });
  }

  // ── 이야기 카드 전용 편집 페이지로 이동 ─────────────────────────────────

  /// 이야기 카드 전용 화면을 열고, 완료 결과(list)를 임시 상태에만 반영한다.
  /// 여기서는 Firestore write를 하지 않는다 — 실제 저장은 [_save]에서만.
  Future<void> _openProfileStoriesPage() async {
    final result = await Navigator.push<List<ProfileStory>>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileStoriesEditScreen(
          initialStories: List<ProfileStory>.from(_profileStories),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _profileStories = List<ProfileStory>.from(result);
    });
  }

  // ── UI 빌더 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Scaffold를 루트로 두어야 키보드 대응(resizeToAvoidBottomInset)과
    // 높이 제약이 정상적으로 동작한다. 로딩 오버레이는 body 안 Stack에서 처리한다.
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '프로필 편집',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
            letterSpacing: -0.2,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _isLoading ? null : () => Navigator.pop(context),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              // 하단 잘림 방지: 저장 버튼이 시스템 내비게이션 바에 가깝게
              // 붙지 않도록 인셋을 더한다(ideal_type_screen.dart와 같은 패턴).
              32 + MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 사진 (Photo Workshop) ────────────────────────────────
                const _StudioSectionHeader(
                  title: '사진',
                  subtitle: '첫 번째 사진이 대표 사진으로 노출돼요',
                ),
                const SizedBox(height: 12),
                _PhotoManagementGrid(
                  photoUrls: _photoUrls,
                  busyIndex: _busyPhotoIndex,
                  onSlotTap: _handlePhotoSlotTap,
                ),
                const SizedBox(height: 26),

                // ── 기본 정보 (Identity Basics Surface) ──────────────────
                const _StudioSectionHeader(title: '기본 정보'),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfacePrimary,
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _nameController,
                        style: const TextStyle(
                          fontSize: 15.5,
                          color: AppColors.textStrong,
                        ),
                        decoration: _studioInput('이름'),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        '성별',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _GenderSelector(
                        selected: _gender,
                        onChanged: (g) => setState(() => _gender = g),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _bioController,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: AppColors.textStrong,
                        ),
                        decoration: _studioInput('한줄 소개', counterText: ''),
                        maxLength: 100,
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),

                // ── 이야기 (Story Preview Entry) ─────────────────────────
                const _StudioSectionHeader(
                  title: '나의 이야기',
                  subtitle: '상대가 대화를 시작할 수 있도록 나만의 이야기를 들려주세요',
                ),
                const SizedBox(height: 12),
                _ProfileStoriesSummary(
                  stories: _profileStories,
                  onTap: _openProfileStoriesPage,
                ),
                const SizedBox(height: 26),

                // ── 상세 정보 (Facts Editor Surface) ─────────────────────
                const _StudioSectionHeader(title: '상세 정보'),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfacePrimary,
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HeightRow(controller: _heightController),
                      const _FactDivider(),
                      _EditPickerField(
                        label: '직업',
                        value: _jobDisplayText(),
                        onTap: _openJobPicker,
                      ),
                      const _FactDivider(),
                      _EditPickerField(
                        label: '종교',
                        value: ProfileOptions.keyToLabel(
                          ProfileOptions.religions,
                          _religion ?? '',
                        ),
                        onTap: () => _showPicker(
                          title: '종교',
                          options: ProfileOptions.religions,
                          currentKey: _religion,
                          onSelected: (k) => setState(() => _religion = k),
                        ),
                      ),
                      const _FactDivider(),
                      _EditPickerField(
                        label: '흡연',
                        value: ProfileOptions.keyToLabel(
                          ProfileOptions.smokingOptions,
                          _smoking ?? '',
                        ),
                        onTap: () => _showPicker(
                          title: '흡연',
                          options: ProfileOptions.smokingOptions,
                          currentKey: _smoking,
                          onSelected: (k) => setState(() => _smoking = k),
                        ),
                      ),
                      const _FactDivider(),
                      _EditPickerField(
                        label: '음주',
                        value: ProfileOptions.keyToLabel(
                          ProfileOptions.drinkingOptions,
                          _drinking ?? '',
                        ),
                        onTap: () => _showPicker(
                          title: '음주',
                          options: ProfileOptions.drinkingOptions,
                          currentKey: _drinking,
                          onSelected: (k) => setState(() => _drinking = k),
                        ),
                      ),
                      const _FactDivider(),
                      _EditPickerField(
                        label: '최종학력',
                        value: ProfileOptions.keyToLabel(
                          ProfileOptions.educationOptions,
                          _education ?? '',
                        ),
                        onTap: () => _showPicker(
                          title: '최종학력',
                          options: ProfileOptions.educationOptions,
                          currentKey: _education,
                          onSelected: (k) => setState(() => _education = k),
                        ),
                      ),
                      const _FactDivider(),
                      _EditPickerField(
                        label: 'MBTI',
                        value: _mbti,
                        onTap: () => _showPicker(
                          title: 'MBTI',
                          options: ProfileOptions.mbtiOptions,
                          currentKey: _mbti,
                          onSelected: (k) => setState(() => _mbti = k),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),

                // ── 태그 (Identity Keywords Editor) ──────────────────────
                const _StudioSectionHeader(
                  title: '태그',
                  subtitle: '나를 소개하고 원하는 상대를 알려주는 키워드예요',
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfacePrimary,
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TagSubSection(
                        title: '관심사',
                        keys: _interests,
                        options: ProfileOptions.interests,
                        tone: _TagTone.interest,
                        emptyText: '관심사를 추가해보세요',
                        onEdit: () => _openTagPage(
                          title: '관심사',
                          subtitle: '나의 취미·라이프스타일을 보여주세요',
                          options: ProfileOptions.interests,
                          current: _interests,
                          onSaved: (keys) => setState(() => _interests = keys),
                        ),
                      ),
                      const _TagSubDivider(),
                      _TagSubSection(
                        title: '나를 표현하는 키워드',
                        keys: _personalityTags,
                        options: ProfileOptions.personalities,
                        tone: _TagTone.personality,
                        emptyText: '나를 표현하는 키워드를 추가해보세요',
                        onEdit: () => _openTagPage(
                          title: '성향 키워드',
                          subtitle: '나의 성격·스타일을 잘 나타내는 키워드를 골라보세요',
                          options: ProfileOptions.personalities,
                          current: _personalityTags,
                          onSaved: (keys) =>
                              setState(() => _personalityTags = keys),
                        ),
                      ),
                      const _TagSubDivider(),
                      _TagSubSection(
                        title: '이런 친구를 원해요',
                        keys: _idealTags,
                        options: ProfileOptions.ideals,
                        tone: _TagTone.ideal,
                        emptyText: '원하는 친구 키워드를 추가해보세요',
                        onEdit: () => _openTagPage(
                          title: '이상형 키워드',
                          subtitle: '내가 선호하는 상대의 키워드를 선택해주세요',
                          options: ProfileOptions.ideals,
                          current: _idealTags,
                          onSaved: (keys) => setState(() => _idealTags = keys),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),

                // ── 찾는 관계 (Relationship Intent Surface) ──────────────
                const _StudioSectionHeader(title: '찾는 관계'),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMintSoft,
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(
                      color: AppColors.mint.withValues(alpha: 0.4),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _EditPickerField(
                    label: '어떤 인연을 찾나요?',
                    value: ProfileOptions.keyToLabel(
                      ProfileOptions.relationshipGoals,
                      _relationshipGoal ?? '',
                    ),
                    onTap: () => _showPicker(
                      title: '찾는 관계',
                      options: ProfileOptions.relationshipGoals,
                      currentKey: _relationshipGoal,
                      onSelected: (k) => setState(() => _relationshipGoal = k),
                    ),
                  ),
                ),
                const SizedBox(height: 26),

                // ── 가치관 (Values Preview Entry) ────────────────────────
                const _StudioSectionHeader(
                  title: '가치관',
                  subtitle: '연애와 관계에서 중요하게 생각하는 방식을 알려주세요',
                ),
                const SizedBox(height: 12),
                _ValueAnswersSummary(
                  answers: _valueAnswers,
                  onTap: _openValueAnswersPage,
                ),
                const SizedBox(height: 28),
                _SaveActionArea(onSave: _isLoading ? null : _save),
              ],
            ),
          ),
          if (_isLoading) const LoadingIndicator(overlay: true),
        ],
      ),
    );
  }
}

// ── 내부 헬퍼 위젯들 ──────────────────────────────────────────────────────────

/// 카드 안에서 쓰는 작은 소제목 + "편집" 버튼 행(관심사/성향/이상형 태그
/// 서브섹션용). PremiumSectionCard의 title/trailing과 달리 카드 자체를
/// 만들지 않고, 카드 내부 한 줄만 차지한다.
class _TagSectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onEdit;

  const _TagSectionHeader({required this.title, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: onEdit,
            child: const Text('편집', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }
}

class _EditPickerField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;

  const _EditPickerField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasValue ? value! : '선택',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: hasValue ? FontWeight.w700 : FontWeight.w500,
                      color: hasValue
                          ? AppColors.mintDeep
                          : AppColors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 상세 정보 surface의 field 사이 subtle divider.
class _FactDivider extends StatelessWidget {
  const _FactDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, color: AppColors.borderSubtle);
  }
}

/// 키 입력 row — label 좌측 + compact numeric field 우측. picker row와 높이를
/// 맞춘다. controller·formatter·keyboardType·suffix 계약은 그대로 유지한다.
class _HeightRow extends StatelessWidget {
  final TextEditingController controller;

  const _HeightRow({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const Text(
              '키',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textStrong,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 118,
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.right,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textStrong,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '선택',
                  hintStyle: const TextStyle(color: AppColors.textMuted),
                  suffixText: 'cm',
                  filled: true,
                  fillColor: AppColors.surfaceSecondary,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    borderSide: const BorderSide(
                      color: AppColors.brandPrimaryStrong,
                      width: 1.5,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editorial Choice Sheet의 옵션 행. 선택은 pale mint + mintDeep + check.
class _ChoiceRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          color: selected ? AppColors.surfaceMintSoft : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    color: selected ? AppColors.mintDeep : AppColors.textStrong,
                  ),
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: AppColors.mintDeep,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 바텀시트 상단 drag handle.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.borderStrong,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
    );
  }
}

/// 태그 key 목록을 label로 변환해서 칩으로 표시한다.
/// 태그 하위 영역별 색 역할. 관심사=옅은 민트, 성향=중립 아웃라인,
/// 이상형=아주 옅은 coral. 데이터 처리는 tone과 무관하게 동일하다.
enum _TagTone { interest, personality, ideal }

class _TagChipStyle {
  final Color background;
  final Color border;
  final Color text;

  const _TagChipStyle({
    required this.background,
    required this.border,
    required this.text,
  });

  static _TagChipStyle of(_TagTone tone) {
    switch (tone) {
      case _TagTone.interest:
        return const _TagChipStyle(
          background: AppColors.mintSoft,
          border: AppColors.mintSoft,
          text: AppColors.mintDeep,
        );
      case _TagTone.personality:
        return const _TagChipStyle(
          background: AppColors.surface,
          border: AppColors.borderStrong,
          text: AppColors.textStrong,
        );
      case _TagTone.ideal:
        return const _TagChipStyle(
          background: AppColors.expressiveAccentSoft,
          border: AppColors.expressiveAccentSoft,
          text: AppColors.expressiveAccent,
        );
    }
  }
}

class _TagChipDisplay extends StatelessWidget {
  final List<String> keys;
  final List<TagOption> options;
  final _TagTone tone;

  const _TagChipDisplay({
    required this.keys,
    required this.options,
    this.tone = _TagTone.interest,
  });

  @override
  Widget build(BuildContext context) {
    final labels = ProfileOptions.keysToLabels(options, keys);
    final style = _TagChipStyle.of(tone);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: labels
          .map(
            (label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: style.background,
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(color: style.border),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: style.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

/// 태그 continuous surface 안에서 하위 영역(관심사/성향/이상형)을 나누는
/// 얇은 구분선. 좌우 padding은 surface가 이미 가지므로 여기선 세로 여백만.
class _TagSubDivider extends StatelessWidget {
  const _TagSubDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Divider(height: 1, color: AppColors.borderSubtle),
    );
  }
}

/// 태그 한 하위 영역 — 소제목 + 편집 + 선택 chip(또는 빈 상태 문구).
class _TagSubSection extends StatelessWidget {
  final String title;
  final List<String> keys;
  final List<TagOption> options;
  final _TagTone tone;
  final String emptyText;
  final VoidCallback onEdit;

  const _TagSubSection({
    required this.title,
    required this.keys,
    required this.options,
    required this.tone,
    required this.emptyText,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TagSectionHeader(title: title, onEdit: onEdit),
        if (keys.isEmpty)
          _EmptyTagHint(text: emptyText)
        else
          _TagChipDisplay(keys: keys, options: options, tone: tone),
      ],
    );
  }
}

/// 이야기·가치관 요약이 공통으로 쓰는 진입 surface. 밝은 흰 표면 전체가
/// 탭 영역이며, ripple이 표면을 덮는다. [entryKey]는 InkWell에 부여해
/// 부모 테스트가 진입 영역을 찾을 수 있게 한다.
class _PreviewEntrySurface extends StatelessWidget {
  final Key entryKey;
  final VoidCallback onTap;
  final Widget child;

  const _PreviewEntrySurface({
    required this.entryKey,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.surface);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: radius,
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: entryKey,
          onTap: onTap,
          borderRadius: radius,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }
}

/// 요약 하단의 진입 CTA 행(라벨 + chevron). 실제 이동이 있는 유일한 action.
class _PreviewCtaRow extends StatelessWidget {
  final String label;

  const _PreviewCtaRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            color: AppColors.mintDeep,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        const Icon(
          Icons.chevron_right_rounded,
          size: 18,
          color: AppColors.textMuted,
        ),
      ],
    );
  }
}

/// 가치관 요약(Values Preview Entry). 응답 수 요약 + 앞쪽 답변 미리보기 +
/// 진입 CTA를 밝은 표면 하나에 담는다. 표면 전체가 탭 영역이다.
class _ValueAnswersSummary extends StatelessWidget {
  final Map<String, String> answers;
  final VoidCallback onTap;

  const _ValueAnswersSummary({required this.answers, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // catalog 순서로, 현재 질문이면서 answer가 유효한 것만 요약/카운트한다.
    // unknown question key와 invalid answer는 요약에 포함하지 않는다.
    final answered = <MapEntry<String, String>>[];
    for (final question in ValueQuestions.all) {
      final answer = answers[question.key];
      if (answer != null &&
          ValueQuestions.isValidAnswer(question.key, answer)) {
        answered.add(MapEntry(question.key, answer));
      }
    }
    final total = ValueQuestions.all.length;
    final count = answered.length;
    final hasAny = count > 0;

    const maxPreview = 2;
    final preview = answered.take(maxPreview).toList();
    final remaining = count - preview.length;

    return _PreviewEntrySurface(
      entryKey: const ValueKey('value-answers-edit-entry'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasAny)
            const Text(
              '아직 답변한 가치관 질문이 없어요',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            )
          else ...[
            _CountLabel(text: '$count / $total 답변'),
            const SizedBox(height: 12),
            for (var i = 0; i < preview.length; i++) ...[
              if (i > 0) const _PreviewDivider(),
              _ValuePreviewRow(
                question: ValueQuestions.byKey(preview[i].key)!.profileLabel,
                answer: ValueQuestions.answerLabel(
                  preview[i].key,
                  preview[i].value,
                )!,
              ),
            ],
            if (remaining > 0) ...[
              const SizedBox(height: 6),
              Text(
                '외 $remaining개',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          _PreviewCtaRow(label: hasAny ? '수정하기' : '답변하기'),
        ],
      ),
    );
  }
}

/// 응답 수/작성 수 compact 민트 라벨.
class _CountLabel extends StatelessWidget {
  final String text;

  const _CountLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: AppColors.mintDeep,
      ),
    );
  }
}

/// 요약 미리보기 항목 사이 얇은 구분선.
class _PreviewDivider extends StatelessWidget {
  const _PreviewDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Divider(height: 1, color: AppColors.borderSubtle),
    );
  }
}

/// 가치관 미리보기 한 줄 — 질문(textMuted) · 답변(textStrong).
class _ValuePreviewRow extends StatelessWidget {
  final String question;
  final String answer;

  const _ValuePreviewRow({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$question · ',
            style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
          ),
          TextSpan(
            text: answer,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textStrong,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 이야기 카드 요약. catalog에 존재하고 정규화 후 빈 답변이 아닌 항목만
/// 보여준다. unknown story는 보존만 하고 raw key를 화면에 노출하지 않는다.
class _ProfileStoriesSummary extends StatelessWidget {
  final List<ProfileStory> stories;
  final VoidCallback onTap;

  const _ProfileStoriesSummary({required this.stories, required this.onTap});

  String _sanitizePreview(String value) {
    final withoutControls = value.replaceAll(
      RegExp(r'[\u0000-\u0009\u000B-\u001F\u007F]'),
      '',
    );
    return stripEmoji(withoutControls);
  }

  @override
  Widget build(BuildContext context) {
    final visibleStories = <ProfileStory>[];
    for (final story in stories) {
      if (!ProfileStoryPrompts.isValidKey(story.promptKey)) continue;
      final answer = _sanitizePreview(story.answer);
      if (answer.isEmpty) continue;
      visibleStories.add(
        ProfileStory(promptKey: story.promptKey, answer: answer),
      );
    }

    final count = visibleStories.length;
    final hasAny = count > 0;
    const maxPreview = 2;
    final preview = visibleStories.take(maxPreview).toList();
    final remaining = count - preview.length;

    return _PreviewEntrySurface(
      entryKey: const ValueKey('profile-stories-edit-entry'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasAny)
            const Text(
              '아직 작성한 이야기가 없어요',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            )
          else ...[
            _CountLabel(text: '$count / ${ProfileStoryPrompts.maxStories}개 작성'),
            const SizedBox(height: 12),
            for (var i = 0; i < preview.length; i++) ...[
              if (i > 0) const _PreviewDivider(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ProfileStoryPrompts.labelFor(preview[i].promptKey) ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.expressiveAccent,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    preview[i].answer,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textStrong,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ],
            if (remaining > 0) ...[
              const SizedBox(height: 8),
              Text(
                '외 $remaining개',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          _PreviewCtaRow(label: hasAny ? '수정하기' : '작성하기'),
        ],
      ),
    );
  }
}

class _EmptyTagHint extends StatelessWidget {
  final String text;
  const _EmptyTagHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
    );
  }
}

/// 편집 studio의 섹션 헤더(제목 + 선택 subtitle). 반복 카드 대신 여백/타이포로
/// 구분하는 상단 섹션(사진·기본 정보)에서 쓴다.
class _StudioSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _StudioSectionHeader({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
            letterSpacing: -0.2,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}

/// 편집 화면의 마지막 저장 영역(Calm Save Closure). 얇은 상단 divider로 편집
/// 흐름을 마무리하고, 기존 [PrimaryButton]과 저장 콜백·label을 그대로 쓴다.
/// [onSave]가 null이면(저장 중) 버튼이 비활성화된다.
class _SaveActionArea extends StatelessWidget {
  final VoidCallback? onSave;

  const _SaveActionArea({required this.onSave});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1, color: AppColors.borderSubtle),
        const SizedBox(height: 20),
        PrimaryButton(label: '저장', onPressed: onSave),
      ],
    );
  }
}

/// 사진 옵션 시트의 action 행(대표 설정 / 변경 / 삭제). 반환값은 호출부가
/// 그대로 pop 한다 — 삭제만 danger 톤이고, 행 전체 danger 배경은 쓰지 않는다.
class _PhotoOptionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final bool danger;
  final VoidCallback onTap;

  const _PhotoOptionRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 21, color: iconColor),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: danger ? AppColors.error : AppColors.textStrong,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 기본 정보 입력 데코레이션 — filled neutral + focus mint. error는 theme 유지.
InputDecoration _studioInput(String label, {String? counterText}) {
  return InputDecoration(
    labelText: label,
    counterText: counterText,
    labelStyle: const TextStyle(color: AppColors.textMuted),
    filled: true,
    fillColor: AppColors.surfaceSecondary,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.control),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.control),
      borderSide: const BorderSide(
        color: AppColors.brandPrimaryStrong,
        width: 1.5,
      ),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.control),
      borderSide: BorderSide.none,
    ),
  );
}

class _GenderSelector extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _GenderSelector({required this.selected, required this.onChanged});

  static const _options = [('male', '남성'), ('female', '여성'), ('other', '기타')];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: _options.map((opt) {
        final value = opt.$1;
        final label = opt.$2;
        final isSelected = selected == value;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Semantics(
              selected: isSelected,
              button: true,
              label: label,
              child: GestureDetector(
                onTap: () => onChanged(value),
                child: AnimatedContainer(
                  duration: AppDurations.fast,
                  alignment: Alignment.center,
                  height: 46,
                  decoration: BoxDecoration(
                    // 선택 상태: pale mint + mintDeep 텍스트 + check.
                    color: isSelected
                        ? AppColors.surfaceMintSoft
                        : AppColors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    border: Border.all(
                      color: isSelected
                          ? AppColors.mintDeep
                          : AppColors.borderSubtle,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isSelected) ...[
                        const Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: AppColors.mintDeep,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          color: isSelected
                              ? AppColors.mintDeep
                              : AppColors.textBody,
                          fontWeight: isSelected
                              ? FontWeight.w800
                              : FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 사진 4슬롯(대표 1 + 일상 3) 2x2 그리드.
class _PhotoManagementGrid extends StatelessWidget {
  final List<String> photoUrls;
  final int? busyIndex;
  final ValueChanged<int> onSlotTap;

  const _PhotoManagementGrid({
    required this.photoUrls,
    required this.busyIndex,
    required this.onSlotTap,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: kMaxProfilePhotos,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1,
      ),
      itemBuilder: (context, index) {
        final url = index < photoUrls.length ? photoUrls[index] : null;
        return _PhotoSlot(
          url: url,
          isMain: index == 0,
          busy: busyIndex == index,
          onTap: () => onSlotTap(index),
        );
      },
    );
  }
}

class _PhotoSlot extends StatelessWidget {
  final String? url;
  final bool isMain;
  final bool busy;
  final VoidCallback onTap;

  const _PhotoSlot({
    required this.url,
    required this.isMain,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = url != null;
    return Semantics(
      button: true,
      label: hasPhoto ? (isMain ? '대표 사진' : '사진') : '사진 추가',
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.surface),
          child: Container(
            decoration: BoxDecoration(
              // 등록: 흰 배경 / 빈 슬롯: 옅은 mint로 "사진 추가" 자리임을 표현.
              color: hasPhoto
                  ? AppColors.surfacePrimary
                  : AppColors.surfaceMintSoft,
              border: Border.all(
                color: hasPhoto
                    ? AppColors.borderSubtle
                    : AppColors.mint.withValues(alpha: 0.4),
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasPhoto)
                  Image.network(
                    url!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: AppColors.surfaceSecondary,
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                else
                  const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        color: AppColors.mintDeep,
                        size: 26,
                      ),
                      SizedBox(height: 6),
                      Text(
                        '사진 추가',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.mintDeep,
                        ),
                      ),
                    ],
                  ),
                if (isMain && hasPhoto)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.ink.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                      child: const Text(
                        '대표',
                        style: TextStyle(
                          color: AppColors.surface,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                if (busy)
                  Container(
                    color: AppColors.ink.withValues(alpha: 0.32),
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.mint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
