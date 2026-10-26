// ponytail: native confirm() is the confirmation dialog; swap for a modal if it ever needs styling.
export const confirmAction = (message: string): boolean => window.confirm(message);
