const statusEl = document.getElementById("status");
const notesListEl = document.getElementById("notesList");

function renderNotes(notes) {
  notesListEl.textContent = "";
  for (const note of notes) {
    const li = document.createElement("li");
    li.textContent = note.text;
    notesListEl.appendChild(li);
  }
  statusEl.textContent = `${notes.length} notes`;
}

async function loadNotes() {
  try {
    const res = await fetch("/api/notes");
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    const notes = await res.json();
    renderNotes(notes);
  } catch(err) {
    statusEl.textContent = `Error loading notes: ${err.message}`;
  }
}

loadNotes();
