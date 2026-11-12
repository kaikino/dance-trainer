import 'package:flutter/material.dart';

import '../ble/node_client.dart';
import '../ble/protocol.dart';
import '../store/settings.dart';
import '../ui/feet_diagram.dart';
import '../ui/style.dart';

/// "How to wear": three cards on putting the nodes on, telling them apart,
/// and what calibration is for. Opens by itself on the first run, and from
/// Home any time after.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.manager});
  final NodeManager manager;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pages = 3;
  final _pager = PageController();
  int _page = 0;
  bool _scanning = false;
  Role? _buzzing;

  NodeManager get m => widget.manager;

  @override
  void initState() {
    super.initState();
    m.addListener(_onNodes);
  }

  @override
  void dispose() {
    m.removeListener(_onNodes);
    _pager.dispose();
    super.dispose();
  }

  void _onNodes() {
    if (mounted) setState(() {});
  }

  Future<void> _done() async {
    AppSettings.onboardingSeen = true;
    AppSettings.save().catchError((_) {});
    if (mounted) Navigator.pop(context);
  }

  void _go(int page) =>
      _pager.animateToPage(page, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      await m.scanAndConnect();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is BleUnavailable ? e.message : '$e')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _buzz(NodeClient n) async {
    setState(() => _buzzing = n.role);
    try {
      await n.buzzTest(Haptic.double);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted && _buzzing == n.role) setState(() => _buzzing = null);
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _pages - 1;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // Leaving with Back counts as seen too.
        if (didPop) {
          AppSettings.onboardingSeen = true;
          AppSettings.save().catchError((_) {});
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('How to wear'),
          actions: [
            if (!last) TextButton(onPressed: _done, child: const Text('Skip')),
            const SizedBox(width: Space.sm),
          ],
        ),
        body: PageView(
          controller: _pager,
          onPageChanged: (p) => setState(() => _page = p),
          children: [_wear(context), _whichIsWhich(context), _calibration(context)],
        ),
        bottomNavigationBar: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: ContentWidth(
            maxWidth: 900,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    height: Sizes.button,
                    child: _page == 0
                        ? null
                        : TextButton.icon(
                            onPressed: () => _go(_page - 1),
                            icon: const Icon(Icons.arrow_back_rounded),
                            label: const Text('Back'),
                          ),
                  ),
                  Expanded(child: _Dots(count: _pages, index: _page)),
                  SizedBox(
                    width: 140,
                    height: Sizes.button,
                    child: FilledButton(
                      onPressed: last ? _done : () => _go(_page + 1),
                      child: Text(last ? 'Got it' : 'Next'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wear(BuildContext context) => const _Card(
        step: 1,
        title: 'Put the nodes on',
        picture: FeetDiagram(showNodes: true, height: double.infinity),
        points: [
          (Icons.swap_horiz_rounded, 'The node marked L goes on your left ankle, R on your right.'),
          (Icons.straighten_rounded, 'Long side along your foot, with the USB-C port toward your toes.'),
          (Icons.lock_outline_rounded, 'Strap it snug, so it does not turn when you kick.'),
        ],
      );

  Widget _whichIsWhich(BuildContext context) {
    final theme = Theme.of(context);
    final connected = m.connectedNodes;
    return _Card(
      step: 2,
      title: 'Check which is which',
      picture: FeetDiagram(showNodes: true, active: _buzzing, buzzing: _buzzing, height: double.infinity),
      points: const [
        (Icons.vibration_rounded, 'Tap Buzz: the node on that ankle should vibrate.'),
        (Icons.swap_horiz_rounded, 'If the other one buzzes, swap the two nodes over.'),
      ],
      footer: connected.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Switch both nodes on, then scan for them.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: Space.md),
                SizedBox(
                  height: Sizes.button,
                  child: FilledButton.tonalIcon(
                    onPressed: _scanning ? null : _scan,
                    icon: _scanning
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.bluetooth_searching_rounded),
                    label: Text(_scanning ? 'Scanning…' : 'Scan for nodes'),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                for (final r in Role.values) ...[
                  if (r == Role.right) const SizedBox(width: Space.md),
                  Expanded(
                    child: SizedBox(
                      height: Sizes.button,
                      child: FilledButton.tonalIcon(
                        onPressed: m.nodes.firstWhere((n) => n.role == r).connected
                            ? () => _buzz(m.nodes.firstWhere((n) => n.role == r))
                            : null,
                        icon: const Icon(Icons.vibration_rounded),
                        label: Text('Buzz ${footName(r).toLowerCase()}'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _calibration(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Card(
      step: 3,
      title: 'Calibrate each foot',
      picture: const FeetDiagram(showStance: true, height: double.infinity),
      points: const [
        (
          Icons.explore_rounded,
          'Calibration tells each node which way your toes point, so a forward step is judged as forward.'
        ),
        (Icons.north_rounded, 'You slide each foot forward three times. It takes about a minute.'),
      ],
      footer: Container(
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: Radii.mdAll),
        child: Row(
          children: [
            Icon(Icons.accessibility_new_rounded, color: scheme.onTertiaryContainer, size: 32),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(stanceInstruction,
                  style: theme.textTheme.titleMedium?.copyWith(color: scheme.onTertiaryContainer, height: 1.35)),
            ),
          ],
        ),
      ),
    );
  }
}

/// One card: a picture, a title and a few short points, side by side in
/// landscape and stacked in portrait.
class _Card extends StatelessWidget {
  const _Card({required this.step, required this.title, required this.picture, required this.points, this.footer});
  final int step;
  final String title;
  final Widget picture;
  final List<(IconData, String)> points;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('STEP $step OF 3', style: theme.textTheme.overline.copyWith(color: scheme.primary)),
        const SizedBox(height: Space.sm),
        Text(title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: Space.lg),
        for (final (icon, line) in points)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: scheme.secondaryContainer, shape: BoxShape.circle),
                  child: Icon(icon, size: 20, color: scheme.onSecondaryContainer),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(line, style: theme.textTheme.titleMedium?.copyWith(height: 1.35)),
                  ),
                ),
              ],
            ),
          ),
        if (footer != null) ...[const SizedBox(height: Space.sm), footer!],
      ],
    );
    Widget art(double height) => Container(
          height: height,
          padding: const EdgeInsets.symmetric(vertical: Space.xl, horizontal: Space.md),
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: Radii.lgAll),
          child: picture,
        );
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > 760 && c.maxWidth > c.maxHeight;
      const pad = EdgeInsets.fromLTRB(Space.xl, Space.lg, Space.xl, Space.xl);
      return SingleChildScrollView(
        padding: pad,
        child: ConstrainedBox(
          // Centred in the height on a tablet; scrolls when it does not fit.
          constraints: BoxConstraints(minHeight: wide ? c.maxHeight - pad.vertical : 0),
          child: Center(
            child: ContentWidth(
              maxWidth: wide ? 1100 : 560,
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(flex: 5, child: art((c.maxHeight - 80).clamp(260.0, 460.0))),
                        const SizedBox(width: 48),
                        Expanded(flex: 6, child: text),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [art(300), const SizedBox(height: Space.xl), text],
                    ),
            ),
          ),
        ),
      );
    });
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count, index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Card ${index + 1} of $count',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: Space.xs),
              width: i == index ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == index ? scheme.primary : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
