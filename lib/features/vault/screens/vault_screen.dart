// 🗂️ Travel Document & Booking Vault — main screen.
//
// Metadata-only, fast list (files are downloaded only when a document is
// opened). Shows upcoming bookings, expiring documents, recent entries and
// trips that have documents — all from real saved data. Search and filters
// run over the already-loaded metadata (no duplicate Firebase queries).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../travel_document.dart';

enum _QuickFilter { all, upcoming, expiring }

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  TravelDocType? _typeFilter;
  String? _tripFilter;
  _QuickFilter _quick = _QuickFilter.all;

  @override
  void initState() {
    super.initState();
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) _c.vaultService.start(uid);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('🗂️ Document Vault')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Sign in required',
          message:
              'Your documents are stored privately under your account. '
              'Sign in to use the Travel Document & Booking Vault.',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('🗂️ Travel Document & Booking Vault')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/vault/edit'),
        icon: const Icon(Icons.add),
        label: const Text('Add Document/Booking'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[_c.vaultService, _c.tripPlanStore]),
        builder: (BuildContext context, _) {
          if (_c.vaultService.loading && _c.vaultService.docs.isEmpty) {
            return const LoadingView(message: 'Opening your vault…');
          }
          return _buildBody();
        },
      ),
    );
  }

  Widget _buildBody() {
    final List<TravelDocument> docs = _c.vaultService.docs;
    final DateTime today = DateTime.now();

    // ---- search + filters (in-memory over loaded metadata) ----
    final List<TravelDocument> filtered = <TravelDocument>[
      for (final TravelDocument d in docs)
        if (d.matchesQuery(_query, _c.vaultService.tripName(d.tripId)))
          if (_typeFilter == null || d.type == _typeFilter)
            if (_tripFilter == null || d.tripId == _tripFilter)
              if (_quick != _QuickFilter.upcoming ||
                  (d.timelineDate?.isAfter(today) ?? false))
                if (_quick != _QuickFilter.expiring ||
                    (d.expiryDate != null &&
                        d.expiryStatus(today) != VaultExpiryStatus.valid))
                  d,
    ];
    final bool isFiltering = _query.isNotEmpty ||
        _typeFilter != null ||
        _tripFilter != null ||
        _quick != _QuickFilter.all;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: <Widget>[
        if (_c.vaultService.lastError != null)
          ErrorState(
            message: _c.vaultService.lastError!,
            onRetry: () {
              final String? u = _c.authRepository.currentUser?.uid;
              if (u != null) _c.vaultService.start(u);
            },
          ),
        if (!_c.vaultService.remindersPermission) ...<Widget>[
          _noteBanner(
            'Notifications are turned off, so expiry reminders will not fire. '
            'Enable notifications for Tourism in system settings.',
          ),
          const SizedBox(height: 10),
        ],
        _searchField(),
        const SizedBox(height: 10),
        _quickChips(),
        const SizedBox(height: 8),
        _filterRow(),
        const SizedBox(height: 16),
        if (docs.isEmpty)
          EmptyState(
            icon: Icons.folder_shared_outlined,
            title: 'Your vault is empty',
            message:
                'Keep every travel document and booking in one secure place: '
                'passport, visa, ID, flight/train/bus tickets, hotel bookings, '
                'car rentals, activities and insurance.\n\n'
                'Tap "Add Document/Booking" to add your first entry — upload a '
                'PDF/JPG/PNG or enter the details manually.',
          )
        else if (isFiltering) ...<Widget>[
          Text('${filtered.length} result${filtered.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No documents match your search or filters.',
                  textAlign: TextAlign.center),
            )
          else
            for (final TravelDocument d in filtered)
              _docTile(d),
        ] else ...<Widget>[
          _upcomingSection(today),
          _expiringSection(today),
          Text('Recent documents & bookings',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final TravelDocument d in docs.take(10)) _docTile(d),
          if (docs.length > 10)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Showing your 20 most recent entries. Use search or '
                  'filters to find older ones.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 16),
          _tripsSection(),
        ],
        const SizedBox(height: 24),
        const Center(
          child: Text('TRAVEL-VAULT-2026-09-13-01',
              style: TextStyle(fontSize: 10, color: Colors.grey)),
        ),
      ],
    );
  }

  // ---------------- sections ----------------

  Widget _upcomingSection(DateTime now) {
    final DateTime today = DateTime(now.year, now.month, now.day);
    final List<(DateTime, String, TravelDocument)> entries =
        <(DateTime, String, TravelDocument)>[
      for (final TravelDocument d in _c.vaultService.docs)
        for (final (DateTime dt, String label) in d.timelineEntries())
          if (!dt.isBefore(today)) (dt, label, d),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Upcoming bookings', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        AppCard(
          child: Column(
            children: <Widget>[
              for (final (DateTime dt, String label, TravelDocument d)
                  in entries.take(6))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: <Widget>[
                      Text(d.type.emoji, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Text(_friendlyDate(dt, today),
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.primary)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _expiringSection(DateTime now) {
    final List<TravelDocument> expiring = <TravelDocument>[
      for (final TravelDocument d in _c.vaultService.docs)
        if (d.expiryDate != null &&
            d.expiryStatus(now) != VaultExpiryStatus.valid)
          d,
    ]..sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
    if (expiring.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Documents expiring soon',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final TravelDocument d in expiring.take(4))
          _docTile(d),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _tripsSection() {
    final Map<String, List<TravelDocument>> byTrip =
        <String, List<TravelDocument>>{};
    for (final TravelDocument d in _c.vaultService.docs) {
      final String? t = d.tripId;
      if (t == null) continue;
      (byTrip[t] ??= <TravelDocument>[]).add(d);
    }
    if (byTrip.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Trips with documents',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final MapEntry<String, List<TravelDocument>> e
                in byTrip.entries)
              ActionChip(
                avatar: const Icon(Icons.luggage, size: 16),
                label: Text(
                    '${_tripLabel(e.key)} (${e.value.length})',
                    style: const TextStyle(fontSize: 12.5)),
                onPressed: () => setState(() => _tripFilter = e.key),
              ),
          ],
        ),
      ],
    );
  }

  // ---------------- widgets ----------------

  Widget _noteBanner(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: <Widget>[
          const Icon(Icons.notifications_off, size: 18, color: AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.warning))),
        ]),
      );

  Widget _searchField() => TextField(
        controller: _searchCtrl,
        onChanged: (String v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText:
              'Search by title, PNR, booking ID, airline, hotel or trip…',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

  Widget _quickChips() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final (_QuickFilter f, String label, IconData icon)
              in <(_QuickFilter, String, IconData)>[
                (_QuickFilter.all, 'All', Icons.folder_outlined),
                (_QuickFilter.upcoming, 'My upcoming bookings', Icons.event),
                (_QuickFilter.expiring, 'Expiring soon', Icons.timer_outlined),
              ])
            ChoiceChip(
              avatar: Icon(icon, size: 16),
              label: Text(label, style: const TextStyle(fontSize: 12.5)),
              selected: _quick == f,
              onSelected: (bool v) => setState(() => _quick = v ? f : _QuickFilter.all),
            ),
        ],
      );

  Widget _filterRow() => Row(children: <Widget>[
        Expanded(
          child: DropdownButtonFormField<TravelDocType?>(
            value: _typeFilter,
            isDense: true,
            decoration: const InputDecoration(
                labelText: 'Type', isDense: true, border: OutlineInputBorder()),
            items: <DropdownMenuItem<TravelDocType?>>[
              const DropdownMenuItem<TravelDocType?>(
                  value: null, child: Text('All types', style: TextStyle(fontSize: 13))),
              for (final TravelDocType t in TravelDocType.values)
                DropdownMenuItem<TravelDocType?>(
                    value: t,
                    child: Text('${t.emoji} ${t.label}',
                        style: const TextStyle(fontSize: 13))),
            ],
            onChanged: (TravelDocType? v) => setState(() => _typeFilter = v),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<String?>(
            value: _tripFilter,
            isDense: true,
            decoration: const InputDecoration(
                labelText: 'Trip', isDense: true, border: OutlineInputBorder()),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                  value: null, child: Text('All trips', style: TextStyle(fontSize: 13))),
              for (final String tripId in _tripIdsWithDocs())
                DropdownMenuItem<String?>(
                    value: tripId,
                    child: Text(_tripLabel(tripId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13))),
            ],
            onChanged: (String? v) => setState(() => _tripFilter = v),
          ),
        ),
      ]);

  List<String> _tripIdsWithDocs() {
    final Set<String> ids = <String>{
      for (final TravelDocument d in _c.vaultService.docs)
        if (d.tripId != null) d.tripId!,
    };
    return ids.toList();
  }

  String _tripLabel(String tripId) {
    final String name = _c.vaultService.tripName(tripId);
    return name.isEmpty ? 'Trip' : name;
  }

  Widget _docTile(TravelDocument d) {
    final VaultExpiryStatus st =
        d.expiryDate == null ? VaultExpiryStatus.valid : d.expiryStatus(DateTime.now());
    final Color? chipColor = switch (st) {
      VaultExpiryStatus.expired => AppTheme.danger,
      VaultExpiryStatus.expiresToday => AppTheme.danger,
      VaultExpiryStatus.expiresSoon => AppTheme.warning,
      VaultExpiryStatus.valid => null,
    };
    final String trip = _c.vaultService.tripName(d.tripId);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => context.push('/vault/detail', extra: d.id),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(child: Text(d.type.emoji, style: const TextStyle(fontSize: 18))),
        ),
        title: Text(d.title,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          <String>[
            d.type.label,
            if (d.documentNumber != null && d.documentNumber!.isNotEmpty)
              '#${d.documentNumber}',
            if (trip.isNotEmpty) 'Trip: $trip',
            if (d.uploadStatus == VaultUploadStatus.uploadFailed)
              'File upload failed',
            if (d.uploadStatus == VaultUploadStatus.none && d.fileUrl == null)
              'No file',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5),
        ),
        trailing: chipColor == null
            ? const Icon(Icons.chevron_right)
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(_expiryChipText(d),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: chipColor)),
              ),
      ),
    );
  }

  String _expiryChipText(TravelDocument d) {
    final VaultExpiryStatus st = d.expiryStatus(DateTime.now());
    return switch (st) {
      VaultExpiryStatus.expired => 'Expired',
      VaultExpiryStatus.expiresToday => 'Expires today',
      VaultExpiryStatus.expiresSoon => 'In ${d.daysUntilExpiry()} d',
      VaultExpiryStatus.valid => 'Valid',
    };
  }

  String _friendlyDate(DateTime dt, DateTime today) {
    final DateTime d = DateTime(dt.year, dt.month, dt.day);
    final int diff = d.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return '${dt.day} ${_month(dt.month)}';
  }

  static String _month(int m) => const <String>[
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ][m - 1];
}
