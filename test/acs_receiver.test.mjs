import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFileSync } from 'node:fs';
import { createReceiver, resolveGroupId, fallbackGroupId } from '../web/acs_receiver.mjs';

test('group locator matches Swift UUID and development fallback', () => {
  const swift = readFileSync(new URL('../../Audio-Streaming/AudioStreaming/Core/Configuration/ACSCallConfig.swift', import.meta.url), 'utf8');
  assert.ok(swift.toLowerCase().includes(fallbackGroupId));
  assert.equal(resolveGroupId('AABBCCDD-1234-5678-9012-123456789ABC'), 'aabbccdd-1234-5678-9012-123456789abc');
  assert.equal(resolveGroupId('legacy-event'), fallbackGroupId);
});

function fixture({ agentState = 'Connected' } = {}) {
  const call = Object.assign(new EventEmitter(), {
    state: 'Connected', remoteParticipants: [], remoteAudioStreams: [],
    async hangUp(options) { call.hangUpOptions = options; },
    async muteIncomingAudio() { call.playbackMuted = true; },
    async unmuteIncomingAudio() { call.playbackMuted = false; },
  });
  const states = [];
  const streams = [];
  let join;
  let disposed = false;
  let clientDisposed = false;
  let credentialOptions;
  const silentStream = {};
  let silentStreamDisposed = false;
  const agent = Object.assign(new EventEmitter(), {
    connectionState: agentState,
    join(locator, options) { join = { locator, options }; return call; },
    async dispose() { disposed = true; },
  });
  const receiver = createReceiver({
    createSilentAudioStream() {
      return { stream: silentStream, async dispose() { silentStreamDisposed = true; } };
    },
    AzureCommunicationTokenCredential: class {
      constructor(options) { credentialOptions = options; }
      dispose() {}
    },
    CallClient: class {
      async dispose() { clientDisposed = true; }
      async createCallAgent() {
        return agent;
      }
    },
  }, { onState: value => states.push(value), onStream: value => streams.push(value), onError: assert.fail });
  return { receiver, call, agent, states, streams, silentStream,
    get silentStreamDisposed() { return silentStreamDisposed; },
    get join() { return join; }, get disposed() { return disposed; },
    get clientDisposed() { return clientDisposed; },
    get credentialOptions() { return credentialOptions; },
  };
}

test('another listener does not look like the broadcaster or provide audio', async () => {
  const context = fixture();
  await context.receiver.start('legacy-event', async () => 'token');
  assert.equal(context.join.locator.groupId, fallbackGroupId);
  assert.equal(context.join.options.audioOptions.muted, true);
  assert.deepEqual(context.join.options.audioOptions.localAudioStreams, [context.silentStream]);
  assert.equal(context.join.options.videoOptions, undefined);
  assert.equal(context.states.at(-1), 'waitingForBroadcaster');
  assert.equal(context.receiver.getDiagnostics().callState, 'Connected');
  assert.deepEqual(context.receiver.getDiagnostics().remoteParticipants, []);
  const otherListener = Object.assign(new EventEmitter(), {
    state: 'Connected', displayName: 'Audio listener',
  });
  context.call.remoteParticipants = [otherListener];
  context.call.emit('remoteParticipantsUpdated');
  assert.equal(context.states.at(-1), 'waitingForBroadcaster');
  const listenerStream = {};
  context.call.remoteAudioStreams = [{ getMediaStream: async () => listenerStream }];
  context.call.emit('remoteAudioStreamsUpdated');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.streams.at(-1), null);
  otherListener.displayName = 'Mobile broadcaster';
  otherListener.emit('displayNameChanged');
  assert.equal(context.states.at(-1), 'connected');
  otherListener.displayName = 'Audio listener';
  otherListener.emit('displayNameChanged');
  assert.equal(context.states.at(-1), 'waitingForBroadcaster');

  const broadcaster = Object.assign(new EventEmitter(), {
    state: 'Connected', displayName: 'Mobile broadcaster',
  });
  context.call.remoteParticipants = [otherListener, broadcaster];
  context.call.emit('remoteParticipantsUpdated');
  assert.equal(context.states.at(-1), 'connected');
  const stream = {};
  context.call.remoteAudioStreams = [{ getMediaStream: async () => stream }];
  context.call.emit('remoteAudioStreamsUpdated');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.streams.at(-1), stream);
  context.call.remoteParticipants = [otherListener];
  context.call.emit('remoteParticipantsUpdated');
  assert.equal(context.states.at(-1), 'waitingForBroadcaster');
  context.call.remoteParticipants = [broadcaster];
  context.call.emit('remoteParticipantsUpdated');
  assert.equal(context.states.at(-1), 'connected');
  await context.receiver.setPlaybackMuted(true);
  assert.equal(context.call.playbackMuted, true);
  await context.receiver.setPlaybackMuted(false);
  assert.equal(context.call.playbackMuted, false);
  await context.receiver.stop();
  await context.receiver.stop();
  assert.deepEqual(context.call.hangUpOptions, { forEveryone: false });
  assert.equal(context.disposed, true);
  assert.equal(context.clientDisposed, true);
  assert.equal(context.silentStreamDisposed, true);
  assert.equal(context.call.listenerCount('stateChanged'), 0);
  assert.equal(otherListener.listenerCount('stateChanged'), 0);
  assert.equal(broadcaster.listenerCount('stateChanged'), 0);
});

