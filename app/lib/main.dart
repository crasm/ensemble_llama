// ignore_for_file: prefer_const_literals_to_create_immutables, prefer_const_constructors
// TODO: delete ^^^

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:ensemble_protos/llamacpp.dart' as pb;
import 'package:grpc/grpc.dart';
import 'package:logging/logging.dart';
import 'package:state_machine/state_machine.dart' as sm;

Logger _log = Logger('main.dart');

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: '
        '${record.loggerName}: '
        '${record.message}');
  });

  runApp(const EnsembleApp());
}

class EnsembleApp extends StatelessWidget {
  const EnsembleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ensemble',
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.lightBlue,
            brightness: Brightness.light,
          )),
      home: Home(),
    );
  }
}

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.color.primary,
        foregroundColor: context.color.onPrimary,
        title: Text('Ensemble'),
        actions: [
          PopupMenuButton(
            itemBuilder: (context) {
              return [
                PopupMenuItem(child: Text('Settings')),
              ];
            },
          )
        ],
      ),
      body: PageView(children: [
        CompletionsPage(),
        CompletionsPage(),
      ]),
    );
  }
}

class CompletionsPage extends StatefulWidget {
  const CompletionsPage({super.key});
  @override
  State<StatefulWidget> createState() => _CompletionsPageState();
}

