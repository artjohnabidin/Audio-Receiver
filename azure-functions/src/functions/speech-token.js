import { app } from '@azure/functions';
import { createSpeechTokenHandler } from '../speech-token-handler.js';

const handler = createSpeechTokenHandler();

app.http('speechToken', {
  route: 'speech/token',
  methods: ['POST', 'OPTIONS'],
  authLevel: 'anonymous',
  handler: (request, context) =>
    createSpeechTokenHandler({ log: context }) (request),
});