/// Summary of overall update queue progress.
///
/// Aggregates status across all devices being updated.
class UpdateSummary {
  final int total;
  final int completed;
  final int failed;
  final int inProgress;

  const UpdateSummary({
    required this.total,
    required this.completed,
    required this.failed,
    required this.inProgress,
  });

  /// Overall progress as a fraction (0.0 to 1.0)
  double get overallProgress => total > 0 ? completed / total : 0.0;

  /// Overall progress as a percentage (0 to 100)
  double get overallProgressPercent => overallProgress * 100;

  /// Human-readable status text
  String get statusText => '$completed/$total completed';

  /// Detailed status text including failures
  String get detailedStatusText {
    if (failed > 0) {
      return '$completed/$total completed, $failed failed';
    }
    if (inProgress > 0) {
      return '$completed/$total completed, $inProgress in progress';
    }
    return statusText;
  }

  /// Check if all updates are complete (either success or failure)
  bool get isComplete => total > 0 && (completed + failed) == total;

  /// Check if any updates are in progress
  bool get hasActiveUpdates => inProgress > 0;

  @override
  String toString() => 'UpdateSummary($detailedStatusText)';
}
