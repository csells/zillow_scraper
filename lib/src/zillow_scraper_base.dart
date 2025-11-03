import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

class ZillowResult {
  final String? address;
  final num? zestimate;

  ZillowResult({this.address, this.zestimate});

  String get zestimateFormatted {
    final z = zestimate;
    if (z == null) return '—';
    // Simple currency formatting without intl dependency
    final s = z.toStringAsFixed(0);
    final withCommas = s.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    return '\$$withCommas';
  }

  @override
  String toString() =>
      'address: ${address ?? "—"} | zestimate: $zestimateFormatted';
}

Future<ZillowResult?> scrapeZillow(String url) async {
  final html = await _fetchHtml(url);
  if (html == null || html.isEmpty) return null;

  // Quick bot-block detection
  if (html.contains('captcha') ||
      html.contains('verify you are a human') ||
      html.contains('Please verify')) {
    stderr.writeln('Fetched a bot-check page, not the listing HTML.');
    return null;
  }

  final doc = html_parser.parse(html);

  // --- ADDRESS ---
  final address = _extractAddress(doc, html);

  // --- ZESTIMATE ---
  final zestimate = _extractZestimate(doc, html);

  if (address == null && zestimate == null) return null;
  return ZillowResult(address: address, zestimate: zestimate);
}

Future<String?> _fetchHtml(String url) async {
  final headers = _realisticHeaders();
  final client = http.Client();
  try {
    final uri = Uri.parse(url);
    final resp = await client
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      stderr.writeln('HTTP ${resp.statusCode} from Zillow.');
      return null;
    }

    // Try to decode properly; http package already handles gzip.
    return resp.body;
  } on TimeoutException {
    stderr.writeln('Timed out fetching $url');
    return null;
  } finally {
    client.close();
  }
}

Map<String, String> _realisticHeaders() {
  // You can rotate these if you like; using a current-ish mainstream UA helps.
  // You can also override via env var: UA="..." dart run ...
  final ua =
      Platform.environment['UA'] ??
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/130.0.0.0 Safari/537.36';

  return {
    'User-Agent': ua,
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://www.google.com/',
    'Connection': 'keep-alive',
    // Avoid setting Sec-CH-UA headers from server code—they’re client hints. UA above is enough.
  };
}

String? _extractAddress(dom.Document doc, String html) {
  // 1) JSON-LD (most reliable for address fields)
  final ld = _parseAllJsonLd(doc);
  for (final obj in ld) {
    final addr = _findAddressObject(obj);
    final formatted = _formatAddress(addr);
    if (formatted != null) return formatted;
    // Some JSON-LD uses a "name" that contains the full address
    final name = _dig<String>(obj, ['name']);
    if (name != null && _looksLikeAddress(name)) return name;
  }

  // 2) Next.js data blob (id="__NEXT_DATA__")
  final next = _parseNextData(doc);
  if (next != null) {
    final addrObj = _findAddressObject(next);
    final formatted = _formatAddress(addrObj);
    if (formatted != null) return formatted;

    // common variants in app data
    final line1 = _findFirstValueByKeys<String>(next, const [
      'streetAddress',
      'line1',
      'addressLine1',
    ]);
    final city = _findFirstValueByKeys<String>(next, const [
      'addressLocality',
      'city',
    ]);
    final region = _findFirstValueByKeys<String>(next, const [
      'addressRegion',
      'state',
    ]);
    final zip = _findFirstValueByKeys<String>(next, const [
      'postalCode',
      'zipcode',
      'zip',
    ]);
    final maybe = _joinAddress(line1, city, region, zip);
    if (maybe != null) return maybe;
  }

  // 3) Zillow's preloaded data scripts (data-zrr-shared-data-key / apollo, sometimes wrapped in <!-- -->)
  for (final json in _parseAllZillowPreloadJson(doc)) {
    final addrObj = _findAddressObject(json);
    final formatted = _formatAddress(addrObj);
    if (formatted != null) return formatted;
  }

  // 4) Title fallback (often "1234 Main St, City, ST ZIP | Zillow")
  final title = doc.querySelector('title')?.text.trim();
  if (title != null) {
    final maybe =
        RegExp(
          r'^\s*(.+?),\s*Zillow',
          caseSensitive: false,
        ).firstMatch(title)?.group(1) ??
        title.replaceAll('| Zillow', '').trim();
    if (_looksLikeAddress(maybe)) return maybe;
  }

  return null;
}

