import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/chat_appointment.dart';
import '../../services/chat/chat_service.dart';

/// 약속 카드 날짜를 "2026년 7월 24일 금요일" 형태로 포맷한다.
/// 새 dependency 없이 한국어 요일 라벨만 매핑한다.
String formatAppointmentDate(DateTime dt) {
  const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  final weekday = weekdays[(dt.weekday - 1) % 7];
  return '${dt.year}년 ${dt.month}월 ${dt.day}일 $weekday요일';
}

/// 약속 카드 시간을 "오후 7:00" 형태로 포맷한다.
String formatAppointmentTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${isPm ? '오후' : '오전'} $hour12:$minute';
}

/// 채팅 입력창 왼쪽 캘린더(약속 제안) 버튼. [onPressed]가 null이면 비활성화된다
/// (blocked/unmatched/제출 진행 중).
class ChatAppointmentButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const ChatAppointmentButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('chat-appointment-button'),
      tooltip: '약속 제안',
      onPressed: onPressed,
      icon: const Icon(Icons.calendar_month_rounded),
      color: AppColors.mintDeep,
      disabledColor: AppColors.textSecondary,
    );
  }
}

/// 약속 제안 입력 바텀시트.
///
/// 입력값 검증·제출 진행 상태·실패 시 입력 유지를 스스로 관리한다. [onSubmit]은
/// 실제 서비스 호출을 수행하고 성공 여부를 반환한다. 성공하면 시트를 닫으며
/// `true`를 pop하고, 실패하면 열린 채로 입력을 유지한다.
class AppointmentProposalSheet extends StatefulWidget {
  final Future<bool> Function({
    required DateTime scheduledAt,
    required String place,
    required String note,
  })
  onSubmit;

  /// 테스트/초기값 주입용. 실제 사용에서는 사용자가 피커로 선택한다.
  final DateTime? initialDate;
  final TimeOfDay? initialTime;
  final DateTime? now;

  const AppointmentProposalSheet({
    super.key,
    required this.onSubmit,
    this.initialDate,
    this.initialTime,
    this.now,
  });

  @override
  State<AppointmentProposalSheet> createState() =>
      _AppointmentProposalSheetState();
}

