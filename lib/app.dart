import 'package:flutter/material.dart';

import 'ui/home.dart';

class CytestApp extends StatelessWidget {
  const CytestApp({super.key});

  static const _seed = Color(0xFF22B8CF);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cytest',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: _seed,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
