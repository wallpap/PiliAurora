import 'dart:async';

import 'package:material_ui/material_ui.dart';

class SeekIndicator extends StatefulWidget {
  final ValueChanged<Duration> onSubmitted;
  final Duration duration;
  final bool forward;

  const SeekIndicator({
    super.key,
    required this.onSubmitted,
    required this.duration,
    required this.forward,
  });

  @override
  State<SeekIndicator> createState() => _SeekIndicatorState();
}

class _SeekIndicatorState extends State<SeekIndicator> {
  late Duration _duration;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _duration = widget.duration;
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () {
      widget.onSubmitted(_duration);
    });
  }

  void _increment() {
    _restartTimer();
    setState(() => _duration += widget.duration);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        splashColor: const Color(0x44767676),
        onTap: _increment,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.forward
                  ? const [Color(0x00767676), Color(0x88767676)]
                  : const [Color(0x88767676), Color(0x00767676)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                widget.forward ? Icons.fast_forward : Icons.fast_rewind,
                size: 24.0,
                color: Colors.white,
              ),
              const SizedBox(height: 8.0),
              Text(
                '${widget.forward ? '快进' : '快退'}${_duration.inSeconds}秒',
                style: const TextStyle(
                  fontSize: 12.0,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
