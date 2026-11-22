export function cleanNoteText(raw) {
  return raw.trim();
}

export function formatStatus(count) {
  return count == 1 ? "1 note" : `${count} notes`
}
