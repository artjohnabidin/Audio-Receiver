export const fallbackGroupId = '7d9f1c20-5a34-4b67-8c12-3e6f90a2b451';
const listenerDisplayName = 'Audio listener';

export function resolveGroupId(eventId) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(eventId)
    ? eventId.toLowerCase() : fallbackGroupId;
}

export function createReceiver({ CallClient, AzureCommunicationTokenCredential, createSilentAudioStream }, callbacks) {
  let agent;
  let credential;
  let client;
  let call;
  let closed = false;
  let timer;
  let streamVersion = 0;
  let playbackMuted = false;
  let cancelAgentWait;
  let silentAudio;
  const subscriptions = [];
  const subscribe = (target, event, handler) => {
    target.on(event, handler);
    subscriptions.push(() => target.off(event, handler));
  };
  const report = error => {
    if (!closed) callbacks.onError(String(error?.message || error));
  };
  const applyPlaybackMute = () => playbackMuted
    ? call.muteIncomingAudio()
    : call.unmuteIncomingAudio();
  const hasConnectedBroadcaster = () => call?.remoteParticipants.some(
    participant => participant.state === 'Connected'
      && participant.displayName !== listenerDisplayName,
  ) ?? false;
  const stateChanged = () => {
    if (closed) return;
    if (call.state === 'Disconnected') {
      callbacks.onStream(null);
      callbacks.onState('disconnected');
      clearTimeout(timer);
      const reason = call.callEndReason;
      if (reason?.code) report(new Error(`ACS call ended (${reason.code}/${reason.subCode || 0})`));
    } else if (call.state === 'Connected') {
      clearTimeout(timer);
      void applyPlaybackMute().catch(report);
      callbacks.onState(hasConnectedBroadcaster() ? 'connected' : 'waitingForBroadcaster');
    } else {
      callbacks.onState('connecting');
    }
  };
  const audioChanged = async () => {
    const version = ++streamVersion;
    try {
      const remote = call.state === 'Connected' && hasConnectedBroadcaster()
        ? call.remoteAudioStreams[0]
        : null;
      const stream = remote ? await remote.getMediaStream() : null;
      if (!closed && version === streamVersion) {
        if (stream) await applyPlaybackMute();
        callbacks.onStream(stream);
      }
    } catch (error) { report(error); }
  };
  const participants = new Set();
  const participantChanged = () => {
    stateChanged();
    void audioChanged();
  };
  const participantsChanged = () => {
    for (const participant of call.remoteParticipants) {
      if (!participants.has(participant)) {
        participants.add(participant);
        subscribe(participant, 'stateChanged', participantChanged);
        subscribe(participant, 'displayNameChanged', participantChanged);
      }
    }
    stateChanged();
    void audioChanged();
  };
  const receiver = {
    getDiagnostics() {
      return {
        agentConnectionState: agent?.connectionState || 'NotInitialized',
        callState: call?.state || 'NotJoined',
        callEndReason: call?.callEndReason || null,
        remoteParticipants: call?.remoteParticipants.map(participant => participant.state) || [],
        remoteAudioStreams: call?.remoteAudioStreams.length || 0,
      };
    },
    async setPlaybackMuted(muted) {
      if (closed || !call) return;
      playbackMuted = muted;
      if (muted) await call.muteIncomingAudio();
      else await call.unmuteIncomingAudio();
    },
    async start(eventId, fetchToken) {
      try {
        const token = await fetchToken();
        if (closed) return;
        credential = new AzureCommunicationTokenCredential({
          token, tokenRefresher: fetchToken, refreshProactively: true,
        });
        client = new CallClient();
        const createdAgent = await client.createCallAgent(credential, { displayName: listenerDisplayName });
        if (closed) { await createdAgent.dispose(); return; }
        agent = createdAgent;
        timer = setTimeout(() => {
          report(new Error('ACS connection timed out after 45 seconds'));
          void receiver.stop();
        }, 45000);
        if (agent.connectionState !== 'Connected') {
          await new Promise((resolve, reject) => {
            cancelAgentWait = () => reject(new Error('ACS join cancelled'));
            subscribe(agent, 'connectionStateChanged', event => {
              if (event.newValue === 'Connected') {
                cancelAgentWait = null;
                resolve();
              } else if (event.reason === 'invalidToken') {
                reject(new Error('ACS rejected the calling token. Please sign in again.'));
              }
            });
            if (agent.connectionState === 'Connected') {
              cancelAgentWait = null;
              resolve();
            }
          });
        }
        if (closed) return;
        silentAudio = createSilentAudioStream();
        call = agent.join({ groupId: resolveGroupId(eventId) }, {
          audioOptions: { muted: true, localAudioStreams: [silentAudio.stream] },
        });
        subscribe(call, 'stateChanged', () => { stateChanged(); void audioChanged(); });
        subscribe(call, 'remoteAudioStreamsUpdated', () => { void audioChanged(); });
        subscribe(call, 'remoteParticipantsUpdated', participantsChanged);
        participantsChanged();
        await audioChanged();
      } catch (error) {
        await receiver.stop();
        throw error;
      }
    },
    async stop() {
      if (closed) return;
      closed = true;
      cancelAgentWait?.();
      cancelAgentWait = null;
      ++streamVersion;
      clearTimeout(timer);
      subscriptions.splice(0).forEach(unsubscribe => unsubscribe());
      callbacks.onStream(null);
      callbacks.onState('disconnected');
      try { if (call) await call.hangUp({ forEveryone: false }); }
      finally {
        try { await agent?.dispose(); }
        finally {
          try { await client?.dispose(); }
          finally {
            try { credential?.dispose(); }
            finally { await silentAudio?.dispose(); }
          }
        }
      }
    },
  };
  return receiver;
}