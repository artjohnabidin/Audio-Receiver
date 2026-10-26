import { CallClient, LocalAudioStream } from '@azure/communication-calling';
import { AzureCommunicationTokenCredential } from '@azure/communication-common';
import { AzureLogger, setLogLevel } from '@azure/logger';
import { createReceiver } from './acs_receiver.mjs';

let activeReceiver;
const diagnosticLogs = [];

function createSilentAudioStream() {
  const context = new AudioContext();
  try {
    const mediaStream = context.createMediaStreamDestination().stream;
    mediaStream.getAudioTracks().forEach(track => { track.enabled = false; });
    return {
      stream: new LocalAudioStream(mediaStream),
      async dispose() {
        mediaStream.getTracks().forEach(track => track.stop());
        await context.close();
      },
    };
  } catch (error) {
    void context.close();
    throw error;
  }
}

globalThis.acsAudioReceiver = {
  enableDiagnostics() {
    AzureLogger.log = (...values) => {
      const message = values.map(value => typeof value === 'string' ? value : '[SDK data]').join(' ')
        .replace(/https?:\/\/[^\s)"']+/g, value => {
          try { const url = new URL(value); return url.origin + url.pathname; }
          catch { return '[URL]'; }
        })
        .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
        .replace(/[A-Za-z0-9_+=/-]{40,}/g, '[redacted]');
      diagnosticLogs.push(message.slice(0, 1500));
      if (diagnosticLogs.length > 1000) diagnosticLogs.shift();
    };
    setLogLevel('verbose');
  },
  getDiagnostics() {
    return { ...activeReceiver?.getDiagnostics(), logs: [...diagnosticLogs] };
  },
  create(onState, onStream, onError) {
    activeReceiver = createReceiver({ CallClient, AzureCommunicationTokenCredential, createSilentAudioStream }, {
      onState, onStream, onError,
    });
    return activeReceiver;
  },
};