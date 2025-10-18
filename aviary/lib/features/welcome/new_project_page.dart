import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:git/git.dart';

class NewProjectPage extends StatefulWidget {
  const NewProjectPage({super.key});

  @override
  State<NewProjectPage> createState() => _NewProjectPageState();
}

class _NewProjectPageState extends State<NewProjectPage> {
  final _nameController = TextEditingController();
  String? _forkUrl;
  String? _patchesUrl;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _isProjectConfigurationValid => _nameController.text.isNotEmpty && _forkUrl != null && _patchesUrl != null;

  void _onFlockUrlEntered(String url) {
    setState(() {
      _forkUrl = url;
    });
  }

  void _onFlockUrlInvalidated() {
    setState(() {
      _forkUrl = null;
    });
  }

  void _onPatchesUrlEntered(String url) {
    setState(() {
      _patchesUrl = url;
    });
  }

  void _onPatchesUrlInvalidated() {
    setState(() {
      _patchesUrl = null;
    });
  }

  void _submit() {
    if (!_isProjectConfigurationValid) {
      // Can't submit because the configuration is invalid.
      return;
    }

    // TODO: submit the chosen project
    // widget.onProjectConfigurationSubmitted(
    //   ProjectConfiguration(name: _nameController.text, forkGitUrl: _forkUrl!, patchesGitUrl: _patchesUrl!),
    // );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 0,
          children: [
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      icon: Icon(Icons.arrow_back),
                      iconSize: 14,
                      visualDensity: VisualDensity.compact,
                      onPressed: () {},
                    ),
                  ),
                ),
                _buildTitle("Your Nest Configuration"),
                Spacer(),
              ],
            ),
            const SizedBox(height: 48),
            _buildLabel("Fork Name"),
            _buildFinePrint(
              "What do you call your fork? This name will identify this nest in your recent projects list.",
            ),
            const SizedBox(height: 8),
            _TextField(controller: _nameController, hint: "Flock", validationStatus: ValidationStatus.unknown),
            const SizedBox(height: 48),
            _buildLabel("Fork Repository URL"),
            _buildFinePrint("Where is your Flutter fork (ex: Flock)?"),
            const SizedBox(height: 8),
            _GitRepoTextField(
              hint: "https://github.com/join-the-flock/flock",
              onValidUrlEntered: _onFlockUrlEntered,
              onInvalidUrlEntered: _onFlockUrlInvalidated,
            ),
            const SizedBox(height: 48),
            _buildLabel("Patches Repository URL"),
            _buildFinePrint("Where are the patch files with the changes you made to Flutter?"),
            const SizedBox(height: 8),
            _GitRepoTextField(
              hint: "https://github.com/join-the-flock/flock-patches",
              onValidUrlEntered: _onPatchesUrlEntered,
              onInvalidUrlEntered: _onPatchesUrlInvalidated,
            ),
            const SizedBox(height: 48),
            Center(
              child: _SubmitButton(isEnabled: _isProjectConfigurationValid, onPressed: _submit),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        text.toUpperCase(),
        textAlign: TextAlign.center,
        style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(text));
  }

  Widget _buildFinePrint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(text, style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 12)),
    );
  }
}

class _GitRepoTextField extends StatefulWidget {
  const _GitRepoTextField({required this.hint, required this.onValidUrlEntered, required this.onInvalidUrlEntered});

  final String hint;

  /// Callback invoked when the user enters a valid Git repository URL,
  /// perhaps by typing, or perhaps by pasting.
  final void Function(String url) onValidUrlEntered;

  /// Callback invoked when the user enters an invalid Git repository URL,
  /// or alters a valid URL to become invalid.
  final VoidCallback onInvalidUrlEntered;

  @override
  State<_GitRepoTextField> createState() => _GitRepoTextFieldState();
}

class _GitRepoTextFieldState extends State<_GitRepoTextField> {
  static const _checkUrlDelay = Duration(milliseconds: 1500);

