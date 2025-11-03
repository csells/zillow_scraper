# Zestimater

A Dart library for scraping Zillow home value estimates for any US address.

## Features

- Get Zillow's estimated home value (Zestimate) for any address
- Automatically finds the Zillow home details URL from an address
- Works with properties that are actively listed or not for sale

## Usage

### API Usage

```dart
import 'package:zestimater/zestimater.dart';

Future<void> main() async {
  // Get zestimate from address
  final result =
    await Zestimater.getZestimate('11222 Dilling Street, Studio City, CA');

  print('Address: ${result.address}');
  print('Zestimate: ${result.zestimateFormatted}');
  print('Home Details URL: ${result.homeDetailsUrl}');
}
```

### CLI Usage

Run directly from the command line:

```bash
dart run example/main.dart "11222 Dilling Street, Studio City, CA"
```

Output:
```
Address: 11222 Dilling Street, Studio City, CA 91602
Home Details URL: https://www.zillow.com/homedetails/11222-Dilling-St-North-Hollywood-CA-91602/20025974_zpid/
Zestimate: $3,747,600.00
```

## How It Works

The scraper:
1. Converts your address into a Zillow search URL
2. Follows redirects to find the home details page
3. Parses multiple JSON data structures embedded in the HTML:
   - `__NEXT_DATA__` script tag (Next.js application data)
   - `gdpClientCache` (double-encoded JSON with property data)
   - `data-zrr-shared-data-key` script tags (Zillow preloaded data)
4. Searches for the zestimate under multiple possible keys (`zestimate`,
   `price`)
5. Returns the first valid numeric value found

## Limitations

- This scraper relies on Zillow's current HTML structure and may break if Zillow
  changes their site
- Zillow may rate-limit or block requests with CAPTCHA challenges
- Works best with valid, complete US addresses
- Only returns the current Zestimate (not historical data or price range)
