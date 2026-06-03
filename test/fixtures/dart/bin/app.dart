import 'dart:io';
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  await for (final HttpRequest req in server) {
    req.response..statusCode = 200..write('ok from dart');
    await req.response.close();
  }
}
