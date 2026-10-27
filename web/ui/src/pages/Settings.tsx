import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { SecretField } from '../components/SecretField';
import { type FieldSpec, SettingsForm } from '../components/SettingsForm';
import { SshKeys } from '../components/SshKeys';
import type { Me, Settings as SettingsData, Tailscale } from '../types';
import { usePoll } from '../usePoll';

const SECRETS: [string, string][] = [
  ['ANTHROPIC_API_KEY', 'Anthropic API key'], ['OPENAI_API_KEY', 'OpenAI API key'],
  ['GROK_CODE_XAI_API_KEY', 'xAI API key (Grok)'], ['CLAUDE_CODE_OAUTH_TOKEN', 'Claude Code OAuth token'],
];
const ACCESS: FieldSpec[] = [
  { key: 'AGENTOS_LAN_SSH', label: 'Allow SSH from the LAN (key-only)', type: 'bool' },
  { key: 'AGENTOS_CONSOLE', label: 'Local console', type: 'select', options: ['', 'headless', 'terminal'] },
  { key: 'AGENTOS_AUTO_REBOOT', label: 'Auto-reboot at 04:00 for kernel updates', type: 'bool' },
];
const DESKTOPS: FieldSpec[] = [
  { key: 'AGENTOS_MAX_DESKTOPS', label: 'Max desktops (1-16)', type: 'number' },
  { key: 'AGENTOS_SCREENSHOT_WIDTH', label: 'Screenshot width (640-1920)', type: 'number' },
  { key: 'AGENTOS_DESKTOP_IDLE_MINUTES', label: 'Stop idle desktops after (minutes, 0 = never)', type: 'number' },
];
const WEB: FieldSpec[] = [
  { key: 'AGENTOS_WEB_USERS', label: 'Allowed tailnet logins (comma-separated)', type: 'text' },
  { key: 'AGENTOS_WEB', label: 'Web UI enabled', type: 'bool' },
];

// AGENTOS_AUTO_REBOOT and AGENTOS_WEB default to on when unset: show unset as '1'.
const withDefaults = (v: Record<string, string>) => ({ ...v, AGENTOS_AUTO_REBOOT: v.AGENTOS_AUTO_REBOOT || '1', AGENTOS_WEB: v.AGENTOS_WEB || '1' });

export function Settings({ me }: { me: Me | null }) {
  const settings = usePoll(() => api<SettingsData>('/api/settings'));
  const ts = usePoll(() => api<Tailscale>('/api/system/tailscale'));
  const save = async (values: Record<string, string>) => {
    if (values.AGENTOS_WEB_USERS !== undefined) values = { ...values, AGENTOS_WEB_USERS: values.AGENTOS_WEB_USERS.replace(/\s+/g, '') };
    // Reload on failure too: keys saved before the failing one were written and applied.
    try {
      await api('/api/settings', 'PUT', { values });
    } finally {
      settings.reload();
    }
  };
  const saveOne = (key: string, value: string) => save({ [key]: value });
  const webGuard = (changed: Record<string, string>) => {
    const users = changed.AGENTOS_WEB_USERS;
    if (users !== undefined && me && !users.toLowerCase().split(',').map((u) => u.trim()).includes(me.login)) {
      if (!confirmAction(`${me.login} is not in the new list: you will lose access to this page. Continue?`)) return false;
    }
    return changed.AGENTOS_WEB !== '0' || confirmAction('Disable the web UI? You will need SSH or the console to turn it back on.');
  };
  const s = settings.data;
  return (
    <section>
      <h1>Settings</h1>
      <ErrorText error={settings.error} />
      {s && (
        <>
          <div className="panel">
            <h2>API keys and tokens</h2>
            <p className="hint">Use a dedicated, spend-capped key per AgentOS machine: a hijacked agent can read any key stored here.</p>
            {SECRETS.map(([k, label]) => <SecretField key={k} name={k} label={label} isSet={s.secrets[k]} onSave={saveOne} />)}
          </div>
          <div className="panel">
            <h2>Tailscale</h2>
            <p>State: {ts.data?.state ?? '…'} {ts.data?.dnsName && <code>{ts.data.dnsName}</code>} · serve: {ts.data?.serve ?? '…'}</p>
            <p className="hint">Use a single-use, pre-approved auth key tagged <code>tag:agentos</code>. See docs/tailscale-acl.md in the AgentOS repository, and <a href="https://tailscale.com/kb/1068/tags" target="_blank" rel="noreferrer">Tailscale tags</a>.</p>
            <SecretField name="TS_AUTHKEY" label="Auth key (tskey-auth-…)" onSave={saveOne} />
          </div>
          <SshKeys />
          <SettingsForm title="Access and console" fields={ACCESS} values={withDefaults(s.values)} onSave={save} />
          <SettingsForm title="Desktops" fields={DESKTOPS} values={s.values} onSave={save} />
          <SettingsForm title="Web UI" fields={WEB} values={withDefaults(s.values)} onSave={save} beforeSave={webGuard} />
        </>
      )}
    </section>
  );
}
