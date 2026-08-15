import 'package:flutter/material.dart';

void main() {
  runApp(const ProCompanionApp());
}

class ProCompanionApp extends StatelessWidget {
  const ProCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'PRO Companion',
      home: Scaffold(
        body: Center(
          child: Text('PRO Companion'),
        ),
      ),
    );
  }
}
