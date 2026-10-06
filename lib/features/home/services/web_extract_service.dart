import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// G3: fetch a web page and extract readable text for the model.
///
/// Security posture (mirrors the learning gateway's egress-guard idea):
/// - only http/https;
/// - DNS resolves the host and every resolved IP must be public (blocks
///   loopback / RFC1918 / link-local / CGNAT / ULA targets);
/// - redirects are followed manually (max 3) so every hop is re-validated,
///   preventing redirect-based SSRF.
class WebExtractService {
  WebExtractService._();

  static const int defaultMaxChars = 8000;
  static const int _maxRedirects = 3;
  static const Duration _timeout = Duration(seconds: 15);

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      responseType: ResponseType.plain,
      followRedirects: false,
      validateStatus: (_) => true,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0 Safari/537.36 KelivoWebExtract/1.0',
        'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.5',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
      },
    ),
  );

  /// Entry used by the `web_extract` local tool. Returns a JSON payload.
  static Future<String> extract(Map<String, dynamic> args) async {
    final url = (args['url'] ?? '').toString().trim();
    final maxCharsRaw = args['max_chars'];
    final maxChars =
        maxCharsRaw is num && maxCharsRaw > 0 && maxCharsRaw <= 50000
        ? maxCharsRaw.toInt()
        : defaultMaxChars;
    if (url.isEmpty) {
      return jsonEncode({
        'error': 'invalid_url',
        'message': 'The `url` argument is required.',
      });
    }
    try {
      var current = Uri.parse(url);
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        final violation = await _egressViolation(current);
        if (violation != null) {
          return jsonEncode({
            'error': 'blocked_private_host',
            'message': violation,
          });
        }
        final response = await _dio.getUri<dynamic>(current);
        final status = response.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          final location = (response.headers.value('location') ?? '').trim();
          if (location.isEmpty) {
            return jsonEncode({
              'error': 'fetch_failed',
              'message': 'HTTP $status without a Location header.',
            });
          }
          if (hop == _maxRedirects) {
            return jsonEncode({
              'error': 'too_many_redirects',
              'message': 'More than $_maxRedirects redirects.',
            });
          }
          current = current.resolve(location);
          continue;
        }
        if (status < 200 || status >= 300) {
          return jsonEncode({
            'error': 'fetch_failed',
            'message': 'HTTP $status from ${current.host}',
          });
        }
        final body = response.data?.toString() ?? '';
        return _buildPayload(current, body, maxChars);
      }
      return jsonEncode({'error': 'fetch_failed', 'message': 'Unreachable.'});
    } on FormatException catch (e) {
      return jsonEncode({'error': 'invalid_url', 'message': e.message});
    } on DioException catch (e) {
      return jsonEncode({'error': 'fetch_failed', 'message': e.type.name});
    } catch (e) {
      return jsonEncode({'error': 'fetch_failed', 'message': '$e'});
    }
  }

  /// Returns a human-readable reason when [uri] must not be fetched, else null.
  static Future<String?> _egressViolation(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return 'Only http/https URLs are allowed.';
    }
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return 'URL has no host.';
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(
        host,
        type: InternetAddressType.any,
      );
    } catch (_) {
      return 'DNS resolution failed for "$host".';
    }
    for (final addr in addresses) {
      if (_isPrivateAddress(addr)) {
        return 'Host "$host" resolves to a private/loopback address '
            '(${addr.address}) and is blocked.';
      }
    }
    return null;
  }

  static bool _isPrivateAddress(InternetAddress addr) {
    final type = addr.type;
    if (type == InternetAddressType.IPv4) {
      final o = addr.address
          .split('.')
          .map((e) => int.tryParse(e) ?? 0)
          .toList();
      if (o.isEmpty || o.length != 4) return true;
      if (o[0] == 127 || o[0] == 10 || o[0] == 0) return true;
      if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
      if (o[0] == 192 && o[1] == 168) return true;
      if (o[0] == 169 && o[1] == 254) return true; // link-local
      if (o[0] == 100 && o[1] >= 64 && o[1] <= 127) return true; // CGNAT
      return false;
    }
    if (type == InternetAddressType.IPv6) {
      final a = addr.address.toLowerCase();
      if (a == '::1' || a == '::') return true;
      if (a.startsWith('fe80')) return true; // link-local
      if (a.startsWith('fc') || a.startsWith('fd')) return true; // ULA
      if (a.startsWith('::ffff:')) {
        // IPv4-mapped — validate the embedded v4.
        final embedded = a.substring(7);
        try {
          return _isPrivateAddress(InternetAddress(embedded));
        } catch (_) {
          return true;
        }
      }
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // HTML → readable text (simplified readability)

  static String _buildPayload(Uri uri, String html, int maxChars) {
    final title = _extractTitle(html);
    final text = _extractText(html, maxChars);
    return jsonEncode({
      'url': uri.toString(),
      'title': title,
      'text': text.text,
      'truncated': text.truncated,
    });
  }

  static String _extractTitle(String html) {
    final m = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return '';
    return _decodeEntities(m.group(1) ?? '').trim();
  }

  static ({String text, bool truncated}) _extractText(
    String html,
    int maxChars,
  ) {
    var doc = html;
    // Drop non-content regions entirely.
    doc = _stripTagBlocks(doc, const [
      'script',
      'style',
      'noscript',
      'svg',
      'iframe',
      'template',
      'form',
      'nav',
      'aside',
      'footer',
      'head',
    ]);
    doc = doc.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    // Prefer the main content region when present.
    final main = RegExp(
      r'<(article|main)[^>]*>(.*)</\1>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(doc);
    if (main != null && (main.group(2)?.length ?? 0) > 200) {
      doc = main.group(2) ?? doc;
    }

    // Structural conversions before stripping tags.
    doc = doc.replaceAll(
      RegExp(
        r'<(br|/p|/div|/section|/article|/h[1-6]|/li|/tr|/blockquote)>',
        caseSensitive: false,
      ),
      '\n',
    );
    doc = doc.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
    doc = doc.replaceAll(
      RegExp(r'<h[1-6][^>]*>', caseSensitive: false),
      '\n\n',
    );

    // Strip remaining tags and decode entities.
    doc = doc.replaceAll(RegExp(r'<[^>]+>'), ' ');
    doc = _decodeEntities(doc);

    // Normalize whitespace.
    final lines = doc
        .split('\n')
        .map((l) => _squeezeSpaces(l).trim())
        .where((l) => l.isNotEmpty)
        .toList();
    var out = lines.join('\n');
    var truncated = false;
    if (out.length > maxChars) {
      out = out.substring(0, maxChars);
      truncated = true;
    }
    return (text: out, truncated: truncated);
  }

  static String _stripTagBlocks(String html, List<String> tags) {
    var out = html;
    for (final tag in tags) {
      out = out.replaceAll(
        RegExp('<$tag[^>]*>.*?</$tag>', caseSensitive: false, dotAll: true),
        ' ',
      );
      // Self-closing / unclosed variants (e.g. <head> without close).
      out = out.replaceAll(RegExp('<$tag[^>]*/?>', caseSensitive: false), ' ');
    }
    return out;
  }

  static String _decodeEntities(String input) {
    var out = input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&ldquo;', '"')
        .replaceAll('&rdquo;', '"')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '…');
    out = out.replaceAllMapped(RegExp(r'&#(\d{1,6});'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      if (code == null || code < 32 || code > 0x10FFFF) return '';
      return String.fromCharCode(code);
    });
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]{1,5});'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      if (code == null || code < 32 || code > 0x10FFFF) return '';
      return String.fromCharCode(code);
    });
    return out;
  }

  static String _squeezeSpaces(String input) {
    return input.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
  }
}
