import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/alerts.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/report_peek_sheet.dart';
import '../volunteer/offer_sheet.dart';

/// In-app notification inbox (alarms, standard requests, nearby reports, info).
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Json>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Api.instance.get('/me/notifications', query: {'limit': 100}) as Json;
      if (mounted) setState(() => _items = (res['items'] as List).cast<Json>());
      if (mounted) await context.read<AlertCenter>().markAllRead();
    } catch (e) {
      showError(e);
    }
  }

  void _open(Json n) {
    final data = (n['data'] as Map?)?.cast<String, dynamic>() ?? {};
    switch (n['kind']) {
      case 'alarm' || 'standard':
        openOffer(data['offer_id'] as String);
      case 'nearby':
        showReportPeek(data['report_id'] as String);
      default:
        if (data['report_id'] != null) {
          showReportPeek(data['report_id'] as String);
        }
    }
  }

  static (IconData, Color) _style(String kind) => switch (kind) {
        'alarm' => (Icons.notifications_active_rounded, AppColors.primary),
        'standard' => (Icons.volunteer_activism_outlined, AppColors.ink),
        'nearby' => (Icons.visibility_outlined, AppColors.info),
        'confirm_prompt' => (Icons.how_to_vote_outlined, AppColors.success),
        'accuracy_prompt' => (Icons.fact_check_outlined, AppColors.info),
        _ => (Icons.info_outline_rounded, AppColors.inkMuted),
      };

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifikasi')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: items.isEmpty
                  ? ListView(children: const [EmptyHint(icon: Icons.inbox_outlined, text: 'Belum ada notifikasi.')])
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                      itemBuilder: (_, i) {
                        final n = items[i];
                        final (icon, color) = _style(n['kind'] as String);
                        return ListTile(
                          onTap: () => _open(n),
                          leading: CircleAvatar(
                              backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color)),
                          title: Text(n['title'] as String,
                              style: TextStyle(fontWeight: n['read'] == true ? FontWeight.w600 : FontWeight.w900)),
                          subtitle: Text('${n['body']}\n${timeAgo(n['created_at'])}'),
                          isThreeLine: true,
                        );
                      },
                    ),
            ),
    );
  }
}
