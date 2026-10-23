
(function () {
  let activeSession = null;

  function setStatus(session, message) {
    if (activeSession === session && !session.stopped) {
      session.onStatus(message);
    }
  }

  function closeRecognizer(session) {
    session.stopped = true;
    try {
      session.recognizer?.close();
    } finally {
      session.audioConfig?.close?.();
    }
  }

  function stopSession(session) {
    if (!session || session.stopped) return Promise.resolve();

    if (activeSession === session) {
      activeSession = null;
    }

    return new Promise((resolve) => {
      if (!session.started) {
        closeRecognizer(session);
        resolve();
        return;
      }

      session.recognizer.stopContinuousRecognitionAsync(
        () => {
          closeRecognizer(session);
          resolve();
        },
        () => {
          closeRecognizer(session);
          resolve();
        }
      );
    });
  }

  async function start(stream, token, region, onTranscript, onStatus) {
    if (activeSession) {
      await stopSession(activeSession);
    }

    const sdk = globalThis.SpeechSDK;

    if (!sdk) {
      throw new Error('Azure Speech SDK did not load');
    }

    if (!token || !region) {
      throw new Error('Missing Azure Speech authorization');
    }

    const session = {
      onTranscript,
      onStatus,
      started: false,
      stopped: false,
    };

    activeSession = session;

    try {
      const speechConfig =
        sdk.SpeechConfig.fromAuthorizationToken(token, region);

      session.speechConfig = speechConfig;

      // Automatically identify Japanese or US English.
      const autoDetect =
        sdk.AutoDetectSourceLanguageConfig.fromLanguages([
          'ja-JP',
          'en-US',
        ]);

      session.audioConfig = sdk.AudioConfig.fromStreamInput(stream);

      // Use automatic language identification instead of
      // hard-coding speechRecognitionLanguage = 'en-US'.
      session.recognizer = sdk.SpeechRecognizer.FromConfig(
        speechConfig,
        autoDetect,
        session.audioConfig
      );

      session.recognizer.recognizing = (_sender, event) => {
        if (session.stopped) return;

        const text = event.result?.text?.trim();

        if (text) {
          onTranscript(text, false);
        }
      };

      session.recognizer.recognized = (_sender, event) => {
        if (session.stopped) return;

        if (
          event.result?.reason === sdk.ResultReason.RecognizedSpeech
        ) {
          const text = event.result.text?.trim();

          if (text) {
            onTranscript(text, true);
          }
        }
      };

      session.recognizer.canceled = (_sender, event) => {
        if (session.stopped) return;

        const details =
          event.errorDetails ||
          event.reason ||
          'Recognition canceled';

        setStatus(session, `Azure Speech canceled: ${details}`);

        void stopSession(session);
      };

      setStatus(session, 'Starting Japanese/English recognition');

      await new Promise((resolve, reject) => {
        session.recognizer.startContinuousRecognitionAsync(
          resolve,
          reject
        );
      });

      if (session.stopped || activeSession !== session) {
        await stopSession(session);
        return;
      }

      session.started = true;

      setStatus(
        session,
        'Transcribing with automatic Japanese/English detection'
      );
    } catch (error) {
      if (activeSession === session) {
        activeSession = null;
      }

      closeRecognizer(session);
      throw error;
    }
  }

  function updateToken(token) {
    if (!activeSession || activeSession.stopped || !token) {
      return false;
    }

    activeSession.recognizer.authorizationToken = token;
    return true;
  }

  async function stop() {
    await stopSession(activeSession);
  }

  globalThis.azureSpeechTranscriber = {
    start,
    updateToken,
    stop,
  };
})();