  final _focusNode = FocusNode();
  final _controller = TextEditingController();
  var _validationStatus = ValidationStatus.unknown;
  String _previousUrl = "";
  Timer? _urlCheckTimer;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFieldFocusChange);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _pasteClipboardToTextField() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data == null || data.text == null || data.text!.isEmpty) {
      return;
    }
    if (!_controller.selection.isValid) {
      return;
    }

    final pasteText = data.text as String;

    var newText = _controller.text;
    final insertAt = _controller.selection.start;
    if (!_controller.selection.isCollapsed) {
      // Delete the selected text.
      newText = "${newText.substring(0, _controller.selection.start)}${newText.substring(_controller.selection.end)}";
    }
    newText = "${newText.substring(0, insertAt)}$pasteText${newText.substring(insertAt)}";

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertAt + pasteText.length),
    );

    _verifyUrl();
  }

  void _onFieldFocusChange() {
    if (!_focusNode.hasFocus) {
      _verifyUrl();
    }
  }

  void _onFieldValueChange() {
    _urlCheckTimer?.cancel();

    final uri = Uri.tryParse(_controller.text);
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      // This isn't even a valid URL, so it definitely isn't a git repo.
      return;
    }

    _urlCheckTimer = Timer(_checkUrlDelay, _verifyUrl);
  }

  Future<void> _verifyUrl() async {
    if (_previousUrl == _controller.text) {
      // The URL hasn't changed since the last time we checked.
      return;
    }

    setState(() {
      _validationStatus = ValidationStatus.validating;
      _previousUrl = _controller.text;
    });

    final url = _controller.text;
    if (url.isEmpty) {
      // Leave an empty field in a non-error state to avoid annoying users.
      setState(() {
        _validationStatus = ValidationStatus.unknown;
      });
      widget.onInvalidUrlEntered();
      return;
    }

    final isUrlValid = await _isValidGitRepository(url);
    if (!mounted) {
      return;
    }
    if (url != _controller.text) {
      // The URL changed while verifying. Fizzle.
      return;
    }

    setState(() {
      if (true == isUrlValid) {
        _validationStatus = ValidationStatus.valid;
        widget.onValidUrlEntered(_controller.text);
      } else {
        _validationStatus = ValidationStatus.invalid;
        widget.onInvalidUrlEntered();
      }
    });
  }

  /// Pins the given [url], assuming it's an accessible Git repository, returning
  /// `true` if it responds as a Git repository, `false` if it responds as something
  /// else, or `null` if something goes wrong and we don't know what's at the URL.
  Future<bool?> _isValidGitRepository(String url) async {
    try {
      final result = await runGit(['ls-remote', url], throwOnError: false);
      return result.exitCode == 0;
    } catch (exception) {
      // Ignore errors. We're not sure why this happened. We don't know if it's valid.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final LogicalKeySet pasteKeySet = Platform.isMacOS
        ? LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyV)
        : LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyV);

    return Shortcuts(
      // We re-implement the paste shortcut because Flutter won't let us override
      // the standard `PasteTextIntent` - it throws an error when we try. So we
      // emit our own custom `Intent`, which we implement with our own `Action`.
      shortcuts: <LogicalKeySet, Intent>{pasteKeySet: const _CustomPasteIntent()},
      child: Actions(
        actions: {
          // We handle pasting ourselves so that we can immediately try to verify
          // the URL, instead of waiting with a timer for a second or two.
          _CustomPasteIntent: CallbackAction<_CustomPasteIntent>(
            onInvoke: (intent) {
              _pasteClipboardToTextField();
              return null;
            },
          ),
        },
        child: _TextField(
          focusNode: _focusNode,
          controller: _controller,
          hint: widget.hint,
          validationStatus: _validationStatus,
          onChanged: _onFieldValueChange,
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    this.focusNode,
    required this.controller,
    required this.hint,
    required this.validationStatus,
    this.onChanged,
  });

  final FocusNode? focusNode;
  final TextEditingController controller;
  final String hint;
  final ValidationStatus validationStatus;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      focusNode: focusNode,
      controller: controller,
      style: TextStyle(fontSize: 14),
      cursorColor: Colors.purple,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
        border: OutlineInputBorder(
          borderSide: BorderSide(
            color: validationStatus == ValidationStatus.valid
                ? Colors.greenAccent
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: validationStatus == ValidationStatus.valid
                ? Colors.greenAccent
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.purpleAccent)),
        fillColor: Colors.black.withValues(alpha: 0.3),
        errorText: validationStatus == ValidationStatus.invalid ? "Bad URL/Can't Access URL" : null,
        suffixIcon: switch (validationStatus) {
          ValidationStatus.valid => Icon(Icons.check_circle, color: Colors.greenAccent),
          ValidationStatus.validating => IntrinsicWidth(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(padding: EdgeInsets.all(8), strokeAlign: -1, strokeWidth: 2),
              ),
            ),
          ),
          ValidationStatus.unknown => null,
          ValidationStatus.invalid => null,
        },
      ),
      onChanged: (_) => onChanged?.call(),
    );
  }
}

enum ValidationStatus { unknown, validating, valid, invalid }

class _CustomPasteIntent extends Intent {
  const _CustomPasteIntent();
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({this.isEnabled = true, required this.onPressed});

  final bool isEnabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(foregroundColor: Colors.greenAccent, backgroundColor: Colors.green.shade900),
      onPressed: isEnabled ? onPressed : null,
      child: Text("Fly to your Nest"),
    );
  }
}
