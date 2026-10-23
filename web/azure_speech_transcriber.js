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
    if (activeSession === session) activeSession = null;
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
        },
      );
    });
  }

  async function start(stream, token, region, onTranscript, onStatus) {
    if (activeSession) await stopSession(activeSession);
    const sdk = globalThis.SpeechSDK;
    if (!sdk) throw new Error('Azure Speech SDK did not load');
    if (!token || !region) throw new Error('Missing Azure Speech authorization');

    const session = {
      onTranscript,
      onStatus,
      started: false,
      stopped: false,
    };
    activeSession = session;

    try {
      const speechConfig = sdk.SpeechConfig.fromAuthorizationToken(token, region);
      speechConfig.speechRecognitionLanguage = 'en-US';
      session.speechConfig = speechConfig;
      session.audioConfig = sdk.AudioConfig.fromStreamInput(stream);
      session.recognizer = new sdk.SpeechRecognizer(
        speechConfig,
        session.audioConfig,
      );
      session.recognizer.recognizing = (_sender, event) => {
        const text = event.result?.text?.trim();
        if (text && !session.stopped) onTranscript(text, false);
      };
      session.recognizer.recognized = (_sender, event) => {
        if (
          event.result?.reason === sdk.ResultReason.RecognizedSpeech &&
          event.result.text.trim() &&
          !session.stopped
        ) {
          onTranscript(event.result.text.trim(), true);
        }
      };
      session.recognizer.canceled = (_sender, event) => {
        if (session.stopped) return;
        const details = event.errorDetails || event.reason || 'Recognition canceled';
        setStatus(session, `Azure Speech canceled: ${details}`);
        void stopSession(session);
      };

      setStatus(session, 'Starting Azure Speech recognition');
      await new Promise((resolve, reject) => {
        session.recognizer.startContinuousRecognitionAsync(resolve, reject);
      });
      if (session.stopped || activeSession !== session) {
        await stopSession(session);
        return;
      }
      session.started = true;
      setStatus(session, 'Transcribing with Azure Speech (English)');
    } catch (error) {
      if (activeSession === session) activeSession = null;
      closeRecognizer(session);
      throw error;
    }
  }

  function updateToken(token) {
    if (!activeSession || activeSession.stopped || !token) return false;
    activeSession.recognizer.authorizationToken = token;
    return true;
  }

  async function stop() {
    await stopSession(activeSession);
  }

  globalThis.azureSpeechTranscriber = { start, updateToken, stop };
})();