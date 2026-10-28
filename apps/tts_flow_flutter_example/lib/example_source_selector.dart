import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ExampleTtsSource {
  sample('Bundled WAV'),
  mimo('MiMo'),
  gemini('Gemini'),
  edge('Edge (experimental)');

  const ExampleTtsSource(this.label);
  final String label;

  bool get needsApiKey => this == mimo || this == gemini;
  String get preferenceKey => 'tts_flow_example.${name}_api_key';
}

/// 示例专用配置；环境注入的密钥不写入本地，也不出现在诊断字符串中。
class ExampleSourceConfiguration {
  const ExampleSourceConfiguration(this.source, {this.apiKey = ''});
  final ExampleTtsSource source;
  final String apiKey;
}

class ExampleSourceSelector extends StatefulWidget {
  const ExampleSourceSelector({
    required this.builder,
    this.ttsSource = '',
    this.mimoApiKey = '',
    this.geminiApiKey = '',
    super.key,
  });

  final String ttsSource;
  final String mimoApiKey;
  final String geminiApiKey;
  final Widget Function(BuildContext, ExampleSourceConfiguration) builder;

  @override
  State<ExampleSourceSelector> createState() => _ExampleSourceSelectorState();
}

class _ExampleSourceSelectorState extends State<ExampleSourceSelector> {
  SharedPreferences? _preferences;
  ExampleSourceConfiguration? _configuration;
  var _changing = true;
  var _revision = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String _environmentKey(ExampleTtsSource source) => switch (source) {
    ExampleTtsSource.mimo => widget.mimoApiKey.trim(),
    ExampleTtsSource.gemini => widget.geminiApiKey.trim(),
    _ => '',
  };

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      _preferences = preferences;
      final requested = widget.ttsSource.trim().toLowerCase();
      final source = ExampleTtsSource.values
          .where((source) => source.name == requested)
          .firstOrNull;
      await _select(
        source ??
            (widget.mimoApiKey.trim().isNotEmpty
                ? ExampleTtsSource.mimo
                : ExampleTtsSource.sample),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _changing = false;
        _error = 'Unable to load local settings.';
      });
    }
  }

  Future<void> _select(ExampleTtsSource source, {bool editKey = false}) async {
    final preferences = _preferences;
    if (preferences == null) return;
    setState(() => _changing = true);
    var key = _environmentKey(source);
    if (source.needsApiKey && key.isEmpty) {
      key = preferences.getString(source.preferenceKey)?.trim() ?? '';
      if (key.isEmpty || editKey) {
        final entered = await showDialog<String>(
          context: context,
          builder: (_) => _ApiKeyDialog(
            source: source,
            preferences: preferences,
            initialValue: key,
          ),
        );
        if (!mounted) return;
        if (entered == null) {
          // 首次启动取消输入时仍可使用离线样本；切换取消则保留原来源。
          setState(() {
            _configuration ??= const ExampleSourceConfiguration(
              ExampleTtsSource.sample,
            );
            _changing = false;
          });
          return;
        }
        key = entered;
        if (key.isEmpty) {
          _apply(const ExampleSourceConfiguration(ExampleTtsSource.sample));
          return;
        }
      }
    }
    if (!mounted) return;
    _apply(ExampleSourceConfiguration(source, apiKey: key));
  }

  void _apply(ExampleSourceConfiguration configuration) {
    setState(() {
      _configuration = configuration;
      _revision++;
      _changing = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final configuration = _configuration;
    final source = configuration?.source;
    return Column(
      children: [
        Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    if (constraints.maxWidth >= 920) ...[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Speech playground',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Choose a voice. Bring your text to life.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 32),
                    ],
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<ExampleTtsSource>(
                              key: ValueKey(source),
                              initialValue: source,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'TTS source',
                                prefixIcon: Icon(Icons.hub_outlined, size: 20),
                              ),
                              items: ExampleTtsSource.values
                                  .map(
                                    (source) => DropdownMenuItem(
                                      value: source,
                                      child: Text(source.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _changing
                                  ? null
                                  : (source) {
                                      if (source != null &&
                                          source != configuration?.source) {
                                        _select(source);
                                      }
                                    },
                            ),
                          ),
                          if (source != null && source.needsApiKey) ...[
                            const SizedBox(width: 12),
                            if (constraints.maxWidth < 500)
                              IconButton.outlined(
                                tooltip: _environmentKey(source).isNotEmpty
                                    ? 'Key from environment'
                                    : 'API Key',
                                onPressed:
                                    _changing ||
                                        _environmentKey(source).isNotEmpty
                                    ? null
                                    : () => _select(source, editKey: true),
                                icon: Icon(
                                  _environmentKey(source).isNotEmpty
                                      ? Icons.lock_outline_rounded
                                      : Icons.key_rounded,
                                ),
                              )
                            else
                              TextButton.icon(
                                onPressed:
                                    _changing ||
                                        _environmentKey(source).isNotEmpty
                                    ? null
                                    : () => _select(source, editKey: true),
                                icon: const Icon(Icons.key),
                                label: Text(
                                  _environmentKey(source).isNotEmpty
                                      ? 'Key from environment'
                                      : 'API Key',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_error != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        if (_changing) const LinearProgressIndicator(),
        if (configuration != null)
          Expanded(
            child: KeyedSubtree(
              // 使用修订号，避免 Widget key 的诊断信息泄露 API Key。
              key: ValueKey(_revision),
              child: widget.builder(context, configuration),
            ),
          ),
      ],
    );
  }
}

class _ApiKeyDialog extends StatefulWidget {
  const _ApiKeyDialog({
    required this.source,
    required this.preferences,
    required this.initialValue,
  });

  final ExampleTtsSource source;
  final SharedPreferences preferences;
  final String initialValue;

  @override
  State<_ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<_ApiKeyDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save({bool clear = false}) async {
    final key = _controller.text.trim();
    if (!clear && key.isEmpty) {
      setState(() => _error = 'Please enter an API Key.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = clear
          ? await widget.preferences.remove(widget.source.preferenceKey)
          : await widget.preferences.setString(
              widget.source.preferenceKey,
              key,
            );
      if (!saved) throw StateError('Preference write failed');
      if (mounted) Navigator.pop(context, clear ? '' : key);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Unable to save the API Key locally. Please retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('${widget.source.label} API Key'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  errorText: _error,
                ),
                onSubmitted: (_) {
                  if (!_saving) _save();
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Saved locally in SharedPreferences without encryption. '
                'Use a development key on this device only.',
              ),
            ],
          ),
        ),
        actions: [
          if (widget.initialValue.isNotEmpty)
            TextButton(
              onPressed: _saving ? null : () => _save(clear: true),
              child: const Text('Delete saved key'),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
    );
  }
}