num? _extractZestimate(dom.Document doc, String html) {
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
      'gdpClientCache'
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

  // 3) As a last resort, regex scan the raw HTML
  // Common forms:
  //   "zestimate":1234567
  //   "zestimate":{"amount":1234567 ...}
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

// ------------------------------ helpers

List<Map<String, dynamic>> _parseAllJsonLd(dom.Document doc) {
  final nodes = doc.querySelectorAll('script[type="application/ld+json"]');
  final out = <Map<String, dynamic>>[];
  for (final n in nodes) {
    final raw = n.text.trim();
    if (raw.isEmpty) continue;
    for (final obj in _safeDecodePossiblyArray(raw)) {
      out.add(obj);
    }
  }
  return out;
}

Map<String, dynamic>? _parseNextData(dom.Document doc) {
  final node = doc.querySelector('#__NEXT_DATA__');
  if (node == null) return null;
  final raw = node.text.trim();
  if (raw.isEmpty) return null;
  return _safeDecode(raw);
}

Iterable<Map<String, dynamic>> _parseAllZillowPreloadJson(
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

// Finds first reasonable address object in a large JSON structure.
Map<String, dynamic>? _findAddressObject(dynamic json) {
  Map<String, dynamic>? best;

  void visit(dynamic node) {
    if (node is Map<String, dynamic>) {
      final keys = node.keys.map((k) => k.toLowerCase()).toSet();
      final hasStreet =
          keys.contains('streetaddress') ||
          keys.contains('addressline1') ||
          keys.contains('line1');
      final hasCity = keys.contains('addresslocality') || keys.contains('city');
      final hasRegion =
          keys.contains('addressregion') || keys.contains('state');
      final hasZip =
          keys.contains('postalcode') ||
          keys.contains('zipcode') ||
          keys.contains('zip');

      if ((hasStreet && hasCity && hasRegion && hasZip) ||
          (hasStreet && (hasCity || hasRegion) && (hasZip || hasRegion))) {
        best ??= node;
      }
      node.values.forEach(visit);
    } else if (node is List) {
      node.forEach(visit);
    }
  }

  visit(json);
  return best;
}

String? _formatAddress(Map<String, dynamic>? addr) {
  if (addr == null) return null;

  String? line1 = _findFirstValueByKeys<String>(addr, const [
    'streetAddress',
    'addressLine1',
    'line1',
  ]);
  String? city = _findFirstValueByKeys<String>(addr, const [
    'addressLocality',
    'city',
    'locality',
  ]);
  String? region = _findFirstValueByKeys<String>(addr, const [
    'addressRegion',
    'state',
    'region',
  ]);
  String? zip = _findFirstValueByKeys<String>(addr, const [
    'postalCode',
    'zipcode',
    'zip',
  ]);

  // Sometimes address is provided as a single "fullAddress" or "formattedAddress"
  final single = _findFirstValueByKeys<String>(addr, const [
    'formattedAddress',
    'fullAddress',
  ]);
  final combined = _joinAddress(line1, city, region, zip);
  return single ?? combined;
}

String? _joinAddress(String? line1, String? city, String? region, String? zip) {
  final parts = <String>[];
  if ((line1 ?? '').trim().isNotEmpty) parts.add(line1!.trim());
  final cityStateZip = [
    city,
    region,
    zip,
  ].where((s) => (s ?? '').trim().isNotEmpty).join(', ').replaceAll(', ,', ',');
  if (cityStateZip.trim().isNotEmpty) {
    if (parts.isNotEmpty) {
      parts.add(cityStateZip.replaceAll(RegExp(r',\s+,'), ','));
    } else {
      return cityStateZip;
    }
  }
  return parts.isEmpty ? null : parts.join(', ');
}

bool _looksLikeAddress(String s) {
  // Very light heuristic for "123 Main St, City, ST 12345" forms
  return RegExp(r'\d{2,} .+?, .+?, [A-Z]{2} \d{5}').hasMatch(s) ||
      RegExp(r'\d{2,} .+?, [A-Z]{2} \d{5}').hasMatch(s);
}

T? _findFirstValueByKeys<T>(dynamic json, List<String> keys) {
  final lower = keys.map((e) => e.toLowerCase()).toList();

  T? result;
  void visit(dynamic node) {
    if (result != null) return;
    if (node is Map<String, dynamic>) {
      for (final k in node.keys) {
        if (lower.contains(k.toLowerCase())) {
          final v = node[k];
          if (v is T) {
            result = v;
            return;
          } else if (v is String && T == String) {
            result = v as T;
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
  return result;
}

num? _findZestimateInJson(dynamic json) {
  if (json == null) return null;

  num? candidate;
  void visit(dynamic node) {
    if (candidate != null) return;

    if (node is Map<String, dynamic>) {
      // Direct key - try 'zestimate' first, then 'price'
      // Zillow sometimes stores zestimate as 'price' in __NEXT_DATA__
      for (final key in ['zestimate', 'price']) {
        if (node.containsKey(key)) {
          final v = node[key];
          if (v is num) {
            candidate = v;
            return;
          } else if (v is Map) {
            final amount = v['amount'] ?? v['value'];
            if (amount is num) {
              candidate = amount;
              return;
            } else if (amount is String) {
              final parsed = num.tryParse(
                amount.replaceAll(RegExp(r'[^\d.]'), ''),
              );
              if (parsed != null) {
                candidate = parsed;
                return;
              }
            }
          } else if (v is String) {
            final parsed = num.tryParse(v.replaceAll(RegExp(r'[^\d.]'), ''));
            if (parsed != null) {
              candidate = parsed;
              return;
            }
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

Map<String, dynamic>? _safeDecode(String raw) {
  try {
    // Some blobs are strings containing JSON-escaped JSON; decode twice if needed.
    dynamic first = jsonDecode(raw);
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
  } catch (_) {
    // Try stripping comment wrappers if any left
    try {
      final cleaned = raw
          .replaceAll(RegExp(r'^\s*<!--'), '')
          .replaceAll(RegExp(r'-->\s*$'), '')
          .replaceAll('&quot;', '"');
      dynamic decoded = jsonDecode(cleaned);
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
  }
  return null;
}

List<Map<String, dynamic>> _safeDecodePossiblyArray(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return [decoded];
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList();
    }
  } catch (_) {
    // ignore
  }
  return const [];
}

T? _dig<T>(Map<String, dynamic> obj, List<String> path) {
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
