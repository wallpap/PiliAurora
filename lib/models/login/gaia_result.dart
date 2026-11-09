class GaiaChallenge {
  const GaiaChallenge({
    required this.token,
    required this.gt,
    required this.challenge,
  });

  final String token;
  final String gt;
  final String challenge;
}

sealed class GaiaVerificationResult {
  const GaiaVerificationResult();
}

final class GaiaVerified extends GaiaVerificationResult {
  const GaiaVerified(this.riskId);
  final String riskId;
}

final class GaiaRejected extends GaiaVerificationResult {
  const GaiaRejected();
}
