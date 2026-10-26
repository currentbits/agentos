export function ErrorText({ error }: { error: string | null | undefined }) {
  return error ? <p className="error" role="alert">{error}</p> : null;
}