class _CompletionsPageState extends State<CompletionsPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final sm.StateMachine _state;
  late final sm.State _isViewing, _isEditing, _isPreparing, _isGenerating;
  late final sm.StateTransition _doPrepare, _doGenerate, _doStopGenerating;

  final ScrollController _scrollCtl = ScrollController();

  late final ClientChannel _channel;
  late final pb.LlamaCppClient _client;

  late final Future<int> _ctx;

  ResponseStream<pb.Token>? _resp;

  final TextEditingController _textCtl = TextEditingController();
  List<pb.Token> _decodedTokens = [];

  @override
  void initState() {
    super.initState();

    _state = sm.StateMachine('gen page state');

    _isViewing = _state.newState('viewing');
    _isEditing = _state.newState('editing');
    _isPreparing = _state.newState('preparing');
    _isGenerating = _state.newState('generating');

    _doPrepare = _state.newStateTransition(
      'prepare',
      [_isViewing, _isEditing],
      _isPreparing,
    )..listen((_) {
        _onPrepare();
        setState(() {});
      });

    _doGenerate = _state.newStateTransition(
      'generate',
      [_isPreparing],
      _isGenerating,
    )..listen((_) {
        _onGenerate();
        setState(() {});
      });

    _doStopGenerating = _state.newStateTransition(
      'stop generating',
      [_isPreparing, _isGenerating],
      _isViewing,
    )..listen((_) {
        _onStop();
        setState(() {});
      });

    _state.start(_isViewing);

    _channel = ClientChannel(
      'brick',
      port: 8888,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    _client = pb.LlamaCppClient(_channel);

    _textCtl.text = 'A chat.\nUSER: ';

    _ctx = () async {
      final resp = await _client.newContext(
        pb.NewContextArgs(
          nCtx: 8192,
          ropeScalingType: 1,
          ropeFreqScale: 0.50,
        ),
      );

      assert(resp.hasCtx());
      return resp.ctx;
    }();
  }

  @override
  void dispose() {
    super.dispose();
    _textCtl.dispose();
    _scrollCtl.dispose();
    _channel.shutdown();
    // TODO(crasm): how and when to free context?
  }

  String _contextString() {
    StringBuffer buf = StringBuffer();
    _decodedTokens.forEach((tok) => buf.write(tok.text));
    return buf.toString();
  }

  String _runesToString(Iterable<int> runes) {
    final buf = StringBuffer();
    runes.forEach(buf.writeCharCode);
    return buf.toString();
  }

  Future<void> _onPrepare() async {
    // TODO(crasm): should trimming be a configurable option?
    final buf = _textCtl.text.trimRight();
    final ctx = await _ctx;

    //
    // Figure out if we need to trim the context, and how much text to add
    var i = 0; // token index
    var j = 0; // rune index
    if (_decodedTokens.isNotEmpty) {
      final bufRunes = buf.runes.toList(growable: false);
      while (i < _decodedTokens.length) {
        final tokRunes = _decodedTokens[i].text.runes.toList(growable: false);

        if (j + tokRunes.length <= bufRunes.length) {
          final bufTokMatch = bufRunes.sublist(j, j + tokRunes.length);
          if (listEquals(tokRunes, bufTokMatch)) {
            // The text is unchanged, so we can skip decoding this token again.
            i++;
            j += tokRunes.length;
            continue;
          } else {
            _log.fine('First token that has changed:'
                ' `${_runesToString(tokRunes)}`'
                ' != `${_runesToString(bufTokMatch)}`');
          }
        }

        break;
      }
    }

    _log.info('Trimming context window to $i tokens');
    _decodedTokens.length = i;
    await _client.trim(pb.TrimArgs(ctx: ctx, length: i));

    //
    // Add needed text, and decode
    _log.info('Adding and tokenizing ${buf.runes.length - j} runes');
    final addedTokens = await _client.addText(pb.AddTextArgs(
      ctx: ctx,
      text: _runesToString(buf.runes.skip(j)),
    ));
    _log.info('Added ${addedTokens.toks.length} tokens');
    _decodedTokens.addAll(addedTokens.toks);

    _log.info('Ingesting context');
    await for (final progress in _client.ingest(pb.IngestArgs(ctx: ctx))) {
      _log.info('Ingesting progress: ${progress.done}/${progress.total} '
          '(batch size: ${progress.batchSize})');
    }

    _doGenerate();
  }

  /// Generates new tokens
  Future<void> _onGenerate() async {
    _log.info('Generating started');
    _resp = _client.generate(pb.GenerateArgs(ctx: await _ctx))
      ..listen(
        (tok) {
          if (tok.hasText()) {
            _decodedTokens.add(tok);
            _textCtl.text = _contextString();
            setState(() {/* Added a generated token */});
          }
        },
        onDone: () {
          _log.fine('Generating done');
          _doStopGenerating();
        },
        onError: (e) {
          // This is commonly triggered when the call is canceled client-side.
          if (_isGenerating()) _doStopGenerating();
          switch (e.code) {
            case StatusCode.cancelled:
              _log.info('Generating was cancelled');
              _log.finest(e);
            default:
              _log.severe(e);
          }
        },
        cancelOnError: true,
      );
  }

  Future<void> _onStop() async {
    await _resp?.cancel();
  }

  // Reasonable defaults (but should be updated immediately)
  bool _isHeightInitialized = false;
  double _maxHeight = 600.0;
  double _divTop = 400.0;
  final _divThickness = 32.0;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: LayoutBuilder(builder: (context, box) {
        if (!_isHeightInitialized) {
          _isHeightInitialized = true;
          _maxHeight = box.maxHeight;
          _divTop = box.maxHeight / 3.0 * 2.0;
        }

        return Stack(
          children: [
            Positioned(
                top: 0,
                height: _divTop,
                left: 0,
                right: 0,
                child: _genArea(context)),
            Positioned(
                top: _divTop + _divThickness,
                bottom: 0,
                left: 0,
                right: 0,
                child: _params(context)),
            Positioned(
                top: _divTop,
                left: 0,
                right: 0,
                height: _divThickness,
                child: _divBar(context)),
          ],
        );
      }),
    );
  }

  final FocusNode _genFocusNode = FocusNode();

  Widget _genArea(BuildContext ctx) {
    const style = TextStyle(
      fontFamily: 'monospace',
      inherit: false,
      color: Colors.black,
      fontWeight: FontWeight.normal,
      wordSpacing: 0.8,
      letterSpacing: 0.0,
      fontSize: 14.0,
      height: 1.3,
      leadingDistribution: null,
      textBaseline: TextBaseline.alphabetic,
    );

    return LayoutBuilder(builder: (context, box) {
      const topPadding = 12.0;
      const horizontalPadding = 12.0;

      final genText = TextSpan(text: _textCtl.text, style: style);
      final painter =
          TextPainter(text: genText, textDirection: TextDirection.ltr);

      painter.layout(maxWidth: box.maxWidth - 2 * horizontalPadding);
      final textHeightPadded = painter.height + topPadding;
      painter.dispose();

      final mustScroll = textHeightPadded > _divTop / 2;

      final mainColumn = Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: topPadding),
            GestureDetector(
              onTap: _doStopGenerating,
              child: _isGenerating()
                  ? Text(_contextString(), style: style)
                  : TextField(
                      focusNode: _genFocusNode,
                      controller: _textCtl,
                      style: style,
                      maxLines: null,
                      decoration: null,
                    ),
            ),
            SizedBox(
              height: mustScroll ? _divTop / 2 : _divTop - textHeightPadded,
              child: GestureDetector(onTap: () {
                if (_isGenerating()) {
                  _doStopGenerating();
                } else {
                  _focusGenTail();
                }
              }),
            ),
          ],
        ),
      );

      return mustScroll
          ? SingleChildScrollView(controller: _scrollCtl, child: mainColumn)
          : mainColumn;
    });
  }

  void _focusGenTail() {
    if (!_genFocusNode.hasPrimaryFocus) {
      _genFocusNode.requestFocus();
      _textCtl.selection = TextSelection.fromPosition(
          TextPosition(offset: _textCtl.text.length));
    } else {
      _genFocusNode.unfocus();
    }
  }

  Widget _params(BuildContext context) {
    return Container(
      color: context.color.surfaceVariant,
      padding: EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Expanded(
            child: ReorderableListView(
              onReorder: (oldIndex, newIndex) {},
              children: ['Temperature', 'Top K', 'Top P', 'Min P'].map((p) {
                return ListTile(key: Key(p), title: Text(p));
              }).toList(),
            ),
          ),
          Column(children: [
            IconButton.filled(
              onPressed: () {
                if (_isPreparing()) return;
                if (_isGenerating()) {
                  _doStopGenerating();
                } else {
                  _doPrepare();
                }
              },
              iconSize: 48,
              icon: Icon(_isPreparing() || _isGenerating()
                  ? Icons.pause
                  : Icons.play_arrow),
            ),
            Container(),
          ]),
        ],
      ),
    );
  }

  Widget _divBar(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        setState(() {
          _divTop = (_divTop + details.delta.dy)
              .clamp(0.0, _maxHeight - _divThickness);
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: context.color.surfaceVariant,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20.0),
            topRight: Radius.circular(20.0),
          ),
        ),
        child: Icon(Icons.drag_handle, color: context.color.onSurfaceVariant),
      ),
    );
  }
}

extension on BuildContext {
  ColorScheme get color => Theme.of(this).colorScheme;
}
