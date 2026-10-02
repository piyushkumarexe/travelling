import 'package:flutter/foundation.dart';

enum ConnectionRisk { safe, tight, missed }

enum ConnectionMode { flight, train, bus }

@immutable
class ConnectionAssessment {
  const ConnectionAssessment({
    required this.risk,
    required this.availableMinutes,
    required this.requiredMinutes,
    required this.marginMinutes,
    required this.reasons,
    required this.actions,
  });

  final ConnectionRisk risk;
  final int availableMinutes;
  final int requiredMinutes;
  final int marginMinutes;
  final List<String> reasons;
  final List<String> actions;
}

/// Deterministic transfer-risk engine. It never claims live provider status:
/// the traveler enters the known delay and connection conditions, and every
/// minute added to the required buffer is explainable in [reasons].
abstract final class ConnectionGuardianEngine {
  static ConnectionAssessment assess({
    required DateTime scheduledArrival,
    required DateTime nextDeparture,
    required ConnectionMode incomingMode,
    required ConnectionMode outgoingMode,
    int knownDelayMinutes = 0,
    bool terminalChange = false,
    bool baggageRecheck = false,
    bool internationalTransfer = false,
    bool mobilityAssistance = false,
  }) {
    final DateTime expectedArrival =
        scheduledArrival.add(Duration(minutes: knownDelayMinutes.clamp(0, 1440)));
    final int available = nextDeparture.difference(expectedArrival).inMinutes;
    int required = _baseBuffer(incomingMode, outgoingMode);
    final List<String> reasons = <String>[
      '${_modeName(incomingMode)} → ${_modeName(outgoingMode)} base buffer: $required min',
    ];
    void add(bool condition, int minutes, String reason) {
      if (!condition) return;
      required += minutes;
      reasons.add('$reason: +$minutes min');
    }

    add(terminalChange, 20, 'Terminal/station change');
    add(baggageRecheck, 35, 'Collect and re-check baggage');
    add(internationalTransfer, 45, 'Immigration/security transfer');
    add(mobilityAssistance, 20, 'Mobility assistance allowance');

    final int margin = available - required;
    final ConnectionRisk risk = available < 0
        ? ConnectionRisk.missed
        : margin < 15
            ? ConnectionRisk.tight
            : ConnectionRisk.safe;
    final List<String> actions = switch (risk) {
      ConnectionRisk.safe => <String>[
          'Keep tickets and platform/terminal details ready.',
          'Recheck the provider status before leaving the first leg.',
        ],
      ConnectionRisk.tight => <String>[
          'Inform staff on the incoming leg that the connection is tight.',
          'Open the next provider’s official app and verify gate/platform.',
          if (baggageRecheck)
            'Confirm whether baggage can be checked through to the destination.',
          'Prepare a fallback departure before the first leg begins.',
        ],
      ConnectionRisk.missed => <String>[
          'Contact the official provider immediately for rebooking options.',
          'Keep delay evidence, tickets and receipts for claims.',
          'Do not pay an unofficial agent or unverified payment link.',
        ],
    };
    return ConnectionAssessment(
      risk: risk,
      availableMinutes: available,
      requiredMinutes: required,
      marginMinutes: margin,
      reasons: List<String>.unmodifiable(reasons),
      actions: List<String>.unmodifiable(actions),
    );
  }

  static int _baseBuffer(ConnectionMode incoming, ConnectionMode outgoing) {
    if (incoming == ConnectionMode.flight || outgoing == ConnectionMode.flight) {
      return 60;
    }
    if (incoming == ConnectionMode.train && outgoing == ConnectionMode.train) {
      return 25;
    }
    return 30;
  }

  static String _modeName(ConnectionMode mode) => switch (mode) {
        ConnectionMode.flight => 'Flight',
        ConnectionMode.train => 'Train',
        ConnectionMode.bus => 'Bus',
      };
}
