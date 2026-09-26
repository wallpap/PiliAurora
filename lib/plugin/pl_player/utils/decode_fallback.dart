bool isHardwareDecodeFailure(String event) {
  final message = event.toLowerCase();
  if (message.contains('hwaccel initialisation returned error')) return true;
  if (!message.contains('av1')) return false;

  return message.contains('hardware accelerated av1 decoding') ||
      message.contains('hwaccel initialisation returned error') ||
      message.contains('failed to get pixel format') ||
      message.contains('could not open codec');
}
