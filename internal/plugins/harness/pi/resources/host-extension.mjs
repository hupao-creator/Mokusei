// Executed only by the external Pi extension host. Configuration and decisions
// are supplied by Go; this resource registers native callbacks and forwards IPC.
import { Socket } from 'node:net';
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
const config = JSON.parse(readFileSync(process.env.MOKUSEI_PI_BRIDGE_CONFIG, 'utf8'));
export default function(pi) {
  const channel = new Socket({fd: 3, readable: true, writable: true});
  const lines = createInterface({input: channel});
  const pending = new Map();
  let sequence = 0;
  let closed = false;
  const write = value => channel.write(JSON.stringify(value) + '\n');
  const rejectAll = () => {
    closed = true;
    for (const item of pending.values()) { item.clean(); item.reject(new Error('Mokusei Host bridge disconnected')); }
    pending.clear();
  };
  channel.on('error', rejectAll);
  channel.on('close', rejectAll);
  lines.on('line', line => {
    let value;
    try { value = JSON.parse(line); } catch { channel.destroy(); return; }
    const item = pending.get(value.id);
    if (!item) return;
    pending.delete(value.id); item.clean();
    if (value.error !== undefined) item.reject(new Error(value.error));
    else item.resolve({content: [{type: 'text', text: JSON.stringify(value.result)}], details: {}});
  });
  for (const tool of config.tools) pi.registerTool({...tool, label: tool.name,
    execute(callId, args, signal) {
      if (closed || channel.destroyed || signal?.aborted) return Promise.reject(new Error('Mokusei Host call cancelled'));
      const id = String(++sequence);
      return new Promise((resolve, reject) => {
        const abort = () => {
          if (!pending.delete(id)) return;
          signal?.removeEventListener('abort', abort);
          write({type: 'cancel', id}); reject(new Error('Mokusei Host call cancelled'));
        };
        pending.set(id, {resolve, reject, clean: () => signal?.removeEventListener('abort', abort)});
        signal?.addEventListener('abort', abort, {once: true});
        write({type: 'call', id, callId, name: tool.name, arguments: args});
      });
    }
  });
  pi.on('session_start', async () => {
    if (config.exclusive) pi.setActiveTools(config.tools.map(tool => tool.name));
    write({type: 'ready', tools: pi.getActiveTools()});
  });
  pi.on('before_agent_start', async event => {
    if (closed) throw new Error('Mokusei Host bridge disconnected');
    return {systemPrompt: config.exclusive ? config.instructions : [event.systemPrompt, config.instructions].filter(Boolean).join('\n\n')};
  });
  pi.on('session_shutdown', async () => { rejectAll(); lines.close(); channel.destroy(); });
}
