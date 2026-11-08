"""Execute the bundled Pi history-read guard without an installed native CLI."""
from pathlib import Path
import subprocess


# Record Pi's registration boundary, then invoke the production callback. The
# expected decision is literal: a registration marker cannot prove enforcement.
PROBE = r"""
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

const {default: register} = await import(pathToFileURL(process.argv[2]).href);
const events = new Map();
const commands = new Map();
register({
  on(name, callback) {
    assert.equal(events.has(name), false, `duplicate event registration: ${name}`);
    events.set(name, callback);
  },
  registerCommand(name, command) {
    assert.equal(commands.has(name), false, `duplicate command registration: ${name}`);
    commands.set(name, command);
  },
});
assert.equal(typeof commands.get('mokusei-thread-read-guard')?.handler, 'function',
             'the native guard verification command must be registered');
const guard = events.get('tool_call');
assert.equal(typeof guard, 'function', 'the tool_call guard must be registered');

for (const toolName of ['bash', 'write', 'edit', 'read', 'custom_tool']) {
  const decision = await guard({type: 'tool_call', toolCallId: `read-${toolName}`,
                                toolName, input: {}}, {});
  assert.equal(decision?.block, true, `history reads must block ${toolName}`);
  assert.equal(typeof decision.reason, 'string', `${toolName} needs a refusal reason`);
  assert.ok(decision.reason.trim(), `${toolName} needs a nonempty refusal reason`);
}
console.log('Pi history-read guard blocked all native and custom tool probes.');
"""


def main():
    root = Path(__file__).resolve().parents[3]
    guard = root / "internal/plugins/harness/pi/resources/read-guard.mjs"
    result = subprocess.run(["node", "--input-type=module", "-", str(guard)],
                            input=PROBE, text=True, cwd=root, timeout=15)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
