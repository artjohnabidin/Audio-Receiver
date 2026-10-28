
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
      session.transcriber?.close();
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

      session.transcriber.stopTranscribingAsync(
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

    let lastDetectedLanguage = 'speech';

    function getDetectedLanguage(result) {
      try {
        const detected =
          sdk.AutoDetectSourceLanguageResult.fromResult(result);

        const languageMap = {
          'ja-JP': 'nihongo',
          'en-US': 'english',
        };

        const language = languageMap[detected.language];

        if (language) {
          lastDetectedLanguage = language;
        }

        return lastDetectedLanguage;
      } catch (error) {
        console.warn('Could not determine detected language:', error);
        return 'unknown';
      }
    }

    try {
      const speechEndpoint = new URL(
        `wss://${region}.stt.speech.microsoft.com/speech/universal/v2`
      );
      const speechConfig = sdk.SpeechConfig.fromEndpoint(speechEndpoint);
      speechConfig.authorizationToken = token;

      speechConfig.setProperty(
        sdk.PropertyId.SpeechServiceConnection_LanguageIdMode,
        'Continuous'
      );
      speechConfig.setProperty(
        sdk.PropertyId.SpeechServiceResponse_DiarizeIntermediateResults,
        'true'
      );

      const autoDetect = sdk.AutoDetectSourceLanguageConfig.fromLanguages([
        'ja-JP',
        'en-US',
      ]);

      session.audioConfig = sdk.AudioConfig.fromStreamInput(stream);

      session.transcriber = sdk.ConversationTranscriber.FromConfig(
        speechConfig,
        autoDetect,
        session.audioConfig
      );

      session.transcriber.transcribing = (_sender, event) => {
        if (session.stopped) return;

        const result = event.result;
        const text = result?.text?.trim();

        if (text) {
          const language = getDetectedLanguage(result);

          console.info('[Azure Speech] Interim language:', language);
          console.info('[Azure Speech] Interim transcript:', text);

          setStatus(session, `Detected ${language}: ${text}`);
          onTranscript(text, result.speakerId ?? '', false);
        }
      };

      session.transcriber.transcribed = (_sender, event) => {
        if (session.stopped) {
          console.warn('[Azure] Callback ignored because session is stopped');
          return;
        }

        if (event.result?.reason === sdk.ResultReason.RecognizedSpeech) {
          const text = event.result.text?.trim();

          if (text) {
            const language = getDetectedLanguage(event.result);

            console.info('[Azure Speech] Language:', language);
            console.info('[Azure Speech] Final transcript:', text);

            setStatus(session, `Detected ${language}: ${text}`);
            onTranscript(text, event.result.speakerId ?? '', true);
          }
        } else {
          console.info(
            '[Azure Speech] Recognition result:',
            event.result?.reason
          );
        }
      };

      session.transcriber.canceled = (_sender, event) => {
        if (session.stopped) return;

        console.error('[Azure Speech] Recognition canceled', {
          reason: event.reason,
          errorCode: event.errorCode,
          errorDetails: event.errorDetails,
        });

        const details = [
          `Reason: ${event.reason}`,
          `Code: ${event.errorCode ?? 'unknown'}`,
          `Details: ${event.errorDetails ?? 'none'}`,
        ].join(' | ');

        setStatus(session, `Azure Speech canceled: ${details}`);

        void stopSession(session);
      };

      setStatus(session, 'Starting Japanese/English recognition');

      await new Promise((resolve, reject) => {
        session.transcriber.startTranscribingAsync(
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

    activeSession.transcriber.authorizationToken = token;
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
