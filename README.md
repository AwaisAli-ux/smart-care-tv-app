# mbapp

A new Flutter project.

## Device binding & remote lock system

The app now gates login/launch behind a device-binding backend — see
`backend/README.md` for the PHP + MySQL API, the admin panel (lock/unlock
users & devices), and setup steps. `lib/services/auth_config.dart` must be
pointed at your deployed backend before release builds.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
