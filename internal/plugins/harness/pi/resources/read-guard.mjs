// Fail closed at the external Pi tool-call boundary. Go verifies this command
// was loaded from this exact extension before submitting a history question.
export default function(pi) {
  pi.on('tool_call', () => ({block: true, reason: 'Thread reads may only answer from conversation history.'}));
  pi.registerCommand('mokusei-thread-read-guard', {handler: async () => {}});
}
