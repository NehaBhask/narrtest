# Contributing to Narrator

Thank you for helping make Narrator better for the visually impaired community! 🙏

## Getting Started

1. Fork the repo and clone it locally
2. Run `flutter pub get`
3. Run `flutter test test/unit/` — all 150 tests should pass before you start

## Project Structure

```
lib/
├── core/           # Constants, DPDP consent, model manager
├── pipelines/
│   ├── pipeline1/  # Always-on obstacle detection (YOLO)
│   └── pipeline2/  # Wake word → STT → VLM → TTS
├── services/       # TTS, haptics, language, connectivity
├── screens/        # UI screens
└── widgets/        # Reusable UI components
```

## Coding Guidelines

- All business logic must have unit tests — minimum 80% coverage
- No user data (audio/frames) may be persisted — DPDP compliance is non-negotiable
- New languages require updating `SupportedLanguages.all` in `constants.dart` AND `IndicTrans2Tag` in `language_service.dart`
- Obstacle class changes must be mirrored in both `obstacle_detector.dart` and `narrator_ncnn.cpp`

## Running Tests

```bash
flutter test test/unit/           # unit tests
flutter test test/unit/ --coverage  # with coverage report
```

## Pull Request Checklist

- [ ] All existing tests pass (`flutter test test/unit/`)
- [ ] New code has corresponding tests
- [ ] `flutter analyze` shows no errors
- [ ] No user data is stored or transmitted without explicit consent
- [ ] README updated if new features added

## Reporting Bugs

Open a GitHub Issue with:
- Device model and Android version
- Steps to reproduce
- Expected vs actual behaviour

## Privacy

Any contribution that touches data handling must comply with India's DPDP Act 2023.  
Contact: privacy@narrator-app.in
