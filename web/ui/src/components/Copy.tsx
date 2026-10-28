// A value to paste somewhere else, with a Copy button.
export function Copy({ text, label }: { text: string; label?: string }) {
  return (
    <div className="copy">
      {label && <span>{label}</span>}
      <code>{text}</code>
      <button type="button" onClick={() => void navigator.clipboard?.writeText(text)}>Copy</button>
    </div>
  );
}
