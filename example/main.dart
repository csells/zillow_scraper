// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:zestimater/zestimater.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run example/main.dart "home address"');
    exit(-1);
  }

  final res = await Zestimater.getZestimate(args.first.trim());
  print('Address: ${res.address}');
  print('Home Details URL: ${res.homeDetailsUrl}');
  print('Zestimate: ${res.zestimateFormatted}');
}
