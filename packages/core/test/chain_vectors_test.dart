import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import '../tool/write_chain_vectors.dart' as writer;

/// #28 criterion 7: the verifier reads the committed chain vectors, which the
/// companion's shore verifier (#62) reuses and burgee vendors. Run from
/// packages/core, as CI's `dart test` step does.
const vectorDir = '../../fixtures/chain';
const manifestName = 'SHA256SUMS';
const vectorFormat = 'pro-companion-chain-vector/1';
final sumLine = RegExp(r'^([0-9a-f]{64})  (\S+)$');

/// The admission each vector device held (#49), written here rather than read
/// from the writer, so a writer that lost the admission cannot agree with
/// itself.
const admissionOf = {
  '01J8Z0D0000000000000000001': '00000000-0000-0000-0000-0000000000a1',
  '01J8Z0D0000000000000000002': '00000000-0000-0000-0000-0000000000b1',
};

String baseName(File f) => f.uri.pathSegments.last;

void main() {
  final files = Directory(vectorDir).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => baseName(a).compareTo(baseName(b)));
  final written = writer.vectorFiles();

  test('the set covers intact, gapped, broken and handoff chains', () {
    expect(files.map((f) => baseName(f).replaceAll('.json', '')).toSet(), {
      'intact', 'gapped-middle', 'gapped-start', 'broken-payload', 'broken-relinked', //
      'broken-relinked-start', 'broken-first-link', 'broken-fork', 'handoff',
    });
    expect(written.keys.toSet(), files.map(baseName).toSet(), reason: 'the writer writes exactly the committed set');
  });

  for (final file in files) {
    final vector = jsonDecode(file.readAsStringSync()) as Map;
    final events = [for (final e in vector['events'] as List) e as Map];
    final texts = [for (final e in events) e['canonical'] as String];

    group('${vector['name']}', () {
      test('is in the set format and names itself after its file', () {
        expect(vector['format'], vectorFormat);
        expect('${vector['name']}.json', baseName(file));
      });

      test('each recorded hash is the SHA-256 of its canonical text', () {
        for (final e in events) {
          expect(chainHash(e['canonical'] as String), e['hash']);
        }
      });

      test('each text is RFC 8785 canonical: serialising it again changes nothing', () {
        for (final text in texts) {
          expect(canonicalJson(jsonDecode(text)), text);
        }
      });

      test("each text is what the core writes for its event: read into an envelope and written back, it "
          'is unchanged', () {
        for (final text in texts) {
          expect(canonicalJson(EventEnvelope.fromWire(jsonDecode(text) as Map).toWire()), text);
        }
      });

      test("each event carries its device's admission id (#49)", () {
        for (final text in texts) {
          final wire = jsonDecode(text) as Map;
          expect(wire['admission_id'], admissionOf[wire['device_id']], reason: text);
        }
      });

      test('is exactly what tool/write_chain_vectors.dart writes today', () {
        expect(file.readAsStringSync().replaceAll('\r\n', '\n'), written[baseName(file)],
            reason: 'run: dart run tool/write_chain_vectors.dart (from packages/core), then update SHA256SUMS');
      });

      test('the verifier reaches the expected verdict for each device', () {
        final got = verifyChains(texts);
        final expected = vector['expected'] as Map;
        expect(got.keys.toSet(), expected.keys.toSet());
        expected.forEach((device, want) {
          want as Map;
          final verdict = got[device]!;
          expect(verdict.state.name, want['verdict'], reason: '$device: $verdict');
          expect(verdict.atSeq, want['at_seq'], reason: '$device: $verdict');
          expect(verdict.atUlid, want['at_ulid'], reason: '$device: $verdict');
          expect(verdict.afterSeq, want['after_seq'], reason: '$device: $verdict');
        });
      });
    });
  }

  test('SHA256SUMS lists every file in the set with its current hash', () {
    final listed = <String, String>{};
    for (final line in File('$vectorDir/$manifestName').readAsLinesSync()) {
      if (line.isEmpty) continue;
      final m = sumLine.firstMatch(line);
      expect(m, isNotNull, reason: 'not a sha256sum line: "$line"');
      listed[m!.group(2)!] = m.group(1)!;
    }
    final present =
        Directory(vectorDir).listSync().whereType<File>().map(baseName).where((n) => n != manifestName).toSet();
    expect(listed.keys.toSet(), present, reason: 'SHA256SUMS must list exactly the files here');
    listed.forEach((name, hash) {
      expect(sha256.convert(File('$vectorDir/$name').readAsBytesSync()).toString(), hash,
          reason: '$name changed without SHA256SUMS');
    });
  });

  test('the README states the direction and that verdicts are decided by hand', () {
    final readme = File('$vectorDir/README.md').readAsStringSync();
    expect(readme, contains('pro-companion is canonical'));
    expect(readme, contains('burgee vendors'));
    expect(readme, contains('never generated by the verifier'));
  });
}
