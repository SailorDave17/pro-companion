// The host's half of a magic link on a device (#113 criterion 5), for integration_test/sync_flow.sh:
// reads the link the local stack mailed to an address, opens it one hop as the volunteer's browser
// would, and prints the app's sign-in address the redirect names. The script hands that address to
// the phone as the intent a tap on the link would send.
//
//   dart run integration_test/stack_link.dart <email>
//
// Not a test: a host tool, beside the device flow it serves.

import 'dart:io';

import '../test/support/local_stack.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run integration_test/stack_link.dart <email>');
    exitCode = 64;
    return;
  }
  final stack = await LocalStack.connect();
  final opened = await stack.openMailedLink(args.single, within: const Duration(seconds: 30));
  stdout.writeln(opened.redirect);
}
