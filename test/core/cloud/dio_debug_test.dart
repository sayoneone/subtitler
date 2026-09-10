import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug dio to local server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      request.response.statusCode = 200;
      request.response.write(jsonEncode({'ok': true}));
      await request.response.close();
    });

    final dio = Dio();
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '$baseUrl/translate/v2/translate',
        data: {'a': 1},
      );
      print('SUCCESS: ${response.data}');
    } catch (e, st) {
      print('ERROR: $e');
      print(st);
    }
    await server.close(force: true);
  });
}
