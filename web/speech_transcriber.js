(function () {
  const modelBase =
    'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/d42f2d9f7ca24806fb667456a18a9f1b60f70d16/';
  const modelFiles = [
    ['encoder-epoch-99-avg-1.int8.onnx', 'encoder.onnx'],
    ['decoder-epoch-99-avg-1.int8.onnx', 'decoder.onnx'],
    ['joiner-epoch-99-avg-1.int8.onnx', 'joiner.onnx'],
    ['tokens.txt', 'tokens.txt'],
  ];
  const modelDirectory = '/audio-receiver-asr';
<<<<<<< HEAD
  const minimumSpeechRmsDbfs = -60;
  const minimumSpeechRms = 10 ** (minimumSpeechRmsDbfs / 20);
=======
>>>>>>> main
  let activeSession = null;

  function notifyStatus(session, message) {
    if (activeSession === session) session.onStatus(message);
  }

  async function loadModel(session, module) {
    const fs = module.FS;
    if (!fs.analyzePath(modelDirectory).exists) fs.mkdir(modelDirectory);

    for (const [sourceName, targetName] of modelFiles) {
      const targetPath = `${modelDirectory}/${targetName}`;
      if (fs.analyzePath(targetPath).exists) continue;
      notifyStatus(session, `Downloading speech model: ${targetName}`);
      const response = await fetch(`${modelBase}${sourceName}`, {
        signal: session.abortController.signal,
        cache: 'force-cache',
      });
      if (!response.ok) {
        throw new Error(
          `Could not download ${targetName} (HTTP ${response.status})`,
        );
      }
      fs.writeFile(targetPath, new Uint8Array(await response.arrayBuffer()));
    }
  }

  function resample(samples, inputRate, outputRate) {
    if (inputRate === outputRate) return samples;
    const ratio = inputRate / outputRate;
    const outputLength = Math.floor(samples.length / ratio);
    const output = new Float32Array(outputLength);
    if (inputRate > outputRate) {
      for (let i = 0; i < outputLength; i += 1) {
        const start = i * ratio;
        const end = (i + 1) * ratio;
        let weightedSamples = 0;
        for (let j = Math.floor(start); j < Math.ceil(end); j += 1) {
          const overlap = Math.max(
            0,
            Math.min(end, j + 1) - Math.max(start, j),
          );
          weightedSamples += samples[j] * overlap;
        }
        output[i] = weightedSamples / ratio;
      }
      return output;
    }

    for (let i = 0; i < outputLength; i += 1) {
      const position = i * ratio;
      const left = Math.floor(position);
      const right = Math.min(left + 1, samples.length - 1);
      const fraction = position - left;
      output[i] = samples[left] * (1 - fraction) + samples[right] * fraction;
    }
    return output;
  }

<<<<<<< HEAD
  function measureLevel(samples) {
    let squaredSum = 0;
    let peak = 0;
    for (const sample of samples) {
      squaredSum += sample * sample;
      peak = Math.max(peak, Math.abs(sample));
    }
    return {
      rms: Math.sqrt(squaredSum / samples.length),
      peak,
    };
  }

  function toDbfs(amplitude) {
    return 20 * Math.log10(Math.max(amplitude, 1e-8));
  }

=======
>>>>>>> main
  async function stopSession(session) {
    if (session.stopped) return;
    session.stopped = true;
    session.abortController.abort();
    session.track?.removeEventListener('ended', session.onTrackEnded);
<<<<<<< HEAD
    session.audioContext.removeEventListener(
      'statechange',
      session.onAudioContextStateChange,
    );
=======
>>>>>>> main
    session.source?.disconnect();
    session.processor?.disconnect();
    session.silentOutput?.disconnect();
    if (session.recognizerStream) session.recognizerStream.free();
    if (session.recognizer) session.recognizer.free();
    if (session.audioContext && session.audioContext.state !== 'closed') {
      await session.audioContext.close();
    }
  }

  async function start(stream, audioContext, onTranscript, onStatus) {
    if (activeSession) await stop(activeSession);

    const session = {
      abortController: new AbortController(),
      audioContext,
      onTranscript,
      onStatus,
<<<<<<< HEAD
      smoothedRms: null,
      meterPeak: 0,
      lastMeterUpdate: 0,
=======
>>>>>>> main
      stopped: false,
    };
    activeSession = session;

    try {
      const module = globalThis.Module;
      if (!module?.FS || typeof globalThis.createOnlineRecognizer !== 'function') {
        throw new Error('The local speech recognition runtime did not load');
      }

      await loadModel(session, module);
      if (activeSession !== session) return;

      notifyStatus(session, 'Initializing English speech recognizer');
      session.recognizer = globalThis.createOnlineRecognizer(module, {
        featConfig: { sampleRate: 16000, featureDim: 80 },
        modelConfig: {
          transducer: {
            encoder: `${modelDirectory}/encoder.onnx`,
            decoder: `${modelDirectory}/decoder.onnx`,
            joiner: `${modelDirectory}/joiner.onnx`,
          },
          paraformer: { encoder: '', decoder: '' },
          zipformer2Ctc: { model: '' },
          nemoCtc: { model: '' },
          toneCtc: { model: '' },
          tokens: `${modelDirectory}/tokens.txt`,
          numThreads: 1,
          provider: 'cpu',
          debug: 0,
          modelType: 'zipformer',
          modelingUnit: 'cjkchar',
          bpeVocab: '',
        },
        decodingMethod: 'greedy_search',
        maxActivePaths: 4,
        enableEndpoint: 1,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20,
        hotwordsFile: '',
        hotwordsScore: 1.5,
        ctcFstDecoderConfig: { graph: '', maxActive: 3000 },
        ruleFsts: '',
        ruleFars: '',
      });
      session.recognizerStream = session.recognizer.createStream();

<<<<<<< HEAD
=======
      await session.audioContext.resume();
>>>>>>> main
      session.track = stream.getAudioTracks()[0];
      if (!session.track) throw new Error('The remote audio track is unavailable');
      session.onTrackEnded = () => {
        notifyStatus(session, 'Remote audio ended');
        void stopSession(session);
      };
      session.track.addEventListener('ended', session.onTrackEnded, { once: true });

      session.source = session.audioContext.createMediaStreamSource(stream);
      session.processor = session.audioContext.createScriptProcessor(4096, 1, 1);
      session.silentOutput = session.audioContext.createGain();
      session.silentOutput.gain.value = 0;
<<<<<<< HEAD
      session.onAudioContextStateChange = () => {
        if (session.audioContext.state === 'running') {
          notifyStatus(session, 'Transcribing locally (English) - measuring input');
        } else if (session.audioContext.state === 'suspended') {
          notifyStatus(
            session,
            'Transcription ready - click Enable audio to allow browser audio processing',
          );
        }
      };
      session.audioContext.addEventListener(
        'statechange',
        session.onAudioContextStateChange,
      );
=======
>>>>>>> main
      session.processor.onaudioprocess = (event) => {
        if (session.stopped) return;
        const samples = resample(
          event.inputBuffer.getChannelData(0),
          session.audioContext.sampleRate,
          16000,
        );
        if (samples.length === 0) return;

<<<<<<< HEAD
        const { rms, peak } = measureLevel(samples);
        session.smoothedRms =
          session.smoothedRms === null
            ? rms
            : session.smoothedRms * 0.8 + rms * 0.2;
        session.meterPeak = Math.max(session.meterPeak, peak);
        const now = performance.now();
        if (now - session.lastMeterUpdate >= 1000) {
          const rmsDbfs = toDbfs(session.smoothedRms);
          const peakDbfs = toDbfs(session.meterPeak);
          notifyStatus(
            session,
            `Transcribing locally (English) - input RMS ${rmsDbfs.toFixed(0)} dBFS, peak ${peakDbfs.toFixed(0)} dBFS`,
          );
          session.lastMeterUpdate = now;
          session.meterPeak = 0;
        }

        const recognitionSamples = rms < minimumSpeechRms
          ? new Float32Array(samples.length)
          : samples;
        session.recognizerStream.acceptWaveform(16000, recognitionSamples);
=======
        session.recognizerStream.acceptWaveform(16000, samples);
>>>>>>> main
        while (session.recognizer.isReady(session.recognizerStream)) {
          session.recognizer.decode(session.recognizerStream);
        }

        const result = session.recognizer.getResult(session.recognizerStream).text;
        const endpoint = session.recognizer.isEndpoint(session.recognizerStream);
        if (result || endpoint) session.onTranscript(result, endpoint);
        if (endpoint) session.recognizer.reset(session.recognizerStream);
      };
      session.source.connect(session.processor);
      session.processor.connect(session.silentOutput);
      session.silentOutput.connect(session.audioContext.destination);
<<<<<<< HEAD
      session.onAudioContextStateChange();
=======
      notifyStatus(session, 'Transcribing locally (English)');
>>>>>>> main
    } catch (error) {
      if (activeSession === session) {
        activeSession = null;
        await stopSession(session);
        notifyStatus(session, `Transcription failed: ${error}`);
      }
      throw error;
    }
  }

  async function stop(session = activeSession) {
    if (!session) return;
    if (activeSession === session) activeSession = null;
    await stopSession(session);
  }

  globalThis.speechTranscriber = { start, stop };
})();
