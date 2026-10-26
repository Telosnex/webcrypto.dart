// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'detected_runtime_stub.dart'
    if (dart.library.js_interop) 'detected_runtime_js_interop.dart';

export 'detected_runtime_stub.dart'
    if (dart.library.js_interop) 'detected_runtime_js_interop.dart'
    show detectedRuntime;

/// Return `null` instead of [value] on Firefox.
///
/// PKCS8 is not support for ECDH / ECDSA on firefox:
/// https://bugzilla.mozilla.org/show_bug.cgi?id=1133698
///
/// This utility helps filter away test cases and features known to not work on
/// Firefox and which has been documented in the API documentation.
T? nullOnFirefox<T>(T value) => detectedRuntime == 'firefox' ? null : value;

/// Return `null` instead of [value] on Safari.
///
/// This utility helps filter away test cases and features known to not work on
/// Safari and which has been documented in the API documentation.
T? nullOnSafari<T>(T value) => detectedRuntime == 'safari' ? null : value;

/// Removes, on Safari, the test cases that generate an RSA key with public
/// exponent 3; other browsers and the VM keep them.
///
/// Safari cannot generate such a key: `generateKey` throws `OperationError`.
/// WebKit's `CryptoKeyRSA::generatePair` (Source/WebCore/crypto/cocoa/
/// CryptoKeyRSACocoa.cpp) passes the exponent to CommonCrypto's
/// `CCRSACryptorGeneratePair` and turns any failure into `OperationError`.
/// CommonCrypto rejects e = 3, most likely because it follows FIPS 186-4
/// (B.3.1: e > 2^16), which rules out small exponents after the e = 3 attacks
/// on careless RSA use (Hastad's broadcast attack, cube roots of unpadded
/// messages, Bleichenbacher's 2006 signature forgery). CommonCrypto returns
/// only a status code, so the FIPS reason is inferred, not confirmed. OAEP and
/// PSS padding prevent those attacks, and Chrome and Firefox generate e = 3.
///
/// Safari does import and use e = 3 keys: the cases with keys generated on
/// Linux or Chrome pass, so only generation is skipped.
/// `test/crypto_subtle_test.dart` ("generateKeyPair: e3") checks that Safari
/// still rejects generation.
List<Map> withoutRsaE3GenerationOnSafari(List<Map> cases) {
  if (detectedRuntime != 'safari') return cases;
  return cases.where((c) {
    final params = c['generateKeyParams'];
    return !(params is Map && '${params['publicExponent']}' == '3');
  }).toList();
}
