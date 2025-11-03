# Zillow Scraper

A Dart library for scraping Zillow Zestimates (home value estimates) for any US address.

## Features

- Get Zillow's estimated home value (Zestimate) for any address
- Automatically finds the Zillow home details URL from an address
- Extracts zestimates from multiple JSON data sources in Zillow's HTML
- Handles Zillow's complex nested JSON structures (including `gdpClientCache`)
- Returns formatted currency values
- Works with properties that are actively listed or not for sale

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  zestimater: ^0.1.0
```

Or install via command line:

```bash
dart pub add zestimater
```

## Usage

### API Usage

```dart
import 'package:zestimater/zestimater.dart';

Future<void> main() async {
  // Get zestimate from address
  final result = await Zestimater.getZestimate('12290 SW Marion St, Tigard, OR 97223');

  print('Address: ${result.address}');
  print('Zestimate: ${result.zestimateFormatted}');  // $598,500.00
  print('Home Details URL: ${result.homeDetailsUrl}');
}
```

### CLI Usage

Run directly from the command line:

```bash
dart run example/main.dart "12290 SW Marion St, Tigard, OR 97223"
```

Output:
```
Address: 12290 SW Marion St, Tigard, OR 97223
Home Details URL: https://www.zillow.com/homedetails/12290-SW-Marion-St-Tigard-OR-97223/48604316_zpid/
Zestimate: $598,500.00
```

## API Reference

### `Zestimater` class

Static methods for retrieving Zillow data.

#### `Zestimater.getZestimate(String address)`

Gets the Zestimate for a given address.

**Parameters:**
- `address` (String): The full street address (e.g., "123 Main St, City, State ZIP")

**Returns:** `Future<Zestimate>`

**Throws:**
- `Exception` if the address cannot be found on Zillow
- `Exception` if the zestimate cannot be extracted from the page
- `Exception` if HTTP request fails or times out
- `Exception` if Zillow returns a CAPTCHA page

**Example:**
```dart
final result = await Zestimater.getZestimate('123 Main St, Portland, OR 97201');
print(result.zestimateFormatted);  // $450,000.00
```

#### `Zestimater.getHomeDetailsUrlFromAddress(String address)`

Converts a street address to a Zillow home details URL.

**Parameters:**
- `address` (String): The full street address

**Returns:** `Future<Uri>`

**Throws:**
- `Exception` if the address cannot be converted to a Zillow URL

**Example:**
```dart
final url = await Zestimater.getHomeDetailsUrlFromAddress('123 Main St, Portland, OR 97201');
print(url);  // https://www.zillow.com/homedetails/...
```

#### `Zestimater.getHomeValueFromUrl(Uri url)`

Extracts the zestimate from a Zillow home details URL.

**Parameters:**
- `url` (Uri): The Zillow home details URL

**Returns:** `Future<int>`

**Throws:**
- `Exception` if the zestimate cannot be extracted
- `Exception` if Zillow returns a CAPTCHA page

**Example:**
```dart
final url = Uri.parse('https://www.zillow.com/homedetails/...');
final zestimate = await Zestimater.getHomeValueFromUrl(url);
print('\$$zestimate');  // $598500
```

### `Zestimate` class

Represents the result of a Zillow scrape.

**Properties:**
- `address` (String): The property address
- `zestimate` (int): The estimated home value in dollars
- `homeDetailsUrl` (Uri): The Zillow home details page URL
- `zestimateFormatted` (String): Currency-formatted zestimate (e.g., "$598,500.00")

**Example:**
```dart
final result = await Zestimater.getZestimate('123 Main St, Portland, OR 97201');
print('Raw value: ${result.zestimate}');              // 598500
print('Formatted: ${result.zestimateFormatted}');     // $598,500.00
print('Link: ${result.homeDetailsUrl}');              // https://...
```

## How It Works

The scraper:
1. Converts your address into a Zillow search URL
2. Follows redirects to find the home details page
3. Parses multiple JSON data structures embedded in the HTML:
   - `__NEXT_DATA__` script tag (Next.js application data)
   - `gdpClientCache` (double-encoded JSON with property data)
   - `data-zrr-shared-data-key` script tags (Zillow preloaded data)
4. Searches for the zestimate under multiple possible keys (`zestimate`, `price`)
5. Returns the first valid numeric value found

## Limitations

- This scraper relies on Zillow's current HTML structure and may break if Zillow changes their site
- Zillow may rate-limit or block requests with CAPTCHA challenges
- Works best with valid, complete US addresses
- Only returns the current Zestimate (not historical data or price range)

## Error Handling

The library throws exceptions for all error conditions rather than returning null values. This ensures errors are visible and can be properly handled:

```dart
try {
  final result = await Zestimater.getZestimate('Invalid Address XYZ');
} on Exception catch (e) {
  print('Failed to get zestimate: $e');
}
```

## License

This project is for educational purposes. Please review Zillow's Terms of Service before using this library in production.
