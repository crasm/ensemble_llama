// ignore_for_file: avoid_catches_without_on_clauses

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

import 'package:ensemble_llama/llama_ffi.dart';
import 'package:ensemble_llama/src/llama.dart' show Token;
import 'package:ensemble_llama/src/message_control.dart';
import 'package:ensemble_llama/src/message_response.dart';
import 'package:ensemble_llama/src/samplers.dart';

import 'package:ensemble_llama/src/isolate_models.dart';
import 'package:ensemble_llama/src/isolate_param_extensions.dart';
import 'package:ensemble_llama/src/isolate_state.dart';

extension on ResponseMessage {
  void send() => _response.send(this);
}

/// Samples the next token randomly, using the probabilities in the given
/// [Candidates].
final class _DefaultLastSampler implements Sampler {
  const _DefaultLastSampler();
  @override
  Token? sample(Context ctx, Candidates cands, TokenBuf _) =>
      ctx.tokenFromId(llama_sample_token(ctx.pointer, cands.pointer));
}

final _log = Logger('LlamaCppIsolate');

late final SendPort _logPort;
late final SendPort _response;

final ReceivePort _controlPort = ReceivePort();
final Stream<ControlMessage> _control = _controlPort.cast<ControlMessage>();

void init(
    ({
      SendPort response,
      SendPort log,
      Level logLevel,
      bool disableGgmlLog,
    }) args) {
  _response = args.response;

  _logPort = args.log;
  Logger.root.level = args.logLevel;
  Logger.root.onRecord.listen(_logPort.send);

  _control.listen(_onControl);
  HandshakeResp(_controlPort.sendPort).send();

  llama_backend_init(false);
  if (!args.disableGgmlLog) {
    _log.info('llama.cpp logs enabled');
    llama_log_set(
      Pointer.fromFunction(_onLlamaLog),
      Pointer.fromAddress(0), // not used
    );
  } else {
    _log.info('llama.cpp logs disabled');
  }
}

void _onLlamaLog(int levelGgml, Pointer<Char> text, Pointer<Void> userData) {
  final level = switch (levelGgml) {
    ggml_log_level.GGML_LOG_LEVEL_ERROR => Level.SEVERE,
    ggml_log_level.GGML_LOG_LEVEL_WARN => Level.WARNING,
    ggml_log_level.GGML_LOG_LEVEL_INFO => Level.FINER,
    _ => throw Exception('Unknown log level: $levelGgml'),
  };

  _log.log(level, () => text.cast<Utf8>().toDartString().trimRight());
}

void _onModelLoadProgress(double progress, Pointer<Void> id) =>
    InitModelProgressResp(id.address, progress).send();

Future<void> _onControl(ControlMessage ctl) async {
  switch (ctl) {
    case ExitCtl():
      _exit(ctl);
    case InitModelCtl():
      _loadModel(ctl);
    case FreeModelCtl():
      _freeModel(ctl);
    case InitContextCtl():
      _newContext(ctl);
    case FreeContextCtl():
      _freeContext(ctl);
    case TokenizeCtl():
      _tokenize(ctl);
    case EditCtl():
      _edit(ctl);
    case IngestCtl():
      await _ingest(ctl);
    case GenerateCtl():
      await _generate(ctl);
  }
}

void _exit(ExitCtl ctl) {
  _controlPort.close();
  llama_backend_free();
  Isolate.exit(_response, ctl.done());
}

void _loadModel(InitModelCtl ctl) {
  Pointer<Char>? pathStrC;
  try {
    final params = llama_model_default_params()..setSimpleFrom(ctl.params);

    params.progress_callback = Pointer.fromFunction(_onModelLoadProgress);
    // use the pointer value itself to store ctl.id, so we don't need to malloc
    params.progress_callback_user_data = Pointer.fromAddress(ctl.id);

    pathStrC = ctl.path.toNativeUtf8(allocator: calloc).cast<Char>();
    final rawModel = llama_load_model_from_file(pathStrC, params).address;
    if (rawModel == 0) {
      ctl.error(Exception('failed loading model: ${ctl.path}')).send();
      return;
    }

    ctl.done(state.addModel(rawModel)).send();
  } catch (e) {
    ctl.error(e).send();
  } finally {
    if (pathStrC != null) calloc.free(pathStrC);
  }
}

