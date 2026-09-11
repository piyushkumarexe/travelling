import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../data/models/profile.dart';
import '../../../data/repositories/ai_repository.dart';

/// Real AI tourism assistant (NVIDIA API via the Yatrawise backend).
/// No canned responses: every answer comes from the live model with the
/// user's location and preferences as context.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _ChatMessage {
  _ChatMessage({required this.role, required this.text, this.isError = false});
  final String role; // user | assistant
  final String text;
  final bool isError;
}

class _AssistantScreenState extends State<AssistantScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<_ChatMessage> _messages = <_ChatMessage>[];
  bool _loading = false;
  String? _locationLabel;
  String? _profileContext;

  static const List<String> _suggestions = <String>[
    'Best attractions near me',
    'Safety tips for travelers',
    'Emergency phrases locals use',
    'Good places for photography',
    'Is this area safe at night?',
  ];

  @override
  void initState() {
    super.initState();
    _loadContext();
  }

  Future<void> _loadContext() async {
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (pos != null) {
        final String? label = await _c.placesRepository
            .reverseGeocode(LatLng(pos.latitude, pos.longitude));
        if (mounted && label != null) {
          setState(() => _locationLabel = label);
        }
      }
    } catch (_) {
      // Location context is optional; the assistant still works without it.
    }
    try {
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        final Profile? p = await _c.profileRepository.get(uid);
        if (mounted && p != null) {
          final List<String> parts = <String>[
            if (p.name.isNotEmpty) 'Name: ${p.name}',
            if (p.interests.isNotEmpty) 'Interests: ${p.interests.join(', ')}',
            'Budget: ${p.budget}',
            'Travel style: ${p.travelStyle}',
            'Preferred language: ${p.language}',
          ];
          setState(() => _profileContext = parts.join(' | '));
        }
      }
    } catch (_) {
      // Profile context is optional.
    }
  }

  Future<void> _send(String text) async {
    final String clean = text.trim();
    if (clean.isEmpty || _loading) return;
    setState(() {
      _messages = <_ChatMessage>[..._messages, _ChatMessage(role: 'user', text: clean)];
      _loading = true;
    });
    _input.clear();
    _scrollToBottom();
    try {
      final List<AiChatMessage> apiMessages = _messages
          .where((_ChatMessage m) => !m.isError)
          .map((m) => AiChatMessage(role: m.role, content: m.text))
          .toList()
          .cast<AiChatMessage>();
      // Keep the prompt compact: last 20 turns max.
      final int from = apiMessages.length > 20 ? apiMessages.length - 20 : 0;
      final String reply = await _c.aiRepository.chat(
        messages: apiMessages.sublist(from),
        locationLabel: _locationLabel,
        profileContext: _profileContext,
      );
      if (!mounted) return;
      setState(() {
        _messages = <_ChatMessage>[
          ..._messages,
          _ChatMessage(role: 'assistant', text: reply),
        ];
        _loading = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages = <_ChatMessage>[
          ..._messages,
          _ChatMessage(
            role: 'assistant',
            text:
                'I could not reach the AI service: ${e.toString()}\n\n'
                'Check your internet connection (and that the Yatrawise '
                'backend is deployed) and try again.',
            isError: true,
          ),
        ];
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Tourism Assistant'),
        actions: <Widget>[
          if (_locationLabel != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                children: <Widget>[
                  Icon(Icons.place, size: 14, color: scheme.primary),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 130,
                    child: Text(
                      _locationLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _messages.isEmpty && !_loading
                ? _emptyState(scheme)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length + (_loading ? 1 : 0),
                    itemBuilder: (BuildContext context, int i) {
                      if (i == _messages.length) {
                        return _typingBubble(scheme);
                      }
                      return _bubble(_messages[i], scheme);
                    },
                  ),
          ),
          if (_messages.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _suggestions.length,
                  separatorBuilder: (BuildContext context, int i) =>
                      const SizedBox(width: 8),
                  itemBuilder: (BuildContext context, int i) => ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(_suggestions[i]),
                    onPressed: () => _send(_suggestions[i]),
                  ),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText:
                            'Ask about places, food, safety, transport…',
                      ),
                      onSubmitted: (String v) => _send(v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: scheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _loading ? null : () => _send(_input.text),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.send, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xFF14B8A6), Color(0xFF0D9488)],
                ),
                shape: BoxShape.circle,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: const Color(0xFF0D9488).withOpacity(0.30),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: const Icon(Icons.auto_awesome,
                  size: 34, color: Colors.white),
            ),
            const SizedBox(height: 16),
            Text(
              'Ask me anything about your trip',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Recommendations, local info, transport, safety — I answer '
              'using live AI with your location and preferences as context.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _typingBubble(ColorScheme scheme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? scheme.surfaceContainerHighest
              : Colors.white,
          border: Border.all(
              color: scheme.outlineVariant.withOpacity(0.6)),
          borderRadius:
              const BorderRadius.only(bottomLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _Dot(delay: i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_ChatMessage m, ColorScheme scheme) {
    final bool isUser = m.role == 'user';
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = isUser
        ? scheme.primary
        : (m.isError
            ? scheme.errorContainer
            : (dark ? scheme.surfaceContainerHighest : Colors.white));
    final Color fg = isUser
        ? scheme.onPrimary
        : (m.isError ? scheme.onErrorContainer : scheme.onSurface);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment:
            isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
            border: isUser || m.isError
                ? null
                : Border.all(
                    color: scheme.outlineVariant.withOpacity(0.6)),
            boxShadow: isUser || m.isError
                ? null
                : <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withOpacity(dark ? 0.25 : 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: SelectableText(
            m.text,
            style: TextStyle(color: fg, fontSize: 14.5),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.delay});
  final int delay;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();
  late final Animation<double> _anim =
      Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(
            parent: _controller,
            curve: Interval(widget.delay * 0.2, 0.6 + widget.delay * 0.2,
                curve: Curves.easeInOut)),
      );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
