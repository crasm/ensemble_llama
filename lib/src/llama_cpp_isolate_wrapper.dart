import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:ensemble_llama/ensemble_llama_cpp.dart';
import 'package:ensemble_llama/src/ensemble_llama_base.dart'
    show ModelParams, ContextParams, SamplingParams;

// 4294967295 (32 bit unsigned)
// -1 (32 bit signed)
const int32Max = 0xFFFFFFFF;

extension on llama_model_params {
  void setSimpleFrom(ModelParams p) {
    n_gpu_layers = p.gpuLayers;
    main_gpu = p.cudaMainGpu;
    // Skipping: tensor_split
    // Skipping: progress_callback{,_user_data}
    vocab_only = p.loadOnlyVocabSkipTensors;
    use_mmap = p.useMmap;
    use_mlock = p.useMlock;
  }
}

extension on llama_context_params {
  void setSimpleFrom(ContextParams p) {
    seed = p.seed;
    n_ctx = p.contextSizeTokens;
    n_batch = p.batchSizeTokens;

    rope_freq_base = p.ropeFreqBase;
    rope_freq_scale = p.ropeFreqScale;

    mul_mat_q = p.cudaUseMulMatQ;
    f16_kv = p.useFloat16KVCache;
    logits_all = p.computeAllLogits;
    embedding = p.embeddingModeOnly;
  }
}

class Model {
  final int _rawPointer;
  const Model._(this._rawPointer);
  Pointer<llama_model> get _ffiPointer =>
      Pointer.fromAddress(_rawPointer).cast<llama_model>();
  @override
  String toString() => "Model{$_rawPointer}";
}

class Context {
  final int _rawPointer;
  final Model model;
  final ContextParams params;
  const Context._(this._rawPointer, this.model, this.params);
  Pointer<llama_context> get _ffiPointer =>
      Pointer.fromAddress(_rawPointer).cast<llama_context>();
}

class Token {
  final int id;
  final String _str;
  const Token(this.id, this._str);

  factory Token.fromId(Context ctx, int id) => Token(
        id,
        libllama
            .llama_token_get_text(ctx._ffiPointer, id)
            .cast<Utf8>()
            .toDartString()
            .replaceAll("▁", " "), // replace U+2581 with a space
      );

  @override
  String toString() {
    return _str;
  }
}

class LogMessage {
  final int level;
  final String text;
  const LogMessage({
    required this.level,
    required this.text,
  });

  @override
  String toString() {
    String levelStr = switch (level) {
      ggml_log_level.GGML_LOG_LEVEL_ERROR => 'ERROR',
      ggml_log_level.GGML_LOG_LEVEL_WARN => 'WARN',
      ggml_log_level.GGML_LOG_LEVEL_INFO => 'INFO',
      _ => throw Exception("Unknown log level: $level"),
    };

    return "$levelStr: $text";
  }
}

sealed class ControlMessage {
  final id = Random().nextInt(int32Max);
  ControlMessage();
}

class ExitCtl extends ControlMessage {
  ExitResp done() => ExitResp(id);
}

class LoadModelCtl extends ControlMessage {
  final String path;
  final ModelParams params;
  LoadModelCtl(this.path, this.params);

  LoadModelResp done(Model model) => LoadModelResp(id, model: model);
  LoadModelResp error(Object err) => LoadModelResp(id, err: err);
  LoadModelProgressResp progress(double progress) =>
      LoadModelProgressResp(id, progress);
}

class FreeModelCtl extends ControlMessage {
  final Model model;
  FreeModelCtl(this.model);

  FreeModelResp done() => FreeModelResp(id);
}

class NewContextCtl extends ControlMessage {
  final Model model;
  final ContextParams params;
  NewContextCtl(this.model, this.params);

  NewContextResp done(Context ctx) => NewContextResp(id, ctx: ctx);
  NewContextResp error(Object err) => NewContextResp(id, err: err);
}

class FreeContextCtl extends ControlMessage {
  final Context ctx;
  FreeContextCtl(this.ctx);

  FreeContextResp done() => FreeContextResp(id);
}

class GenerateCtl extends ControlMessage {
  final Context ctx;
  final String prompt;
  final SamplingParams sparams;
  GenerateCtl(this.ctx, this.prompt, this.sparams);

