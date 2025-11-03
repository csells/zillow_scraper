import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

/// A class representing a Zestimate for a home.
///
/// [address] is the address of the home. [zestimate] is the Zestimate for the
/// home. [homeDetailsUrl] is the URL of the home details page on Zillow.
class Zestimate {
  /// Creates a new [Zestimate] instance.
  ///
  /// [address] is the address of the home. [zestimate] is the Zestimate for the
  /// home. [homeDetailsUrl] is the URL of the home details page on Zillow.
  Zestimate({
    required this.address,
    required this.zestimate,
    required this.homeDetailsUrl,
  });

  /// The address of the home.
  final String address;

  /// The Zestimate for the home.
  final int zestimate;

  /// The URL of the home details page on Zillow.
  final Uri homeDetailsUrl;

  /// The Zestimate for the home formatted as a string in USD.
  String get zestimateFormatted =>
      NumberFormat.currency(locale: 'en_US', symbol: r'$').format(zestimate);
}

/// A class for getting Zestimates for homes.
abstract class Zestimater {
  /// Creates a new [Zestimater] instance.
  Zestimater._();

  /// Gets the Zestimate for a home.
  ///
  /// [address] is the address of the home.
  ///
  /// Returns a [Zestimate] instance.
  static Future<Zestimate> getZestimate(String address) async {
    final url = await getHomeDetailsUrlFromAddress(address);
    final zestimate = await getHomeValueFromUrl(url);
    return Zestimate(
      address: address,
      zestimate: zestimate,
      homeDetailsUrl: url,
    );
  }

  /// Gets the home details URL for a home.
  ///
  /// [address] is the address of the home.
  ///
  /// Returns a [Uri] instance.
  static Future<Uri> getHomeDetailsUrlFromAddress(String address) async {
    // 1️⃣  Slugify: replace spaces/punctuation with dashes.
    final slug = address
        .replaceAll('#', '')
        .replaceAll(RegExp(r'[^\w\s-]'), ' ')
        .replaceAll(RegExp(r'\s+'), '-')
        .trim();

    final searchUrl = 'https://www.zillow.com/homes/${slug}_rb/';

    // 2️⃣  Fetch the search page.
    final headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
      'Accept-Language': 'en-US,en;q=0.9',
    };

    final resp = await http.get(Uri.parse(searchUrl), headers: headers);

    // 3️⃣  Follow redirect, if Zillow sends one.
    if (resp.statusCode >= 300 && resp.statusCode < 400) {
      final loc = resp.headers['location'];
      if (loc != null && loc.contains('/homedetails/')) {
        return Uri.parse(
          loc.startsWith('http') ? loc : 'https://www.zillow.com$loc',
        );
      }
    }

    // 4️⃣  If no redirect, try to discover a home-details link in the HTML.
    final match = RegExp(
      r'(/homedetails/[A-Za-z0-9\-_/]+_zpid/)',
    ).firstMatch(resp.body);
    if (match != null) {
      return Uri.parse('https://www.zillow.com${match.group(1)}');
    }

