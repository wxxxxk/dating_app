import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune/birth_profile.dart';
import '../../services/profile/birth_profile_service.dart';
import '../../shared/widgets/birth_time_selector.dart';
import '../../shared/widgets/primary_button.dart';

/// 기존 사용자 출생시간 보완 화면 (Phase 5-2).
///
/// Phase 5-2 이전에 가입한 사용자는 출생시간을 물어본 적이 없다. 이를 자동으로
/// "모름"으로 확정하거나 정오를 대입하지 않고, 사주 화면에 들어올 때 한 번만
/// 물어본다. 저장하면 다시 표시되지 않는다.
///
/// 앱 전체를 막지 않는다 — 디스커버리·채팅·커뮤니티는 그대로 쓸 수 있다.
class BirthTimeCompletionScreen extends StatefulWidget {
  /// 이미 저장돼 있는 생년월일. 이 화면에서는 바꾸지 않는다.
  final DateTime birthDate;

  final BirthProfileService birthProfileService;

  /// 저장이 끝난 뒤 호출된다. 보통 사주 화면을 다시 로드한다.
  final VoidCallback onCompleted;

  const BirthTimeCompletionScreen({
    super.key,
    required this.birthDate,
    required this.birthProfileService,
    required this.onCompleted,
  });

  @override
  State<BirthTimeCompletionScreen> createState() =>
      _BirthTimeCompletionScreenState();
}

class _BirthTimeCompletionScreenState extends State<BirthTimeCompletionScreen> {
  bool? _timeKnown;
  int? _minutes;
  bool _saving = false;
  String? _error;

  bool get _canSave {
    if (_timeKnown == null) return false;
    if (_timeKnown == true) return _minutes != null;
    return true;
  }

  Future<void> _save() async {
    // 중복 submit 방지 — 저장 중에는 다시 호출되지 않는다.
    if (_saving || !_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.birthProfileService.save(
        birthDate: widget.birthDate,
        birthProfile: _timeKnown == true
            ? BirthProfile.knownTime(_minutes!)
            : const BirthProfile.unknownTime(),
      );
      if (mounted) widget.onCompleted();
    } on BirthProfileFailure {
      // 실패해도 사용자가 고른 값은 그대로 남겨 다시 입력하지 않게 한다.
      if (mounted) {
        setState(() => _error = '저장에 실패했어요. 잠시 후 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 사주 탭 안에 그대로 얹히므로 자체 Scaffold/AppBar를 만들지 않는다.
    return SingleChildScrollView(
      key: const Key('birth-time-completion-screen'),
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        32 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '더 정확한 사주 해석을 위해\n태어난 시간을 알려주세요.',
            style: TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '태어난 시간을 입력하면 시주(時柱)까지 반영한 해석을 볼 수 있어요.\n'
            '모르셔도 생년월일을 기반으로 기본 해석을 제공해요.',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.border),
            ),
            child: BirthTimeSelector(
              timeKnown: _timeKnown,
              minutes: _minutes,
              onKnownChanged: (known) => setState(() {
                _timeKnown = known;
                if (!known) _minutes = null;
              }),
              onMinutesChanged: (m) => setState(() => _minutes = m),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(fontSize: 13, color: AppColors.error),
            ),
          ],
          const SizedBox(height: 28),
          PrimaryButton(
            key: const Key('birth-time-save'),
            label: _saving ? '저장 중…' : '저장하기',
            color: AppColors.matchPrimary,
            onPressed: _canSave && !_saving ? _save : null,
          ),
        ],
      ),
    );
  }
}
