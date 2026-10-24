/// Runs before each native build of the kiln release workflow. BoringSSL
/// needs NASM for its x86 assembly on Windows; the runner images have none.
/// This installs the pinned NASM and adds it to the toolchain description.
library;

import 'dart:io';

const _version = '2.16.03';
const _sha256 =
    '3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6';

Future<void> main() async {
  final target = Platform.environment['TARGET'] ?? '';
  if (!target.startsWith('windows-')) return;

  final temp = Platform.environment['RUNNER_TEMP']!;
  final zip = '$temp/nasm.zip';
  await _run('curl', [
    '-sSfLo',
    zip,
    'https://www.nasm.us/pub/nasm/releasebuilds/$_version/win64/'
        'nasm-$_version-win64.zip',
  ]);
  final sum = await Process.run('sha256sum', [zip]);
  if ('${sum.stdout}'.split(' ').first != _sha256) {
    stderr.writeln('NASM: SHA-256 mismatch: ${sum.stdout}');
    exit(1);
  }
  await _run('unzip', ['-q', zip, '-d', temp]);

  File(
    Platform.environment['GITHUB_PATH']!,
  ).writeAsStringSync('$temp/nasm-$_version\n', mode: FileMode.append);
  File(Platform.environment['GITHUB_ENV']!).writeAsStringSync(
    'KILN_TOOLCHAIN_EXTRA=NASM $_version\n',
    mode: FileMode.append,
  );
}

Future<void> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    stderr.writeln('$executable failed:\n${result.stderr}');
    exit(result.exitCode);
  }
}
