import 'package:flutter/material.dart';

import '../../features/settings/pages/owner_identity_page.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';

/// Desktop right-side pane for the owner identity declaration (AAA furnace-2).
class DesktopOwnerIdentityPane extends StatelessWidget {
  const DesktopOwnerIdentityPane({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            l10n.ownerIdentityPageTitle,
            style: TextStyle(
              fontSize: 18,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
            ),
          ),
        ),
        Expanded(
          child: OwnerIdentityContent(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          ),
        ),
      ],
    );
  }
}