  GenerateResp done() => GenerateResp(id);
  GenerateResp error(Object err) => GenerateResp(id, err: err);
  GenerateTokenResp token(Token tok) => GenerateTokenResp(id, tok);
}

sealed class ResponseMessage {
  final int id;
  final Object? err;
  const ResponseMessage(this.id, {this.err}) : assert(id <= int32Max);
  void throwIfErr() {
    if (err != null) {
      throw err!;
    }
  }
}

class HandshakeResp extends ResponseMessage {
  final SendPort controlPort;
  const HandshakeResp(this.controlPort, [super.id = 0]);
}

class ExitResp extends ResponseMessage {
  const ExitResp(super.id);
}

// TODO: include mem used, model details?
class LoadModelResp extends ResponseMessage {
  final Model? model;
  const LoadModelResp(super.id, {super.err, this.model});
}

class LoadModelProgressResp extends ResponseMessage {
  final double progress;
  const LoadModelProgressResp(super.id, this.progress);
}

class FreeModelResp extends ResponseMessage {
  const FreeModelResp(super.id);
}

class NewContextResp extends ResponseMessage {
  final Context? ctx;
  const NewContextResp(super.id, {super.err, this.ctx});
}

class FreeContextResp extends ResponseMessage {
  const FreeContextResp(super.id);
}

class GenerateResp extends ResponseMessage {
  const GenerateResp(super.id, {super.err});
}

class GenerateTokenResp extends ResponseMessage {
  final Token tok;
  const GenerateTokenResp(super.id, this.tok);
}

class EntryArgs {
  final SendPort log, response;
  const EntryArgs({required this.log, required this.response});
}

late final SendPort _log;
late final SendPort _response;

final ReceivePort _controlPort = ReceivePort();
final Stream<ControlMessage> _control = _controlPort.cast<ControlMessage>();

void init(EntryArgs args) {
  _log = args.log;
  _response = args.response;

  _control.listen(_onControl);
  _response.send(HandshakeResp(_controlPort.sendPort));

  libllama.llama_backend_init(false);
  libllama.llama_log_set(
    Pointer.fromFunction(_onLlamaLog),
    Pointer.fromAddress(0), // not used
  );
}

void _onLlamaLog(int level, Pointer<Char> text, Pointer<Void> userData) =>
    _log.send(LogMessage(
        level: level, text: text.cast<Utf8>().toDartString().trimRight()));

void _onModelLoadProgress(double progress, Pointer<Void> id) =>
    _response.send(LoadModelProgressResp(id.address, progress));

