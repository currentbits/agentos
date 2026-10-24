AgentOS installer data partition

Interactive install: boot this stick and follow the menu on screen.

Unattended install: copy agentos.env.example to agentos.env on this partition,
set AGENTOS_INSTALL_DISK and whatever else you need, then boot. The installer
erases that disk without asking.

agentos.env may contain secrets (API keys, Tailscale key, password hash).
Delete it from this stick after installing.
