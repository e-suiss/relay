import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  final String? stamp = Platform.environment['LOCK_DATE'];
  final DateTime lockDate =
      stamp == null || stamp.isEmpty ? DateTime.now().toUtc() : DateTime.parse(stamp).toUtc();
  final DateTime cutoff = lockDate.subtract(const Duration(days: 7));
  final YamlMap lock = loadYaml(File('pubspec.lock').readAsStringSync()) as YamlMap;
  final YamlMap packages = lock['packages'] as YamlMap;
  final http.Client client = http.Client();
  final List<String> young = <String>[];
  for (final MapEntry<dynamic, dynamic> e in packages.entries) {
    final YamlMap p = e.value as YamlMap;
    if (p['source'] != 'hosted') continue;
    final String name = e.key as String;
    final String version = p['version'] as String;
    final http.Response r =
        await client.get(Uri.parse('https://pub.dev/api/packages/$name'));
    final Map<String, Object?> info = jsonDecode(r.body) as Map<String, Object?>;
    final List<Object?> versions = info['versions']! as List<Object?>;
    final Map<String, Object?> v = versions
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> x) => x['version'] == version);
    final DateTime published = DateTime.parse(v['published']! as String);
    stdout.writeln('$name $version $published');
    if (published.isAfter(cutoff)) young.add('$name $version ($published)');
  }
  client.close();
  if (young.isNotEmpty) {
    stderr.writeln('Published less than 7 days before $lockDate: ${young.join(', ')}');
    exit(1);
  }
}