void _onControl(ControlMessage ctl) {
  switch (ctl) {
    case ExitCtl():
      _controlPort.close();
      libllama.llama_backend_free();
      _response.send(ctl.done());

    case LoadModelCtl():
      Pointer<Char>? pathStrC;
      try {
        final params = libllama.llama_model_default_params()
          ..setSimpleFrom(ctl.params);

        params.progress_callback = Pointer.fromFunction(_onModelLoadProgress);
        // use the pointer value itself to store ctl.id, so we don't need to malloc
        params.progress_callback_user_data = Pointer.fromAddress(ctl.id);

        pathStrC = ctl.path.toNativeUtf8(allocator: calloc).cast<Char>();
        final rawModel =
            libllama.llama_load_model_from_file(pathStrC, params).address;
        if (rawModel == 0) {
          _response
              .send(ctl.error(Exception("failed loading model: ${ctl.path}")));
          return;
        }

        _response.send(ctl.done(Model._(rawModel)));
      } on ArgumentError catch (e) {
        _response.send(ctl.error(e));
      } finally {
        if (pathStrC != null) calloc.free(pathStrC);
      }

    case FreeModelCtl():
      assert(ctl.model._rawPointer != 0);
      libllama.llama_free_model(ctl.model._ffiPointer);
      _response.send(ctl.done());

    case NewContextCtl():
      assert(ctl.model._rawPointer != 0);
      final params = libllama.llama_context_default_params()
        ..setSimpleFrom(ctl.params);

      final rawCtx = libllama
          .llama_new_context_with_model(ctl.model._ffiPointer, params)
          .address;
      if (rawCtx == 0) {
        _response.send(ctl.error(Exception("failed creating context")));
        return;
      }

      _response.send(ctl.done(Context._(rawCtx, ctl.model, ctl.params)));

    case FreeContextCtl():
      libllama.llama_free(ctl.ctx._ffiPointer);
      _response.send(ctl.done());

    case GenerateCtl():
      Set<Pointer> allocs = {};
      llama_batch? batch;
      try {
        final ctx = ctl.ctx;

        final Pointer<Char> promptStrC =
            ctl.prompt.toNativeUtf8(allocator: calloc).cast<Char>();
        allocs.add(promptStrC);

        final Pointer<Int32> tokenBuf = calloc
            .allocate(ctx.params.batchSizeTokens * sizeOf<Int32>())
            .cast<Int32>();
        allocs.add(tokenBuf);

        // Tokenize prompt
        int promptTokenCount = libllama.llama_tokenize(
          ctx.model._ffiPointer,
          promptStrC,
          ctl.prompt.length,
          tokenBuf,
          ctx.params.batchSizeTokens,
          true,
        );

        if (promptTokenCount < 0) {
          ctl.error(Exception("llama_tokenize failed with $promptTokenCount"));
          return;
        }

        // Evaluate initial prompt
        batch = libllama.llama_batch_init(ctx.params.batchSizeTokens, 0);
        batch.n_tokens = promptTokenCount;

        for (var i = 0; i < promptTokenCount; i++) {
          batch.token[i] = tokenBuf[i];
          batch.pos[i] = i;
          batch.seq_id[i] = 0;
          batch.logits[i] = 0; // = false;
        }

        batch.logits[batch.n_tokens - 1] = 1; // = true;

        final status = libllama.llama_decode(ctx._ffiPointer, batch);
        if (status != 0) {
          _response
              .send(ctl.error(Exception("llama_decode failed with $status")));
          return;
        }

        var nCur = batch.n_tokens;
        // var nDecode = 0;

        final nVocab = libllama.llama_n_vocab(ctx.model._ffiPointer);

        Pointer<llama_token_data> candidates =
            calloc.allocate(nVocab * sizeOf<llama_token_data>());
        allocs.add(candidates);
        Pointer<llama_token_data_array> candidatesWrapper =
            calloc.allocate(sizeOf<llama_token_data_array>());
        allocs.add(candidatesWrapper);

        candidatesWrapper.ref.data = candidates;
        candidatesWrapper.ref.size = nVocab;
        candidatesWrapper.ref.sorted = false;

        while (nCur <= ctx.params.batchSizeTokens) {
          final logits = libllama.llama_get_logits_ith(
              ctx._ffiPointer, batch.n_tokens - 1);

          for (var i = 0; i < nVocab; i++) {
            candidates[i].id = i;
            candidates[i].logit = logits[i];
            candidates[i].p = 0.0;
          }

          final mu = calloc.allocate(sizeOf<Float>()).cast<Float>();
          allocs.add(mu);
          final newTokenId = libllama.llama_sample_token_greedy(
              ctx._ffiPointer, candidatesWrapper);

          // Check if end of stream
          if (newTokenId == libllama.llama_token_eos(ctx._ffiPointer) ||
              nCur == ctx.params.batchSizeTokens) {
            _response.send(ctl.done());
            return;
          }

          _response.send(ctl.token(Token.fromId(ctx, newTokenId)));

          batch.n_tokens = 0;

          batch.token[batch.n_tokens] = newTokenId;
          batch.pos[batch.n_tokens] = nCur;
          batch.seq_id[batch.n_tokens] = 0;
          batch.logits[batch.n_tokens] = 1; // = true;

          batch.n_tokens += 1;
          // nDecode += 1;
          nCur += 1;

          final status = libllama.llama_decode(ctx._ffiPointer, batch);
          if (status != 0) {
            _response
                .send(ctl.error(Exception("llama_decode failed with $status")));
            return;
          }
        }
      } finally {
        for (final p in allocs) {
          calloc.free(p);
        }
        if (batch != null) libllama.llama_batch_free(batch);
      }
  }
}
