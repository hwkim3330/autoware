import 'package:flutter/material.dart';

import '../models/autoware_state.dart';
import '../models/enums.dart';
import '../services/monitoring_service.dart';
import '../theme/app_theme.dart';
import '../widgets/autoware_module_tile.dart';
import '../widgets/status_badge.dart';
import '../widgets/summary_card.dart';
import 'screen_header.dart';

class AutowareStackScreen extends StatelessWidget {
  final MonitoringService service;
  const AutowareStackScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MonitorBody(
      service: service,
      titleOverride: 'Autoware Stack',
      builder: (context, data) {
        final aw = data.autoware;
        final modules = AutowareState.moduleOrder
            .where(aw.modules.containsKey)
            .toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'SELECTED STACK',
              trailing: StatusBadge(
                  text: aw.selectedStack, color: StatusColors.amber),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(aw.stackReason.isEmpty ? '—' : aw.stackReason,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'AUTOWARE MODULES',
              child: GridView.count(
                crossAxisCount:
                    MediaQuery.of(context).size.width > 1000 ? 4 : 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 2.0,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                children: [
                  for (final k in modules)
                    AutowareModuleTile(moduleKey: k, status: aw.modules[k]!),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'EXCLUDED MODULES (vs FULL_STACK)',
              child: aw.excludedModules.isEmpty
                  ? const Text('None — full stack active',
                      style: TextStyle(color: AppTheme.textMuted))
                  : Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final m in aw.excludedModules)
                          StatusBadge(text: m, color: StatusColors.gray),
                      ],
                    ),
            ),
            const SizedBox(height: 14),
            SectionCard(
              title: 'RESOURCE IMPACT',
              child: KvRow('Resource saving vs full stack',
                  '${data.metrics.resourceSavingPercent.toStringAsFixed(1)} %',
                  valueColor: StatusColors.green),
            ),
          ],
        );
      },
    );
  }
}