class _AppointmentProposalSheetState extends State<AppointmentProposalSheet> {
  final _placeController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialDate != null) {
      final d = widget.initialDate!;
      _date = DateTime(d.year, d.month, d.day);
    }
    _time = widget.initialTime;
  }

  @override
  void dispose() {
    _placeController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  DateTime get _today {
    final now = widget.now ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<void> _pickDate() async {
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? today,
      firstDate: today,
      lastDate: today.add(
        const Duration(days: ChatService.appointmentMaxDaysAhead),
      ),
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_date == null || _time == null) {
      setState(() => _error = '날짜와 시간을 선택해 주세요.');
      return;
    }
    final scheduledAt = DateTime(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );

    try {
      ChatService.normalizeAppointmentInput(
        scheduledAt: scheduledAt,
        place: _placeController.text,
        note: _noteController.text,
        now: widget.now,
      );
    } on AppointmentValidationError catch (e) {
      setState(() => _error = e.message);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.onSubmit(
      scheduledAt: scheduledAt,
      place: _placeController.text.trim(),
      note: _noteController.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _error = '약속을 제안하지 못했어요.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '약속 제안하기',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _PickerField(
                      buttonKey: const ValueKey('chat-appointment-date'),
                      label: '날짜',
                      value: _date == null ? '날짜 선택' : formatAppointmentDate(_date!),
                      onTap: _submitting ? null : _pickDate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PickerField(
                      buttonKey: const ValueKey('chat-appointment-time'),
                      label: '시간',
                      value: _time == null
                          ? '시간 선택'
                          : formatAppointmentTime(
                              DateTime(0, 1, 1, _time!.hour, _time!.minute),
                            ),
                      onTap: _submitting ? null : _pickTime,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('chat-appointment-place'),
                controller: _placeController,
                enabled: !_submitting,
                maxLength: ChatService.appointmentPlaceMaxLength,
                decoration: _fieldDecoration(
                  label: '장소',
                  hint: '예: 성수역 3번 출구',
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('chat-appointment-note'),
                controller: _noteController,
                enabled: !_submitting,
                minLines: 1,
                maxLines: 3,
                maxLength: ChatService.appointmentNoteMaxLength,
                decoration: _fieldDecoration(
                  label: '메모 (선택)',
                  hint: '예: 근처 카페에서 만나요',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  key: const ValueKey('chat-appointment-error'),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('chat-appointment-submit'),
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.mint,
                  foregroundColor: AppColors.onMint,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.onMint,
                        ),
                      )
                    : const Text(
                        '약속 제안하기',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration({required String label, required String hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.border),
      ),
    );
  }
}

class _PickerField extends StatelessWidget {
  final Key buttonKey;
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _PickerField({
    required this.buttonKey,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          key: buttonKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.button),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 약속 제안 메시지를 카드로 렌더링한다. appointment 문서를 실시간 구독해
/// pending/accepted/declined 상태를 반영하고, 수신자에게만 응답 버튼을 보인다.
class AppointmentMessageCard extends StatefulWidget {
  final String appointmentId;
  final String currentUid;
  final Stream<ChatAppointment?> stream;
  final Future<void> Function(ChatAppointmentStatus status) onRespond;

  /// appointment 로드 실패 시 안전 대체 문구.
  final String fallbackText;

  const AppointmentMessageCard({
    super.key,
    required this.appointmentId,
    required this.currentUid,
    required this.stream,
    required this.onRespond,
    this.fallbackText = '약속을 불러오지 못했어요.',
  });

  @override
  State<AppointmentMessageCard> createState() => _AppointmentMessageCardState();
}

class _AppointmentMessageCardState extends State<AppointmentMessageCard> {
  bool _responding = false;

  Future<void> _respond(ChatAppointmentStatus status) async {
    if (_responding) return;
    setState(() => _responding = true);
    try {
      await widget.onRespond(status);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('응답하지 못했어요.')));
      }
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChatAppointment?>(
      stream: widget.stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return _CardShell(
            appointmentId: widget.appointmentId,
            child: const _AppointmentLoading(),
          );
        }
        final appointment = snap.data;
        if (appointment == null) {
          return _CardShell(
            appointmentId: widget.appointmentId,
            child: Text(
              widget.fallbackText,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          );
        }
        return _CardShell(
          appointmentId: widget.appointmentId,
          child: _buildContent(appointment),
        );
      },
    );
  }

  Widget _buildContent(ChatAppointment appointment) {
    final isRecipient = appointment.isRecipient(widget.currentUid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('📅', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            const Text(
              '약속 제안',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const Spacer(),
            _StatusBadge(status: appointment.status),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          formatAppointmentDate(appointment.scheduledAt),
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          formatAppointmentTime(appointment.scheduledAt),
          style: const TextStyle(
            fontSize: 14,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.place_rounded,
              size: 16,
              color: AppColors.mintDeep,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                appointment.place,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        if (appointment.note.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            appointment.note,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 12),
        _buildStatusFooter(appointment, isRecipient),
      ],
    );
  }

  Widget _buildStatusFooter(ChatAppointment appointment, bool isRecipient) {
    switch (appointment.status) {
      case ChatAppointmentStatus.pending:
        if (isRecipient) {
          return Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: ValueKey(
                    'chat-appointment-decline-${widget.appointmentId}',
                  ),
                  onPressed: _responding
                      ? null
                      : () => _respond(ChatAppointmentStatus.declined),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('이번에는 어려워요'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: ValueKey(
                    'chat-appointment-accept-${widget.appointmentId}',
                  ),
                  onPressed: _responding
                      ? null
                      : () => _respond(ChatAppointmentStatus.accepted),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.mint,
                    foregroundColor: AppColors.onMint,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text(
                    '수락',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          );
        }
        return const Text(
          '상대의 답변을 기다리고 있어요.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        );
      case ChatAppointmentStatus.accepted:
        return const SizedBox.shrink();
      case ChatAppointmentStatus.declined:
        return const Text(
          '이번 약속은 성사되지 않았어요.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        );
    }
  }
}

class _CardShell extends StatelessWidget {
  final String appointmentId;
  final Widget child;

  const _CardShell({required this.appointmentId, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('chat-appointment-card-$appointmentId'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.mint.withValues(alpha: 0.4)),
          boxShadow: AppShadows.card,
        ),
        child: child,
      ),
    );
  }
}

class _AppointmentLoading extends StatelessWidget {
  const _AppointmentLoading();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Text(
          '약속을 불러오는 중이에요',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final ChatAppointmentStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color fg;
    late final Color bg;
    switch (status) {
      case ChatAppointmentStatus.accepted:
        label = '약속 확정';
        fg = AppColors.onMint;
        bg = AppColors.mint;
        break;
      case ChatAppointmentStatus.declined:
        label = '제안 종료';
        fg = AppColors.textSecondary;
        bg = AppColors.divider;
        break;
      case ChatAppointmentStatus.pending:
        label = '답변 대기';
        fg = AppColors.mintDeep;
        bg = AppColors.mintSoft;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }
}

/// 약속 수락/거절 결과를 가운데 정렬된 작은 시스템 행으로 표시한다.
/// 일반 사용자 말풍선 grouping과 섞이지 않는다.
class AppointmentResponseRow extends StatelessWidget {
  final String text;

  const AppointmentResponseRow({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
