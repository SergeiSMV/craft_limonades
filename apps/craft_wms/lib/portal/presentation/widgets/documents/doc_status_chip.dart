import 'package:flutter/material.dart';

import '../../../../core/gen/strings.g.dart';
import '../ui/portal_badge.dart';

/// Статус документа в 1С (ADHOC-56 - отметкой Polaris): «Ожидает» - внимание,
/// «Проведено» - успех.
class DocStatusChip extends StatelessWidget {
  const DocStatusChip({super.key, required this.posted});

  final bool posted;

  @override
  Widget build(BuildContext context) => posted
      ? PortalBadge(
          t.portal.documents.statusPosted,
          tone: PortalBadgeTone.success,
        )
      : PortalBadge(
          t.portal.documents.statusWaiting,
          tone: PortalBadgeTone.warning,
        );
}
