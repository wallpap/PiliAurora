import 'package:pili_aurora/app/bootstrap.dart';
import 'package:pili_aurora/pages/setting/decoder_test_process.dart';

Future<void> main(List<String> arguments) =>
    arguments.firstOrNull == decoderTestWorkerArgument
    ? runDecoderTestWorker()
    : bootstrapApplication(arguments);
