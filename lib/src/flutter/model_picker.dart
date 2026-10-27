import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../catalog/model_info.dart';
import '../omni_ai.dart';

/// Opens a searchable sheet of models and returns the picked one.
///
/// ```dart
/// final m = await showModelPicker(context, ai: ai, type: ModelType.image);
/// if (m != null) setState(() => imageModel = m.id);
/// ```
Future<ModelInfo?> showModelPicker(
  BuildContext context, {
  required OmniAI ai,
  ModelType type = ModelType.text,
  String? selected,
  String? provider,
}) =>
    showModalBottomSheet<ModelInfo>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: ModelPicker(
          ai: ai,
          type: type,
          selected: selected,
          provider: provider,
          onSelected: (m) => Navigator.of(context).pop(m),
        ),
      ),
    );

/// A searchable list of models with logos, prices, context sizes and
/// capability badges, filtered to one [type].
class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.ai,
    required this.onSelected,
    this.type = ModelType.text,
    this.selected,
    this.provider,
  });

  final OmniAI ai;
  final ModelType type;
  final String? selected;
  final String? provider;
  final ValueChanged<ModelInfo> onSelected;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  final _search = TextEditingController();
  String? _provider;
  bool _freeOnly = false;
  bool _toolsOnly = false;
  bool _visionOnly = false;

  @override
  void initState() {
    super.initState();
    _provider = widget.provider;
    widget.ai.catalog.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ModelInfo> _filtered() => widget.ai.catalog
      .search(_search.text, type: widget.type, provider: _provider)
      .where((m) => !_freeOnly || m.isFree)
      .where((m) => !_toolsOnly || m.toolCall)
      .where((m) => !_visionOnly || m.vision)
      .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.ai.catalog,
      builder: (context, _) {
        final catalog = widget.ai.catalog;
        final providers = {for (final m in catalog.ofType(widget.type)) m.provider}.toList()..sort();
        final models = _filtered();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search ${widget.type.label.toLowerCase()} models',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: catalog.loading
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: catalog.refresh),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _chip('All', _provider == null, () => setState(() => _provider = null)),
                  for (final p in providers) _chip(_providerName(p), _provider == p, () => setState(() => _provider = p)),
                  if (widget.type == ModelType.text) ...[
                    _chip('Free', _freeOnly, () => setState(() => _freeOnly = !_freeOnly)),
                    _chip('Tools', _toolsOnly, () => setState(() => _toolsOnly = !_toolsOnly)),
                    _chip('Vision', _visionOnly, () => setState(() => _visionOnly = !_visionOnly)),
                  ],
                ],
              ),
            ),
            if (catalog.errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(
                  catalog.errors.entries.map((e) => '${_providerName(e.key)}: ${e.value}').join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Expanded(
              child: models.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          catalog.loading ? 'Loading models…' : 'No models. Add an API key, or change the filters.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: models.length,
                      itemBuilder: (context, i) => ModelTile(
                        model: models[i],
                        selected: models[i].id == widget.selected,
                        onTap: () => widget.onSelected(models[i]),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  String _providerName(String id) => widget.ai.providers.where((p) => p.id == id).firstOrNull?.name ?? id;

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FilterChip(label: Text(label), selected: on, onSelected: (_) => onTap(), visualDensity: VisualDensity.compact),
      );
}

/// One model row: logo, name, lab, price, context and badges.
class ModelTile extends StatelessWidget {
  const ModelTile({super.key, required this.model, this.selected = false, this.onTap});
  final ModelInfo model;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final badges = <String>[
      if (model.reasoning) 'Thinks',
      if (model.toolCall) 'Tools',
      if (model.vision) 'Vision',
      if (model.audioIn) 'Hears',
      if (model.makesImages && model.types.contains(ModelType.text)) 'Images',
      if (model.openWeights) 'Open',
      if (model.loaded == true) 'Loaded',
    ];
    return ListTile(
      selected: selected,
      onTap: onTap,
      leading: ModelLogo(model: model),
      title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(model.id, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (badges.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final b in badges)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(b, style: small?.copyWith(color: theme.colorScheme.onSecondaryContainer, fontSize: 11)),
                    ),
                ],
              ),
            ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(model.priceLabel, style: theme.textTheme.labelMedium),
          if (model.contextWindow != null) Text(model.contextLabel, style: small),
        ],
      ),
      isThreeLine: badges.isNotEmpty,
    );
  }
}

/// The lab's logo (from models.dev), or its initial when offline.
class ModelLogo extends StatelessWidget {
  const ModelLogo({super.key, required this.model, this.size = 36});
  final ModelInfo model;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = Text((model.lab ?? model.provider).characters.first.toUpperCase(),
        style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(size / 4)),
      child: SvgPicture.network(
        model.logoUrl,
        width: size * 0.6,
        height: size * 0.6,
        colorFilter: ColorFilter.mode(scheme.onSurfaceVariant, BlendMode.srcIn),
        placeholderBuilder: (_) => initial,
        errorBuilder: (_, __, ___) => initial,
      ),
    );
  }
}
