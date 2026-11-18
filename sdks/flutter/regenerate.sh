#!/bin/sh
set -eu
cd "$(dirname "$0")"
flutter pub get --enforce-lockfile
dart run tool/generate.dart
dart format lib/src/generated
