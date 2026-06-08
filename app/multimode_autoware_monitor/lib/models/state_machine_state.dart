class StateMachineState {
  final String stateId;
  final String displayName;
  final String previousStateId;
  final String transitionStatus;
  final String transitionReason;

  const StateMachineState({
    required this.stateId,
    required this.displayName,
    required this.previousStateId,
    required this.transitionStatus,
    required this.transitionReason,
  });

  factory StateMachineState.fromJson(Map<String, dynamic> j) =>
      StateMachineState(
        stateId: (j['stateId'] ?? '-').toString(),
        displayName: (j['displayName'] ?? '-').toString(),
        previousStateId: (j['previousStateId'] ?? '-').toString(),
        transitionStatus: (j['transitionStatus'] ?? '-').toString(),
        transitionReason: (j['transitionReason'] ?? '').toString(),
      );

  static const empty = StateMachineState(
    stateId: '-',
    displayName: '-',
    previousStateId: '-',
    transitionStatus: '-',
    transitionReason: '',
  );
}
