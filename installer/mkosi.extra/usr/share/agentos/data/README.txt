AgentOS installer data partition

Interactive install: boot this stick and follow the menu on screen.

Unattended install: copy agentos.env.example to agentos.env on this partition,
set AGENTOS_INSTALL_DISK and whatever else you need, then boot. The installer
erases that disk without asking.

agentos.env may contain secrets (API keys, Tailscale key, password hash).
After an unattended install the installer deletes it from this stick; if that
fails it powers off instead of rebooting, and you must delete it by hand.

Virtual CD (IPMI/BMC virtual media): the .img also boots as a CD. For an
unattended install, put agentos.env on this partition of the image file before
attaching it. A CD is read-only, so the installer cannot delete agentos.env:
it powers off after installing. Detach the CD and delete the image's copy.

Boot the installed system in UEFI mode, and remove this stick after installing.
Under BIOS/CSM, another AgentOS disk or this stick can take over the boot.
