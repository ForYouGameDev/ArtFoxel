import 'dart:async';

import 'package:flutter/material.dart';

class UnsavedWorkGuard extends StatefulWidget {
  const UnsavedWorkGuard({
    required this.hasUnsavedChanges,
    required this.child,
    super.key,
  });

  final bool hasUnsavedChanges;
  final Widget child;

  @override
  State<UnsavedWorkGuard> createState() => _UnsavedWorkGuardState();
}

class _UnsavedWorkGuardState extends State<UnsavedWorkGuard> {
  bool _allowPop = false;

  Future<void> _confirmExit() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this workspace?'),
        content: const Text('Your unsaved changes will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard changes'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.hasUnsavedChanges || _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.hasUnsavedChanges) unawaited(_confirmExit());
      },
      child: widget.child,
    );
  }
}