void _freeModel(FreeModelCtl ctl) {
  try {
    final model = state.removeModel(ctl.model);
    final ctxs = state.contextsForModel[ctl.model];
    if (ctxs != null && ctxs.isNotEmpty) {
      throw StateError('${ctxs.length} contexts are still active for this model');
    }

    llama_free_model(model.pointer);
    // nothing to dispose... yet

    ctl.done().send();
  } catch (e) {
    ctl.error(e).send();
  }
}

void _newContext(InitContextCtl ctl) {
  try {
    final params = llama_context_default_params()..setSimpleFrom(ctl.params);
    final model = state.getModel(ctl.model);
    final rawCtx = llama_new_context_with_model(model.pointer, params).address;
    if (rawCtx == 0) throw Exception('failed creating context');

    ctl.done(state.addContext(rawCtx, model, ctl.params)).send();
  } catch (e) {
    ctl.error(e).send();
  }
}

void _freeContext(FreeContextCtl ctl) {
  try {
    final ctx = state.removeContext(ctl.ctx);
    if (!state.models.containsKey(ctx.model.id)) {
      throw StateError('found ${ctl.ctx}, but missing ${ctx.model}');
    }

    final ctxSet = state.contextsForModel[ctx.model.id];
    if (ctxSet == null || !ctxSet.remove(ctl.ctx)) {
      throw StateError('found ${ctl.ctx}, but not associated with a model');
    }

    llama_free(ctx.pointer);
    ctx.dispose();

    ctl.done().send();
  } catch (e) {
    ctl.error(e).send();
  }
}

void _tokenize(TokenizeCtl ctl) {
  try {
    final ctx = state.getContext(ctl.ctx);
    final numToks = ctx.tokens.addFromString(ctx, ctl.text);
    ctl
        .done(
          ctx.tokens.toList(ctx, numToks),
          ctx.tokens.length - numToks,
        )
        .send();
  } catch (e) {
    ctl.error(e).send();
  }
}

void _edit(EditCtl ctl) {
  try {
    () {
      final ctx = state.getContext(ctl.ctx);
      final newLen = ctl.length;
      if (newLen == null) return;
      if (ctx.tokens.length == newLen) {
        _log.info(() => 'length unchanged');
        return;
      }

      _log.info(() => 'token buffer length changed from ${ctx.tokens.length} to $newLen');
      ctx.tokens.length = newLen;
      if (ctx.logits.length > newLen) {
        _log.info(() =>
            'discarding logits and llama_kv_cache for last last ${ctx.logits.length - newLen} tokens of context window');
        ctx.logits.length = newLen;
        llama_kv_cache_seq_rm(ctx.pointer, 1, newLen, -1); // seq_id = 1 for everything
      }
    }();
    ctl.done().send();
  } catch (e) {
    ctl.error(e).send();
  }
}