    // 5️⃣  If all attempts fail, throw an exception.
    throw Exception('Failed to convert address to Zillow URL.');
  }

  /// Gets the home value from a URL.
  ///
  /// [url] is the URL of the home details page on Zillow.
  ///
  /// Returns an [int] instance.
  static Future<int> getHomeValueFromUrl(Uri url) async {
    final html = await _fetchHtml(url);
    if (html.isEmpty) throw Exception('Fetched empty HTML.');

    // Quick bot-block detection
    if (html.contains('captcha') ||
        html.contains('verify you are a human') ||
        html.contains('Please verify')) {
      throw Exception('Fetched a bot-check page, not the listing HTML.');
    }

    final doc = html_parser.parse(html);
    final zestimate = _extractZestimate(doc, html);

    if (zestimate == null) {
      throw Exception('Failed to extract zestimate.');
    }

    return zestimate.toInt();
  }

  static Future<String> _fetchHtml(Uri url) async {
    final headers = _realisticHeaders();
    final client = http.Client();
    try {
      final resp = await client
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode} from Zillow.');
      }

      return resp.body;
    } on TimeoutException catch (e) {
      throw Exception('Timed out fetching $url: $e');
    } finally {
      client.close();
    }
  }

  static const List<String> _userAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Safari/605.1.15',
    'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Mobile Safari/537.36',
  ];

  static Map<String, String> _realisticHeaders() => {
    // Avoid setting Sec-CH-UA headers from server code—they’re client hints;
    // Random [User-Agent] is enough and realistic referrer should be enough.
    'User-Agent': _userAgents[Random().nextInt(_userAgents.length)],
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://www.google.com/',
    'Connection': 'keep-alive',
  };

  static num? _extractZestimate(dom.Document doc, String html) {
    // 1) Try Next.js JSON first - including nested gdpClientCache
    final next = _parseNextData(doc);
    if (next != null) {
      // First try the whole structure
      final fromNext = _findZestimateInJson(next);
      if (fromNext != null) return fromNext;

      // Then try decoding gdpClientCache (double-encoded JSON)
      final gdpCache = _dig<String>(next, [
        'props',
        'pageProps',
        'componentProps',
        'gdpClientCache',
      ]);
      if (gdpCache != null) {
        final decoded = _safeDecode(gdpCache);
        final fromCache = _findZestimateInJson(decoded);
        if (fromCache != null) return fromCache;
      }
    }

    // 2) Try Zillow preloaded data blocks
    for (final json in _parseAllZillowPreloadJson(doc)) {
      final z = _findZestimateInJson(json);
      if (z != null) return z;
    }

    // 3) As a last resort, regex scan the raw HTML Common forms:
    //    "zestimate":1234567 "zestimate":{"amount":1234567 ...}
    final r1 = RegExp(r'"zestimate"\s*:\s*([0-9]{4,}(?:\.\d+)?)');
    final m1 = r1.firstMatch(html);
    if (m1 != null) return num.tryParse(m1.group(1)!);

    final r2 = RegExp(
      r'"zestimate"\s*:\s*\{[^}]*?"(amount|value)"\s*:\s*([0-9]{4,}(?:\.\d+)?)',
      dotAll: true,
    );
    final m2 = r2.firstMatch(html);
    if (m2 != null) return num.tryParse(m2.group(2)!);

    return null;
  }

  static Map<String, dynamic>? _parseNextData(dom.Document doc) {
    final node = doc.querySelector('#__NEXT_DATA__');
    if (node == null) return null;
    final raw = node.text.trim();
    if (raw.isEmpty) return null;
    return _safeDecode(raw);
  }

  static Iterable<Map<String, dynamic>> _parseAllZillowPreloadJson(
    dom.Document doc,
  ) sync* {
    final scripts = doc.querySelectorAll(
      'script[data-zrr-shared-data-key],script[id^="hdpApolloPreloadedData"]',
    );
    for (final s in scripts) {
      var raw = s.text.trim();
      if (raw.startsWith('<!--')) {
        // Zillow often wraps JSON in HTML comments.
        raw = raw
            .replaceFirst(RegExp(r'^\s*<!--\s*'), '')
            .replaceFirst(RegExp(r'\s*-->\s*$'), '');
      }
      if (raw.isEmpty) continue;
      final decoded = _safeDecode(raw);
      if (decoded != null) yield decoded;
    }
  }

  /// Attempts to extract a numeric value from various formats:
  /// - Direct number
  /// - Map with 'amount' or 'value' key
  /// - String that can be parsed as a number
  static num? _extractNumericValue(dynamic value) {
    if (value is num) return value;

    if (value is Map) {
      final amount = value['amount'] ?? value['value'];
      if (amount is num) return amount;
      if (amount is String) {
        return num.tryParse(amount.replaceAll(RegExp(r'[^\d.]'), ''));
      }
    }

    if (value is String) {
      return num.tryParse(value.replaceAll(RegExp(r'[^\d.]'), ''));
    }

    return null;
  }

  static num? _findZestimateInJson(dynamic json) {
    if (json == null) return null;

    num? candidate;
    void visit(dynamic node) {
      if (candidate != null) return;

      if (node is Map<String, dynamic>) {
        // Try common keys: 'zestimate' or 'price'
        for (final key in ['zestimate', 'price']) {
          if (node.containsKey(key)) {
            final extracted = _extractNumericValue(node[key]);
            if (extracted != null) {
              candidate = extracted;
              return;
            }
          }
        }
        node.values.forEach(visit);
      } else if (node is List) {
        node.forEach(visit);
      }
    }

    visit(json);
    return candidate;
  }

  static Map<String, dynamic>? _safeDecode(String raw) {
    try {
      // Some blobs are strings containing JSON-escaped JSON; decode twice if
      // needed.
      final dynamic first = jsonDecode(raw);
      if (first is String) {
        return jsonDecode(first) as Map<String, dynamic>;
      }
      if (first is Map<String, dynamic>) return first;
      if (first is List &&
          first.isNotEmpty &&
          first.first is Map<String, dynamic>) {
        // Not expected but normalize
        return first.first as Map<String, dynamic>;
      }
    } on Object catch (_) {
      // Try stripping comment wrappers if any left
      try {
        final cleaned = raw
            .replaceAll(RegExp(r'^\s*<!--'), '')
            .replaceAll(RegExp(r'-->\s*$'), '')
            .replaceAll('&quot;', '"');
        dynamic decoded = jsonDecode(cleaned);
        if (decoded is String) decoded = jsonDecode(decoded);
        if (decoded is Map<String, dynamic>) return decoded;
      } on Object catch (e2) {
        throw Exception('Failed to decode JSON: $e2');
      }
    }

    throw Exception('Failed to decode JSON.');
  }

  static T? _dig<T>(Map<String, dynamic> obj, List<String> path) {
    dynamic cur = obj;
    for (final k in path) {
      if (cur is Map<String, dynamic> && cur.containsKey(k)) {
        cur = cur[k];
      } else {
        return null;
      }
    }
    return cur is T ? cur : null;
  }
}
