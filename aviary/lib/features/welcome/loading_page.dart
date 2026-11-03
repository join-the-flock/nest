import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      child: Center(child: CupertinoActivityIndicator(color: Colors.blueGrey)),
    );
  }
}