Future<void> _ingest(IngestCtl ctl) async {
  final handle = ReceivePort();
  try {
    var mustCancel = false;
    handle.listen((_) => mustCancel = true);
    ctl.handshake(handle.sendPort).send();

    // Evaluate prompt.
    //
    // To do so, we fill up a llama_batch with tokens, call llama_decode()
    // to load those tokens into the model, and repeat until we run out of
    // prompt tokens.

    final ctx = state.getContext(ctl.ctx);
    final batch = ctx.batch;
    final tokens = ctx.tokens;
    final batchSize = ctx.params.batchSizeTokens;

    int i; // index of the next token to be decoded
    var j = 0; // start batch at zero tokens on every _ingest()
    while ((i = ctx.logits.length) + j < tokens.length) {
      final tokensToDecode = tokens.length - i;
      final isLastBatch = tokensToDecode <= batchSize;
      final fillCount = isLastBatch ? tokensToDecode : batchSize;

      batch.n_tokens = fillCount;
      for (j = 0; j < fillCount; j++) {
        batch.token[j] = tokens[i + j];
        batch.pos[j] = i + j; // is just j sufficient? small numbers anyhow
        batch.n_seq_id[j] = 1;
        batch.seq_id[j][0] = 1;
        // We enable computeAllLogits for every new context, so this should be
        // unnecessary
        // batch.logits[j] = 1;
      }

      // ignore: inference_failure_on_instance_creation
      await Future.delayed(Duration.zero);
      if (mustCancel) return;
      final status = llama_decode(ctx.pointer, batch);
      if (status != 0) {
        throw Exception('llama_decode failed with $status');
      }
      ctx.logits.add(llama_get_logits(ctx.pointer), batch.n_tokens);

      assert(j <= batchSize);
      if (j == batchSize) j = 0;
    }

    ctl.done().send();
  } catch (e) {
    ctl.error(e).send();
  } finally {
    handle.close();
  }
}

Future<void> _generate(GenerateCtl ctl) async {
  final handle = ReceivePort();
  try {
    var mustCancel = false;
    handle.listen((_) => mustCancel = true);
    ctl.handshake(handle.sendPort).send();

    final ctx = state.getContext(ctl.ctx);
    final contextSize = ctx.params.contextSizeTokens;

    final candidates = ctx.candidates;
    final tokens = ctx.tokens;

    for (final s in ctl.samplers) {
      if (s is NativeMemoryUser) (s as NativeMemoryUser).alloc();
    }

    if (ctx.needsIngesting) {
      throw StateError('context tokens need to be ingested or removed before generation can begin');
    }

    //
    // Generate tokens to fill context
    //

    while (ctx.logits.length < contextSize) {
      candidates.load(ctx.logits.last);

      // Apply each sampler in turn. If we receive a token back, it should
      // be the last sampler. If there are samplers remaining and we already
      // have a token, it is an error.
      Token? tok;
      final samplerCount = ctl.samplers.length;
      for (var i = 0; i < samplerCount; i++) {
        final samp = ctl.samplers[i];
        tok = samp.sample(ctx, candidates, tokens);

        if (tok != null) {
          if (samplerCount > i + 1) {
            final unused = ctl.samplers.skip(i + 1).toList(growable: false);
            final buf = StringBuffer()..writeAll(unused);
            throw ArgumentError.value(unused,
                'Unexpected token from $samp. Unable to process these additional samplers: $buf');
          }

          break;
        }
      }

      tok ??= const _DefaultLastSampler().sample(ctx, candidates, tokens);

      // Yield to this isolate's event loop
      // TODO(crasm): this might cause problems if another _onControl(GenerateCtl)
      // comes in for this context. In that case, we'd have to have some sort
      // of mutex check where that request should yield until this one finishes.
      // ignore: inference_failure_on_instance_creation
      await Future.delayed(Duration.zero);
      if (mustCancel) return;

      tokens.add(tok!.id);
      ctl.token(tok).send();

      // Check if end of stream
      if (tok.id == llama_token_eos(ctx.model.pointer)) {
        break;
      }

      //
      // Decode next token
      //

      final batch = ctx.batch;
      batch.n_tokens = 1;

      batch.token[0] = tok.id;
      batch.pos[0] = ctx.logits.length;
      batch.n_seq_id[0] = 1;
      batch.seq_id[0][0] = 1;
      // We enable computeAllLogits for every new context, so this should be
      // unnecessary
      // batch.logits[0] = 1;

      final status = llama_decode(ctx.pointer, batch);
      if (status != 0) {
        throw Exception('llama_decode failed with $status');
      }

      ctx.logits.add(llama_get_logits(ctx.pointer), batch.n_tokens);
    }

    ctl.done().send();
  } catch (e) {
    ctl.error(e).send();
  } finally {
    for (final s in ctl.samplers) {
      if (s is NativeMemoryUser) (s as NativeMemoryUser).free();
    }

    handle.close();
  }
}