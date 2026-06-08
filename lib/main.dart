import 'package:flutter/material.dart';

void main() {
  runApp(const NarratorApp());
}

class NarratorApp extends StatelessWidget {
  const NarratorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Narrator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D5AFE),
          brightness: Brightness.dark,
        ),
      ),
      home: const Scaffold(
        body: Center(child: Text('Narrator')),
      ),
    );
  }
}
