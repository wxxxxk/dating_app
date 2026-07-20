import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';
import '../../models/charm_model.dart';
import '../../services/charm/charm_service.dart';

class CharmReportScreen extends StatefulWidget {
  final String currentUid;
  final CharmService charmService;

  const CharmReportScreen({
    super.key,
    required this.currentUid,
    required this.charmService,
  });

  @override
  State<CharmReportScreen> createState() => _CharmReportScreenState();
}

class _CharmReportScreenState extends State<CharmReportScreen> {
  late Future<_CharmReportData> _future;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_CharmReportData> _load({bool refresh = false}) async {
    final results = await Future.wait([
      widget.charmService.getCharmReport(
        uid: widget.currentUid,
        refresh: refresh,
      ),
      widget.charmService.getReceivedInterestSummary(uid: widget.currentUid),
    ]);
    return _CharmReportData(
      report: results[0] as CharmReport,
      summary: results[1] as CharmInterestSummary,
    );
  }

  Future<void> _reload({bool refresh = false}) async {
    setState(() {
      _refreshing = refresh;
      _future = _load(refresh: refresh);
    });
    try {
      await _future;
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '내 매력 리포트',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '새로 분석',
            onPressed: _refreshing ? null : () => _reload(refresh: true),
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded),
          ),
        ],
      ),
      body: FutureBuilder<_CharmReportData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            if (kDebugMode) {
              debugPrint(
                '[CharmReport] load_failed category=${snap.error.runtimeType}',
              );
            }
            return _CharmErrorState(
              message: '매력 리포트를 만들지 못했어요.\n잠시 후 다시 시도해주세요.',
              onRetry: () => _reload(),
            );
          }
          final data = snap.data;
          if (data == null) {
            return _CharmErrorState(
              message: '매력 리포트를 만들지 못했어요.\n잠시 후 다시 시도해주세요.',
              onRetry: _reload,
            );
          }
          return _CharmReportBody(data: data);
        },
      ),
    );
  }
}

class _CharmReportData {
  final CharmReport report;
  final CharmInterestSummary summary;

  const _CharmReportData({required this.report, required this.summary});
}

class _CharmErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _CharmErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final minHeight =
        MediaQuery.sizeOf(context).height -
        kToolbarHeight -
        MediaQuery.paddingOf(context).vertical;
    final safeMinHeight = minHeight < 0 ? 0.0 : minHeight;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: safeMinHeight),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
            ],
          ),
        ),
      ),
    );
  }
}

class _CharmReportBody extends StatelessWidget {
  final _CharmReportData data;

  const _CharmReportBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final report = data.report;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        _InterestSummaryCard(summary: data.summary),
        const SizedBox(height: 14),
        _FirstImpressionCard(text: report.firstImpression),
        const SizedBox(height: 18),
        const Text(
          '매력 포인트',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        ...report.charmPoints.asMap().entries.map(
          (entry) => _CharmPointTile(index: entry.key, point: entry.value),
        ),
        const SizedBox(height: 14),
        _AppealTipCard(text: report.appealTip),
      ],
    );
  }
}

class _InterestSummaryCard extends StatelessWidget {
  final CharmInterestSummary summary;

  const _InterestSummaryCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.favorite_rounded, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary.badgeLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  summary.description,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FirstImpressionCard extends StatelessWidget {
  final String text;

  const _FirstImpressionCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        // 매력 리포트는 AI/매칭 계열 기능 → 민트 accent (사주 레드 아님).
        border: Border.all(
          color: AppColors.matchPrimary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '첫인상',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.matchPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(
              fontSize: 18,
              height: 1.5,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CharmPointTile extends StatelessWidget {
  final int index;
  final CharmPoint point;

  const _CharmPointTile({required this.index, required this.point});

  @override
  Widget build(BuildContext context) {
    final icons = [
      Icons.lightbulb_rounded,
      Icons.favorite_rounded,
      Icons.chat_bubble_rounded,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icons[index % icons.length], color: AppColors.secondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    point.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    point.description,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppealTipCard extends StatelessWidget {
  final String text;

  const _AppealTipCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.tips_and_updates_rounded, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