test('attaches audio when the mobile broadcaster is already live', async () => {
  const context = fixture();
  const stream = {};
  context.call.remoteParticipants = [Object.assign(new EventEmitter(), {
    state: 'Connected', displayName: 'Mobile broadcaster',
  })];
  context.call.remoteAudioStreams = [{ getMediaStream: async () => stream }];
  await context.receiver.start('event-1', async () => 'token');
  assert.equal(context.states.at(-1), 'connected');
  assert.equal(context.streams.at(-1), stream);
  assert.equal(context.call.playbackMuted, false);
  await context.receiver.stop();
});

test('attaches audio when the broadcaster connects after the listener', async () => {
  const context = fixture();
  await context.receiver.start('event-1', async () => 'token');
  const participant = Object.assign(new EventEmitter(), {
    state: 'Connecting', displayName: 'Mobile broadcaster',
  });
  context.call.remoteParticipants = [participant];
  context.call.emit('remoteParticipantsUpdated');
  assert.equal(context.states.at(-1), 'waitingForBroadcaster');
  const stream = {};
  context.call.remoteAudioStreams = [{ getMediaStream: async () => stream }];
  participant.state = 'Connected';
  participant.emit('stateChanged');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.states.at(-1), 'connected');
  assert.equal(context.streams.at(-1), stream);
  assert.equal(context.call.playbackMuted, false);
  await context.receiver.setPlaybackMuted(true);
  participant.emit('stateChanged');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.call.playbackMuted, true);
  await context.receiver.stop();
});

test('waits for call-agent registration before joining', async () => {
  const context = fixture({ agentState: 'Disconnected' });
  const starting = context.receiver.start('event-1', async () => 'token');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.join, undefined);
  context.agent.connectionState = 'Connected';
  context.agent.emit('connectionStateChanged', { newValue: 'Connected', oldValue: 'Disconnected' });
  await starting;
  assert.equal(context.join.locator.groupId, fallbackGroupId);
  await context.receiver.stop();
});

test('leaving during agent registration never joins', async () => {
  const context = fixture({ agentState: 'Disconnected' });
  const starting = context.receiver.start('event-1', async () => 'token');
  const rejected = assert.rejects(starting, /ACS join cancelled/);
  await new Promise(resolve => setImmediate(resolve));
  await context.receiver.stop();
  await rejected;
  assert.equal(context.join, undefined);
  assert.equal(context.agent.listenerCount('connectionStateChanged'), 0);
});

test('leaving while token fetch is pending never joins', async () => {
  const context = fixture();
  let complete;
  const start = context.receiver.start('event', () => new Promise(resolve => { complete = resolve; }));
  await context.receiver.stop();
  complete('token');
  await start;
  assert.equal(context.join, undefined);
});

test('uses renewable ACS credentials and forwards an event UUID', async () => {
  const context = fixture();
  let refreshes = 0;
  const fetchToken = async () => `token-${++refreshes}`;
  const eventId = 'AABBCCDD-1234-5678-9012-123456789ABC';
  await context.receiver.start(eventId, fetchToken);
  assert.equal(context.join.locator.groupId, eventId.toLowerCase());
  assert.equal(context.credentialOptions.refreshProactively, true);
  assert.equal(context.credentialOptions.token, 'token-1');
  assert.equal(await context.credentialOptions.tokenRefresher(), 'token-2');
  await context.receiver.stop();
});

test('disconnection clears audio instead of restoring a stale stream', async () => {
  const context = fixture();
  context.call.remoteAudioStreams = [{ getMediaStream: async () => ({}) }];
  await context.receiver.start('event', async () => 'token');
  context.call.state = 'Disconnected';
  context.call.emit('stateChanged');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.streams.at(-1), null);
  assert.equal(context.states.at(-1), 'disconnected');
  await context.receiver.stop();
});

test('late incoming audio cannot reactivate a stopped listener', async () => {
  const context = fixture();
  await context.receiver.start('event', async () => 'token');
  context.call.remoteParticipants = [Object.assign(new EventEmitter(), {
    state: 'Connected', displayName: 'Mobile broadcaster',
  })];
  let complete;
  context.call.remoteAudioStreams = [{ getMediaStream: () => new Promise(resolve => { complete = resolve; }) }];
  context.call.emit('remoteAudioStreamsUpdated');
  await context.receiver.stop();
  complete({});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(context.streams.at(-1), null);
});