import 'package:catcher_2/model/report.dart';

abstract class ReportHandler {
  const ReportHandler();
  /// Method called when report has been accepted by user
  Future<bool> handle(Report report);

  @override
  String toString() => runtimeType.toString();
}
