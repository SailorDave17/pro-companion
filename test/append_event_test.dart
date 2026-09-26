import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion_core/store.dart' show EventStore, NewEvent;

import 'support/local_stack.dart';

/// #48: append_event met the way a phone meets it, through the local stack's API. What pgTAP cannot
/// show is the HTTP answer: a refusal is a 422 carrying its reason, and PostgREST commits the
/// refusal record under that error status rather than rolling it back. supabase/tests/
/// append_event_test.sql holds every reason and who can read the records. #49's test here sends an
/// event the core stamped with admit_device's own answer. These skip unless
/// PRO_COMPANION_LOCAL_STACK=1, which the CI job `local-stack` sets (README, Server side).
void main() {
  group('append_event against the local stack (#48)', () {
    late LocalStack stack;
    late String eventId;
    late Phone scorer;
    late Phone stranger;

    setUpAll(() async {
      stack = await LocalStack.connect();
      final day = await stack.raceDay();
      eventId = day.eventId;
      scorer = await stack.admittedPhone(day, 'scorer');
      stranger = await stack.phone();
    });

    Future<(int, Object?)> append(Phone phone, String canonical) => phone.send(
        'POST', '/rest/v1/rpc/append_event', body: {'p_event': eventId, 'p_canonical': canonical});

    String hashOf(String canonical) => sha256.convert(utf8.encode(canonical)).toString();

    test('criteria 1 and 5: an admitted phone\'s event is stored, and a re-send is a no-op', () async {
      final ulid = newUlid();
      final canonical = sampleEvent(ulid);

      final (status, body) = await append(scorer, canonical);
      expect(status, 200, reason: '$body');
      expect(body, {'outcome': 'accepted', 'duplicate': false, 'hash': hashOf(canonical)});
      expect(await stack.eventLogCanonical(ulid), canonical, reason: 'stored exactly as sent');

      final (resentStatus, resentBody) = await append(scorer, canonical);
      expect(resentStatus, 200, reason: '$resentBody');
      expect(resentBody, {'outcome': 'accepted', 'duplicate': true, 'hash': hashOf(canonical)});
      expect(await stack.refusals(eventId), everyElement(isNot(endsWith(hashOf(canonical)))),
          reason: 'a re-send is not a refusal');
    });

    test('criterion 6: a refusal is an HTTP 422 carrying its reason, and its record outlives the '
        'error status', () async {
      final ulid = newUlid();
      final canonical = sampleEvent(ulid).replaceFirst('"seq":1', '"seq":"three"');
      final before = await stack.refusals(eventId);

      final (status, body) = await append(scorer, canonical);
      // A 4xx is never retried, where a transient failure is a network error or a 5xx; and the code
      // is one no PostgREST error carries, so the phone keys on it (#6).
      expect(status, 422, reason: '$body');
      expect(body, {
        'outcome': 'refused',
        'reason': 'inconsistent_canonical',
        'hash': hashOf(canonical),
        'code': 'append_event_refused',
        'message': 'append_event refused the event: inconsistent_canonical',
        'details': 'inconsistent_canonical',
      });

      expect(await stack.refusals(eventId), [...before, 'inconsistent_canonical ${hashOf(canonical)}'],
          reason: 'PostgREST committed the record under the 422');
      expect(await stack.eventLogCanonical(ulid), isNull, reason: 'and the log is unchanged');
    });

    test('criterion 3: a phone holding no admission in the club is refused the same way, and its '
        'event is not kept (G43)', () async {
      final canonical = sampleEvent(newUlid());
      final before = await stack.refusals(eventId);

      final (status, body) = await append(stranger, canonical);
      expect(status, 422, reason: '$body');
      expect(body, allOf(containsPair('code', 'append_event_refused'),
          containsPair('details', 'not_admitted')));
      expect(await stack.refusals(eventId), before);
    });

    test("#49 criterion 1: admit_device's answer is the admission the core stamps, and the stamped text "
        'is stored exactly as the phone wrote it', () async {
      final dir = Directory.systemTemp.createTempSync('pc_49_');
      final store = EventStore.open('${dir.path}${Platform.pathSeparator}core.db');
      addTearDown(() {
        store.close();
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows can hold the WAL file briefly after close; not the test's concern.
        }
      });
      store.setAdmissionId(scorer.admissionId!);
      final event = store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Mark 2 hold'}));
      final canonical = store.readCanonical().single;
      expect((jsonDecode(canonical) as Map)['admission_id'], scorer.admissionId);

      // The id is the phone's own committee_device row, as the phone reads it back.
      final (rowStatus, rows) = await scorer.send('GET', '/rest/v1/committee_device', query: {'select': 'id'});
      expect(rowStatus, 200, reason: '$rows');
      expect(rows, [
        {'id': scorer.admissionId},
      ]);

      final (status, body) = await append(scorer, canonical);
      expect(status, 200, reason: '$body');
      expect(body, {'outcome': 'accepted', 'duplicate': false, 'hash': hashOf(canonical)});
      expect(await stack.eventLogCanonical(event.ulid), canonical, reason: 'stored exactly as the phone wrote it');
    });
  }, skip: localStackRequested ? false : localStackSkip);
}
